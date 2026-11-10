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

/// The Expanded Panel page, as on the Mac: the panel's blocks in order on the
/// left, to click and drag; every block by group to add or remove; and the
/// selected block's choices. Order, additions and moves come from Core's
/// ExpandedPanelPresentation through the engine; each choice saves one field.
internal sealed partial class SettingsWindow
{
    private const string ActionsBlock = "actions";
    private StackPanel? panelEditor;
    private TextBlock? panelAutomatic;
    private Button? panelRestore;
    private PanelEditorProjection? panelProjection;
    private string? panelSelected;
    private readonly Dictionary<string, CheckBox> panelTiles = new();
    private readonly Dictionary<string, IconGlyph> panelTileMarks = new();
    private readonly Dictionary<string, FrameworkElement> panelInspectorPanels = new();
    private readonly Dictionary<string, Dictionary<string, RadioButton>> panelSegments = new();
    private readonly Dictionary<string, CheckBox> panelChecks = new();
    private ComboBox? panelRetention;
    private Border? panelInspectorIcon;
    private TextBlock? panelInspectorTitle, panelInspectorDetail, panelInspectorNote;
    private Button? panelInspectorToggle, panelInspectorUp, panelInspectorDown, panelInfoButton;
    private FrameworkElement? panelMoves;
    private Point? panelDragStart;
    private string? panelDragBlock;

    private void ClearExpandedPanel()
    {
        panelEditor = null; panelAutomatic = null; panelRestore = null; panelProjection = null;
        panelTiles.Clear(); panelTileMarks.Clear(); panelInspectorPanels.Clear(); panelSegments.Clear(); panelChecks.Clear(); panelRetention = null;
        panelInspectorIcon = null; panelInspectorTitle = panelInspectorDetail = panelInspectorNote = null;
        panelInspectorToggle = panelInspectorUp = panelInspectorDown = panelInfoButton = null; panelMoves = null;
        panelDragStart = null; panelDragBlock = null;
    }

    private static bool HasDeepSeekBudget(DesktopPreferences p) => p.DeepSeekMode == "budget" && (p.DeepSeekDailyBudget != null || p.DeepSeekWeeklyBudget != null);
    private object PanelInput(DesktopPreferences p, PanelAction? action = null) => new
    {
        panel = new { layout = p.ExpandedPanelLayout, options = p.ExpandedPanelOptions, providers = NativeCompactBar.Providers(p, engine?.LatestSnapshot),
            deepseekDetailed = p.DeepSeekPanelStyle != "simple", hasBudget = HasDeepSeekBudget(p), language = ui.Language, action }
    };
    private static bool ValidPanel(PanelEditorProjection value) => value.IsValid;
    private PanelEditorProjection? ReadPanel() => ShellProjection.Read<PanelEditorProjection>("projectExpandedPanel", PanelInput(session.Current), ValidPanel).Value;

    /// One edit to the blocks: Core applies it and returns the layout to save.
    private async Task EditPanel(PanelAction action)
    {
        if (sourceClosed || activePane != "expandedPanel" || busy) return;
        await Change(async p =>
        {
            var result = await ShellProjection.QueryAsync<PanelEditorProjection>("projectExpandedPanel", PanelInput(p, action), ValidPanel);
            return p with { ExpandedPanelLayout = result.LayoutJSON };
        });
        RefreshValues();
    }
    /// Only the chosen field changes; the others stay as saved, even a value this version cannot read.
    private Task ChoosePanel(string field, object value)
        => Change(p => p with { ExpandedPanelOptions = PanelChoices.With(p.ExpandedPanelOptions, field, value) });

    /// Opens this page with a block selected, as the Notifications link does.
    private async Task NavigateToPanelBlockAsync(string block)
    {
        panelSelected = block;
        await NavigateAsync("expandedPanel");
        if (!sourceClosed && activePane == "expandedPanel") SelectPanelBlock(block);
    }

    private void BuildExpandedPanel()
    {
        paneSubtitle.Text = ui.Text("main.panel.subtitle"); paneSubtitle.Visibility = Visibility.Visible;
        panelProjection = ReadPanel();
        if (panelProjection == null)
        {
            form.Children.Add(Detail(!ShellProjection.HasFailure("projectExpandedPanel") ? "…" : ui.Text("windows.connection.refresh_failed")));
            return;
        }
        // Restoring the automatic layout sits at the header's end, as on the Mac.
        panelRestore = new Button { Content = ui.Text("main.panel.restore") };
        Identify(panelRestore, "panel.restore", ui.Text("main.panel.restore")); editors.Add(panelRestore);
        panelRestore.Click += async (_, _) => { if (panelRestore.IsVisible && activePane == "expandedPanel") await EditPanel(new("restore")); };
        SetPaneHeader(panelRestore, true);

        var columns = new Grid();
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(280) }); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        columns.ColumnDefinitions.Add(new ColumnDefinition());
        var left = new StackPanel();
        panelEditor = new StackPanel();
        var frame = IslandCard(panelEditor, new Thickness(10, 10, 10, 12)); frame.CornerRadius = new CornerRadius(22);
        Identify(frame, "panel.editor", ui.Text("settings.pane.expanded_panel"));
        left.Children.Add(frame);
        panelAutomatic = Detail(""); panelAutomatic.Margin = new Thickness(4, 0, 4, 0); Identify(panelAutomatic, "panel.automatic", "");
        left.Children.Add(panelAutomatic);
        columns.Children.Add(left);

        var right = new StackPanel(); Grid.SetColumn(right, 2);
        right.Children.Add(SectionTitle(ui.Text("main.panel.blocks")));
        var groups = new StackPanel { Margin = new Thickness(14) };
        foreach (var group in panelProjection.Groups.Select(value => (value.Id, value.Label, Blocks: (IEnumerable<string>)value.Blocks))
            .Append(("panel", ui.Text("panel.group.panel"), new[] { ActionsBlock })))
        {
            var heading = Label(group.Label, 11.5);
            heading.Margin = new Thickness(0, groups.Children.Count == 0 ? 0 : 14, 0, 7);
            heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level3);
            var tiles = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, Margin = new Thickness(0, 0, -6, -6) };
            foreach (string id in group.Blocks) tiles.Children.Add(PanelTile(id));
            groups.Children.Add(new StackPanel { Children = { heading, tiles } });
        }
        right.Children.Add(Card(groups));
        right.Children.Add(SectionTitle(ui.Text("main.panel.selected")));
        right.Children.Add(Card(BuildPanelInspector()));
        columns.Children.Add(right);
        form.Children.Add(columns);
    }

    private string BlockLabel(string id) => id == ActionsBlock ? ui.Text("panel.block.actions")
        : panelProjection?.Catalog.FirstOrDefault(value => value.Id == id)?.Label ?? id;
    private string BlockDetail(string id) => id == ActionsBlock ? ui.Text("panel.block_detail.actions")
        : panelProjection?.Catalog.FirstOrDefault(value => value.Id == id)?.Detail ?? "";
    private string BlockSymbol(string id) => id == ActionsBlock ? "ellipsis.circle"
        : panelProjection?.Catalog.FirstOrDefault(value => value.Id == id)?.Symbol ?? "square.grid.2x2";

    /// A block in the library: a check while it is in the panel, a plus to add it.
    /// The buttons are always there, so their tile only selects them.
    private CheckBox PanelTile(string id)
    {
        var tile = new CheckBox { Style = (Style)FindResource("SettingsComponentTile"), Margin = new Thickness(0, 0, 6, 6) };
        var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new IconGlyph { Symbol = BlockSymbol(id), Width = 12, Height = 12, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        icon.SetBinding(IconGlyph.InkProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = tile }); row.Children.Add(icon);
        var name = Label(BlockLabel(id), 12.5); name.TextTrimming = TextTrimming.CharacterEllipsis;
        name.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = tile }); Grid.SetColumn(name, 1); row.Children.Add(name);
        var mark = new IconGlyph { Width = 10, Height = 10, Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(mark, 2); row.Children.Add(mark);
        tile.Content = row; panelTiles[id] = tile; panelTileMarks[id] = mark; editors.Add(tile);
        Identify(tile, "panel.block." + id, BlockLabel(id)); AutomationProperties.SetHelpText(tile, BlockDetail(id));
        RoutedEventHandler changed = async (_, _) =>
        {
            if (synchronizing || !tile.IsVisible || !tile.IsEnabled || !panelTiles.TryGetValue(id, out var current) || !ReferenceEquals(tile, current)) return;
            panelSelected = id;
            if (id == ActionsBlock || panelProjection?.Catalog.FirstOrDefault(value => value.Id == id) is { Locked: true }) { RefreshValues(); return; }
            await EditPanel(new("toggle", id));
        };
        tile.Checked += changed; tile.Unchecked += changed;
        return tile;
    }

    /// The selected block's card: its name with info, Add or Remove, moves,
    /// then the choices that change it.
    private StackPanel BuildPanelInspector()
    {
        var body = new StackPanel();
        var header = new Grid { Margin = new Thickness(14, 12, 14, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        panelInspectorIcon = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(7), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        panelInspectorIcon.SetResourceReference(Border.BackgroundProperty, "SettingsAccentSoft"); header.Children.Add(panelInspectorIcon);
        var titleLine = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        panelInspectorTitle = Label("", 13.5, FontWeights.SemiBold); panelInspectorTitle.TextTrimming = TextTrimming.CharacterEllipsis; panelInspectorTitle.MaxWidth = 150;
        Identify(panelInspectorTitle, "panel.inspector.title", ""); titleLine.Children.Add(panelInspectorTitle);
        var box = InfoBox(""); box.Margin = new Thickness(14, 0, 14, 10);
        panelInspectorDetail = (TextBlock)box.Child;
        panelInfoButton = InfoButton(ui.Text("main.panel.selected"), box, "panel.inspector"); titleLine.Children.Add(panelInfoButton);
        Grid.SetColumn(titleLine, 1); header.Children.Add(titleLine);
        panelInspectorToggle = new Button { VerticalAlignment = VerticalAlignment.Center }; Identify(panelInspectorToggle, "panel.inspector.toggle", "");
        panelInspectorToggle.Click += async (_, _) =>
        {
            if (panelSelected == null || panelSelected == ActionsBlock || !panelInspectorToggle.IsVisible || !panelInspectorToggle.IsEnabled) return;
            await EditPanel(new("toggle", panelSelected));
        };
        editors.Add(panelInspectorToggle); Grid.SetColumn(panelInspectorToggle, 2); header.Children.Add(panelInspectorToggle);
        body.Children.Add(header); body.Children.Add(box);
        panelInspectorNote = Detail(""); panelInspectorNote.Margin = new Thickness(14, 0, 14, 10); Identify(panelInspectorNote, "panel.inspector.note", "");
        body.Children.Add(panelInspectorNote);

        // Up and Down move among the blocks the panel shows now.
        var moves = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left };
        // The settings button template draws text content, as the Mac's bordered buttons do.
        Button Move(string key, int offset)
        {
            var button = new Button { Content = (offset < 0 ? "↑  " : "↓  ") + ui.Text(key), Margin = new Thickness(0, 0, 8, 0) };
            Identify(button, "panel.inspector." + (offset < 0 ? "up" : "down"), ui.Text(key)); editors.Add(button);
            button.Click += async (_, _) => { if (panelSelected != null && button.IsVisible && button.IsEnabled) await EditPanel(new("shift", panelSelected, Offset: offset)); };
            moves.Children.Add(button); return button;
        }
        panelInspectorUp = Move("main.panel.move_up", -1); panelInspectorDown = Move("main.panel.move_down", 1);
        var movesHost = new StackPanel(); movesHost.Children.Add(Hairline(14));
        var movesRow = new Border { Child = moves, Margin = new Thickness(14, 10, 14, 10) }; movesHost.Children.Add(movesRow);
        panelMoves = movesHost; body.Children.Add(movesHost);

        (string, string)[] ShowHide() => [("on", "main.panel.show"), ("off", "main.panel.hide")];
        StackPanel Option(string id, string titleKey, UIElement control, string? info = null)
        {
            var host = new StackPanel(); host.Children.Add(Hairline(14));
            var inner = new StackPanel { Margin = new Thickness(14, 10, 14, 10) };
            var heading = new WrapPanel(); var label = Label(ui.Text(titleKey)); label.TextWrapping = TextWrapping.Wrap; heading.Children.Add(label);
            inner.Children.Add(heading);
            if (control is FrameworkElement element) { element.HorizontalAlignment = HorizontalAlignment.Left; element.Margin = new Thickness(0, 7, 0, 0); }
            inner.Children.Add(control);
            if (info != null)
            {
                var infoBox = InfoBox(info); infoBox.Margin = new Thickness(0, 8, 0, 0); inner.Children.Add(infoBox);
                heading.Children.Add(InfoButton(ui.Text(titleKey), infoBox, "panel.option." + id)); AutomationProperties.SetHelpText(control, info);
            }
            host.Children.Add(inner); return host;
        }
        StackPanel Note(string key)
        {
            var host = new StackPanel(); host.Children.Add(Hairline(14));
            var note = Detail(ui.Text(key)); note.Margin = new Thickness(14, 8, 14, 10); host.Children.Add(note); return host;
        }

        // The task list.
        var tasks = new StackPanel();
        tasks.Children.Add(Option("pageSize", "main.panel.page_size", PanelSegmentChoices("pageSize", "main.panel.page_size",
            [("3", "3"), ("4", "4"), ("5", "5"), ("6", "6")], value => ChoosePanel("pageSize", int.Parse(value, System.Globalization.CultureInfo.InvariantCulture)), literal: true),
            ui.Text("main.panel.page_size_help")));
        tasks.Children.Add(Option("rowStyle", "main.panel.row_style", PanelSegmentChoices("rowStyle", "main.panel.row_style",
            [("twoLine", "main.panel.row_two"), ("oneLine", "main.panel.row_one")], value => ChoosePanel("rowStyle", value)), ui.Text("main.panel.row_style_help")));
        var fields = new StackPanel();
        foreach (var (field, note) in new[] { ("rate", (string?)null), ("turnTime", null), ("model", null), ("source", "panel.field.source_note"), ("subagents", null), ("cost", "panel.field.cost_note") })
            fields.Children.Add(PanelCheck("field." + field, ui.Text("panel.field." + field), note == null ? null : ui.Text(note), async () =>
            {
                var chosen = new[] { "rate", "turnTime", "model", "source", "subagents", "cost" }
                    .Where(name => panelChecks.TryGetValue("field." + name, out var box) && box.IsChecked == true).ToArray();
                await ChoosePanel("rowFields", chosen);
            }));
        tasks.Children.Add(Option("rowFields", "main.panel.fields", fields, ui.Text("main.panel.fields_help")));
        panelRetention = new ComboBox { VerticalAlignment = VerticalAlignment.Center, SelectedValuePath = "Tag" };
        foreach (var item in new[] { (5, "settings.five_minutes"), (15, "settings.fifteen_minutes"), (30, "settings.thirty_minutes"), (60, "settings.one_hour"), (240, "settings.four_hours"), (0, "settings.until_clicked") })
            panelRetention.Items.Add(new ComboBoxItem { Tag = item.Item1, Content = ui.Text(item.Item2) });
        Identify(panelRetention, "panel.option.retention", ui.Text("reminders.retention")); editors.Add(panelRetention);
        panelRetention.SelectionChanged += async (_, _) =>
        { if (!synchronizing && activePane == "expandedPanel" && panelRetention.SelectedValue is int minutes) await Change(p => p with { RetentionMinutes = minutes }); };
        var retention = new StackPanel(); retention.Children.Add(Hairline(14)); retention.Children.Add(InfoRow(ui.Text("reminders.retention"), panelRetention));
        tasks.Children.Add(retention);
        var hidden = new StackPanel(); hidden.Children.Add(Hairline(14));
        hidden.Children.Add(LinkRow(ui.Text("settings.hide_projects"), ui.Text("main.panel.in_general"), "panel.link.hide_projects",
            async () => { if (activePane == "expandedPanel") await NavigateAsync("general"); }));
        tasks.Children.Add(hidden);
        panelInspectorPanels["tasks"] = tasks; body.Children.Add(tasks);

        // Codex and Claude: each its own windows, the rest shared by every quota.
        foreach (string provider in new[] { "codex", "claude" })
        {
            var quota = new StackPanel();
            quota.Children.Add(Option(provider + "Periods", "main.panel.periods", PanelSegmentChoices(provider + "Periods", "main.panel.periods",
                [("both", "main.panel.periods_both"), ("weekly", "main.panel.periods_weekly"), ("fiveHour", "main.panel.periods_five")],
                value => ChoosePanel(provider + "Periods", value))));
            quota.Children.Add(Option(provider + ".style", "main.panel.style", PanelSegmentChoices(provider + ".style", "main.panel.style",
                [("split", "appearance.quota_split"), ("classic", "appearance.quota_classic")], value => Change(p => p with { ExpandedQuotaStyle = value }))));
            quota.Children.Add(Option(provider + ".arrange", "main.panel.arrange", PanelSegmentChoices(provider + ".arrange", "main.panel.arrange",
                [("pair", "main.panel.arrange_pair"), ("stack", "main.panel.arrange_stack")], value => ChoosePanel("quotaArrange", value))));
            quota.Children.Add(Option(provider + ".details", "main.panel.details", PanelSegmentChoices(provider + ".details", "main.panel.details",
                ShowHide(), value => ChoosePanel("quotaDetails", value == "on")), ui.Text("main.panel.details_help")));
            quota.Children.Add(Option(provider + ".paceTick", "main.panel.pace_tick", PanelSegmentChoices(provider + ".paceTick", "main.panel.pace_tick",
                ShowHide(), value => ChoosePanel("paceTick", value == "on")), ui.Text("main.panel.pace_tick_help")));
            quota.Children.Add(Note("main.panel.shared_note"));
            panelInspectorPanels[provider] = quota; body.Children.Add(quota);
        }

        var deepseek = new StackPanel();
        deepseek.Children.Add(Option("dial", "main.panel.dial", PanelSegmentChoices("dial", "main.panel.dial",
            [("budget", "main.panel.dial_budget"), ("day", "main.panel.dial_day")], value => ChoosePanel("deepseekDial", value)), ui.Text("main.panel.dial_help")));
        deepseek.Children.Add(Option("peak", "main.panel.peak", PanelSegmentChoices("peak", "main.panel.peak",
            ShowHide(), value => ChoosePanel("deepseekPeak", value == "on")), ui.Text("main.panel.peak_help")));
        var budgetLink = new StackPanel(); budgetLink.Children.Add(Hairline(14));
        budgetLink.Children.Add(LinkRow(ui.Text("main.panel.budget_link"), ui.Text("main.panel.in_deepseek"), "panel.link.deepseek",
            async () => { if (activePane == "expandedPanel") await NavigateAsync("deepseek"); }));
        deepseek.Children.Add(budgetLink);
        panelInspectorPanels["deepseek"] = deepseek; body.Children.Add(deepseek);

        var spend = new StackPanel();
        spend.Children.Add(Option("spendTasks", "main.panel.spend_tasks", PanelSegmentChoices("spendTasks", "main.panel.spend_tasks",
            [("2", "2"), ("4", "4")], value => ChoosePanel("spendTasks", value == "4" ? 4 : 2), count: true), ui.Text("main.panel.spend_tasks_help")));
        spend.Children.Add(Option("elsewhere", "main.panel.elsewhere", PanelSegmentChoices("elsewhere", "main.panel.elsewhere",
            ShowHide(), value => ChoosePanel("spendElsewhere", value == "on")), ui.Text("main.panel.elsewhere_help")));
        panelInspectorPanels["deepseekSpend"] = spend; body.Children.Add(spend);

        var week = new StackPanel();
        week.Children.Add(Option("weekLine", "main.panel.week_line", PanelSegmentChoices("weekLine", "main.panel.week_line",
            ShowHide(), value => ChoosePanel("weekLine", value == "on")), ui.Text("main.panel.week_line_help")));
        panelInspectorPanels["deepseekWeek"] = week; body.Children.Add(week);

        // The header's buttons; Open apps keeps its own setting.
        var actionChecks = new StackPanel();
        actionChecks.Children.Add(PanelCheck("action.apps", ui.Text("panel.action.apps"), "Codex · Claude · DeepSeek",
            () => Change(p => p with { ShowAppButtons = panelChecks["action.apps"].IsChecked == true })));
        foreach (string action in new[] { "markRead", "pin", "settings" })
            actionChecks.Children.Add(PanelCheck("action." + action, ui.Text("panel.action." + action), null, async () =>
            {
                var chosen = new[] { "markRead", "pin", "settings" }
                    .Where(name => panelChecks.TryGetValue("action." + name, out var box) && box.IsChecked == true).ToArray();
                await ChoosePanel("headerActions", chosen);
            }));
        var actions = new StackPanel(); actions.Children.Add(Option("headerActions", "main.panel.actions", actionChecks, ui.Text("main.panel.actions_help")));
        panelInspectorPanels[ActionsBlock] = actions; body.Children.Add(actions);
        return body;
    }

    /// A choice as the Mac's segmented control. `literal` shows the values as
    /// they are; `count` names a number of tasks.
    private Border PanelSegmentChoices(string id, string titleKey, (string Value, string Key)[] options, Func<string, Task> edit, bool literal = false, bool count = false)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var group = panelSegments[id] = new();
        foreach (var (value, key) in options)
        {
            string text = count ? ui.Text("main.panel.spend_count").Replace("%ld", key, StringComparison.Ordinal) : literal ? key : ui.Text(key);
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), GroupName = "panel.option." + id, Content = text };
            Identify(choice, "panel.option." + id + "." + value, text); editors.Add(choice); group[value] = choice; row.Children.Add(choice);
            choice.Checked += async (_, _) =>
            {
                if (synchronizing || activePane != "expandedPanel" || !choice.IsVisible || !choice.IsEnabled || busy) return;
                await edit(value);
            };
        }
        var track = new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        track.SetResourceReference(Border.BackgroundProperty, "SettingsFill"); Identify(track, "panel.option." + id, ui.Text(titleKey)); return track;
    }

    private FrameworkElement PanelCheck(string id, string title, string? note, Func<Task> edit)
    {
        var check = new CheckBox { Style = (Style)FindResource("SettingsCheck"), Margin = new Thickness(0, 3, 0, 3), VerticalAlignment = VerticalAlignment.Center };
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(Label(title, 12.5));
        if (note != null) { var detail = Label(note, 11.5); detail.Margin = new Thickness(6, 0, 0, 0); detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); content.Children.Add(detail); }
        check.Content = content; Identify(check, "panel.option." + id, title); editors.Add(check); panelChecks[id] = check;
        RoutedEventHandler changed = async (_, _) => { if (!synchronizing && activePane == "expandedPanel" && check.IsVisible && check.IsEnabled && !busy) await edit(); };
        check.Checked += changed; check.Unchecked += changed;
        return check;
    }

    /// A row that opens another page or place: its title, where it leads, and a chevron.
    private Button LinkRow(string title, string? destination, string id, Func<Task> open)
    {
        var row = new Grid { MinHeight = 44 };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = Label(title, 13); label.TextWrapping = TextWrapping.Wrap; label.Margin = new Thickness(0, 8, 8, 8); row.Children.Add(label);
        if (destination != null)
        {
            var where = Label(destination, 12.5); where.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); Grid.SetColumn(where, 1); row.Children.Add(where);
        }
        var chevron = new IconGlyph { Symbol = "chevron.right", Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        chevron.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); Grid.SetColumn(chevron, 2); row.Children.Add(chevron);
        var button = new Button { Style = (Style)FindResource("SettingsRowButton"), Content = row };
        Identify(button, id, destination == null ? title : title + " · " + destination); editors.Add(button);
        button.Click += async (_, _) => { if (button.IsVisible && button.IsEnabled) await open(); };
        return button;
    }

    internal void SelectPanelBlock(string id)
    {
        if (id != panelSelected && panelInfoButton != null && panelInspectorDetail?.Parent is Border box) SetInfoShown(panelInfoButton, box, false);
        panelSelected = id;
        bool previous = synchronizing; synchronizing = true;
        try { RefreshExpandedPanel(); } finally { synchronizing = previous; }
    }

    private void RefreshExpandedPanel()
    {
        if (panelEditor == null || activePane != "expandedPanel") return;
        var projection = ReadPanel();
        if (projection == null) { panelEditor.IsEnabled = false; return; }
        panelProjection = projection; panelEditor.IsEnabled = !busy && !session.RequiresRestart;
        var preferences = session.Current; var options = projection.Options;
        var catalog = projection.Catalog.ToDictionary(value => value.Id);
        string selected = panelSelected is { } chosen && (chosen == ActionsBlock || catalog.ContainsKey(chosen)) ? chosen
            : projection.Visible.FirstOrDefault() ?? "tasks";
        panelSelected = selected;
        bool saved = preferences.ExpandedPanelLayout != null;
        panelRestore!.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        panelAutomatic!.Text = saved ? "" : ui.Text("main.panel.automatic"); panelAutomatic.Visibility = saved ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(panelAutomatic, panelAutomatic.Text);
        DrawPanelEditor(projection, selected, preferences);

        foreach (var (id, tile) in panelTiles)
        {
            bool placed = id == ActionsBlock || catalog.TryGetValue(id, out var block) && block.Placed;
            bool available = id == ActionsBlock || catalog.TryGetValue(id, out var item) && item.Available;
            tile.IsChecked = placed;
            tile.SetResourceReference(ForegroundProperty, placed && available ? "SettingsPrimary" : "SettingsSecondary");
            tile.Tag = id == selected ? "selected" : null;
            if (panelTileMarks.TryGetValue(id, out var mark))
            {
                mark.Symbol = placed ? "checkmark" : "plus";
                mark.SetResourceReference(IconGlyph.InkProperty, placed ? "SettingsAccent" : "SettingsSecondary");
            }
        }

        bool actions = selected == ActionsBlock;
        var entry = actions ? null : catalog[selected];
        bool shown = actions || entry!.Placed;
        panelInspectorTitle!.Text = BlockLabel(selected); AutomationProperties.SetName(panelInspectorTitle, panelInspectorTitle.Text);
        if (panelInfoButton != null) AutomationProperties.SetName(panelInfoButton, ui.Text("main.info").Replace("%@", panelInspectorTitle.Text, StringComparison.Ordinal));
        var glyph = new IconGlyph { Symbol = BlockSymbol(selected), Width = 12, Height = 12 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsAccent"); panelInspectorIcon!.Child = glyph;
        panelInspectorDetail!.Text = BlockDetail(selected);
        panelInspectorToggle!.Visibility = actions ? Visibility.Collapsed : Visibility.Visible;
        panelInspectorToggle.Content = ui.Text(shown ? "main.collapsed.remove" : "main.collapsed.add");
        panelInspectorToggle.Style = shown ? (Style)FindResource(typeof(Button)) : (Style)FindResource("SettingsProminentButton");
        panelInspectorToggle.IsEnabled = !busy && entry?.Locked != true;
        AutomationProperties.SetName(panelInspectorToggle, panelInspectorTitle.Text + " · " + panelInspectorToggle.Content);
        string note = actions ? ui.Text("main.panel.always")
            : entry!.Locked ? ui.Text("main.panel.last")
            : !entry.Available ? ui.Text("main.panel.unavailable").Replace("%@", BlockProviderName(selected), StringComparison.Ordinal) : "";
        panelInspectorNote!.Text = note; panelInspectorNote.Visibility = note.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(panelInspectorNote, note);
        int position = projection.Visible.ToList().IndexOf(selected);
        panelMoves!.Visibility = !actions && position >= 0 && projection.Visible.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        panelInspectorUp!.IsEnabled = !busy && position > 0; panelInspectorDown!.IsEnabled = !busy && position >= 0 && position < projection.Visible.Count - 1;
        foreach (var (id, panel) in panelInspectorPanels) panel.Visibility = id == selected && shown ? Visibility.Visible : Visibility.Collapsed;

        void Pick(string id, string value) { if (panelSegments.TryGetValue(id, out var group)) foreach (var (key, choice) in group) choice.IsChecked = key == value; }
        string OnOff(bool value) => value ? "on" : "off";
        Pick("pageSize", options.PageSize.ToString(System.Globalization.CultureInfo.InvariantCulture)); Pick("rowStyle", options.RowStyle);
        foreach (string field in new[] { "rate", "turnTime", "model", "source", "subagents", "cost" }) panelChecks["field." + field].IsChecked = options.RowFields.Contains(field);
        // One line keeps only the speed and the turn time.
        foreach (string field in new[] { "model", "source", "subagents", "cost" }) panelChecks["field." + field].IsEnabled = !busy && !options.OneLine;
        panelRetention!.SelectedValue = preferences.RetentionMinutes;
        foreach (string provider in new[] { "codex", "claude" })
        {
            Pick(provider + "Periods", options.Periods(provider)); Pick(provider + ".style", preferences.ExpandedQuotaStyle);
            Pick(provider + ".arrange", options.QuotaArrange); Pick(provider + ".details", OnOff(options.QuotaDetails)); Pick(provider + ".paceTick", OnOff(options.PaceTick));
        }
        Pick("dial", options.DeepseekDial); Pick("peak", OnOff(options.DeepseekPeak));
        Pick("spendTasks", options.SpendTasks == 4 ? "4" : "2"); Pick("elsewhere", OnOff(options.SpendElsewhere)); Pick("weekLine", OnOff(options.WeekLine));
        panelChecks["action.apps"].IsChecked = preferences.ShowAppButtons;
        foreach (string action in new[] { "markRead", "pin", "settings" }) panelChecks["action." + action].IsChecked = options.InHeader(action);
    }

    private static string BlockProviderName(string block) => block switch
    {
        "codex" => "Codex", "claude" => "Claude", _ => "DeepSeek"
    };

    /// The panel's outline: each shown block in order, paired quotas side by
    /// side and the buttons in the first header. Click selects; drag moves.
    private void DrawPanelEditor(PanelEditorProjection projection, string selected, DesktopPreferences preferences)
    {
        var editor = panelEditor!; editor.Children.Clear();
        var options = projection.Options;
        foreach (var (section, index) in projection.Sections.Select((value, index) => (value, index)))
        {
            if (index > 0)
            {
                if (section.Joined) editor.Children.Add(new Border { Height = 6 });
                else editor.Children.Add(new Border { Height = 1, Margin = new Thickness(6, 6, 6, 6), Background = PacerPalette.Overlay(26) });
            }
            var blocks = section.Kind == "quota" ? section.Providers.ToArray() : [section.Kind];
            var row = new Grid();
            for (int column = 0; column < blocks.Length; column++)
            {
                if (column > 0) row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
                row.ColumnDefinitions.Add(new ColumnDefinition());
                var block = PanelBlockButton(blocks[column], selected, options, preferences, section.SpendBeside, paired: blocks.Length > 1);
                Grid.SetColumn(block, row.ColumnDefinitions.Count - 1); row.Children.Add(block);
            }
            if (section.Actions)
            {
                var host = new StackPanel();
                host.Children.Add(PanelActionsStrip(selected == ActionsBlock, options, preferences.ShowAppButtons));
                host.Children.Add(row); editor.Children.Add(host);
            }
            else editor.Children.Add(row);
        }
    }

    private Button PanelActionsStrip(bool selected, PanelOptions options, bool apps)
    {
        var icons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        void Icon(string symbol) => icons.Children.Add(new IconGlyph { Symbol = symbol, Width = 10, Height = 10, Margin = new Thickness(5, 0, 0, 0), Ink = PacerPalette.Secondary });
        if (apps) Icon("square.grid.2x2");
        if (options.InHeader("markRead")) Icon("checkmark.rectangle.stack");
        if (options.InHeader("pin")) Icon("pin");
        if (options.InHeader("settings")) Icon("gearshape");
        Icon("ellipsis");
        var border = new Border { Child = icons, Padding = new Thickness(6, 3, 6, 3), CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(selected ? 2 : 0), BorderBrush = selected ? new SolidColorBrush(Color.FromRgb(10, 132, 255)) : null, Background = Brushes.Transparent };
        var button = new Button { Content = border, Style = (Style)FindResource("SettingsRowButton"), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 0, 4) };
        Identify(button, "panel.editor.actions", ui.Text("panel.block.actions"));
        button.Click += (_, _) => SelectPanelBlock(ActionsBlock);
        return button;
    }

    private string PanelSummary(string id, PanelOptions options, bool spendBeside) => id switch
    {
        "tasks" => options.PageSize + " · " + ui.Text(options.OneLine ? "main.panel.row_one" : "main.panel.row_two"),
        "codex" or "claude" => ui.Text(options.Periods(id) switch { "weekly" => "main.panel.periods_weekly", "fiveHour" => "main.panel.periods_five", _ => "main.panel.periods_both" }),
        "deepseek" => ui.Text(options.DeepseekDial == "day" ? "main.panel.dial_day" : "main.panel.dial_budget"),
        "deepseekSpend" => ui.Text("main.panel.spend_count").Replace("%ld", options.SpendTasks.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal),
        "deepseekWeek" => ui.Text(options.WeekLine ? "main.panel.show" : "main.panel.hide") + " · " + ui.Text("main.panel.week_line"),
        _ => ""
    };

    /// <param name="paired">Quotas sharing a row are narrow, so they show only the service's name, as on the Mac.</param>
    private Button PanelBlockButton(string id, string selected, PanelOptions options, DesktopPreferences preferences, bool spendBeside, bool paired = false)
    {
        bool isSelected = id == selected;
        var content = new StackPanel { Margin = paired ? new Thickness(6, 8, 6, 8) : new Thickness(10, 8, 10, 8) };
        var title = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = paired ? HorizontalAlignment.Center : HorizontalAlignment.Left };
        Brush tint = id switch { "codex" or "claude" or "deepseek" => PacerPalette.Provider(id), "deepseekSpend" or "deepseekWeek" => PacerPalette.DeepSeek, _ => PacerPalette.Secondary };
        if (!paired) title.Children.Add(new IconGlyph { Symbol = BlockSymbol(id), Width = 12, Height = 12, Ink = tint, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        title.Children.Add(new TextBlock { Text = paired ? BlockProviderName(id) : BlockLabel(id), FontSize = 12.5, FontWeight = FontWeights.SemiBold,
            Foreground = paired ? tint : PacerPalette.Primary, TextTrimming = TextTrimming.CharacterEllipsis });
        content.Children.Add(title);
        string summary = paired ? "" : PanelSummary(id, options, spendBeside);
        if (summary.Length > 0)
            content.Children.Add(new TextBlock { Text = summary, FontSize = 11, Foreground = PacerPalette.Secondary, Margin = new Thickness(18, 2, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis });
        var surface = new Border { Child = content, CornerRadius = new CornerRadius(12), Background = PacerPalette.Overlay((byte)(isSelected ? 31 : 15)),
            BorderThickness = new Thickness(isSelected ? 2 : 0), BorderBrush = isSelected ? new SolidColorBrush(Color.FromRgb(10, 132, 255)) : null,
            MinHeight = id == "tasks" ? 56 : 44 };
        var button = new Button { Content = surface, Style = (Style)FindResource("SettingsRowButton"), AllowDrop = true, Tag = id };
        Identify(button, "panel.editor." + id, BlockLabel(id) + (summary.Length > 0 ? ", " + summary : ""));
        AutomationProperties.SetItemStatus(button, isSelected ? ui.Text("main.panel.selected") : "");
        button.Click += (_, _) => { if (panelDragBlock == null) SelectPanelBlock(id); };
        button.PreviewMouseLeftButtonDown += (_, e) => { panelDragStart = e.GetPosition(this); panelDragBlock = null; };
        button.PreviewMouseMove += (_, e) =>
        {
            if (e.LeftButton != MouseButtonState.Pressed || panelDragStart is not Point start || busy) return;
            var now = e.GetPosition(this);
            if (Math.Abs(now.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance && Math.Abs(now.X - start.X) < SystemParameters.MinimumHorizontalDragDistance) return;
            panelDragBlock = id; panelDragStart = null;
            try { DragDrop.DoDragDrop(button, new DataObject("PacerPanelBlock", id), DragDropEffects.Move); }
            finally { _ = Dispatcher.InvokeAsync(() => panelDragBlock = null, System.Windows.Threading.DispatcherPriority.Background); }
        };
        button.DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent("PacerPanelBlock") ? DragDropEffects.Move : DragDropEffects.None; e.Handled = true; };
        button.Drop += async (_, e) =>
        {
            if (e.Data.GetData("PacerPanelBlock") is not string dragged || dragged == id || panelProjection == null) return;
            e.Handled = true;
            // The upper half drops before this block, the lower half after it.
            var visible = panelProjection.Visible.ToList();
            bool after = e.GetPosition(button).Y > button.ActualHeight / 2;
            string? before = after ? visible.SkipWhile(value => value != id).Skip(1).FirstOrDefault(value => value != dragged) : id;
            await EditPanel(new("move", dragged, Before: before));
        };
        return button;
    }
}
