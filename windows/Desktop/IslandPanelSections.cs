using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
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

    private Grid? noServicesRow;
    private Grid NoServicesRow()
    {
        if (noServicesRow != null) return noServicesRow;
        var row = new Grid { Margin = new Thickness(9, 8, 9, 8) };
        row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var text = new TextBlock { Text = ui.Text("provider.none_enabled"), FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Island.Secondary"); row.Children.Add(text);
        var open = new Button { Content = ui.Text("common.open_settings"), Style = (Style)FindResource("QuotaLinkButton"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(open, "island.none.settings"); AutomationProperties.SetName(open, ui.Text("common.open_settings"));
        open.Click += (_, _) => { if (!presentationStopped && expanded) { DismissForSettings(); SettingsRequested?.Invoke(); } };
        Grid.SetColumn(open, 1); row.Children.Add(open);
        AutomationProperties.SetAutomationId(row, "island.none");
        return noServicesRow = row;
    }

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
        if (provider != null && DesktopPreferences.ValidProviderId(provider)) detail.Foreground = PacerPalette.Provider(provider);
        else detail.SetResourceReference(TextBlock.ForegroundProperty, "Island.Tertiary");
    }

    /// What each quota section and chart was last drawn from; equal inputs keep their views.
    private readonly Dictionary<FrameworkElement, string> drawnFrom = new();
    private static readonly JsonSerializerOptions SignatureJson = new() { NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals };
    /// Whether `element` must be drawn again for `inputs`, which also carry the island's tone and accent.
    private bool Redraw(FrameworkElement element, object inputs)
    {
        string signature = JsonSerializer.Serialize(new { inputs, PacerPalette.Accent, PacerPalette.Light }, SignatureJson);
        if (drawnFrom.TryGetValue(element, out var drawn) && drawn == signature) return false;
        drawnFrom[element] = signature; return true;
    }

    /// Fills every section and, only when the shape changed, rebuilds their order.
    /// Returns whether anything the panel measures may have changed.
    private bool RenderPanel(EngineSnapshot snapshot)
    {
        PanelBuilds++;
        bool changed = false;
        var headings = new List<string>();
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
                    headings.Add(parts.Title.Text + "\u001f" + parts.Detail.Text);
                    changed |= FillQuota(parts.Slots, section, snapshot);
                    changed |= PlaceHeaderResets(parts.Trailing, section, snapshot);
                    AutomationProperties.SetAutomationId(parts.Section, "island.section.quota." + string.Join("-", section.Providers));
                    placed.Add((section, parts.Section, parts.Trailing, parts.Header));
                    break;
                }
                case "deepseekSpend" or "deepseekWeek":
                {
                    bool spend = section.Kind == "deepseekSpend";
                    var parts = spend ? Chart(ref spendSection, "spend") : Chart(ref weekSection, "week");
                    var data = snapshot.Wallet?.Solo;
                    object? chart = spend ? data?.Distribution : data?.Week;
                    // An empty chart takes no room unless it carries the panel's buttons.
                    if (chart == null && !section.ShowsHeader) break;
                    parts.Header.Visibility = section.ShowsHeader ? Visibility.Visible : Visibility.Collapsed;
                    parts.Title.Text = section.Title;
                    SetDetail(parts.Detail, spend ? null : data?.Week?.LineText, null);
                    headings.Add(parts.Title.Text + "\u001f" + parts.Detail.Text + "\u001f" + section.ShowsHeader);
                    if (Redraw(parts.Content, new { chart, section.ShowsHeader }))
                    {
                        FrameworkElement? content = spend
                            ? data?.Distribution is { } distribution ? new DeepSeekDistributionView(distribution, showsTitle: !section.ShowsHeader) : null
                            : data?.Week is { } week ? new DeepSeekWeekView(week, showsTitle: !section.ShowsHeader) : null;
                        parts.Content.Child = content; changed = true;
                    }
                    parts.Content.Margin = new Thickness(9, section.ShowsHeader && chart != null ? 8 : 0, 9, chart == null ? 0 : 4);
                    placed.Add((section, parts.Section, parts.Trailing, parts.Header));
                    break;
                }
            }
        }
        // A panel always keeps somewhere for its buttons.
        if (placed.Count == 0) placed.Add((new("tasks", [], true, false, false, true, "", null), TasksSection, TaskHeaderTrailing, TaskToolbar));
        tasksShown = placed.Any(item => ReferenceEquals(item.Element, TasksSection));
        // Without any service the panel says so under its blocks and offers Settings, as on the Mac.
        bool noServices = snapshot.QuotaDashboard is { Providers.Count: 0 } && snapshot.Modules?.Any(module => module.Enabled) != true;
        var none = NoServicesRow();

        string signature = string.Join("|", placed.Select(item => item.Section.Key + ":" + item.Section.Joined + ":" + item.Element.GetHashCode())) + ":" + noServices;
        if (signature != sectionSignature)
        {
            sectionSignature = signature; changed = true;
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
            if (noServices)
            {
                var hairline = new Border { Height = 1, Margin = new Thickness(9, 10, 9, 10) };
                hairline.SetResourceReference(Border.BackgroundProperty, "Island.Overlay08");
                PanelContent.Children.Add(hairline); PanelContent.Children.Add(none);
            }
        }
        // The pager's divider only separates it from the buttons beside it.
        PageDivider.Visibility = ReferenceEquals(PanelActions.Parent, TaskHeaderTrailing) ? Visibility.Visible : Visibility.Collapsed;
        ApplyHeaderActions();
        if (!MoreButton.ContextMenu.IsOpen) BuildMoreMenu();
        // New heading text can widen the panel.
        string headingText = string.Join("\u001e", headings);
        if (headingText != drawnHeadings) { drawnHeadings = headingText; changed = true; }
        return changed;
    }
    private string? drawnHeadings;

    /// Measuring the panel with an unchanged width reuses each section's cached
    /// size, so everything that render replaced is marked up to the panel first.
    private void InvalidatePanelMeasure()
    {
        void Up(UIElement element)
        {
            for (DependencyObject? node = element; node != null && !ReferenceEquals(node, PanelContent); node = VisualTreeHelper.GetParent(node))
                (node as UIElement)?.InvalidateMeasure();
        }
        Up(QuotaSlots); Up(TaskPages); Up(StatusLabel);
        foreach (var parts in extraQuota) Up(parts.Slots);
        if (spendSection != null) Up(spendSection.Content);
        if (weekSection != null) Up(weekSection.Content);
        if (noServicesRow != null) Up(noServicesRow);
        PanelContent.InvalidateMeasure();
    }

    private void UpdateHarnessAccount(string provider)
    {
        if (presentationStopped || latest == null) return;
        if (PanelLive) { if (RenderPanel(latest)) Relayout(); }
        else panelDirty = true;
    }

    private void OpenModuleSettings(string provider)
    {
        if (!presentationStopped && expanded) ProviderSettingsRequested?.Invoke(provider);
    }
    /// Codex's banked resets while its block's switch is on and an account has any.
    private QuotaAccountPresentation? ResetAccount(PanelSection section, EngineSnapshot snapshot) =>
        panelOptions.CodexResets && section.Providers.Contains("codex")
            && snapshot.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == "codex")?.History?.Account is { PanelText: not null } usage ? usage : null;

    /// Codex alone keeps its capsule at the right of the section's header row, before any panel
    /// buttons, so the quota row keeps its height. Returns whether the header changed.
    private bool PlaceHeaderResets(StackPanel trailing, PanelSection section, EngineSnapshot snapshot)
    {
        var account = section.Providers.Count == 1 ? ResetAccount(section, snapshot) : null;
        var existing = trailing.Children.OfType<Button>().FirstOrDefault(value => AutomationProperties.GetAutomationId(value) == "island.codex.resets");
        string? key = account == null ? null : account.PanelText + "" + account.ExpirySoon;
        if ((existing?.Tag as string) == key) return false;
        if (existing != null) trailing.Children.Remove(existing);
        if (account != null) trailing.Children.Insert(0, ResetCapsule(account, new Thickness(0, 0, 6, 0)));
        return true;
    }

    /// The capsule for Codex's banked resets, as on the Mac: the count and the next deadline. It
    /// opens History with every deadline showing; a popup would close the panel.
    /// Sharing a row with other services, it alternates the count with the time left, as the
    /// collapsed bar alternates its quota values, so it stays narrow enough for one column.
    private Button ResetCapsule(QuotaAccountPresentation account, Thickness margin, bool alternate = false)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        var arrow = new IconGlyph { Symbol = "arrow.counterclockwise", Width = 11, Height = 11, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
        string ink = account.ExpirySoon ? "Island.Attention" : "Island.Secondary";
        arrow.SetResourceReference(IconGlyph.InkProperty, ink); label.Children.Add(arrow);
        string[] phases = alternate && account.PanelCountText is { } count && account.PanelTimeText is { } time ? [count, time]
            : [alternate ? account.PanelCountText ?? account.PanelText ?? "" : account.PanelText ?? ""];
        if (phases.Length > 1)
        {
            // The collapsed bar's own rotation, as the Mac reuses its own: four-second turns, the
            // old text leaving upward as the next fades in, in one cell sized by the longest, so a
            // turn repaints without measuring the panel again. It runs only while it shows.
            var turns = new AlternatingQuotaText { FontSize = 11, ValueWeight = FontWeights.Medium, Centered = true, VerticalAlignment = VerticalAlignment.Center };
            turns.Update(phases.Select(value => new AlternatingQuotaText.Item("codex", value, false, Ink: ink)).ToArray(), true);
            label.Children.Add(turns);
        }
        else
        {
            var title = new TextBlock { Text = phases[0], VerticalAlignment = VerticalAlignment.Center };
            title.SetResourceReference(TextBlock.ForegroundProperty, ink); label.Children.Add(title);
        }
        var capsule = new Button { Content = label, Style = (Style)FindResource("QuotaLinkButton"), HorizontalAlignment = HorizontalAlignment.Center,
            Margin = margin, VerticalAlignment = VerticalAlignment.Center, Tag = account.PanelText + "" + account.ExpirySoon };
        AutomationProperties.SetAutomationId(capsule, "island.codex.resets");
        AutomationProperties.SetName(capsule, account.PanelText ?? "");
        capsule.Click += (_, _) => { if (presentationStopped || !expanded) return; DismissForSettings(); ResetExpiriesRequested?.Invoke(); };
        return capsule;
    }

    /// Shared with other services, the capsule sits in Codex's own column under its status, as on
    /// the Mac. Only a Codex drawn without a ring column leaves it a centered row of its own.
    private static void AddResetCapsule(Grid slots, Button capsule)
    {
        if (capsule.Parent != null) return;
        if (slots.RowDefinitions.Count == 0) slots.RowDefinitions.Add(new() { Height = GridLength.Auto });
        slots.RowDefinitions.Add(new() { Height = GridLength.Auto });
        Grid.SetRow(capsule, slots.RowDefinitions.Count - 1);
        Grid.SetColumnSpan(capsule, Math.Max(1, slots.ColumnDefinitions.Count));
        slots.Children.Add(capsule);
    }
    private bool ReportsCredits(EngineSnapshot snapshot, string provider) =>
        snapshot.Modules?.Any(module => module.Provider == provider && module.ReportsAccountCredits == true) == true;

    /// One quota section in the chosen style, as Core drew it for its services.
    /// Returns false, keeping the section's views, when nothing it draws changed.
    private bool FillQuota(Grid slots, PanelSection section, EngineSnapshot snapshot)
    {
        var dashboard = snapshot.QuotaDashboard is { SchemaVersion: 1 } data ? data : null;
        var layout = expandedQuotaStyle == "classic" ? section.Classic : section.Split;
        var options = panelOptions;
        DashboardProvider? Reading(string provider) => dashboard?.Providers.FirstOrDefault(value => value.Provider == provider);
        string? Help(string provider) => snapshot.Sources.FirstOrDefault(source => source.Provider == provider && source.Transport == "app-server")?.Reason;
        bool deepseek = section.Providers.Contains("deepseek") || layout?.Slots.Any(slot => slot.Provider == "deepseek") == true;
        var creditModules = section.Providers.Where(provider => ReportsCredits(snapshot, provider)).ToArray();
        bool accountCredits = creditModules.Length > 0;
        // Codex's banked resets ride under its quota while the block's switch is on.
        var resetAccount = section.Providers.Count > 1 ? ResetAccount(section, snapshot) : null;
        if (!Redraw(slots, new
        {
            resets = resetAccount == null ? null : new { resetAccount.PanelText, resetAccount.PanelCountText, resetAccount.PanelTimeText, resetAccount.ExpirySoon },
            section, layout, style = expandedQuotaStyle, deepseekPanelStyle, options = options.Key, panelBudgetDial,
            readings = section.Providers.Select(Reading), legacy = layout?.Kind == "legacyCodex" ? dashboard?.LegacyCodex : null,
            quota = snapshot.Quota.Where(value => section.Providers.Contains(value.Provider)), help = section.Providers.Select(Help),
            gauges = section.Providers.Select(provider => panel?.Gauge(provider)), wallet = deepseek ? snapshot.Wallet : null,
            connection = deepseek ? snapshot.DeepseekConnection : null, web = deepseek && canConnectDeepSeekWeb?.Invoke() == true,
            credits = creditModules.Select(provider => snapshot.AccountCredits?.FirstOrDefault(value => value.Provider == provider)),
            creditStates = creditModules.Select(provider => harnessAccounts?[provider] is { } account ? account.State + account.Busy : null)
        })) return false;
        slots.Children.Clear(); slots.ColumnDefinitions.Clear(); slots.RowDefinitions.Clear();
        var resets = resetAccount == null ? null : ResetCapsule(resetAccount, new Thickness(0, 6, 0, 0), alternate: true);
        string connectUnavailable = ui.Text(demo ? "windows.deepseek.demo_web_help" : "windows.deepseek.runtime_required");
        if (layout?.Kind == "legacyCodex" && dashboard?.LegacyCodex is { } legacy)
            slots.Children.Add(new LegacyQuotaView(legacy, ui, Help("codex"), QuotaStatus(Reading("codex"))));
        else if (layout?.Kind == "classicRings" && dashboard != null)
            slots.Children.Add(new ClassicQuotaView(layout, section.Providers.Select(Reading).OfType<DashboardProvider>().ToArray(), snapshot.Quota, snapshot.Wallet, ui,
                QuotaStatus, DeepSeekConnectAction(snapshot), connectUnavailable, DeepSeekStatus(snapshot), options, panelBudgetDial,
                (provider, details, showsName) => AccountCell(provider, true, details, showsName), resets));
        else if (layout?.Kind == "splitSingle" && accountCredits && section.Providers.Count == 1)
        {
            var cell = AccountCell(section.Providers[0], false, true, false);
            cell.Margin = new Thickness(9, 0, 9, 0); slots.Children.Add(cell);
        }
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
                var reading = Reading(providers[index]);
                FrameworkElement cell = providers[index] switch
                {
                    var credits when ReportsCredits(snapshot, credits) => AccountCell(credits, false, false, true),
                    "deepseek" => new DeepSeekQuotaCell(snapshot.Wallet, ui, connectAction: DeepSeekConnectAction(snapshot), connectUnavailable: connectUnavailable,
                        balanceStatus: DeepSeekStatus(snapshot), budgetDial: panelBudgetDial),
                    var provider => new QuotaCell(provider, snapshot.Quota.FirstOrDefault(q => q.Provider == provider), snapshot.Wallet, Help(provider),
                        reading, QuotaStatus(reading), panel?.Gauge(provider), options.PaceTick, below: provider == "codex" ? resets : null)
                };
                QuotaCells.Add(slots, cell, index, layout?.Columns ?? providers.Length);
            }
        }
        if (resets != null) AddResetCapsule(slots, resets);
        return true;

        FrameworkElement AccountCell(string provider, bool classic, bool details, bool showsName) =>
            HarnessAccountCard.Build(ui, provider, harnessAccounts?[provider], snapshot.AccountCredits?.FirstOrDefault(value => value.Provider == provider),
                true, "island." + provider + ".account", classic, details, showsName, () => OpenModuleSettings(provider),
                snapshot.Modules?.FirstOrDefault(module => module.Provider == provider)?.DisplayName);
    }

    /// The header shows the chosen buttons; the rest wait in the More menu.
    private void ApplyHeaderActions()
    {
        MarkReadButton.Visibility = panelOptions.InHeader("markRead") ? Visibility.Visible : Visibility.Collapsed;
        PinButton.Visibility = panelOptions.InHeader("pin") ? Visibility.Visible : Visibility.Collapsed;
        SettingsButton.Visibility = panelOptions.InHeader("settings") ? Visibility.Visible : Visibility.Collapsed;
        // Return to Top Center is for Free Move, and waits while the island already sits there, as Settings' button.
        RecenterButton.Visibility = panelOptions.InHeader("recenter") && compactPreferences.DisplayMode != "notch" ? Visibility.Visible : Visibility.Collapsed;
        RecenterButton.IsEnabled = SaveIslandPlacement != null && (compactPreferences.IslandPlacement != null || compactPreferences.Position != "center");
    }

    /// Unchecked header buttons first, then Refresh and Quit, which always live here.
    /// Return to Top Center has no place here: unchecked, it stays in Settings alone.
    private string? menuShape;
    private void BuildMoreMenu()
    {
        var menu = MoreButton.ContextMenu;
        // The menu is rebuilt only when what it lists changed.
        string shape = string.Join(",", showAppButtons ? Array.Empty<string>() : AvailableApplications()) + ";" + panelOptions.Key + ";" + MarkReadButton.IsEnabled + ";" + pinned;
        if (shape == menuShape && menu.Items.Count > 0) return;
        menuShape = shape;
        menu.Items.Clear();
        int hidden = 0;
        if (!showAppButtons)
            foreach (string provider in AvailableApplications())
            {
                var item = new MenuItem { Header = OpenApplicationLabel(provider) };
                item.Icon = ProviderIcon.CreateLaunch(provider, 14, item);
                AutomationProperties.SetAutomationId(item, "island.menu.open." + provider);
                item.Click += async (_, _) => await OpenDesktopApplicationFromMenu(provider);
                menu.Items.Add(item); hidden++;
            }
        if (panelOptions.InMenu("markRead"))
        {
            var item = new MenuItem { Header = ui.Text("activity.mark_all_read"), IsEnabled = MarkReadButton.IsEnabled };
            AutomationProperties.SetAutomationId(item, "island.menu.markRead");
            item.Click += OnMarkRead; menu.Items.Add(item); hidden++;
        }
        if (panelOptions.InMenu("pin"))
        {
            var item = new MenuItem { Header = ui.Text(pinned ? "common.unpin" : "common.pin") };
            AutomationProperties.SetAutomationId(item, "island.menu.pin");
            item.Click += OnPin; menu.Items.Add(item); hidden++;
        }
        if (panelOptions.InMenu("settings")) { menu.Items.Add(SettingsMenu); hidden++; }
        if (hidden > 0) menu.Items.Add(new Separator());
        menu.Items.Add(RefreshMenu); menu.Items.Add(new Separator()); menu.Items.Add(QuitMenu);
    }
}
