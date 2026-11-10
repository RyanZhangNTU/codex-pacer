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
        if (method.Length > 0 && method != "projectCompactBar" && method != "projectExpandedPanel") return;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (!IsVisible) return;
            if (activePane == "expandedPanel")
            {
                if (panelEditor == null || panelTiles.Count == 0) RebuildPane("expandedPanel");
                RefreshValues(); return;
            }
            if (method == "projectExpandedPanel") return;
            if (activePane is "notifications" or "deepseek") { RefreshValues(); return; }
            if (activePane != "collapsed") return;
            if (compactEditor == null || compactTiles.Count == 0) { RebuildPane("collapsed"); RefreshValues(); }
            else RefreshValues();
        });
    }
    private void ClearCollapsed()
    {
        compactEditor?.CancelGesture(); if (compactEditor != null) compactEditor.IsEnabled = false;
        compactEditor = null; compactGroups.Clear(); compactRows.Clear(); compactOptions.Clear(); compactChoices.Clear();
        compactWindowRows.Clear(); compactWindowValues.Clear(); compactNoProviders = compactRingDetail = null;
        compactAutomatic = null; compactProjection = null; compactProviderSignature = "";
        compactTiles.Clear(); compactInspector = null; compactInspectorTitle = compactInspectorDetail = null; compactInspectorToggle = null; compactInspectorIcon = null; compactNotice = null;
        compactInspectorPanels.Clear(); compactWindowsPanel = null; compactRingsCustom = null;
        compactSegments.Clear(); compactOptionRows.Clear();
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
    private readonly Dictionary<string, LibraryTile> compactTiles = new();
    private readonly Dictionary<string, FrameworkElement> compactInspectorPanels = new();
    private Border? compactInspector, compactInspectorIcon, compactNotice;
    private TextBlock? compactInspectorTitle, compactInspectorDetail;
    private Button? compactInspectorToggle;
    private StackPanel? compactWindowsPanel;
    private FrameworkElement? compactRingsCustom;
    private string? compactSelected;

    private Button? compactInfoButton;
    private readonly Button?[] compactRingInfo = new Button?[2];
    private readonly Border?[] compactRingBoxes = new Border?[2];
    private readonly Dictionary<string, RadioButton> compactMetric = new();
    // Each component choice's segments, by option and value.
    private readonly Dictionary<string, Dictionary<string, RadioButton>> compactSegments = new();
    private readonly Dictionary<string, FrameworkElement> compactOptionRows = new();

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

    /// A component in the library: clicking selects it; the round button adds
    /// it to the bar or removes it, and keeps the selection.
    private FrameworkElement CompactTile(CompactComponent component)
    {
        LibraryTile? tile = null;
        tile = BuildLibraryTile("compact.component." + component.Id, component.Label, component.Symbol, component.Detail,
            () => SelectCompactComponent(component.Id),
            async () =>
            {
                if (tile == null || !compactTiles.TryGetValue(component.Id, out var current) || !ReferenceEquals(tile, current)) return;
                bool shown = compactProjection?.Components.FirstOrDefault(value => value.Id == component.Id)?.Shown == true;
                await EditCompact(new(shown ? "hide" : "show", component.Id)); RefreshValues();
            });
        tile.Root.Margin = new Thickness(0, 0, 6, 6);
        compactTiles[component.Id] = tile;
        return tile.Root;
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
        compactNotice = LibraryNotice("compact.inspector.notice"); body.Children.Add(compactNotice);

        Grid Option(string titleKey, UIElement choice, string? info = null, string? id = null)
        { var row = InfoRow(ui.Text(titleKey), choice, info, id: id); return row; }
        Border Hair() => Hairline(14);
        // Segments sit under their title so the narrow card never squeezes the words.
        StackPanel Stacked(string titleKey, UIElement control, string? info, string id)
        {
            var host = new StackPanel { Margin = new Thickness(14, 10, 14, 10) };
            var heading = new WrapPanel(); var label = Label(ui.Text(titleKey)); label.TextWrapping = TextWrapping.Wrap; heading.Children.Add(label);
            host.Children.Add(heading);
            if (control is FrameworkElement element) { element.HorizontalAlignment = HorizontalAlignment.Left; element.Margin = new Thickness(0, 7, 0, 0); }
            host.Children.Add(control);
            if (info != null)
            {
                var box = InfoBox(info); box.Margin = new Thickness(0, 8, 0, 0); host.Children.Add(box);
                heading.Children.Add(InfoButton(ui.Text(titleKey), box, id)); AutomationProperties.SetHelpText(control, info);
            }
            return host;
        }
        // A component choice in its own row, kept to hide or disable it later.
        StackPanel Choice(string id, string titleKey, UIElement control, string? info = null)
        {
            var host = new StackPanel(); host.Children.Add(Hair());
            host.Children.Add(control is ComboBox ? Option(titleKey, control, info, "compact.option." + id) : Stacked(titleKey, control, info, "compact.option." + id));
            compactOptionRows[id] = host; return host;
        }
        // Only the chosen field changes; the others stay as saved, even a value this version cannot read.
        Task Choose(string field, object value)
            => Change(p => p with { CompactComponentOptions = CompactChoices.With(p.CompactComponentOptions, field, value) });
        (string, string)[] OnOff(string on, string off) => [("on", on), ("off", off)];

        var activity = new StackPanel(); activity.Children.Add(Hair());
        activity.Children.Add(Option("layout.option.single_core", CompactChoice("singleTask", [("stage", "layout.option.single_core.stage"),
            ("count", "layout.option.single_core.count"), ("percent", "layout.option.single_core.percent")],
            value => Change(p => p with { CompactSingleTask = value }), "layout.option.single_core")));
        activity.Children.Add(Choice("multiRing", "layout.option.multi_ring", CompactChoice("multiRing", [("service", "layout.option.multi_ring.service"),
            ("average", "layout.option.multi_ring.average"), ("segments", "layout.option.multi_ring.segments")],
            value => Choose("multiRing", value), "layout.option.multi_ring")));
        activity.Children.Add(Choice("multiCore", "layout.option.multi_core", CompactOptionSegments("multiCore", "layout.option.multi_core",
            [("count", "layout.option.multi_core.count"), ("percent", "layout.option.multi_core.percent")], value => Choose("multiCore", value)),
            ui.Text("layout.option.multi_core_hint")));
        activity.Children.Add(Choice("endMark", "layout.option.end_mark", CompactOptionSegments("endMark", "layout.option.end_mark",
            OnOff("layout.option.show", "layout.option.hide"), value => Choose("endMark", value == "on")), ui.Text("layout.option.end_mark_hint")));
        compactInspectorPanels["activity"] = activity; body.Children.Add(activity);

        var status = new StackPanel();
        status.Children.Add(Choice("statusShow", "layout.option.status_show", CompactChoice("statusShow", [("urgent", "layout.option.status_show.urgent"),
            ("stage", "layout.option.status_show.stage"), ("count", "layout.option.status_show.count")], value => Choose("statusShow", value), "layout.option.status_show")));
        status.Children.Add(Choice("statusWidth", "layout.option.status_width", CompactOptionSegments("statusWidth", "layout.option.status_width",
            [("short", "72"), ("medium", "108"), ("long", "160")], value => Choose("statusWidth", value), points: true)));
        compactInspectorPanels["status"] = status; body.Children.Add(status);

        var rate = new StackPanel();
        rate.Children.Add(Choice("rateMeasure", "layout.option.rate_measure", CompactOptionSegments("rateMeasure", "layout.option.rate_measure",
            [("total", "layout.option.rate_measure.total"), ("average", "layout.option.rate_measure.average")], value => Choose("rateMeasure", value))));
        compactInspectorPanels["tps"] = rate; body.Children.Add(rate);

        var first = new StackPanel();
        first.Children.Add(Choice("firstOutput", "layout.option.first_output", CompactOptionSegments("firstOutput", "layout.option.first_output",
            [("latest", "layout.option.first_output.latest"), ("median", "layout.option.first_output.median")], value => Choose("firstOutput", value))));
        compactInspectorPanels["firstOutput"] = first; body.Children.Add(first);

        var quota = new StackPanel(); quota.Children.Add(Hair());
        quota.Children.Add(Option("settings.compact_metric", CompactSegments()));
        quota.Children.Add(Choice("quotaMultiple", "layout.option.quota_multiple", CompactChoice("quotaMultiple", [("alternate", "layout.option.quota_multiple.alternate"),
            ("pair", "layout.option.quota_multiple.pair"), ("lowest", "layout.option.quota_multiple.lowest")], value => Choose("quotaMultiple", value), "layout.option.quota_multiple")));
        compactInspectorPanels["quota"] = quota; body.Children.Add(quota);
        var rings = new StackPanel();
        rings.Children.Add(Choice("ringLayout", "layout.option.ring_layout", CompactChoice("ringLayout", [("concentric", "layout.option.ring_layout.concentric"),
            ("sideBySide", "layout.option.ring_layout.sideBySide"), ("split", "layout.option.ring_layout.split")], value => Choose("ringLayout", value), "layout.option.ring_layout")));
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
        compactRingDetail = Label("", 12); compactRingDetail.TextWrapping = TextWrapping.Wrap; compactRingDetail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        compactRingDetail.Margin = new Thickness(14, 0, 14, 10); Identify(compactRingDetail, "compact.ring.detail", ""); rings.Children.Add(compactRingDetail);
        compactAutomatic = new Button { Content = ui.Text("layout.ring_automatic"), VerticalAlignment = VerticalAlignment.Center };
        Identify(compactAutomatic, "compact.ring.automatic", ui.Text("layout.ring_automatic"));
        compactAutomatic.Click += async (_, _) => { if (compactAutomatic.IsVisible && activePane == "collapsed") await Change(p => p with { QuotaRingOuter = "", QuotaRingInner = "" }); };
        editors.Add(compactAutomatic);
        var custom = new StackPanel(); custom.Children.Add(Hair()); custom.Children.Add(InfoRow(ui.Text("main.collapsed.rings_custom"), compactAutomatic));
        compactRingsCustom = custom; rings.Children.Add(custom);
        rings.Children.Add(Choice("paceTick", "layout.option.pace_tick", CompactOptionSegments("paceTick", "layout.option.pace_tick",
            OnOff("layout.option.show", "layout.option.hide"), value => Choose("paceTick", value == "on"))));
        rings.Children.Add(Choice("lowColor", "layout.option.low_color", CompactOptionSegments("lowColor", "layout.option.low_color",
            OnOff("layout.option.low_color.on", "layout.option.low_color.off"), value => Choose("lowColor", value == "on")), ui.Text("layout.option.low_color_hint")));
        rings.Children.Add(Choice("ringDim", "layout.option.ring_dim", CompactOptionSegments("ringDim", "layout.option.ring_dim",
            OnOff("layout.option.ring_dim.on", "layout.option.ring_dim.off"), value => Choose("ringDim", value == "on")), ui.Text("layout.option.ring_dim_hint")));
        // The DeepSeek ring's budget period lives with the rings, as its other settings do.
        rings.Children.Add(Choice("deepseekRing", "layout.option.deepseek_ring", CompactOptionSegments("deepseekRing", "layout.option.deepseek_ring",
            [("day", "layout.option.deepseek_ring.day"), ("week", "layout.option.deepseek_ring.week")], value => Change(p => p with { DeepSeekRingPeriod = value }))));
        compactInspectorPanels["quotaGauge"] = rings; body.Children.Add(rings);
        var clock = new StackPanel();
        clock.Children.Add(Choice("clockShow", "layout.option.clock_show", CompactOptionSegments("clockShow", "layout.option.clock_show",
            [("always", "layout.option.clock_show.always"), ("peak", "layout.option.clock_show.peak")], value => Choose("clockShow", value))));
        compactInspectorPanels["priceClock"] = clock; body.Children.Add(clock);
        var time = new StackPanel();
        time.Children.Add(Choice("timeStyle", "layout.option.time_style", CompactOptionSegments("timeStyle", "layout.option.time_style",
            [("percent", "layout.option.time_style.percent"), ("countdown", "layout.option.time_style.countdown")], value => Choose("timeStyle", value))));
        compactInspectorPanels["timeRemaining"] = time; body.Children.Add(time);
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
        // Which warnings the bar shows is chosen in Notifications, beside their
        // system notifications; this card keeps their style and limit.
        var warnings = new StackPanel(); warnings.Children.Add(Hair());
        var chooseRow = new Grid();
        chooseRow.ColumnDefinitions.Add(new ColumnDefinition()); chooseRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        chooseRow.Children.Add(Label(ui.Text("main.collapsed.warnings_choose"), 13));
        var chevron = new IconGlyph { Symbol = "chevron.right", Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
        chevron.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); Grid.SetColumn(chevron, 1); chooseRow.Children.Add(chevron);
        var chooseWarnings = new Button { Style = (Style)FindResource("SettingsRowButton"), Content = chooseRow };
        Identify(chooseWarnings, "compact.warnings.choose", ui.Text("main.collapsed.warnings_choose"));
        chooseWarnings.Click += async (_, _) => { if (activePane == "collapsed") await NavigateAsync("reminders"); };
        warnings.Children.Add(chooseWarnings);
        warnings.Children.Add(Choice("warningStyle", "layout.option.warning_style", CompactOptionSegments("warningStyle", "layout.option.warning_style",
            [("capsule", "layout.option.warning_style.capsule"), ("dot", "layout.option.warning_style.dot")], value => Choose("warningStyle", value))));
        warnings.Children.Add(Choice("warningLimit", "layout.option.warning_limit", CompactOptionSegments("warningLimit", "layout.option.warning_limit",
            [("2", "layout.option.warning_limit.two"), ("0", "layout.option.warning_limit.all")], value => Choose("warningLimit", value == "2" ? 2 : 0))));
        compactInspectorPanels["warnings"] = warnings; body.Children.Add(warnings);
        return body;
    }
    /// A component choice as the Mac's segmented control; `points` labels widths.
    private Border CompactOptionSegments(string id, string titleKey, (string Value, string Key)[] options, Func<string, Task> edit, bool points = false)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var group = compactSegments[id] = new();
        foreach (var (value, key) in options)
        {
            string text = points ? ui.Text("layout.option.points").Replace("%d", key, StringComparison.Ordinal) : ui.Text(key);
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), GroupName = "compact.option." + id, Content = text };
            Identify(choice, "compact.option." + id + "." + value, text); editors.Add(choice); group[value] = choice; row.Children.Add(choice);
            choice.Checked += async (_, _) =>
            {
                if (synchronizing || activePane != "collapsed" || !choice.IsVisible || !choice.IsEnabled || busy) return;
                await edit(value);
            };
        }
        var track = new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        track.SetResourceReference(Border.BackgroundProperty, "SettingsFill"); Identify(track, "compact.option." + id, ui.Text(titleKey)); return track;
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
    private ComboBox CompactChoice(string id, (string Value, string Key)[] options, Func<string, Task> edit, string? titleKey = null)
    {
        var combo = new ComboBox { MinWidth = 96, SelectedValuePath = "Tag", VerticalAlignment = VerticalAlignment.Center };
        foreach (var item in options) combo.Items.Add(new ComboBoxItem { Tag = item.Value, Content = ui.Text(item.Key) });
        string title = ui.Text(titleKey ?? (id.StartsWith("metric.", StringComparison.Ordinal) ? "settings.compact_metric"
            : id == "ring.0" ? "layout.ring_outer" : id == "ring.1" ? "layout.ring_inner" : "settings.window_weekly"));
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
        if (compactTiles.Count == 0 || compactInspector == null) { RebuildPane("collapsed"); RefreshValues(); return; }
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
            if (!compactTiles.TryGetValue(component.Id, out var tile)) continue;
            tile.Root.Visibility = component.Available ? Visibility.Visible : Visibility.Collapsed;
            PaintLibraryTile(tile, component.Shown, component.Id == selected, locked: false, available: true, tint: null, "main.library.add_to_bar", "main.library.remove_from_bar");
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
        // A component off the bar keeps its settings to change now; they apply once it is added.
        ShowLibraryNotice(compactNotice!, chosen != null && !placed ? ui.Text("main.library.not_added") : null, locked: false);
        foreach (var panel in compactInspectorPanels) if (panel.Key != "box") panel.Value.Visibility = panel.Key == selected ? Visibility.Visible : Visibility.Collapsed;
        compactWindowsPanel!.Visibility = selected is "quota" or "quotaGauge" or "timeRemaining" ? Visibility.Visible : Visibility.Collapsed;
        compactChoices["singleTask"].SelectedValue = session.Current.CompactSingleTask;
        foreach (var segment in compactMetric) segment.Value.IsChecked = segment.Key == session.Current.CompactMetric;
        // Choices read back from the projection, which has already applied each fallback.
        var choices = projection.Choices;
        compactChoices["multiRing"].SelectedValue = choices.MultiRing; compactChoices["statusShow"].SelectedValue = choices.StatusShow;
        compactChoices["quotaMultiple"].SelectedValue = choices.QuotaMultiple; compactChoices["ringLayout"].SelectedValue = choices.RingLayout;
        void Pick(string id, string value) { foreach (var segment in compactSegments[id]) segment.Value.IsChecked = segment.Key == value; }
        Pick("multiCore", choices.MultiCore); Pick("endMark", choices.EndMark ? "on" : "off"); Pick("statusWidth", choices.StatusWidth);
        Pick("rateMeasure", choices.RateMeasure); Pick("firstOutput", choices.FirstOutput);
        Pick("paceTick", choices.PaceTick ? "on" : "off"); Pick("lowColor", choices.LowColor ? "on" : "off"); Pick("ringDim", choices.RingDim ? "on" : "off");
        Pick("deepseekRing", session.Current.DeepSeekRingPeriod); Pick("clockShow", choices.ClockShow); Pick("timeStyle", choices.TimeStyle);
        Pick("warningStyle", choices.WarningStyle); Pick("warningLimit", choices.WarningLimit == 2 ? "2" : "0");
        // The core's average needs the average ring.
        foreach (var segment in compactSegments["multiCore"].Values) segment.IsEnabled = choices.MultiRing == "average";
        compactOptionRows["deepseekRing"].Visibility = providers.Contains("deepseek") && session.Current.DeepSeekDailyBudget != null
            && session.Current.DeepSeekWeeklyBudget != null ? Visibility.Visible : Visibility.Collapsed;
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
