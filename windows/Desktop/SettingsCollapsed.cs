using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private CompactLayoutEditorView? compactEditor;
    private readonly Dictionary<string, StackPanel> compactGroups = new(), compactRows = new(), compactOptions = new();
    private readonly Dictionary<string, CheckBox> compactChecks = new();
    private readonly Dictionary<string, ComboBox> compactChoices = new();
    private readonly Dictionary<string, FrameworkElement> compactWindowRows = new();
    private readonly Dictionary<string, TextBlock> compactWindowValues = new();
    private TextBlock? compactNoProviders, compactRingDetail;
    private Button? compactAutomatic;
    private CompactProjection? compactProjection;
    private string compactProviderSignature = "";
    private bool revealQuotaGauge;

    private void OnShellProjectionChanged(string method)
    {
        if (method.Length > 0 && method != "projectCompactBar") return;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (!IsVisible) return;
            if (activePane is "notifications" or "deepseek") { RefreshValues(); return; }
            if (activePane != "collapsed") return;
            if (compactEditor == null || compactRows.Count == 0) { RebuildPane("collapsed"); RefreshValues(); }
            else RefreshValues();
        });
    }
    private void ClearCollapsed()
    {
        compactEditor?.CancelGesture(); if (compactEditor != null) compactEditor.IsEnabled = false;
        compactEditor = null; compactGroups.Clear(); compactRows.Clear(); compactOptions.Clear(); compactChecks.Clear(); compactChoices.Clear();
        compactWindowRows.Clear(); compactWindowValues.Clear(); compactNoProviders = compactRingDetail = null;
        compactAutomatic = null; compactProjection = null; compactProviderSignature = "";
        if (activePane != "collapsed") revealQuotaGauge = false;
    }
    private async Task NavigateToQuotaGaugeAsync()
    {
        await NavigateAsync("collapsed");
        if (sourceClosed || activePane != "collapsed") return;
        revealQuotaGauge = true; RevealQuotaGauge();
    }
    private void RevealQuotaGauge()
    {
        if (!revealQuotaGauge || !compactRows.TryGetValue("quotaGauge", out var row)) return;
        revealQuotaGauge = false;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (sourceClosed || activePane != "collapsed" || !compactRows.TryGetValue("quotaGauge", out var current) || !ReferenceEquals(current, row)) return;
            row.BringIntoView();
            if (compactChecks.TryGetValue("quotaGauge", out var check)) check.Focus();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
    }
    private string[] CompactProviders() => NativeCompactBar.Providers(session.Current, engine?.LatestSnapshot);
    private CompactProjection ReadCompact() => NativeCompactBar.Shared.Read(session.Current, ui.Language, CompactProviders(), engine?.LatestSnapshot?.CompactContext);
    private async Task EditCompact(CompactEdit edit)
    {
        if (sourceClosed || activePane != "collapsed" || busy || compactEditor?.IsVisible != true) return;
        await Change(p => NativeCompactBar.Shared.EditAsync(p, ui.Language, NativeCompactBar.Providers(p, engine?.LatestSnapshot), edit));
    }
    private void BuildCollapsed()
    {
        compactProjection = ReadCompact();
        if (compactProjection.Components.Length == 0)
        {
            form.Children.Add(Detail(!ShellProjection.HasFailure("projectCompactBar") ? "…" : ui.Text("windows.connection.refresh_failed")));
            return;
        }
        compactEditor = new CompactLayoutEditorView(ui, Resources, EditCompact); editors.Add(compactEditor); form.Children.Add(Card(compactEditor));
        foreach (var group in compactProjection.Groups)
        {
            var title = Label(group.Label, 13, FontWeights.SemiBold); title.Margin = new Thickness(10, 22, 0, 8); form.Children.Add(title);
            var rows = new StackPanel(); compactGroups[group.Id] = rows; form.Children.Add(Card(rows));
            foreach (string id in group.Components)
            {
                var component = compactProjection.Components.Single(value => value.Id == id);
                var caption = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; caption.Children.Add(Label(component.Label)); caption.Children.Add(Detail(component.Detail));
                var icon = new IconGlyph { Symbol = component.Symbol, Width = 12, Height = 12 }; icon.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
                var tile = new Border { Child = icon, Width = 26, Height = 26, CornerRadius = new CornerRadius(7), Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center }; tile.SetResourceReference(Border.BackgroundProperty, "SettingsTile");
                var identity = new DockPanel(); DockPanel.SetDock(tile, Dock.Left); identity.Children.Add(tile); identity.Children.Add(caption);
                var check = new CheckBox { Style = (Style)FindResource("SettingsSwitch") }; compactChecks[id] = check; editors.Add(check);
                Identify(check, "compact.component." + id, component.Label); AutomationProperties.SetHelpText(check, component.Detail);
                RoutedEventHandler changed = async (_, _) =>
                {
                    if (!synchronizing && check.IsVisible && check.IsEnabled && compactChecks.TryGetValue(id, out var current) && ReferenceEquals(check, current))
                        await EditCompact(new(check.IsChecked == true ? "show" : "hide", id));
                };
                check.Checked += changed; check.Unchecked += changed;
                var row = new StackPanel(); row.Children.Add(Row(identity, check, 52));
                var options = new StackPanel { Margin = new Thickness(36, 0, 10, 0) }; row.Children.Add(options);
                compactRows[id] = row; compactOptions[id] = options; BuildCompactOptions(id, options);
            }
        }
        compactNoProviders = Detail(ui.Text("layout.no_quota_providers")); compactNoProviders.Margin = new Thickness(10, 10, 10, 10);
        foreach (string provider in new[] { "codex", "claude" })
        {
            var combo = CompactChoice("window." + provider, [("5h", "settings.window_five_hour"), ("7d", "settings.window_weekly")],
                value => Change(p => provider == "codex" ? p with { CodexQuotaWindow = value } : p with { ClaudeQuotaWindow = value }));
            var fixedValue = Detail(ui.Text("settings.window_weekly")); compactWindowValues[provider] = fixedValue;
            var choices = new Grid(); choices.Children.Add(combo); choices.Children.Add(fixedValue);
            var title = Label(""); Identify(title, "compact.window_label." + provider, "");
            compactWindowRows[provider] = Row(title, choices, 40);
        }
        RevealQuotaGauge();
    }
    private void BuildCompactOptions(string id, StackPanel host)
    {
        Grid Option(UIElement label, UIElement choice)
        {
            var row = Row(label, choice, 26);
            if (label is FrameworkElement text) text.Margin = new Thickness(0, 0, 8, 0);
            return row;
        }
        if (id == "activity")
            host.Children.Add(Option(Label(ui.Text("layout.single_task")), CompactChoice("singleTask", [("stage", "layout.single_task.stage"), ("count", "layout.single_task.count")],
                value => Change(p => p with { CompactSingleTask = value }))));
        else if (id is "quota" or "quotaLabel")
            host.Children.Add(Option(Label(ui.Text("settings.compact_metric")), CompactChoice("metric." + id, [("remaining", "settings.remaining_quota"), ("pace", "settings.pace_percentage")],
                value => Change(p => p with { CompactMetric = value }))));
        else if (id == "warnings")
        {
            var choose = new Button { Content = ui.Text("layout.warnings_choose"), Style = (Style)FindResource("SettingsLink"), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Left, IsEnabled = engine != null };
            Identify(choose, "compact.warnings.choose", ui.Text("layout.warnings_choose")); choose.Click += async (_, _) => { if (choose.IsVisible && activePane == "collapsed") await NavigateAsync("notifications"); }; host.Children.Add(choose);
        }
        else if (id == "quotaGauge")
        {
            for (int index = 0; index < 2; index++)
            {
                int slot = index;
                var combo = CompactChoice("ring." + index, [], value => Change(async p =>
                {
                    var current = await NativeCompactBar.Shared.ReadAsync(p, ui.Language, NativeCompactBar.Providers(p, engine?.LatestSnapshot));
                    return p with { QuotaRingOuter = slot == 0 ? value : current.RingChoices[0], QuotaRingInner = slot == 1 ? value : current.RingChoices[1] };
                }));
                host.Children.Add(Option(Label(ui.Text(index == 0 ? "layout.ring_outer" : "layout.ring_inner")), combo));
            }
            compactRingDetail = Detail(""); host.Children.Add(compactRingDetail);
            compactAutomatic = new Button { Content = ui.Text("layout.ring_automatic"), Style = (Style)FindResource("SettingsLink"), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Left };
            Identify(compactAutomatic, "compact.ring.automatic", ui.Text("layout.ring_automatic"));
            compactAutomatic.Click += async (_, _) => { if (compactAutomatic.IsVisible && activePane == "collapsed") await Change(p => p with { QuotaRingOuter = "", QuotaRingInner = "" }); };
            host.Children.Add(compactAutomatic); editors.Add(compactAutomatic);
        }
    }
    private ComboBox CompactChoice(string id, (string Value, string Key)[] options, Func<string, Task> edit)
    {
        var combo = new ComboBox { MinWidth = 120, SelectedValuePath = "Tag", VerticalAlignment = VerticalAlignment.Center };
        foreach (var item in options) combo.Items.Add(new ComboBoxItem { Tag = item.Value, Content = ui.Text(item.Key) });
        string title = ui.Text(id == "singleTask" ? "layout.single_task" : id.StartsWith("metric.", StringComparison.Ordinal) ? "settings.compact_metric"
            : id == "ring.0" ? "layout.ring_outer" : id == "ring.1" ? "layout.ring_inner" : "settings.window_weekly");
        Identify(combo, "compact." + id, title); compactChoices[id] = combo; editors.Add(combo);
        combo.SelectionChanged += async (_, _) =>
        {
            if (!synchronizing && !sourceClosed && activePane == "collapsed" && combo.IsVisible && combo.IsEnabled && !busy &&
                compactChoices.TryGetValue(id, out var current) && ReferenceEquals(current, combo) && combo.SelectedValue is string value)
            {
                bool focus = combo.IsKeyboardFocusWithin;
                await edit(value);
                if (focus && !sourceClosed && activePane == "collapsed" && combo.IsVisible && combo.IsEnabled) combo.Focus();
            }
        };
        return combo;
    }
    private void RefreshCollapsed()
    {
        if (compactEditor == null) return;
        var projection = ReadCompact();
        if (projection.Components.Length == 0) { compactEditor.IsEnabled = false; return; }
        if (compactRows.Count == 0) { RebuildPane("collapsed"); RefreshValues(); return; }
        compactProjection = projection;
        var providers = CompactProviders(); bool docked = session.Current.DisplayMode != "notch" &&
            (session.Current.IslandPlacement?.Vertical ?? session.Current.Position != "center");
        compactEditor.Update(projection, docked); compactEditor.IsEnabled = !busy && !session.RequiresRestart;
        var components = projection.Components.ToDictionary(value => value.Id);
        foreach (var component in projection.Components)
        {
            compactChecks[component.Id].IsChecked = component.Shown;
            bool options = component.Shown && component.Id is "activity" or "quota" or "quotaGauge" or "warnings" or "quotaLabel";
            if (component.Id == "quotaLabel" && components["quota"].Shown) options = false;
            compactOptions[component.Id].Visibility = options ? Visibility.Visible : Visibility.Collapsed;
        }
        compactChoices["singleTask"].SelectedValue = session.Current.CompactSingleTask;
        compactChoices["metric.quota"].SelectedValue = compactChoices["metric.quotaLabel"].SelectedValue = session.Current.CompactMetric;
        string nextProviders = string.Join(",", providers);
        if (compactProviderSignature != nextProviders || compactChoices["ring.0"].Items.Count == 0)
        {
            compactProviderSignature = nextProviders;
            foreach (int index in new[] { 0, 1 })
            {
                var combo = compactChoices["ring." + index]; combo.Items.Clear();
                foreach (string provider in providers) combo.Items.Add(new ComboBoxItem { Tag = provider, Content = provider switch { "codex" => "Codex", "claude" => "Claude", _ => "DeepSeek" } });
                combo.Items.Add(new ComboBoxItem { Tag = "none", Content = ui.Text("layout.ring_none") });
            }
        }
        for (int index = 0; index < 2; index++) compactChoices["ring." + index].SelectedValue = projection.RingChoices[index];
        bool hasWallet = providers.Contains("deepseek") && projection.RingChoices.Contains("deepseek");
        compactRingDetail!.Visibility = hasWallet ? Visibility.Visible : Visibility.Collapsed;
        compactRingDetail.Text = ui.Text(engine?.LatestSnapshot?.Wallet?.Solo?.Budgets.Count > 0 ? "layout.ring_deepseek" : "layout.ring_deepseek_needs_budget");
        compactAutomatic!.Visibility = session.Current.QuotaRingOuter.Length > 0 || session.Current.QuotaRingInner.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        bool quotaShown = projection.Groups.Single(value => value.Id == "quota").Components.Any(id => components[id].Shown);
        foreach (var window in projection.Windows)
        {
            var row = (Grid)compactWindowRows[window.Provider]; ((TextBlock)row.Children[0]).Text = window.Label;
            AutomationProperties.SetName(compactChoices["window." + window.Provider], window.Label);
            compactChoices["window." + window.Provider].SelectedValue = window.Selection;
            compactChoices["window." + window.Provider].Visibility = window.WeeklyOnly ? Visibility.Collapsed : Visibility.Visible;
            compactWindowValues[window.Provider].Visibility = window.WeeklyOnly ? Visibility.Visible : Visibility.Collapsed;
        }
        foreach (var group in projection.Groups)
        {
            var rows = group.Components.Where(id => components[id].Available).Select(id => (UIElement)compactRows[id]).ToList();
            if (group.Id == "quota")
            {
                if (providers.Length == 0) rows.Add(compactNoProviders!);
                else if (quotaShown) rows.AddRange(projection.Windows.Select(value => (UIElement)compactWindowRows[value.Provider]));
            }
            var panel = compactGroups[group.Id];
            if (!panel.Children.Cast<UIElement>().Where(value => value is not Border).SequenceEqual(rows))
            {
                panel.Children.Clear();
                foreach (var row in rows)
                {
                    if (panel.Children.Count > 0) { var line = new Border { Height = 1, Margin = new Thickness(10, 0, 10, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); panel.Children.Add(line); }
                    panel.Children.Add(row);
                }
            }
        }
    }
}
