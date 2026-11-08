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
            if (compactEditor == null || compactChecks.Count == 0) { RebuildPane("collapsed"); RefreshValues(); }
            else RefreshValues();
        });
    }
    private void ClearCollapsed()
    {
        compactEditor?.CancelGesture(); if (compactEditor != null) compactEditor.IsEnabled = false;
        compactEditor = null; compactGroups.Clear(); compactRows.Clear(); compactOptions.Clear(); compactChecks.Clear(); compactChoices.Clear();
        compactWindowRows.Clear(); compactWindowValues.Clear(); compactNoProviders = compactRingDetail = null;
        compactAutomatic = null; compactProjection = null; compactProviderSignature = "";
        compactTiles.Clear(); compactInspector = null; compactInspectorTitle = compactInspectorDetail = null; compactInspectorToggle = null; compactInspectorIcon = null;
        compactInspectorPanels.Clear(); compactWindowsPanel = null; compactRingsCustom = null;
        if (activePane != "collapsed") revealQuotaGauge = false;
    }
    private async Task NavigateToQuotaGaugeAsync()
    {
        await NavigateAsync("collapsed");
        if (sourceClosed || activePane != "collapsed") return;
        revealQuotaGauge = true; RevealQuotaGauge();
    }
    /// The DeepSeek page's ring link lands on the rings' settings, as on the Mac.
    private void RevealQuotaGauge()
    {
        if (!revealQuotaGauge || compactInspector == null) return;
        revealQuotaGauge = false; SelectCompactComponent("quotaGauge");
        var inspector = compactInspector;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (sourceClosed || activePane != "collapsed" || !ReferenceEquals(compactInspector, inspector)) return;
            inspector.BringIntoView();
            if (compactChoices.TryGetValue("ring.0", out var ring)) ring.Focus();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
    }
    private string[] CompactProviders() => NativeCompactBar.Providers(session.Current, engine?.LatestSnapshot);
    private CompactProjection ReadCompact() => NativeCompactBar.Shared.Read(session.Current, ui.Language, CompactProviders(), engine?.LatestSnapshot?.CompactContext);
    private async Task EditCompact(CompactEdit edit)
    {
        if (sourceClosed || activePane != "collapsed" || busy || compactEditor?.IsVisible != true) return;
        await Change(p => NativeCompactBar.Shared.EditAsync(p, ui.Language, NativeCompactBar.Providers(p, engine?.LatestSnapshot), edit));
    }
    private readonly Dictionary<string, (Border Surface, IconGlyph Mark)> compactTiles = new();
    private readonly Dictionary<string, FrameworkElement> compactInspectorPanels = new();
    private Border? compactInspector, compactInspectorIcon;
    private TextBlock? compactInspectorTitle, compactInspectorDetail;
    private Button? compactInspectorToggle;
    private StackPanel? compactWindowsPanel;
    private FrameworkElement? compactRingsCustom;
    private string? compactSelected;

    private Button? compactInfoButton;
    private readonly Button?[] compactRingInfo = new Button?[2];
    private readonly Border?[] compactRingBoxes = new Border?[2];
    private readonly Dictionary<string, RadioButton> compactMetric = new();

    /// As on the Mac: the bar to click and drag, every component by group to add
    /// or remove, and the settings of the one selected. What each component is
    /// sits behind the inspector's info button.
    private void BuildCollapsed()
    {
        paneSubtitle.Text = ui.Text("main.collapsed.subtitle"); paneSubtitle.Visibility = Visibility.Visible;
        compactProjection = ReadCompact();
        if (compactProjection.Components.Length == 0)
        {
            form.Children.Add(Detail(!ShellProjection.HasFailure("projectCompactBar") ? "…" : ui.Text("windows.connection.refresh_failed")));
            return;
        }
        compactEditor = new CompactLayoutEditorView(ui, Resources, EditCompact) { Margin = new Thickness(0, 0, 0, 22) }; editors.Add(compactEditor); form.Children.Add(compactEditor);
        // Restore Defaults sits at the header's end, as on the Mac.
        var restore = new Button { Content = ui.Text("common.restore_defaults") };
        Identify(restore, "compact.restore", ui.Text("common.restore_defaults")); editors.Add(restore);
        restore.Click += async (_, _) => { if (compactEditor.IsEnabled && activePane == "collapsed") { await EditCompact(new("restore")); RefreshValues(); } };
        SetPaneHeader(restore, true);
        compactEditor.ComponentSelected += SelectCompactComponent;
        var columns = new Grid();
        columns.ColumnDefinitions.Add(new ColumnDefinition()); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) }); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(264) });
        var library = new StackPanel(); library.Children.Add(SectionTitle(ui.Text("main.collapsed.components")));
        var groups = new StackPanel { Margin = new Thickness(14) };
        foreach (var group in compactProjection.Groups)
        {
            var heading = Label(group.Label, 11.5); heading.Margin = new Thickness(0, groups.Children.Count == 0 ? 0 : 14, 0, 7);
            heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level3);
            var tiles = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, Margin = new Thickness(0, 0, -6, -6) };
            compactGroups[group.Id] = new StackPanel { Children = { heading, tiles } }; groups.Children.Add(compactGroups[group.Id]);
            foreach (string id in group.Components) tiles.Children.Add(CompactTile(compactProjection.Components.Single(value => value.Id == id)));
            if (group.Id == "quota") { compactNoProviders = Detail(ui.Text("layout.no_quota_providers")); compactNoProviders.FontSize = 12; compactGroups[group.Id].Children.Add(compactNoProviders); }
        }
        library.Children.Add(Card(groups)); columns.Children.Add(library);
        var inspector = new StackPanel(); inspector.Children.Add(SectionTitle(ui.Text("main.collapsed.selected")));
        inspector.Children.Add(compactInspector = Card(BuildCompactInspector()));
        Grid.SetColumn(inspector, 2); columns.Children.Add(inspector);
        form.Children.Add(columns);
        RevealQuotaGauge();
    }

    /// A component in the library: its icon and name, with a check while it
    /// is on the bar or a plus to add it. Clicking adds or removes it and
    /// selects it.
    private CheckBox CompactTile(CompactComponent component)
    {
        var tile = new CheckBox { Style = (Style)FindResource("SettingsComponentTile"), Margin = new Thickness(0, 0, 6, 6) };
        var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new IconGlyph { Symbol = component.Symbol, Width = 12, Height = 12, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        icon.SetBinding(IconGlyph.InkProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = tile }); row.Children.Add(icon);
        var name = Label(component.Label, 12.5); name.TextTrimming = TextTrimming.CharacterEllipsis;
        name.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = tile }); Grid.SetColumn(name, 1); row.Children.Add(name);
        var mark = new IconGlyph { Width = 10, Height = 10, Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(mark, 2); row.Children.Add(mark);
        tile.Content = row; compactChecks[component.Id] = tile; editors.Add(tile);
        Identify(tile, "compact.component." + component.Id, component.Label); AutomationProperties.SetHelpText(tile, component.Detail);
        RoutedEventHandler changed = async (_, _) =>
        {
            if (synchronizing || !tile.IsVisible || !tile.IsEnabled || !compactChecks.TryGetValue(component.Id, out var current) || !ReferenceEquals(tile, current)) return;
            compactSelected = component.Id;
            await EditCompact(new(tile.IsChecked == true ? "show" : "hide", component.Id));
            RefreshValues();
        };
        tile.Checked += changed; tile.Unchecked += changed;
        compactTiles[component.Id] = (tile.Template?.FindName("Surface", tile) as Border ?? new Border(), mark);
        return tile;
    }

    /// The selected component's card: its name with info, Add or Remove, then the
    /// options that change it. The quota windows follow every component that shows a quota.
    private StackPanel BuildCompactInspector()
    {
        var body = new StackPanel();
        var header = new Grid { Margin = new Thickness(14, 12, 14, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        compactInspectorIcon = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(7), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        compactInspectorIcon.SetResourceReference(Border.BackgroundProperty, "SettingsAccentSoft"); header.Children.Add(compactInspectorIcon);
        var titleLine = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        compactInspectorTitle = Label("", 13.5, FontWeights.SemiBold); compactInspectorTitle.TextTrimming = TextTrimming.CharacterEllipsis; compactInspectorTitle.MaxWidth = 120;
        Identify(compactInspectorTitle, "compact.inspector.title", ""); titleLine.Children.Add(compactInspectorTitle);
        compactInspectorDetail = Detail(""); var infoBox = new Border { Child = compactInspectorDetail };
        var box = InfoBox(""); box.Margin = new Thickness(14, 0, 14, 10);
        compactInfoButton = InfoButton(ui.Text("main.collapsed.selected"), box, "compact.inspector"); titleLine.Children.Add(compactInfoButton);
        Grid.SetColumn(titleLine, 1); header.Children.Add(titleLine);
        compactInspectorToggle = new Button { VerticalAlignment = VerticalAlignment.Center }; Identify(compactInspectorToggle, "compact.inspector.toggle", "");
        compactInspectorToggle.Click += async (_, _) =>
        {
            if (compactSelected == null || compactProjection == null || !compactInspectorToggle.IsVisible) return;
            bool shown = compactProjection.Components.FirstOrDefault(value => value.Id == compactSelected)?.Shown == true;
            await EditCompact(new(shown ? "hide" : "show", compactSelected)); RefreshValues();
        };
        editors.Add(compactInspectorToggle); Grid.SetColumn(compactInspectorToggle, 2); header.Children.Add(compactInspectorToggle);
        body.Children.Add(header); body.Children.Add(box);
        compactInspectorPanels["box"] = box;

        Grid Option(string titleKey, UIElement choice, string? info = null, string? id = null)
        { var row = InfoRow(ui.Text(titleKey), choice, info, id: id); return row; }
        Border Hair() => Hairline(14);
        var activity = new StackPanel(); activity.Children.Add(Hair());
        activity.Children.Add(Option("layout.single_task", CompactChoice("singleTask", [("stage", "layout.single_task.stage"), ("count", "layout.single_task.count")],
            value => Change(p => p with { CompactSingleTask = value }))));
        compactInspectorPanels["activity"] = activity; body.Children.Add(activity);
        var quota = new StackPanel(); quota.Children.Add(Hair());
        quota.Children.Add(Option("settings.compact_metric", CompactSegments()));
        compactInspectorPanels["quota"] = quota; body.Children.Add(quota);
        var rings = new StackPanel();
        for (int index = 0; index < 2; index++)
        {
            int slot = index;
            var combo = CompactChoice("ring." + index, [], value => Change(async p =>
            {
                var current = await NativeCompactBar.Shared.ReadAsync(p, ui.Language, NativeCompactBar.Providers(p, engine?.LatestSnapshot));
                return p with { QuotaRingOuter = slot == 0 ? value : current.RingChoices[0], QuotaRingInner = slot == 1 ? value : current.RingChoices[1] };
            }));
            // A ring set to DeepSeek explains its budget behind ⓘ, as on the Mac.
            var ringRow = Option(index == 0 ? "layout.ring_outer" : "layout.ring_inner", combo, ui.Text("layout.ring_deepseek"), "compact.ring." + index);
            compactRingInfo[index] = (Button)((WrapPanel)((StackPanel)ringRow.Children[0]).Children[0]).Children[1];
            compactRingBoxes[index] = ringRow.Children.OfType<Border>().Single(child => Grid.GetRow(child) == 1);
            rings.Children.Add(Hair()); rings.Children.Add(ringRow);
        }
        compactRingDetail = Label("", 12); compactRingDetail.TextWrapping = TextWrapping.Wrap; compactRingDetail.Foreground = PacerPalette.Attention;
        compactRingDetail.Margin = new Thickness(14, 0, 14, 10); Identify(compactRingDetail, "compact.ring.detail", ""); rings.Children.Add(compactRingDetail);
        compactAutomatic = new Button { Content = ui.Text("layout.ring_automatic"), VerticalAlignment = VerticalAlignment.Center };
        Identify(compactAutomatic, "compact.ring.automatic", ui.Text("layout.ring_automatic"));
        compactAutomatic.Click += async (_, _) => { if (compactAutomatic.IsVisible && activePane == "collapsed") await Change(p => p with { QuotaRingOuter = "", QuotaRingInner = "" }); };
        editors.Add(compactAutomatic);
        var custom = new StackPanel(); custom.Children.Add(Hair()); custom.Children.Add(InfoRow(ui.Text("main.collapsed.rings_custom"), compactAutomatic));
        compactRingsCustom = custom; rings.Children.Add(custom);
        compactInspectorPanels["quotaGauge"] = rings; body.Children.Add(rings);
        compactWindowsPanel = new StackPanel();
        foreach (string provider in new[] { "codex", "claude" })
        {
            var combo = CompactChoice("window." + provider, [("5h", "settings.window_five_hour"), ("7d", "settings.window_weekly")],
                value => Change(p => provider == "codex" ? p with { CodexQuotaWindow = value } : p with { ClaudeQuotaWindow = value }));
            var fixedValue = Detail(ui.Text("settings.window_weekly")); compactWindowValues[provider] = fixedValue;
            var choices = new Grid(); choices.Children.Add(combo); choices.Children.Add(fixedValue);
            string name = provider == "codex" ? "Codex" : "Claude";
            var row = InfoRow(ui.Text("provider.window_selection").Replace("%@", name, StringComparison.Ordinal), choices,
                ui.Has("provider.window_info") ? ui.Text("provider.window_info").Replace("%@", name, StringComparison.Ordinal) : null, id: "compact.window." + provider);
            var title = (TextBlock)((Panel)((StackPanel)row.Children[0]).Children[0]).Children[0]; Identify(title, "compact.window_label." + provider, title.Text);
            var host = new StackPanel(); host.Children.Add(Hair()); host.Children.Add(row);
            compactWindowRows[provider] = host; compactWindowsPanel.Children.Add(host);
        }
        body.Children.Add(compactWindowsPanel);
        var warnings = new StackPanel(); warnings.Children.Add(Hair());
        var chevron = new IconGlyph { Symbol = "chevron.right", Width = 10, Height = 10 }; chevron.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var choose = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Height = double.NaN, MinHeight = 44, Padding = new Thickness(14, 0, 14, 0), IsEnabled = engine != null };
        var line = new DockPanel(); DockPanel.SetDock(chevron, Dock.Right); line.Children.Add(chevron); line.Children.Add(Label(ui.Text("main.collapsed.warnings_choose")));
        choose.Content = line; choose.SetResourceReference(ForegroundProperty, "SettingsPrimary");
        Identify(choose, "compact.warnings.choose", ui.Text("main.collapsed.warnings_choose"));
        choose.Click += async (_, _) => { if (choose.IsVisible && activePane == "collapsed") await NavigateAsync("notifications"); };
        warnings.Children.Add(choose); compactInspectorPanels["warnings"] = warnings; body.Children.Add(warnings);
        return body;
    }

    /// Selects a component for the inspector, as a click on the bar or a library tile does.
    internal void SelectCompactComponent(string id)
    {
        // A new selection starts with its explanation closed, as on the Mac.
        if (id != compactSelected && compactInfoButton != null && compactInspectorPanels.TryGetValue("box", out var box)) SetInfoShown(compactInfoButton, box, false);
        compactSelected = id; compactEditor?.SetSelected(id);
        bool previous = synchronizing; synchronizing = true;
        try { RefreshCollapsed(); } finally { synchronizing = previous; }
    }
    /// What the quota component shows, Remaining or Pace, as the Mac's segmented control.
    private Border CompactSegments()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (value, key) in new[] { ("remaining", "settings.remaining_quota"), ("pace", "settings.pace_percentage") })
        {
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), GroupName = "compact.metric", Content = ui.Text(key) };
            Identify(choice, "compact.metric." + value, ui.Text(key)); editors.Add(choice); compactMetric[value] = choice; row.Children.Add(choice);
            choice.Checked += async (_, _) => { if (!synchronizing && activePane == "collapsed" && choice.IsVisible) await Change(p => p with { CompactMetric = value }); };
        }
        var track = new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        track.SetResourceReference(Border.BackgroundProperty, "SettingsFill"); Identify(track, "compact.metric.quota", ui.Text("settings.compact_metric")); return track;
    }
    private ComboBox CompactChoice(string id, (string Value, string Key)[] options, Func<string, Task> edit)
    {
        var combo = new ComboBox { MinWidth = 96, SelectedValuePath = "Tag", VerticalAlignment = VerticalAlignment.Center };
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
        if (compactChecks.Count == 0 || compactInspector == null) { RebuildPane("collapsed"); RefreshValues(); return; }
        compactProjection = projection;
        var providers = CompactProviders(); bool docked = session.Current.DisplayMode != "notch" &&
            (session.Current.IslandPlacement?.Vertical ?? session.Current.Position != "center");
        compactEditor.Update(projection, docked, session.Current.DisplayMode == "notch", engine?.LatestSnapshot); compactEditor.IsEnabled = !busy && !session.RequiresRestart;
        var components = projection.Components.ToDictionary(value => value.Id);
        // The chosen component, or the first one on the bar, so the inspector always describes something.
        var available = projection.Groups.SelectMany(group => group.Components).Where(id => components.TryGetValue(id, out var item) && item.Available).ToArray();
        string? selected = compactSelected != null && available.Contains(compactSelected) ? compactSelected
            : projection.EditorLeading.Concat(projection.EditorTrailing).FirstOrDefault(available.Contains) ?? available.FirstOrDefault();
        compactEditor.SetSelected(selected);
        foreach (var component in projection.Components)
        {
            if (!compactChecks.TryGetValue(component.Id, out var tile)) continue;
            tile.IsChecked = component.Shown; tile.Visibility = component.Available ? Visibility.Visible : Visibility.Collapsed;
            tile.SetResourceReference(ForegroundProperty, component.Shown ? "SettingsPrimary" : "SettingsSecondary");
            tile.Tag = component.Id == selected ? "selected" : null;
            if (compactTiles.TryGetValue(component.Id, out var parts))
            {
                parts.Mark.Symbol = component.Shown ? "checkmark" : "plus";
                parts.Mark.SetResourceReference(IconGlyph.InkProperty, component.Shown ? "SettingsAccent" : "SettingsSecondary");
            }
        }
        compactNoProviders!.Visibility = providers.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var chosen = selected != null ? components[selected] : null;
        bool placed = chosen?.Shown == true;
        compactInspector!.Visibility = chosen == null ? Visibility.Collapsed : Visibility.Visible;
        if (chosen != null)
        {
            compactInspectorTitle!.Text = chosen.Label; AutomationProperties.SetName(compactInspectorTitle, chosen.Label);
            if (compactInfoButton != null) AutomationProperties.SetName(compactInfoButton, ui.Text("main.info").Replace("%@", chosen.Label, StringComparison.Ordinal));
            var glyph = new IconGlyph { Symbol = chosen.Symbol, Width = 12, Height = 12 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsAccent"); compactInspectorIcon!.Child = glyph;
            if (compactInspectorPanels["box"] is Border box && box.Child is TextBlock info) info.Text = chosen.Detail;
            compactInspectorToggle!.Content = ui.Text(placed ? "main.collapsed.remove" : "main.collapsed.add");
            compactInspectorToggle.Style = placed ? (Style)FindResource(typeof(Button)) : (Style)FindResource("SettingsProminentButton");
            AutomationProperties.SetName(compactInspectorToggle, chosen.Label + " · " + compactInspectorToggle.Content);
        }
        foreach (var panel in compactInspectorPanels) if (panel.Key != "box") panel.Value.Visibility = placed && panel.Key == selected ? Visibility.Visible : Visibility.Collapsed;
        compactWindowsPanel!.Visibility = placed && selected is "quota" or "quotaGauge" or "timeRemaining" ? Visibility.Visible : Visibility.Collapsed;
        compactChoices["singleTask"].SelectedValue = session.Current.CompactSingleTask;
        foreach (var segment in compactMetric) segment.Value.IsChecked = segment.Key == session.Current.CompactMetric;
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
        bool budgets = engine?.LatestSnapshot?.Wallet?.Solo?.Budgets.Count > 0;
        // Without a budget the ring has nothing to fill, which shows in amber; with one, ⓘ on its ring explains it.
        compactRingDetail!.Visibility = hasWallet && !budgets ? Visibility.Visible : Visibility.Collapsed;
        compactRingDetail.Text = ui.Text("layout.ring_deepseek_needs_budget");
        for (int index = 0; index < 2; index++)
        {
            bool info = hasWallet && budgets && projection.RingChoices[index] == "deepseek";
            if (compactRingInfo[index] is { } button) { button.Visibility = info ? Visibility.Visible : Visibility.Collapsed; if (!info && compactRingBoxes[index] is { } ringBox) SetInfoShown(button, ringBox, false); }
        }
        compactRingsCustom!.Visibility = session.Current.QuotaRingOuter.Length > 0 || session.Current.QuotaRingInner.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (string provider in new[] { "codex", "claude" })
            compactWindowRows[provider].Visibility = providers.Contains(provider) && projection.Windows.Any(value => value.Provider == provider) ? Visibility.Visible : Visibility.Collapsed;
        foreach (var window in projection.Windows)
        {
            if (!compactWindowRows.ContainsKey(window.Provider)) continue;
            compactChoices["window." + window.Provider].SelectedValue = window.Selection;
            compactChoices["window." + window.Provider].Visibility = window.WeeklyOnly ? Visibility.Collapsed : Visibility.Visible;
            compactWindowValues[window.Provider].Visibility = window.WeeklyOnly ? Visibility.Visible : Visibility.Collapsed;
        }
    }
}
