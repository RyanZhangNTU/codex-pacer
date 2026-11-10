using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The expanded panel's blocks. Core resolves the saved layout into sections
/// (Core's ExpandedPanelPresentation, through the engine snapshot); this file
/// only places them: the task list and the first quota section are the
/// window's own elements, further quota sections and DeepSeek's charts are
/// built once and reused, and the panel's buttons ride the first header.
public partial class IslandWindow
{
    private sealed class QuotaParts(StackPanel section, Grid header, TextBlock title, TextBlock detail, StackPanel trailing, Grid slots)
    {
        internal StackPanel Section { get; } = section;
        internal Grid Header { get; } = header;
        internal TextBlock Title { get; } = title;
        internal TextBlock Detail { get; } = detail;
        internal StackPanel Trailing { get; } = trailing;
        internal Grid Slots { get; } = slots;
    }
    private sealed class ChartParts(StackPanel section, Grid header, TextBlock title, TextBlock detail, StackPanel trailing, Border content)
    {
        internal StackPanel Section { get; } = section;
        internal Grid Header { get; } = header;
        internal TextBlock Title { get; } = title;
        internal TextBlock Detail { get; } = detail;
        internal StackPanel Trailing { get; } = trailing;
        internal Border Content { get; } = content;
    }

    private PanelOptions panelOptions = PanelOptions.Default;
    private string panelOptionsKey = PanelOptions.Default.Key;
    private bool panelBudgetDial = true;
    private EngineExpandedPanel? panel;
    private string sectionSignature = "";
    private bool tasksShown = true;
    private QuotaParts? firstQuota;
    private readonly List<QuotaParts> extraQuota = [];
    private ChartParts? spendSection, weekSection;
    private readonly List<FrameworkElement> sectionHeaders = [];

    /// Rows on one task page and their height, from the panel's choices.
    private int PageSize => Math.Clamp(panelOptions.PageSize, 3, 6);
    private double RowHeight => TaskRow.RowHeight(panelOptions);
    private double RowsHeight(int count) => count == 0 ? 44 : Math.Min(count, PageSize) * RowHeight + (Math.Min(count, PageSize) - 1) * 2;
    private int PageCount => Math.Max(1, (rows.Count + PageSize - 1) / PageSize);

    /// Takes the snapshot's choices; true when rows must be rebuilt.
    private bool ApplyPanelChoices(EngineSnapshot snapshot)
    {
        panel = snapshot.ExpandedPanel ?? DefaultPanel(snapshot);
        panelBudgetDial = panel.BudgetDial;
        string key = panel.Options.Key;
        if (key == panelOptionsKey) return false;
        panelOptions = panel.Options; panelOptionsKey = key;
        return true;
    }

    /// Before an engine sends the panel, the panel keeps its earlier shape.
    private static EngineExpandedPanel DefaultPanel(EngineSnapshot snapshot)
    {
        var dashboard = snapshot.QuotaDashboard;
        var providers = dashboard?.Providers.Select(value => value.Provider).ToArray()
            ?? snapshot.Sources.Select(source => source.Provider).Distinct().OrderBy(provider => provider == "codex" ? 0 : provider == "claude" ? 1 : 2).ToArray();
        var sections = new List<PanelSection> { new("tasks", [], true, false, false, true, "", null) };
        if (providers.Length > 0)
            sections.Add(new("quota", providers, false, false, false, true, "", null, dashboard?.Split, dashboard?.Classic));
        return new(1, PanelOptions.Default, true, sections);
    }

    private QuotaParts FirstQuota => firstQuota ??= new(QuotaSection, QuotaHeader, QuotaTitle, QuotaDetail, QuotaHeaderTrailing, QuotaSlots);

    private QuotaParts ExtraQuota(int index)
    {
        while (extraQuota.Count <= index)
        {
            var (header, title, detail, trailing) = SectionHeader();
            var slots = new Grid { Margin = new Thickness(0, 8, 0, 4) };
            var section = new StackPanel(); section.Children.Add(header); section.Children.Add(slots);
            extraQuota.Add(new(section, header, title, detail, trailing, slots));
        }
        return extraQuota[index];
    }

    private ChartParts Chart(ref ChartParts? parts, string id)
    {
        if (parts != null) return parts;
        var (header, title, detail, trailing) = SectionHeader();
        var content = new Border { Margin = new Thickness(9, 0, 9, 4) };
        var section = new StackPanel(); section.Children.Add(header); section.Children.Add(content);
        AutomationProperties.SetAutomationId(section, "island.section." + id);
        return parts = new(section, header, title, detail, trailing, content);
    }

    private static (Grid Header, TextBlock Title, TextBlock Detail, StackPanel Trailing) SectionHeader()
    {
        var header = new Grid { Height = 24, Margin = new Thickness(9, 0, 9, 0) };
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new()); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var names = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var title = new TextBlock { FontSize = 11, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Island.Secondary");
        var detail = new TextBlock { FontSize = 11, FontWeight = FontWeights.Medium, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        names.Children.Add(title); names.Children.Add(detail); header.Children.Add(names);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, -2, 0, -2) };
        Grid.SetColumn(trailing, 2); header.Children.Add(trailing);
        return (header, title, detail, trailing);
    }

    private static void SetDetail(TextBlock detail, string? text, string? provider)
    {
        detail.Text = text ?? ""; detail.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        if (provider is "codex" or "claude" or "deepseek") detail.Foreground = PacerPalette.Provider(provider);
        else detail.SetResourceReference(TextBlock.ForegroundProperty, "Island.Tertiary");
    }

    /// Fills every section and, only when the shape changed, rebuilds their order.
    private void RenderPanel(EngineSnapshot snapshot)
    {
        var current = panel ?? DefaultPanel(snapshot);
        var placed = new List<(PanelSection Section, FrameworkElement Element, StackPanel Trailing, FrameworkElement Header)>();
        int quotaIndex = 0;
        foreach (var section in current.Sections)
        {
            switch (section.Kind)
            {
                case "tasks":
                    placed.Add((section, TasksSection, TaskHeaderTrailing, TaskToolbar));
                    break;
                case "quota" when section.Providers.Count > 0:
                {
                    var parts = quotaIndex == 0 ? FirstQuota : ExtraQuota(quotaIndex - 1);
                    quotaIndex++;
                    parts.Title.Text = section.Title.Length > 0 ? section.Title : ui.Text("layout.group.quota_balance");
                    SetDetail(parts.Detail, section.Detail, section.Providers.Count == 1 ? section.Providers[0] : null);
                    FillQuota(parts.Slots, section, snapshot);
                    AutomationProperties.SetAutomationId(parts.Section, "island.section.quota." + string.Join("-", section.Providers));
                    placed.Add((section, parts.Section, parts.Trailing, parts.Header));
                    break;
                }
                case "deepseekSpend" or "deepseekWeek":
                {
                    bool spend = section.Kind == "deepseekSpend";
                    var parts = spend ? Chart(ref spendSection, "spend") : Chart(ref weekSection, "week");
                    var data = snapshot.Wallet?.Solo;
                    FrameworkElement? content = spend
                        ? data?.Distribution is { } distribution ? new DeepSeekDistributionView(distribution, showsTitle: !section.ShowsHeader) : null
                        : data?.Week is { } week ? new DeepSeekWeekView(week, showsTitle: !section.ShowsHeader) : null;
                    // An empty chart takes no room unless it carries the panel's buttons.
                    if (content == null && !section.ShowsHeader) break;
                    parts.Header.Visibility = section.ShowsHeader ? Visibility.Visible : Visibility.Collapsed;
                    parts.Title.Text = section.Title;
                    SetDetail(parts.Detail, spend ? null : data?.Week?.LineText, null);
                    parts.Content.Child = content;
                    parts.Content.Margin = new Thickness(9, section.ShowsHeader && content != null ? 8 : 0, 9, content == null ? 0 : 4);
                    placed.Add((section, parts.Section, parts.Trailing, parts.Header));
                    break;
                }
            }
        }
        // A panel always keeps somewhere for its buttons.
        if (placed.Count == 0) placed.Add((new("tasks", [], true, false, false, true, "", null), TasksSection, TaskHeaderTrailing, TaskToolbar));
        tasksShown = placed.Any(item => ReferenceEquals(item.Element, TasksSection));

        string signature = string.Join("|", placed.Select(item => item.Section.Key + ":" + item.Section.Joined + ":" + item.Element.GetHashCode()));
        if (signature != sectionSignature)
        {
            sectionSignature = signature;
            if (PanelActions.Parent is Panel owner) owner.Children.Remove(PanelActions);
            PanelContent.Children.Clear(); sectionHeaders.Clear();
            for (int index = 0; index < placed.Count; index++)
            {
                var (section, element, trailing, header) = placed[index];
                bool joined = index > 0 && section.Joined;
                if (index > 0 && !joined)
                {
                    var hairline = new Border { Height = 1, Margin = new Thickness(9, 10, 9, 10) };
                    hairline.SetResourceReference(Border.BackgroundProperty, "Island.Overlay08");
                    PanelContent.Children.Add(hairline);
                }
                element.Margin = new Thickness(0, joined ? 10 : 0, 0, 0);
                PanelContent.Children.Add(element);
                sectionHeaders.Add(header);
                if (index == 0)
                {
                    trailing.Children.Add(PanelActions);
                    // Navigation and connection messages sit under the first section.
                    PanelContent.Children.Add(StatusLabel);
                }
            }
        }
        // The pager's divider only separates it from the buttons beside it.
        PageDivider.Visibility = ReferenceEquals(PanelActions.Parent, TaskHeaderTrailing) ? Visibility.Visible : Visibility.Collapsed;
        ApplyHeaderActions();
        if (!MoreButton.ContextMenu.IsOpen) BuildMoreMenu();
    }

    /// One quota section in the chosen style, as Core drew it for its services.
    private void FillQuota(Grid slots, PanelSection section, EngineSnapshot snapshot)
    {
        slots.Children.Clear(); slots.ColumnDefinitions.Clear();
        string connectUnavailable = ui.Text(demo ? "windows.deepseek.demo_web_help" : "windows.deepseek.runtime_required");
        var dashboard = snapshot.QuotaDashboard is { SchemaVersion: 1 } data ? data : null;
        var layout = expandedQuotaStyle == "classic" ? section.Classic : section.Split;
        var options = panelOptions;
        DashboardProvider? Reading(string provider) => dashboard?.Providers.FirstOrDefault(value => value.Provider == provider);
        string? Help(string provider) => snapshot.Sources.FirstOrDefault(source => source.Provider == provider && source.Transport == "app-server")?.Reason;
        if (layout?.Kind == "legacyCodex" && dashboard?.LegacyCodex is { } legacy)
            slots.Children.Add(new LegacyQuotaView(legacy, ui, Help("codex"), QuotaStatus(Reading("codex"))));
        else if (layout?.Kind == "classicRings" && dashboard != null)
            slots.Children.Add(new ClassicQuotaView(layout, section.Providers.Select(Reading).OfType<DashboardProvider>().ToArray(), snapshot.Quota, snapshot.Wallet, ui,
                QuotaStatus, DeepSeekConnectAction(snapshot), connectUnavailable, DeepSeekStatus(snapshot), options, panelBudgetDial));
        else if (layout?.Kind == "splitSingle" && Reading(section.Providers[0]) is { } single)
            slots.Children.Add(new SingleQuotaView(single, snapshot.Quota.FirstOrDefault(value => value.Provider == single.Provider), ui, Help(single.Provider),
                QuotaStatus(single), panel?.Gauge(single.Provider), options.PaceTick));
        else if (layout?.Kind == "deepseekSolo")
            slots.Children.Add(new DeepSeekSoloView(snapshot.Wallet, ui, section.SpendBeside, connectAction: DeepSeekConnectAction(snapshot),
                connectUnavailable: connectUnavailable, balanceStatus: DeepSeekStatus(snapshot), budgetDial: panelBudgetDial, peak: options.DeepseekPeak));
        else
        {
            var providers = layout?.Slots.Select(value => value.Provider).ToArray() ?? section.Providers.ToArray();
            for (int index = 0; index < providers.Length; index++)
            {
                if (index > 0) slots.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
                int column = slots.ColumnDefinitions.Count;
                slots.ColumnDefinitions.Add(new ColumnDefinition());
                var reading = Reading(providers[index]);
                FrameworkElement cell = providers[index] == "deepseek"
                    ? new DeepSeekQuotaCell(snapshot.Wallet, ui, connectAction: DeepSeekConnectAction(snapshot), connectUnavailable: connectUnavailable,
                        balanceStatus: DeepSeekStatus(snapshot), budgetDial: panelBudgetDial)
                    : new QuotaCell(providers[index], snapshot.Quota.FirstOrDefault(q => q.Provider == providers[index]), snapshot.Wallet, Help(providers[index]),
                        reading, QuotaStatus(reading), panel?.Gauge(providers[index]), options.PaceTick);
                Grid.SetColumn(cell, column); slots.Children.Add(cell);
            }
        }
    }

    /// The header shows the chosen buttons; the rest wait in the More menu.
    private void ApplyHeaderActions()
    {
        MarkReadButton.Visibility = panelOptions.InHeader("markRead") ? Visibility.Visible : Visibility.Collapsed;
        PinButton.Visibility = panelOptions.InHeader("pin") ? Visibility.Visible : Visibility.Collapsed;
        SettingsButton.Visibility = panelOptions.InHeader("settings") ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Unchecked header buttons first, then Refresh and Quit, which always live here.
    private void BuildMoreMenu()
    {
        var menu = MoreButton.ContextMenu;
        menu.Items.Clear();
        int hidden = 0;
        if (!showAppButtons)
            foreach (string provider in AvailableApplications())
            {
                var item = new MenuItem { Header = ui.Text("windows.open." + provider) };
                AutomationProperties.SetAutomationId(item, "island.menu.open." + provider);
                item.Click += (_, _) => OpenDesktopApplicationFromMenu(provider);
                menu.Items.Add(item); hidden++;
            }
        if (!panelOptions.InHeader("markRead"))
        {
            var item = new MenuItem { Header = ui.Text("activity.mark_all_read"), IsEnabled = MarkReadButton.IsEnabled };
            AutomationProperties.SetAutomationId(item, "island.menu.markRead");
            item.Click += OnMarkRead; menu.Items.Add(item); hidden++;
        }
        if (!panelOptions.InHeader("pin"))
        {
            var item = new MenuItem { Header = ui.Text(pinned ? "common.unpin" : "common.pin") };
            AutomationProperties.SetAutomationId(item, "island.menu.pin");
            item.Click += OnPin; menu.Items.Add(item); hidden++;
        }
        if (!panelOptions.InHeader("settings")) { menu.Items.Add(SettingsMenu); hidden++; }
        if (hidden > 0) menu.Items.Add(new Separator());
        menu.Items.Add(RefreshMenu); menu.Items.Add(new Separator()); menu.Items.Add(QuitMenu);
    }
}
