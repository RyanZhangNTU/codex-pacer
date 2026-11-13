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

/// The Expanded Panel page, as on the Mac: on the left the panel's outline to
/// click and drag, then every block to add or remove; on the right the
/// selected block's settings. Order, additions and moves come from Core's
/// ExpandedPanelPresentation through the engine; each choice saves one field.
internal sealed partial class SettingsWindow
{
    private const string ActionsBlock = "actions";
    // The outline and the settings side by side need more than the usual column.
    private const double PanelPageWidth = 700;
    private static readonly (string Field, string Symbol)[] PanelFields =
        [("rate", "speedometer"), ("turnTime", "timer"), ("model", "cpu"), ("source", "server.rack"), ("subagents", "person.2"), ("cost", "yensign.circle")];
    private StackPanel? panelEditor;
    private TextBlock? panelAutomatic;
    private Button? panelRestore;
    private PanelEditorProjection? panelProjection;
    private string? panelSelected;
    private readonly Dictionary<string, LibraryTile> panelTiles = new();
    private readonly Dictionary<string, FrameworkElement> panelInspectorPanels = new();
    private readonly Dictionary<string, Dictionary<string, RadioButton>> panelSegments = new();
    private readonly Dictionary<string, CheckBox> panelSwitches = new(), panelChips = new();
    private ComboBox? panelRetention;
    private Border? panelInspectorIcon, panelNotice;
    private TextBlock? panelInspectorTitle, panelInspectorDetail;
    private Button? panelInspectorToggle, panelInfoButton;
    private PanelRowPreview? panelPreview;
    private Point? panelDragStart;
    private string? panelDragBlock;

    private void ClearExpandedPanel()
    {
        panelEditor = null; panelAutomatic = null; panelRestore = null; panelProjection = null;
        panelTiles.Clear(); panelInspectorPanels.Clear(); panelSegments.Clear(); panelSwitches.Clear(); panelChips.Clear(); panelRetention = null;
        panelInspectorIcon = panelNotice = null; panelInspectorTitle = panelInspectorDetail = null;
        panelInspectorToggle = panelInfoButton = null; panelPreview = null;
        panelDragStart = null; panelDragBlock = null;
    }

    private static bool HasDeepSeekBudget(DesktopPreferences p) => p.DeepSeekMode == "budget" && (p.DeepSeekDailyBudget != null || p.DeepSeekWeeklyBudget != null);
    private string[] PanelProviders(DesktopPreferences preferences)
    {
        var snapshot = engine?.LatestSnapshot;
        var quota = NativeCompactBar.Providers(preferences, snapshot);
        return quota.Concat((snapshot?.Modules ?? []).Where(module => module.Enabled && module.ReportsAccountCredits == true)
            .Select(module => module.Provider)).Distinct(StringComparer.Ordinal).ToArray();
    }
    private object PanelInput(DesktopPreferences p, PanelAction? action = null) => new
    {
        panel = new { layout = p.ExpandedPanelLayout, options = p.ExpandedPanelOptions, providers = PanelProviders(p),
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
        form.MaxWidth = headerColumn.MaxWidth = PanelPageWidth;
        panelProjection = ReadPanel();
        if (panelProjection == null)
        {
            form.Children.Add(Detail(!ShellProjection.HasFailure("projectExpandedPanel") ? "…" : ui.Text("windows.connection.refresh_failed")));
            return;
        }
        // Restoring the automatic layout sits at the header's end once the layout was edited, as on the Mac.
        panelRestore = new Button { Content = ui.Text("main.panel.restore") };
        Identify(panelRestore, "panel.restore", ui.Text("main.panel.restore")); editors.Add(panelRestore);
        panelRestore.Click += async (_, _) => { if (panelRestore.IsVisible && activePane == "expandedPanel") await EditPanel(new("restore")); };
        SetPaneHeader(panelRestore, true);

        var columns = new Grid();
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(270) }); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        columns.ColumnDefinitions.Add(new ColumnDefinition());
        var left = new StackPanel();
        // The panel's outline, and whether it follows the services or was arranged by hand.
        var heading = new Grid { Margin = new Thickness(4, 0, 4, 8) };
        heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Label(ui.Text("panel.group.panel"), 12, FontWeights.SemiBold); title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2); heading.Children.Add(title);
        panelAutomatic = Label("", 11.5); panelAutomatic.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        Identify(panelAutomatic, "panel.automatic", ""); Grid.SetColumn(panelAutomatic, 1); heading.Children.Add(panelAutomatic);
        left.Children.Add(heading);
        panelEditor = new StackPanel();
        var frame = IslandCard(panelEditor, new Thickness(10)); frame.CornerRadius = new CornerRadius(20); frame.Margin = new Thickness(0, 0, 0, 22);
        Identify(frame, "panel.editor", ui.Text("settings.pane.expanded_panel"));
        left.Children.Add(frame);

        // Every block by group, one per line, to add or remove.
        left.Children.Add(SectionTitle(ui.Text("main.panel.blocks")));
        var groups = new StackPanel { Margin = new Thickness(10) };
        foreach (var group in panelProjection.Groups.Select(value => (value.Id, value.Label, Blocks: (IEnumerable<string>)value.Blocks))
            .Append(("panel", ui.Text("panel.group.panel"), new[] { ActionsBlock })))
        {
            var label = Label(group.Label, 11); label.Margin = new Thickness(4, groups.Children.Count == 0 ? 0 : 10, 0, 5);
            label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); AutomationProperties.SetHeadingLevel(label, AutomationHeadingLevel.Level3);
            groups.Children.Add(label);
            foreach (string id in group.Blocks) groups.Children.Add(PanelTile(id));
        }
        left.Children.Add(Card(groups));
        columns.Children.Add(left);

        var right = new StackPanel(); Grid.SetColumn(right, 2);
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
    private string? BlockProvider(string id) => panelProjection?.Catalog.FirstOrDefault(value => value.Id == id && value.Group == "quota")?.Id;
    /// The settings cards' ink for a block's service.
    private static string BlockTint(string id) => id switch
    {
        "codex" => "SettingsTintCodex", "claude" => "SettingsTintClaude", "deepseek" or "deepseekSpend" or "deepseekWeek" => "SettingsTintDeepSeek", _ => "SettingsTintNeutral"
    };

    /// A block in the library: its body selects it; the round button adds or
    /// removes it. The buttons are always there, so they have a note instead.
    private FrameworkElement PanelTile(string id)
    {
        bool fixedTile = id == ActionsBlock;
        LibraryTile? tile = null;
        tile = BuildLibraryTile("panel.block." + id, BlockLabel(id), BlockSymbol(id), BlockDetail(id), () => SelectPanelBlock(id),
            fixedTile ? null : (Func<Task>)(async () =>
            {
                if (tile == null || !panelTiles.TryGetValue(id, out var current) || !ReferenceEquals(tile, current)) return;
                if (panelProjection?.Catalog.FirstOrDefault(value => value.Id == id) is { Locked: true }) return;
                await EditPanel(new("toggle", id));
            }), fixedTile ? ui.Text("main.panel.always") : null, provider: BlockProvider(id));
        tile.Root.Margin = new Thickness(0, 0, 0, 5);
        panelTiles[id] = tile;
        return tile.Root;
    }

    /// The selected block's card: its name with info, moves and Add or Remove,
    /// a note while it is not in the panel, then the settings that change it.
    private StackPanel BuildPanelInspector()
    {
        var body = new StackPanel();
        var header = new Grid { Margin = new Thickness(14, 14, 14, 12) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        panelInspectorIcon = new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(9), Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(panelInspectorIcon);
        var titleLine = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        panelInspectorTitle = Label("", 15, FontWeights.SemiBold); panelInspectorTitle.TextTrimming = TextTrimming.CharacterEllipsis; panelInspectorTitle.MaxWidth = 190;
        Identify(panelInspectorTitle, "panel.inspector.title", ""); titleLine.Children.Add(panelInspectorTitle);
        var box = InfoBox(""); box.Margin = new Thickness(14, 0, 14, 12);
        panelInspectorDetail = (TextBlock)box.Child;
        panelInfoButton = InfoButton(ui.Text("main.panel.selected"), box, "panel.inspector"); titleLine.Children.Add(panelInfoButton);
        Grid.SetColumn(titleLine, 1); header.Children.Add(titleLine);
        panelInspectorToggle = new Button { VerticalAlignment = VerticalAlignment.Center, MinHeight = 26 }; Identify(panelInspectorToggle, "panel.inspector.toggle", "");
        panelInspectorToggle.Click += async (_, _) =>
        {
            if (panelSelected == null || panelSelected == ActionsBlock || !panelInspectorToggle.IsVisible || !panelInspectorToggle.IsEnabled) return;
            await EditPanel(new("toggle", panelSelected));
        };
        editors.Add(panelInspectorToggle); Grid.SetColumn(panelInspectorToggle, 2); header.Children.Add(panelInspectorToggle);
        body.Children.Add(header); body.Children.Add(box);
        panelNotice = LibraryNotice("panel.inspector.notice"); body.Children.Add(panelNotice);

        // A row: a hairline, then the title with any ⓘ and the control at its end.
        StackPanel Line(UIElement row) { var host = new StackPanel(); host.Children.Add(Hairline(14)); host.Children.Add(row); return host; }
        StackPanel Inline(string id, string titleKey, FrameworkElement control, string? helpKey = null)
            => Line(InfoRow(ui.Text(titleKey), control, helpKey == null ? null : ui.Text(helpKey), id: "panel.option." + id));
        // A choice too wide for the row's end sits under its title.
        StackPanel Stacked(string id, string titleKey, FrameworkElement control, string? helpKey = null, bool stretch = false)
        {
            var host = new StackPanel { Margin = new Thickness(14, 10, 14, 12) };
            var heading = new WrapPanel { MinHeight = 24 }; var label = Label(ui.Text(titleKey)); label.TextWrapping = TextWrapping.Wrap; heading.Children.Add(label);
            host.Children.Add(heading);
            control.HorizontalAlignment = stretch ? HorizontalAlignment.Stretch : HorizontalAlignment.Left; control.Margin = new Thickness(0, 6, 0, 0);
            host.Children.Add(control);
            if (helpKey != null)
            {
                var info = InfoBox(ui.Text(helpKey)); info.Margin = new Thickness(0, 10, 0, 0); host.Children.Add(info);
                heading.Children.Add(InfoButton(ui.Text(titleKey), info, "panel.option." + id)); AutomationProperties.SetHelpText(control, ui.Text(helpKey));
            }
            return Line(host);
        }
        StackPanel Switch(string id, string titleKey, string? helpKey, Func<bool, Task> edit)
            => Inline(id, titleKey, PanelSwitch(id, ui.Text(titleKey), edit), helpKey);
        StackPanel Link(string titleKey, string destinationKey, string id, string pane)
            => Line(InfoRow(ui.Text(titleKey), PanelLink(ui.Text(titleKey), ui.Text(destinationKey), id, pane)));

        // The task list.
        var tasks = new StackPanel();
        tasks.Children.Add(Inline("pageSize", "main.panel.page_size", PanelSegmentChoices("pageSize", "main.panel.page_size",
            [("3", "3"), ("4", "4"), ("5", "5"), ("6", "6")], value => ChoosePanel("pageSize", int.Parse(value, System.Globalization.CultureInfo.InvariantCulture)), literal: true),
            "main.panel.page_size_help"));
        tasks.Children.Add(Inline("rowStyle", "main.panel.row_style", PanelSegmentChoices("rowStyle", "main.panel.row_style",
            [("twoLine", "main.panel.row_two"), ("oneLine", "main.panel.row_one")], value => ChoosePanel("rowStyle", value)), "main.panel.row_style_help"));
        tasks.Children.Add(Stacked("rowFields", "main.panel.fields", PanelFieldChoices(), stretch: true));
        panelRetention = new ComboBox { VerticalAlignment = VerticalAlignment.Center, SelectedValuePath = "Tag" };
        foreach (var item in new[] { (5, "settings.five_minutes"), (15, "settings.fifteen_minutes"), (30, "settings.thirty_minutes"), (60, "settings.one_hour"), (240, "settings.four_hours"), (0, "settings.until_clicked") })
            panelRetention.Items.Add(new ComboBoxItem { Tag = item.Item1, Content = ui.Text(item.Item2) });
        Identify(panelRetention, "panel.option.retention", ui.Text("reminders.retention")); editors.Add(panelRetention);
        panelRetention.SelectionChanged += async (_, _) =>
        { if (!synchronizing && activePane == "expandedPanel" && panelRetention.SelectedValue is int minutes) await Change(p => p with { RetentionMinutes = minutes }); };
        tasks.Children.Add(Line(InfoRow(ui.Text("reminders.retention"), panelRetention)));
        tasks.Children.Add(Link("settings.hide_projects", "main.panel.in_general", "panel.link.hide_projects", "general"));
        panelInspectorPanels["tasks"] = tasks; body.Children.Add(tasks);

        foreach (string provider in new[] { "codex", "claude", "workbuddy" })
        {
            var quota = new StackPanel();
            bool account = provider == "workbuddy";
            if (!account)
                quota.Children.Add(Stacked(provider + "Periods", "main.panel.periods", PanelSegmentChoices(provider + "Periods", "main.panel.periods",
                    [("both", "main.panel.periods_both"), ("weekly", "main.panel.periods_weekly"), ("fiveHour", "main.panel.periods_five")],
                    value => ChoosePanel(provider + "Periods", value))));
            quota.Children.Add(Inline(provider + ".style", "main.panel.style", PanelSegmentChoices(provider + ".style", "main.panel.style",
                [("split", "appearance.quota_split"), ("classic", "appearance.quota_classic")], value => Change(p => p with { ExpandedQuotaStyle = value }))));
            quota.Children.Add(Inline(provider + ".arrange", "main.panel.arrange", PanelSegmentChoices(provider + ".arrange", "main.panel.arrange",
                [("pair", "main.panel.arrange_pair"), ("stack", "main.panel.arrange_stack")], value => ChoosePanel("quotaArrange", value))));
            quota.Children.Add(Switch(provider + ".details", "main.panel.details", account ? "harness.account.details_help" : "main.panel.details_help",
                value => ChoosePanel("quotaDetails", value)));
            if (account) quota.Children.Add(Link("harness.account.connection", "harness.account.open_settings", "panel.link.workbuddy", provider));
            else quota.Children.Add(Switch(provider + ".paceTick", "main.panel.pace_tick", "main.panel.pace_tick_help", value => ChoosePanel("paceTick", value)));
            panelInspectorPanels[provider] = quota; body.Children.Add(quota);
        }

        var deepseek = new StackPanel();
        deepseek.Children.Add(Inline("dial", "main.panel.dial", PanelSegmentChoices("dial", "main.panel.dial",
            [("budget", "main.panel.dial_budget"), ("day", "main.panel.dial_day")], value => ChoosePanel("deepseekDial", value)), "main.panel.dial_help"));
        deepseek.Children.Add(Switch("peak", "main.panel.peak", "main.panel.peak_help", value => ChoosePanel("deepseekPeak", value)));
        deepseek.Children.Add(Link("main.panel.budget_link", "main.panel.in_deepseek", "panel.link.deepseek", "deepseek"));
        panelInspectorPanels["deepseek"] = deepseek; body.Children.Add(deepseek);

        var spend = new StackPanel();
        spend.Children.Add(Inline("spendTasks", "main.panel.spend_tasks", PanelSegmentChoices("spendTasks", "main.panel.spend_tasks",
            [("2", "2"), ("4", "4")], value => ChoosePanel("spendTasks", value == "4" ? 4 : 2), count: true), "main.panel.spend_tasks_help"));
        spend.Children.Add(Switch("elsewhere", "main.panel.elsewhere", "main.panel.elsewhere_help", value => ChoosePanel("spendElsewhere", value)));
        panelInspectorPanels["deepseekSpend"] = spend; body.Children.Add(spend);

        var week = new StackPanel();
        week.Children.Add(Switch("weekLine", "main.panel.week_line", "main.panel.week_line_help", value => ChoosePanel("weekLine", value)));
        panelInspectorPanels["deepseekWeek"] = week; body.Children.Add(week);

        // The header's buttons; Open apps keeps its own setting. Those turned off move into ⋯.
        var actions = new StackPanel();
        actions.Children.Add(Switch("action.apps", "panel.action.apps", null, value => Change(p => p with { ShowAppButtons = value })));
        foreach (string action in new[] { "markRead", "pin", "settings" })
            actions.Children.Add(Switch("action." + action, "panel.action." + action, null, _ =>
            {
                var chosen = new[] { "markRead", "pin", "settings" }
                    .Where(name => panelSwitches.TryGetValue("action." + name, out var check) && check.IsChecked == true).ToArray();
                return ChoosePanel("headerActions", chosen);
            }));
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

    private CheckBox PanelSwitch(string id, string title, Func<bool, Task> edit)
    {
        var check = new CheckBox { Style = (Style)FindResource("SettingsSwitch") };
        Identify(check, "panel.option." + id, title); editors.Add(check); panelSwitches[id] = check;
        RoutedEventHandler changed = async (_, _) =>
        { if (!synchronizing && activePane == "expandedPanel" && check.IsVisible && check.IsEnabled && !busy) await edit(check.IsChecked == true); };
        check.Checked += changed; check.Unchecked += changed;
        return check;
    }

    /// Which details a task row shows: a sample row that follows the choices,
    /// then a chip for each detail. One line keeps only the speed and the time.
    private StackPanel PanelFieldChoices()
    {
        var host = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch };
        panelPreview = new PanelRowPreview(ui);
        host.Children.Add(panelPreview.Root);
        var chips = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        AutomationProperties.SetName(chips, ui.Text("main.panel.fields"));
        foreach (var (field, symbol) in PanelFields)
        {
            var chip = new CheckBox { Style = (Style)FindResource("SettingsFieldChip"), Margin = new Thickness(0, 0, 6, 6) };
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            var glyph = new IconGlyph { Symbol = symbol, Width = 12, Height = 12, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            glyph.SetBinding(IconGlyph.InkProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = chip }); content.Children.Add(glyph);
            var text = new TextBlock { Text = ui.Text("panel.chip." + field), FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
            text.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = chip });
            text.SetBinding(TextBlock.FontWeightProperty, new System.Windows.Data.Binding(nameof(FontWeight)) { Source = chip });
            content.Children.Add(text);
            chip.Content = content; Identify(chip, "panel.option.field." + field, ui.Text("panel.field." + field)); panelChips[field] = chip;
            RoutedEventHandler changed = async (_, _) =>
            {
                if (synchronizing || activePane != "expandedPanel" || !chip.IsVisible || !chip.IsEnabled || busy) return;
                var chosen = PanelFields.Select(item => item.Field).Where(name => panelChips.TryGetValue(name, out var box) && box.IsChecked == true).ToArray();
                await ChoosePanel("rowFields", chosen);
            };
            chip.Checked += changed; chip.Unchecked += changed;
            chips.Children.Add(chip);
        }
        host.Children.Add(chips);
        return host;
    }

    /// Where a setting lives on another page: its name in the link color and a chevron.
    private Button PanelLink(string title, string destination, string id, string pane)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var text = Label(destination, 12.5); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsLinkText"); content.Children.Add(text);
        var chevron = new IconGlyph { Symbol = "chevron.right", Width = 9, Height = 9, Margin = new Thickness(4, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        chevron.SetResourceReference(IconGlyph.InkProperty, "SettingsLinkText"); content.Children.Add(chevron);
        var button = new Button { Style = (Style)FindResource("SettingsLink"), ContentTemplate = null, Content = content, Cursor = Cursors.Hand };
        Identify(button, id, title + " · " + destination); editors.Add(button);
        button.Click += async (_, _) => { if (button.IsVisible && button.IsEnabled && activePane == "expandedPanel") await NavigateAsync(pane); };
        return button;
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
        panelAutomatic!.Text = ui.Text(saved ? "main.panel.custom" : "main.panel.automatic_short");
        AutomationProperties.SetName(panelAutomatic, panelAutomatic.Text);
        DrawPanelEditor(projection, selected, preferences);

        foreach (var (id, tile) in panelTiles)
        {
            bool actionsTile = id == ActionsBlock;
            catalog.TryGetValue(id, out var block);
            PaintLibraryTile(tile, actionsTile || block?.Placed == true, id == selected, block?.Locked == true, actionsTile || block?.Available != false,
                BlockTint(id), "main.library.add_to_panel", "main.library.remove_from_panel");
        }

        bool actions = selected == ActionsBlock;
        var entry = actions ? null : catalog[selected];
        bool shown = actions || entry!.Placed;
        panelInspectorTitle!.Text = BlockLabel(selected); AutomationProperties.SetName(panelInspectorTitle, panelInspectorTitle.Text);
        if (panelInfoButton != null) AutomationProperties.SetName(panelInfoButton, ui.Text("main.info").Replace("%@", panelInspectorTitle.Text, StringComparison.Ordinal));
        if (BlockProvider(selected) is { } brand)
        {
            panelInspectorIcon!.Child = ProviderIcon.Create(brand, 30, BlockSymbol(selected));
            panelInspectorIcon.ClearValue(Border.BackgroundProperty);
        }
        else
        {
            var glyph = new IconGlyph { Symbol = BlockSymbol(selected), Width = 16, Height = 16 }; glyph.SetResourceReference(IconGlyph.InkProperty, BlockTint(selected));
            panelInspectorIcon!.Child = glyph; panelInspectorIcon.SetResourceReference(Border.BackgroundProperty, BlockTint(selected) + "Soft");
        }
        panelInspectorDetail!.Text = BlockDetail(selected);
        panelInspectorToggle!.Visibility = actions ? Visibility.Collapsed : Visibility.Visible;
        panelInspectorToggle.Content = ui.Text(shown ? "main.collapsed.remove" : "main.collapsed.add");
        panelInspectorToggle.Style = shown ? (Style)FindResource(typeof(Button)) : (Style)FindResource("SettingsProminentButton");
        panelInspectorToggle.IsEnabled = !busy && entry?.Locked != true;
        AutomationProperties.SetName(panelInspectorToggle, panelInspectorTitle.Text + " · " + panelInspectorToggle.Content);
        // Settings stay open while a block is out of the panel; they apply once it is added.
        string? notice = actions ? null
            : entry!.Locked ? ui.Text("main.panel.last")
            : !entry.Placed ? ui.Text("main.library.not_added")
            : !entry.Available ? ui.Text("main.panel.unavailable").Replace("%@", BlockProviderName(selected), StringComparison.Ordinal) : null;
        // The amber note is for a block out of the panel; the others only explain.
        ShowLibraryNotice(panelNotice!, notice, locked: entry?.Placed == true);
        foreach (var (id, panel) in panelInspectorPanels) panel.Visibility = id == selected ? Visibility.Visible : Visibility.Collapsed;

        void Pick(string id, string value) { if (panelSegments.TryGetValue(id, out var group)) foreach (var (key, choice) in group) choice.IsChecked = key == value; }
        void Flip(string id, bool value) { if (panelSwitches.TryGetValue(id, out var check)) check.IsChecked = value; }
        Pick("pageSize", options.PageSize.ToString(System.Globalization.CultureInfo.InvariantCulture)); Pick("rowStyle", options.RowStyle);
        foreach (var (field, chip) in panelChips)
        {
            chip.IsChecked = options.RowFields.Contains(field);
            // One line keeps only the speed and the turn time; the others wait, faded.
            bool usable = !options.OneLine || field is "rate" or "turnTime";
            chip.IsEnabled = usable && !session.RequiresRestart;
            AutomationProperties.SetHelpText(chip, usable ? "" : ui.Text("main.panel.row_style_help"));
        }
        panelPreview?.Update(options);
        panelRetention!.SelectedValue = preferences.RetentionMinutes;
        foreach (string provider in new[] { "codex", "claude", "workbuddy" })
        {
            Pick(provider + "Periods", options.Periods(provider)); Pick(provider + ".style", preferences.ExpandedQuotaStyle);
            Pick(provider + ".arrange", options.QuotaArrange); Flip(provider + ".details", options.QuotaDetails); Flip(provider + ".paceTick", options.PaceTick);
        }
        Pick("dial", options.DeepseekDial); Flip("peak", options.DeepseekPeak);
        Pick("spendTasks", options.SpendTasks == 4 ? "4" : "2"); Flip("elsewhere", options.SpendElsewhere); Flip("weekLine", options.WeekLine);
        Flip("action.apps", preferences.ShowAppButtons);
        foreach (string action in new[] { "markRead", "pin", "settings" }) Flip("action." + action, options.InHeader(action));
    }

    private static string BlockProviderName(string block) => block switch
    {
        "codex" => "Codex", "claude" => "Claude", "workbuddy" => "WorkBuddy", _ => "DeepSeek"
    };

    /// A section's title in the outline, as the panel's own headers read.
    private string PanelSectionTitle(PanelEditorSection section)
    {
        if (section.Kind != "quota") return section.Kind switch
        {
            "tasks" => ui.Text("layout.group.tasks"), "deepseekSpend" => ui.Text("deepseek.where"), "deepseekWeek" => ui.Text("deepseek.week_title"),
            _ => BlockLabel(section.Kind)
        };
        string key = section.Providers is ["deepseek"] ? "layout.group.balance"
            : section.Providers.Any(provider => provider is "deepseek" or "workbuddy") ? "layout.group.quota_balance" : "layout.group.quota";
        return ui.Text(key);
    }

    /// The panel's outline: each section's title, its blocks in order with paired
    /// quotas side by side, and the buttons in the first header. Click selects; drag moves.
    private void DrawPanelEditor(PanelEditorProjection projection, string selected, DesktopPreferences preferences)
    {
        var editor = panelEditor!; editor.Children.Clear();
        var options = projection.Options;
        foreach (var (section, index) in projection.Sections.Select((value, index) => (value, index)))
        {
            if (index > 0)
            {
                if (section.Joined) editor.Children.Add(new Border { Height = 6 });
                else editor.Children.Add(new Border { Height = 1, Margin = new Thickness(8, 8, 8, 6), Background = PacerPalette.Overlay(20) });
            }
            // The section's title, with the buttons at its end in the first one.
            if (!section.Joined)
            {
                var top = new Grid { MinHeight = 22, Margin = new Thickness(8, 0, 4, 4) };
                top.ColumnDefinitions.Add(new ColumnDefinition()); top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                top.Children.Add(new TextBlock { Text = PanelSectionTitle(section), FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Secondary,
                    VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
                if (section.Actions) { var strip = PanelActionsStrip(selected == ActionsBlock, options, preferences.ShowAppButtons); Grid.SetColumn(strip, 1); top.Children.Add(strip); }
                editor.Children.Add(top);
            }
            var blocks = section.Kind == "quota" ? section.Providers.ToArray() : [section.Kind];
            var row = new Grid();
            for (int column = 0; column < blocks.Length; column++)
            {
                if (column > 0) row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
                row.ColumnDefinitions.Add(new ColumnDefinition());
                var block = PanelBlockButton(blocks[column], selected, options, blocks.Length);
                Grid.SetColumn(block, row.ColumnDefinitions.Count - 1); row.Children.Add(block);
            }
            editor.Children.Add(row);
        }
    }

    private Button PanelActionsStrip(bool selected, PanelOptions options, bool apps)
    {
        var icons = new StackPanel { Orientation = Orientation.Horizontal };
        void Icon(string symbol) => icons.Children.Add(new IconGlyph { Symbol = symbol, Width = 11, Height = 11, Margin = new Thickness(icons.Children.Count == 0 ? 0 : 7, 0, 0, 0), Ink = PacerPalette.Secondary });
        if (apps) Icon("square.grid.2x2");
        if (options.InHeader("markRead")) Icon("checkmark.rectangle.stack");
        if (options.InHeader("pin")) Icon("pin");
        if (options.InHeader("settings")) Icon("gearshape");
        Icon("ellipsis");
        var accent = new SolidColorBrush(Color.FromRgb(10, 132, 255));
        var border = new Border { Child = icons, Height = 22, Padding = new Thickness(7, 0, 7, 0), CornerRadius = new CornerRadius(7),
            BorderThickness = new Thickness(selected ? 1.5 : 0), BorderBrush = selected ? accent : null,
            Background = selected ? new SolidColorBrush(Color.FromArgb(56, 10, 132, 255)) : PacerPalette.Overlay(15) };
        var button = new Button { Content = border, Style = (Style)FindResource("SettingsRowButton"), Margin = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, Template = PlainButtonTemplate() };
        Identify(button, "panel.editor.actions", ui.Text("panel.block.actions"));
        AutomationProperties.SetItemStatus(button, selected ? ui.Text("main.panel.selected") : "");
        button.Click += (_, _) => SelectPanelBlock(ActionsBlock);
        return button;
    }

    /// A button that draws only its content, with a ring while it has keyboard focus.
    private static ControlTemplate PlainButtonTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var focus = new FrameworkElementFactory(typeof(Border), "Focus");
        focus.SetValue(Border.CornerRadiusProperty, new CornerRadius(12)); focus.SetValue(Border.BorderThicknessProperty, new Thickness(1.5));
        focus.SetValue(Border.BorderBrushProperty, Brushes.Transparent); focus.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        focus.AppendChild(presenter); template.VisualTree = focus;
        var trigger = new Trigger { Property = UIElement.IsKeyboardFocusedProperty, Value = true };
        trigger.Setters.Add(new Setter(Border.BorderBrushProperty, new SolidColorBrush(Color.FromRgb(10, 132, 255)), "Focus"));
        template.Triggers.Add(trigger);
        return template;
    }

    /// A block's current choices in a few words, each named, as on the Mac.
    private string PanelSummary(string id, PanelOptions options)
    {
        string Both(string title, string value) => ui.Text(title) + " · " + value;
        string count = options.SpendTasks.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return id switch
        {
            "tasks" => ui.Text("main.panel.page_size") + " " + options.PageSize + " · " + ui.Text(options.OneLine ? "main.panel.row_one" : "main.panel.row_two"),
            "codex" or "claude" => ui.Text(options.Periods(id) switch { "weekly" => "main.panel.periods_weekly", "fiveHour" => "main.panel.periods_five", _ => "main.panel.periods_both" }),
            "deepseek" => Both("main.panel.dial", ui.Text(options.DeepseekDial == "day" ? "main.panel.dial_day" : "main.panel.dial_budget")),
            "deepseekSpend" => Both("main.panel.spend_tasks", ui.Text("main.panel.spend_count").Replace("%ld", count, StringComparison.Ordinal)),
            "deepseekWeek" => Both("main.panel.week_line", ui.Text(options.WeekLine ? "main.panel.show" : "main.panel.hide")),
            "workbuddy" => ui.Text("harness.account.title"),
            _ => ""
        };
    }

    /// A block in the outline: a grip, its service's dot, its name and a summary.
    /// Up and Down (or Left and Right) move the focused block, as dragging does.
    /// <param name="row">How many quotas share the row: two show only the service's
    /// name, as on the Mac; three are too narrow for the grip, so the dot sits above the name.</param>
    private Button PanelBlockButton(string id, string selected, PanelOptions options, int row = 1)
    {
        bool isSelected = id == selected, paired = row > 1, narrow = row > 2;
        Brush tint = id is "deepseekSpend" or "deepseekWeek" ? PacerPalette.DeepSeek : PacerPalette.Secondary;
        FrameworkElement marker = BlockProvider(id) is { } provider ? ProviderIcon.Create(provider, 14)
            : new System.Windows.Shapes.Ellipse { Width = 8, Height = 8, Fill = tint, VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { Text = paired ? BlockProviderName(id) : BlockLabel(id), FontSize = 12.5, FontWeight = FontWeights.SemiBold,
            Foreground = PacerPalette.Primary, TextTrimming = TextTrimming.CharacterEllipsis };
        string summary = paired ? "" : PanelSummary(id, options);
        FrameworkElement content;
        if (narrow)
        {
            name.HorizontalAlignment = HorizontalAlignment.Center; name.Margin = new Thickness(0, 5, 0, 0);
            marker.HorizontalAlignment = HorizontalAlignment.Center;
            content = new StackPanel { Margin = new Thickness(4, 8, 4, 8), VerticalAlignment = VerticalAlignment.Center, Children = { marker, name } };
        }
        else
        {
            var grid = new Grid { Margin = new Thickness(6, 8, 10, 8) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.Children.Add(new System.Windows.Shapes.Path { Data = Geometry.Parse("M3,3 h0.01 M7,3 h0.01 M3,6 h0.01 M7,6 h0.01 M3,9 h0.01 M7,9 h0.01"), Stroke = PacerPalette.Tertiary,
                StrokeThickness = 1.6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, Width = 10, Height = 12, VerticalAlignment = VerticalAlignment.Center });
            marker.Margin = new Thickness(6, 0, 6, 0); Grid.SetColumn(marker, 1); grid.Children.Add(marker);
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { name } };
            if (summary.Length > 0)
                names.Children.Add(new TextBlock { Text = summary, FontSize = 11, Foreground = PacerPalette.Secondary, Margin = new Thickness(0, 1, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis });
            Grid.SetColumn(names, 2); grid.Children.Add(names);
            content = grid;
        }
        var accent = new SolidColorBrush(Color.FromRgb(10, 132, 255));
        var surface = new Border { Child = content, CornerRadius = new CornerRadius(12), Background = PacerPalette.Overlay((byte)(isSelected ? 26 : 15)),
            BorderThickness = new Thickness(isSelected ? 2 : 1), BorderBrush = isSelected ? accent : PacerPalette.Overlay(15),
            MinHeight = id == "tasks" ? 58 : 46, Cursor = Cursors.SizeAll };
        // Its own template and no text template: the content is the block itself.
        var button = new Button { Style = (Style)FindResource("SettingsRowButton"), Content = surface, AllowDrop = true, Tag = id, Template = PlainButtonTemplate() };
        Identify(button, "panel.editor." + id, BlockLabel(id) + (summary.Length > 0 ? ", " + summary : ""));
        AutomationProperties.SetItemStatus(button, isSelected ? ui.Text("main.panel.selected") : "");
        button.Click += (_, _) => { if (panelDragBlock == null) SelectPanelBlock(id); };
        button.KeyDown += async (_, e) =>
        {
            if (e.Key is not (Key.Up or Key.Down or Key.Left or Key.Right) || Keyboard.Modifiers != ModifierKeys.None) return;
            e.Handled = true;
            if (busy || panelProjection == null) return;
            SelectPanelBlock(id);
            await EditPanel(new("shift", id, Offset: e.Key is Key.Up or Key.Left ? -1 : 1));
            // The outline was drawn again; the moved block keeps the keyboard.
            if (activePane == "expandedPanel" && panelEditor != null) FindBlock(panelEditor)?.Focus();
        };
        Button? FindBlock(Panel root)
        {
            foreach (var child in root.Children)
            {
                if (child is Button { Tag: string tag } found && tag == id) return found;
                if (child is Panel inner && FindBlock(inner) is { } nested) return nested;
            }
            return null;
        }
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
