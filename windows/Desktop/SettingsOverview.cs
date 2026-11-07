using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// Overview and History, as on the Mac. Overview shows what needs the user, a
/// card per service with the island's own quota view, then the island's task
/// rows; History shows one service's current quota cycle at a time and
/// DeepSeek's recent days. The island's components keep their dark card.
internal sealed partial class SettingsWindow
{
    private const double WidePageWidth = 900;
    private string? historyProvider, overviewKey, historyKey, sidebarCodexKey;
    private StackPanel? overviewBody, historyBody;
    private TextBlock? overviewSubtitle;
    private CodexSourceReport? sidebarCodexReport;
    private bool sidebarCodexPending;
    private string? dismissedUpdate;

    private sealed record AttentionItem(string Id, string Title, string Detail, string Action, Func<Task> Perform);

    private static Border IslandCard(UIElement child, Thickness? padding = null)
    {
        var card = new Border { Background = new SolidColorBrush(Color.FromRgb(36, 36, 40)), BorderBrush = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14), Padding = padding ?? new Thickness(16, 14, 16, 14), Child = child, Margin = new Thickness(0, 0, 0, 12) };
        return card;
    }

    private string[] EnabledProviders()
    {
        var snapshot = engine?.LatestSnapshot;
        if (snapshot?.Modules is { } modules) return new[] { "codex", "claude", "deepseek" }.Where(provider => modules.Any(value => value.Provider == provider && value.Enabled)).ToArray();
        return snapshot?.QuotaDashboard?.Providers.Select(value => value.Provider).ToArray() ?? [];
    }

    private static int RemoteProblems(EngineSnapshot snapshot)
    {
        if (snapshot.Connections is not { } page) return 0;
        int sources = page.Sources.Count(value => value.Module.Tone == "warning");
        int hosts = page.Hosts.Count(host => host.Modules.Any(value => value.Tone == "warning"));
        return Math.Max(sources, hosts);
    }

    /// What needs the user, with the one action that fixes it. The sidebar's
    /// amber dots and Overview's card read the same list, as on the Mac.
    private List<AttentionItem> AttentionItems()
    {
        var items = new List<AttentionItem>(); var snapshot = engine?.LatestSnapshot;
        if (snapshot == null || engine == null || providerConnectionClosed || engine.IsConnectionClosed) return items;
        var enabled = EnabledProviders();
        if (enabled.Contains("claude"))
        {
            string? key = snapshot.ClaudeSetup?.State == "failed" && !snapshot.Demo ? "provider.state.failed"
                : snapshot.ClaudeConnection?.State == "workspaceNeeded" ? "claude.account.workspace_needed"
                : snapshot.ClaudeConnection?.State == "signedOut" ? "claude.account.signed_out" : null;
            if (key != null)
                items.Add(new("claude", "Claude · " + ui.Text(key), ui.Text("main.attention.quota_waits"),
                    ui.Text(key == "provider.state.failed" ? "connections.retry" : key == "claude.account.workspace_needed" ? "claude.quota.choose_workspace" : "claude.quota.connect"),
                    key == "provider.state.failed" ? () => engine.SendAsync("retryClaudeSetup") : () => GuideProviderActionAsync("claude")));
        }
        if (enabled.Contains("codex") && sidebarCodexReport is { SelectedExecutable: null })
            items.Add(new("codex", "Codex CLI · " + ui.Text("provider.state.not_found"), ui.Text("main.attention.codex_cli"), ui.Text("main.overview.open"), () => NavigateAsync("codex")));
        int problems = RemoteProblems(snapshot);
        if (problems > 0)
            items.Add(new("remote", ui.Text("main.pane.remote"), ui.Text(problems == 1 ? "connections.summary.retrying_one" : "connections.summary.retrying").Replace("%ld", problems.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal),
                ui.Text("main.overview.open"), () => NavigateAsync("remote")));
        return items;
    }

    /// Codex's CLI check runs once per source change so the sidebar and Overview
    /// can say when it is missing without opening the Codex page.
    private void EnsureCodexCheck()
    {
        if (engine == null || sourceClosed || sidebarCodexPending || !EnabledProviders().Contains("codex")) return;
        string key = session.Current.CodexExecutable + "\0" + session.Current.CodexHome;
        if (key == sidebarCodexKey) return;
        sidebarCodexKey = key; sidebarCodexPending = true;
        _ = Check();
        async Task Check()
        {
            try
            {
                await sourceReady;
                if (sourceClosed) return;
                sidebarCodexReport = await engine.QueryAsync<CodexSourceReport>("inspectCodexSource", new { codexExecutable = session.Current.CodexExecutable, codexHome = session.Current.CodexHome });
            }
            catch (Exception error) when (error is System.IO.IOException or OperationCanceledException or InvalidOperationException) { sidebarCodexReport = null; }
            finally { sidebarCodexPending = false; if (!sourceClosed) { RefreshSidebar(); RefreshOverview(); } }
        }
    }

    private void ClearOverview() { overviewBody = historyBody = null; overviewSubtitle = null; overviewKey = historyKey = null; }

    private void BuildOverview()
    {
        var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var names = new StackPanel();
        var title = Label(PaneTitle("overview"), 22, FontWeights.Bold); AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1); names.Children.Add(title);
        overviewSubtitle = Label("", 12.5); overviewSubtitle.Margin = new Thickness(0, 3, 0, 0); overviewSubtitle.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        Identify(overviewSubtitle, "settings.overview.subtitle", ""); names.Children.Add(overviewSubtitle);
        header.Children.Add(names);
        var glyph = new IconGlyph { Symbol = "arrow.clockwise", Width = 14, Height = 14 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsPrimary");
        var refresh = new Button { Content = glyph, ContentTemplate = null, Width = 32, Height = 26, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, ToolTip = ui.Text("common.refresh") };
        Identify(refresh, "settings.overview.refresh", ui.Text("common.refresh")); editors.Add(refresh);
        refresh.Click += async (_, _) =>
        {
            await sourceReady;
            try { if (!sourceClosed && engine != null) await engine.SendAsync("refresh", new { discover = true }); }
            catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { ShowIssue("windows.connection.refresh_failed"); }
        };
        Grid.SetColumn(refresh, 1); header.Children.Add(refresh);
        SetPaneHeader(header); Widen();
        overviewBody = new StackPanel(); Identify(overviewBody, "settings.overview", PaneTitle("overview")); form.Children.Add(overviewBody);
        RefreshOverview();
    }

    private void Widen() { form.MaxWidth = headerColumn.MaxWidth = WidePageWidth; }

    private void RefreshOverview()
    {
        if (overviewBody == null || overviewSubtitle == null) return;
        var snapshot = engine?.LatestSnapshot;
        bool closed = providerConnectionClosed || engine?.IsConnectionClosed != false;
        var rows = closed ? [] : snapshot?.Presentation?.Rows ?? [];
        var culture = CultureInfo.GetCultureInfo(ui.Language == "zh-Hans" ? "zh-CN" : "en-US");
        string date = DateTime.Now.ToString(ui.Language == "zh-Hans" ? "M月d日 dddd" : "dddd, MMMM d", culture);
        overviewSubtitle.Text = date + " · " + (rows.Count == 0 ? ui.Text("main.overview.no_tasks")
            : ui.Text(rows.Count == 1 ? "main.overview.tasks_one" : "main.overview.tasks").Replace("%ld", rows.Count.ToString(culture), StringComparison.Ordinal));
        AutomationProperties.SetName(overviewSubtitle, overviewSubtitle.Text);
        var attention = AttentionItems();
        string? update = updater?.CurrentOffer?.Version;
        string key = JsonSerializer.Serialize(new { snapshot?.Presentation, snapshot?.QuotaDashboard, snapshot?.Wallet, snapshot?.Modules, snapshot?.ActivityLinks,
            attention = attention.Select(value => value.Title + value.Detail + value.Action), update, dismissedUpdate, session.Current.ExpandedQuotaStyle, session.Current.AccentColor, closed });
        if (key == overviewKey) return;
        overviewKey = key;
        foreach (UIElement child in overviewBody.Children) PageAccessibility.Retire(child);
        overviewBody.Children.Clear();
        if (update != null && update != dismissedUpdate) overviewBody.Children.Add(UpdateBanner(update));
        if (attention.Count > 0) overviewBody.Children.Add(AttentionCard(attention));
        var enabled = closed ? [] : EnabledProviders();
        if (enabled.Length == 0)
        {
            var none = Label(closed ? ui.Text("windows.connection.closed") : ui.Text("provider.none_enabled")); none.TextWrapping = TextWrapping.Wrap; none.Margin = new Thickness(0, 12, 0, 12);
            overviewBody.Children.Add(Card(Row(none, new Border())));
        }
        else overviewBody.Children.Add(ServiceCards(snapshot!, enabled));
        overviewBody.Children.Add(TasksCard(snapshot, rows));
    }

    /// A found version, with the existing install flow behind Update and Restart.
    private Border UpdateBanner(string version)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = AppIcon(32); icon.Margin = new Thickness(0, 0, 12, 0); grid.Children.Add(icon);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Label(ui.Text("main.update.banner").Replace("%@", version, StringComparison.Ordinal), 13, FontWeights.SemiBold));
        var detail = Detail(ui.Text("main.update.banner_detail")); detail.FontSize = 11.5; text.Children.Add(detail);
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var install = new Button { Content = ui.Text("main.update.install"), Style = (Style)FindResource("SettingsProminentButton") };
        Identify(install, "settings.overview.update", ui.Text("main.update.install"));
        install.Click += (_, _) => { if (updater?.CurrentOffer is { } offer) updater.Presenter?.Offer(offer, true); };
        actions.Children.Add(install);
        var glyph = new IconGlyph { Symbol = "xmark", Width = 11, Height = 11 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var later = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 24, Height = 24, Padding = new Thickness(0), Content = glyph, Margin = new Thickness(8, 0, 0, 0), ToolTip = ui.Text("main.update.later") };
        Identify(later, "settings.overview.update_later", ui.Text("main.update.later"));
        later.Click += (_, _) => { dismissedUpdate = version; RefreshOverview(); };
        actions.Children.Add(later);
        Grid.SetColumn(actions, 2); grid.Children.Add(actions);
        var card = new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Padding = new Thickness(16, 12, 16, 12), Margin = new Thickness(0, 0, 0, 12), Child = grid };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        return card;
    }

    private Border AttentionCard(IReadOnlyList<AttentionItem> items)
    {
        var amber = Color.FromRgb(255, 159, 10);
        var list = new StackPanel();
        for (int index = 0; index < items.Count; index++)
        {
            var item = items[index];
            if (index > 0) list.Children.Add(new Border { Height = 1, Background = new SolidColorBrush(Color.FromArgb(41, amber.R, amber.G, amber.B)) });
            var row = new Grid { Margin = new Thickness(0, 11, 0, 11) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var mark = new IconGlyph { Symbol = "exclamationmark.circle", Width = 18, Height = 18, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
            mark.SetResourceReference(IconGlyph.InkProperty, "SettingsWarning"); row.Children.Add(mark);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(Label(item.Title, 13, FontWeights.SemiBold)); var detail = Detail(item.Detail); detail.FontSize = 11.5; text.Children.Add(detail);
            Grid.SetColumn(text, 1); row.Children.Add(text);
            var action = new Button { Content = item.Action, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
            Identify(action, "settings.overview.attention." + item.Id, item.Title + " · " + item.Action); editors.Add(action);
            action.Click += async (_, _) =>
            {
                try { await sourceReady; if (!sourceClosed) await item.Perform(); }
                catch (Exception error) when (ProviderLoginWindow.Recoverable(error) || error is EngineCommandException) { ShowIssue("windows.connection.refresh_failed"); }
            };
            Grid.SetColumn(action, 2); row.Children.Add(action);
            AutomationProperties.SetName(row, item.Title + " " + item.Detail);
            list.Children.Add(row);
        }
        return new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Padding = new Thickness(16, 0, 16, 0), Margin = new Thickness(0, 0, 0, 12),
            Background = new SolidColorBrush(Color.FromArgb(20, amber.R, amber.G, amber.B)), BorderBrush = new SolidColorBrush(Color.FromArgb(64, amber.R, amber.G, amber.B)), Child = list };
    }

    /// A service with both a 5-hour and a weekly window gets a row of its own;
    /// the others share rows two at a time above them, as on the Mac.
    private StackPanel ServiceCards(EngineSnapshot snapshot, string[] enabled)
    {
        bool Wide(string provider) => provider != "deepseek" && snapshot.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == provider) is { } reading
            && reading.FiveHour.RemainingPercent != null && reading.Weekly.RemainingPercent != null;
        var wide = enabled.Where(Wide).ToArray(); var narrow = enabled.Except(wide).ToArray();
        var stack = new StackPanel();
        for (int index = 0; index < narrow.Length; index += 2)
        {
            var pair = new Grid();
            pair.ColumnDefinitions.Add(new ColumnDefinition()); pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) }); pair.ColumnDefinitions.Add(new ColumnDefinition());
            var first = ServiceCard(narrow[index], snapshot); pair.Children.Add(first);
            if (index + 1 < narrow.Length) { var second = ServiceCard(narrow[index + 1], snapshot); Grid.SetColumn(second, 2); pair.Children.Add(second); }
            stack.Children.Add(pair);
        }
        foreach (string provider in wide) stack.Children.Add(ServiceCard(provider, snapshot));
        return stack;
    }

    private Border ServiceCard(string provider, EngineSnapshot snapshot)
    {
        var content = new StackPanel();
        var header = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = ProviderTile(provider); tile.Margin = new Thickness(0, 0, 8, 0); header.Children.Add(tile);
        var name = new TextBlock { Text = PaneTitle(provider), FontSize = 13.5, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Primary, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(name, 1); header.Children.Add(name);
        var details = new Button { Content = ui.Text("main.overview.details"), Style = (Style)FindResource("SettingsLink"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        Identify(details, "settings.overview.details." + provider, PaneTitle(provider) + " · " + ui.Text("main.overview.details"));
        details.Click += async (_, _) => await NavigateAsync(provider);
        Grid.SetColumn(details, 2); header.Children.Add(details);
        content.Children.Add(header);
        string connectUnavailable = ui.Text(demo ? "windows.deepseek.demo_web_help" : "windows.deepseek.runtime_required");
        if (provider == "deepseek") content.Children.Add(new DeepSeekSoloView(snapshot.Wallet, ui, false, connectUnavailable: connectUnavailable) { Margin = new Thickness(0) });
        else if (snapshot.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == provider) is { } reading)
        {
            var raw = snapshot.Quota.FirstOrDefault(value => value.Provider == provider);
            var help = snapshot.Sources.FirstOrDefault(source => source.Provider == provider && source.Transport == "app-server")?.Reason;
            FrameworkElement? status = reading.Status is { State: not "hidden" } connection
                ? new QuotaConnectionView(provider, connection, ui, () => engine!.SendAsync("retryQuota", new { provider }), () => _ = NavigateAsync(provider)) : null;
            FrameworkElement view = session.Current.ExpandedQuotaStyle == "classic"
                ? new QuotaCell(provider, raw, snapshot.Wallet, help, reading, status) { HorizontalAlignment = HorizontalAlignment.Left }
                : new SingleQuotaView(reading, raw, ui, help, status) { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left };
            content.Children.Add(view);
        }
        else content.Children.Add(new TextBlock { Text = ui.Text("provider.state.searching"), FontSize = 12, Foreground = PacerPalette.Secondary });
        var card = IslandCard(content); Identify(card, "settings.overview.service." + provider, PaneTitle(provider)); return card;
    }

    private Border TasksCard(EngineSnapshot? snapshot, IReadOnlyList<EngineTaskRow> rows)
    {
        var content = new StackPanel();
        var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(9, 0, 9, 4) };
        header.Children.Add(new TextBlock { Text = ui.Text("main.overview.running"), FontSize = 13.5, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Primary });
        header.Children.Add(new TextBlock { Text = snapshot?.Presentation?.TaskCountText ?? "", FontSize = 12, Foreground = PacerPalette.Secondary, Margin = new Thickness(8, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(header);
        if (rows.Count == 0)
        {
            var empty = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(9, 8, 9, 8) };
            empty.Children.Add(new IconGlyph { Symbol = "moon", Ink = PacerPalette.Secondary, Width = 24, Height = 24 });
            empty.Children.Add(new TextBlock { Text = ui.Text("activity.no_tasks"), FontSize = 12, FontWeight = FontWeights.Medium, Foreground = PacerPalette.Secondary, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(empty);
        }
        int index = 0;
        foreach (var value in rows.Take(8))
        {
            if (index++ > 0) content.Children.Add(new Border { Height = 1, Margin = new Thickness(9, 0, 9, 0), Background = new SolidColorBrush(Color.FromArgb(15, 255, 255, 255)) });
            var row = new TaskRow(value) { Language = Language, Height = 54 };
            var state = (TaskRowState)row.DataContext;
            if (surfaceWindow?.CanOpenFromWindow(value) == true)
            {
                var island = surfaceWindow;
                row.SetOpenAction(() => _ = island.OpenFromWindowAsync(value), state.AccessibleName + "\n" + ui.Text("common.open_chat"), false);
            }
            else row.SetOpenAction(null, ui.Text("activity.no_link"), false);
            content.Children.Add(row);
        }
        var card = IslandCard(content, new Thickness(4, 14, 4, 14)); Identify(card, "settings.overview.tasks", ui.Text("main.overview.running")); return card;
    }

    private void BuildHistory()
    {
        paneSubtitle.Text = ui.Text("main.history.subtitle"); paneSubtitle.Visibility = Visibility.Visible; Widen();
        historyBody = new StackPanel(); Identify(historyBody, "settings.history", PaneTitle("history")); form.Children.Add(historyBody);
        RefreshHistory();
    }

    private void RefreshHistory()
    {
        if (historyBody == null) return;
        var snapshot = engine?.LatestSnapshot;
        bool closed = providerConnectionClosed || engine?.IsConnectionClosed != false;
        var enabled = closed ? [] : EnabledProviders();
        var quota = enabled.Where(value => value is "codex" or "claude").ToArray();
        string? provider = historyProvider != null && quota.Contains(historyProvider) ? historyProvider : quota.FirstOrDefault();
        var history = provider == null ? null : snapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == provider)?.History;
        var week = enabled.Contains("deepseek") ? snapshot?.Wallet?.Solo?.Week : null;
        string key = JsonSerializer.Serialize(new { provider, quota, history?.Title, week?.AccessibilityLabel, deepseek = enabled.Contains("deepseek"), closed, busy, session.RequiresRestart });
        if (key != historyKey)
        {
            historyKey = key;
            foreach (UIElement child in historyBody.Children) PageAccessibility.Retire(child);
            historyBody.Children.Clear(); historyView = null;
            if (provider != null) historyBody.Children.Add(HistoryCard(provider, quota, history));
            if (enabled.Contains("deepseek"))
            {
                var content = new StackPanel();
                content.Children.Add(new TextBlock { Text = ui.Text("main.history.deepseek_week"), FontSize = 13.5, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Primary, Margin = new Thickness(0, 0, 0, 12) });
                if (week is { Days.Count: >= 2 }) content.Children.Add(new DeepSeekWeekView(week));
                else content.Children.Add(new TextBlock { Text = ui.Text("main.history.deepseek_empty"), FontSize = 12, Foreground = PacerPalette.Secondary });
                var card = IslandCard(content, new Thickness(18, 16, 18, 16)); Identify(card, "settings.history.deepseek", ui.Text("main.history.deepseek_week"));
                historyBody.Children.Add(card);
            }
            if (enabled.Length == 0)
            {
                var none = Label(closed ? ui.Text("windows.connection.closed") : ui.Text("provider.none_enabled")); none.TextWrapping = TextWrapping.Wrap; none.Margin = new Thickness(0, 12, 0, 12);
                historyBody.Children.Add(Card(Row(none, new Border())));
            }
        }
        if (closed) historyView?.ShowUnavailable(ui.Text("windows.connection.closed"));
        else historyView?.Update(history);
        historyView?.SetInteractionEnabled(!closed && !busy && !session.RequiresRestart);
    }

    private QuotaHistoryView? historyView;

    /// The chosen service's cycle, with chips to switch when both read quota.
    private Border HistoryCard(string provider, string[] providers, QuotaHistoryPresentation? history)
    {
        var content = new StackPanel();
        var header = new Grid { Margin = new Thickness(0, 0, 0, 8) }; header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Label(history?.Title ?? PaneTitle(provider), 13.5, FontWeights.SemiBold); Identify(title, "settings.history.title", title.Text); header.Children.Add(title);
        if (providers.Length > 1)
        {
            var chips = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (string choice in providers)
            {
                var chip = new RadioButton { Style = (Style)FindResource("SettingsChip"), GroupName = "settings.history.providers", IsChecked = choice == provider, Margin = new Thickness(6, 0, 0, 0) };
                var label = new StackPanel { Orientation = Orientation.Horizontal };
                label.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = PacerPalette.Provider(choice), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
                label.Children.Add(Label(PaneTitle(choice), 12)); chip.Content = label;
                Identify(chip, "settings.history.provider." + choice, PaneTitle(choice));
                chip.Checked += (_, _) => { if (!synchronizing && historyProvider != choice) { historyProvider = choice; Dispatcher.BeginInvoke(RefreshHistory); } };
                chips.Children.Add(chip);
            }
            Grid.SetColumn(chips, 1); header.Children.Add(chips);
        }
        content.Children.Add(header);
        historyView = new QuotaHistoryView(ui, provider == "claude" ? PacerPalette.Claude : PacerPalette.Codex, async () =>
        { await sourceReady; if (!sourceClosed && engine != null) await engine.SendAsync("retryQuota", new { provider }); });
        content.Children.Add(historyView);
        var card = new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Padding = new Thickness(18, 16, 18, 16), Margin = new Thickness(0, 0, 0, 12), Child = content };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        Identify(card, "settings.history." + provider, history?.Title ?? PaneTitle(provider));
        return card;
    }
}
