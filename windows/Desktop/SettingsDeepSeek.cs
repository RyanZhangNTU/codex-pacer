using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
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
    private CheckBox? deepseekEnabled, deepseekTurnCost, deepseekProgress;
    private TextBlock? deepseekProgressState;
    private Button? deepseekProgressRetry;
    private FrameworkElement? deepseekProgressStatus;
    private Button? deepseekAutomatic, deepseekSignIn, deepseekRingLink;
    private TextBlock? deepseekDetection, deepseekBalance, deepseekRunway, deepseekDailyReference, deepseekWeeklyReference, deepseekBudgetIssue, deepseekLocalState, deepseekRingHint;
    private StackPanel? deepseekSections, deepseekBudgetRows;
    private FrameworkElement? deepseekRingRow;
    private Border? deepseekOff;
    private TextBlock? deepseekModeNote;
    private FrameworkElement? deepseekBalanceRow;
    private System.Windows.Shapes.Ellipse? deepseekLocalDot;
    private TextBox? deepseekDaily, deepseekWeekly;
    private DeepSeekPriceClock? deepseekClock;
    private DeepSeekPricingTimeline? deepseekPricing;
    private TextBlock? deepseekConnection;
    private FrameworkElement? deepseekAccountHelp, deepseekConnectionDot;
    private readonly Dictionary<string, RadioButton> deepseekChoices = new();
    private readonly string?[] deepseekPendingBudget = [null, null];
    private double? deepseekDailyValue, deepseekWeeklyValue;

    private void ClearDeepSeek()
    {
        ClearDeepSeekConnection();
        deepseekEnabled = deepseekTurnCost = deepseekProgress = null; deepseekAutomatic = deepseekSignIn = deepseekRingLink = null; deepseekConnection = null;
        deepseekProgressState = null; deepseekProgressRetry = null; deepseekProgressStatus = null;
        deepseekDetection = deepseekBalance = deepseekRunway = deepseekDailyReference = deepseekWeeklyReference = deepseekBudgetIssue = deepseekLocalState = deepseekRingHint = null;
        deepseekSections = deepseekBudgetRows = null; deepseekRingRow = null;
        deepseekDaily = deepseekWeekly = null; deepseekOff = null; deepseekModeNote = null; deepseekBalanceRow = null; deepseekLocalDot = null; deepseekClock = null; deepseekPricing = null;
        deepseekDailyValue = deepseekWeeklyValue = null; deepseekChoices.Clear(); Array.Clear(deepseekPendingBudget);
        deepseekAccountHelp = deepseekConnectionDot = null;
    }
    /// As on the Mac: the header holds the module switch, then the balance and
    /// its connection, the dial's mode and budgets, what task rows show, prices,
    /// and folded session locations. The panel style moved to Appearance.
    private void BuildDeepSeek()
    {
        SetPaneHeader(ProviderHeader("deepseek", out var detection, out var module, out var automatic));
        deepseekDetection = detection; deepseekEnabled = module; deepseekAutomatic = automatic;
        Identify(deepseekEnabled, "settings.deepseek.enabled", "DeepSeek"); editors.Add(deepseekEnabled);
        BindToggle(deepseekEnabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { ["deepseek"] = value ? "enabled" : "disabled" } });
        Identify(deepseekAutomatic, "settings.deepseek.automatic", ui.Text("provider.restore_automatic")); editors.Add(deepseekAutomatic);
        deepseekAutomatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { ["deepseek"] = "automatic" } });
        deepseekOff = ModuleOffCard(); form.Children.Add(deepseekOff);
        deepseekSections = new StackPanel(); form.Children.Add(deepseekSections);

        var amount = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        // The amount, its runway and the trend, as on the Mac (the price clock lives on the island and History).
        deepseekClock = new DeepSeekPriceClock();
        deepseekBalance = Label("", 15, FontWeights.SemiBold); amount.Children.Add(deepseekBalance);
        deepseekRunway = Label("", 12); deepseekRunway.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        deepseekRunway.Margin = new Thickness(8, 0, 0, 0); deepseekRunway.VerticalAlignment = VerticalAlignment.Center; amount.Children.Add(deepseekRunway);
        var trend = new Button { Content = ui.Text("main.quota.trend"), Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Identify(trend, "settings.deepseek.trend", ui.Text("main.quota.trend")); trend.Click += async (_, _) => await NavigateAsync("history"); amount.Children.Add(trend);
        deepseekBalanceRow = InfoRow(ui.Text("deepseek.section.balance"), amount);
        deepseekSections.Children.Add(SectionTitle(ui.Text("deepseek.section.balance"), 0));
        deepseekSections.Children.Add(Card(deepseekBalanceRow, BuildDeepSeekConnection()));

        var mode = DeepSeekSegments("mode", new[] { ("balance", "deepseek.mode.balance"), ("budget", "deepseek.mode.budget") }, async value =>
        {
            await sourceReady;
            var suggestion = engine?.LatestSnapshot?.Wallet?.Settings;
            if (value == "budget" && suggestion == null) { ShowIssue("windows.settings.apply_failed"); RefreshValues(); return; }
            await Change(p => p with { DeepSeekMode = value,
                DeepSeekDailyBudget = value == "budget" && p.DeepSeekDailyBudget == null && p.DeepSeekWeeklyBudget == null ? suggestion!.SuggestedDaily : p.DeepSeekDailyBudget,
                DeepSeekWeeklyBudget = value == "budget" && p.DeepSeekDailyBudget == null && p.DeepSeekWeeklyBudget == null ? suggestion!.SuggestedWeekly : p.DeepSeekWeeklyBudget });
        });
        deepseekBudgetRows = new StackPanel();
        deepseekBudgetRows.Children.Add(DeepSeekBudgetField(true)); deepseekBudgetRows.Children.Add(Hairline(14)); deepseekBudgetRows.Children.Add(DeepSeekBudgetField(false));
        deepseekRingRow = new StackPanel();
        ((StackPanel)deepseekRingRow).Children.Add(Hairline(14));
        ((StackPanel)deepseekRingRow).Children.Add(Row(Label(ui.Text("deepseek.budget.ring")), DeepSeekSegments("ring", new[] { ("day", "deepseek.budget.day"), ("week", "deepseek.budget.week") }, value => ChangeDeepSeek(p => p with { DeepSeekRingPeriod = value }))));
        deepseekBudgetRows.Children.Add(deepseekRingRow);
        deepseekRingHint = Label(""); deepseekRingHint.TextWrapping = TextWrapping.Wrap; Identify(deepseekRingHint, "settings.deepseek.ring_hint", "");
        deepseekRingLink = new Button { Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
        Identify(deepseekRingLink, "settings.deepseek.ring_link", ""); deepseekRingLink.Click += async (_, _) => await NavigateToQuotaGaugeAsync();
        deepseekBudgetRows.Children.Add(Hairline(14)); deepseekBudgetRows.Children.Add(Row(deepseekRingHint, deepseekRingLink));
        deepseekBudgetIssue = Detail(""); deepseekBudgetIssue.Margin = new Thickness(14, 0, 14, 10); deepseekBudgetIssue.Visibility = Visibility.Collapsed; Identify(deepseekBudgetIssue, "settings.deepseek.budget.issue", ""); deepseekBudgetRows.Children.Add(deepseekBudgetIssue);
        deepseekBudgetIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        deepseekModeNote = CardFooter("");
        var modeCard = Card(Row(Label(ui.Text("deepseek.mode")), mode), deepseekBudgetRows);
        deepseekSections.Children.Add(SectionTitle(ui.Text("deepseek.section.mode"))); deepseekSections.Children.Add(modeCard); deepseekSections.Children.Add(deepseekModeNote);

        var speed = InfoRow(ui.Text("main.deepseek.speed_basis"), DeepSeekSegments("speed", new[] { ("local", "windows.deepseek.speed_source.local"), ("account", "deepseek.speed_source.account") }, value => ChangeDeepSeek(p => p with { DeepSeekSpeedSource = value })),
            ui.Text("windows.deepseek.speed_basis_help"), id: "settings.deepseek.speed");
        var costs = Toggle("deepseek.turn_cost", "deepseek.turn_cost_help", "settings.deepseek.turn_cost", out var cost);
        deepseekTurnCost = cost; editors.Add(cost); BindToggle(cost, (p, value) => p with { DeepSeekShowsTurnCost = value });
        deepseekProgress = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center };
        Identify(deepseekProgress, "settings.deepseek.progress_ring", ui.Text("main.claude.ring")); editors.Add(deepseekProgress);
        BindToggle(deepseekProgress, (p, value) => p with { DeepSeekProgressRing = value });
        deepseekProgressState = Detail(""); Identify(deepseekProgressState, "settings.deepseek.progress_state", "");
        deepseekProgressRetry = new Button { Content = ui.Text("connections.retry"), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        Identify(deepseekProgressRetry, "settings.deepseek.progress_retry", ui.Text("connections.retry"));
        deepseekProgressRetry.Click += async (sender, _) =>
        {
            if (sourceClosed || !ReferenceEquals(sender, deepseekProgressRetry) || engine == null || !deepseekProgressRetry.IsEnabled) return;
            try { await engine.SendAsync("retryDeepSeekProgressSetup"); }
            catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            {
                if (!sourceClosed && ReferenceEquals(sender, deepseekProgressRetry))
                    deepseekProgressState?.SetCurrentValue(TextBlock.TextProperty, ui.Text(
                        (session.Current.DeepSeekProgressRing ? "deepseek.progress_setup." : "deepseek.progress_cleanup.") + "failed"));
            }
        };
        var progressEnd = new StackPanel { Orientation = Orientation.Horizontal }; progressEnd.Children.Add(deepseekProgressRetry); progressEnd.Children.Add(deepseekProgress);
        var progress = InfoRow(ui.Text("main.claude.ring"), progressEnd, ui.Text("deepseek.progress_ring_help"), deepseekProgressState, "settings.deepseek.progress_ring");
        deepseekProgressStatus = deepseekProgressState;
        deepseekSections.Children.Add(SectionTitle(ui.Text("deepseek.section.display")));
        deepseekSections.Children.Add(Card(speed, costs, progress)); deepseekSections.Children.Add(CardFooter(ui.Text("main.deepseek.estimate_note")));

        var pricing = new Button { Content = ui.Text("deepseek.price_list"), Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
        Identify(pricing, "settings.deepseek.pricing", ui.Text("deepseek.price_list"));
        pricing.Click += (_, _) =>
        {
            if (!SettingsPagePolicy.OpenPricing(ui.Language, guideLinkLauncher)) ShowIssue("windows.pages.open_failed");
        };
        deepseekPricing = new DeepSeekPricingTimeline(ui) { Margin = new Thickness(14, 12, 14, 12) };
        deepseekSections.Children.Add(SectionTitle(ui.Text("deepseek.section.pricing")));
        deepseekSections.Children.Add(Card(deepseekPricing, InfoRow(ui.Text("main.deepseek.estimate"), pricing, ui.Text("windows.deepseek.pricing_note"), id: "settings.deepseek.estimate")));

        var sessions = StatusRow(ui.Text("windows.deepseek.sessions"), out var sessionDot, out var sessionState);
        deepseekLocalDot = sessionDot; deepseekLocalState = sessionState; Identify(deepseekLocalState, "settings.deepseek.local_state", "");
        var home = ProviderHomeEditor("deepseek");
        // Session status reads first inside the folded locations, as on the Mac.
        if (providerHomeLocations?.Content is StackPanel body) { body.Children.Insert(1, sessions); body.Children.Insert(2, Hairline(0, 0)); sessions.Margin = new Thickness(0); }
        deepseekSections.Children.Add(Card(home));
    }
    private Task ChangeDeepSeek(Func<DesktopPreferences, DesktopPreferences> edit) => Change(edit);
    private TextBlock DeepSeekCaption(string value)
    { var text = Detail(value); text.Margin = new Thickness(10, 10, 10, 10); text.LineHeight = 14; return text; }
    private Border DeepSeekSegments(string group, (string Value, string Key)[] options, Func<string, Task> change)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var option in options)
        {
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), GroupName = "deepseek." + group, Content = ui.Text(option.Key) };
            string id = group + "." + option.Value; Identify(choice, "settings.deepseek." + id, ui.Text(option.Key));
            choice.Checked += async (_, _) => { if (!synchronizing) await change(option.Value); };
            deepseekChoices[id] = choice; row.Children.Add(choice); editors.Add(choice);
        }
        var border = new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center }; border.SetResourceReference(Border.BackgroundProperty, "SettingsFill"); return border;
    }
    private Grid DeepSeekBudgetField(bool daily)
    {
        string key = daily ? "deepseek.budget.daily" : "deepseek.budget.weekly";
        var field = new TextBox { Width = 72, MaxLength = 320, TextAlignment = TextAlignment.Right, Tag = ui.Text("deepseek.budget.off"), VerticalAlignment = VerticalAlignment.Center };
        Identify(field, "settings.deepseek.budget." + (daily ? "daily" : "weekly"), ui.Text(key)); editors.Add(field);
        field.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitDeepSeekBudget(daily, field); } };
        field.LostKeyboardFocus += async (_, _) => { if (!composing) await CommitDeepSeekBudget(daily, field); };
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var reference = Detail(""); reference.Margin = new Thickness(0, 0, 10, 0); reference.VerticalAlignment = VerticalAlignment.Center; content.Children.Add(reference);
        var currency = Label("¥"); currency.Margin = new Thickness(0, 0, 4, 0); currency.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); content.Children.Add(currency); content.Children.Add(field);
        if (daily) { deepseekDaily = field; deepseekDailyReference = reference; } else { deepseekWeekly = field; deepseekWeeklyReference = reference; }
        return Row(Label(ui.Text(key)), content);
    }
    private async Task CommitDeepSeekBudget(bool daily, TextBox field)
    {
        if (synchronizing || sourceClosed || activePane != "deepseek") return;
        string text = field.Text.Trim(); int index = daily ? 0 : 1;
        if (deepseekPendingBudget[index] == text) return;
        double? value = null;
        if (text.Length > 0)
        {
            if (!double.TryParse(text, NumberStyles.Float | NumberStyles.AllowThousands, CultureInfo.CurrentCulture, out double parsed) || !double.IsFinite(parsed))
            { if (deepseekBudgetIssue != null) { deepseekBudgetIssue.Text = ui.Text("windows.deepseek.invalid_budget"); AutomationProperties.SetName(deepseekBudgetIssue, deepseekBudgetIssue.Text); deepseekBudgetIssue.Visibility = Visibility.Visible; AutomationProperties.SetLiveSetting(deepseekBudgetIssue, AutomationLiveSetting.Assertive); } return; }
            if (parsed > 0) value = parsed;
        }
        if (deepseekBudgetIssue != null) deepseekBudgetIssue.Visibility = Visibility.Collapsed;
        if (value == (daily ? session.Current.DeepSeekDailyBudget : session.Current.DeepSeekWeeklyBudget)) return;
        deepseekPendingBudget[index] = text;
        try
        {
            var result = await Change(p => daily ? p with { DeepSeekDailyBudget = value } : p with { DeepSeekWeeklyBudget = value });
            if (!sourceClosed && activePane == "deepseek" && ReferenceEquals(field, daily ? deepseekDaily : deepseekWeekly) && result != PreferencesApplyResult.Applied)
                field.Text = DeepSeekBudgetText(daily ? session.Current.DeepSeekDailyBudget : session.Current.DeepSeekWeeklyBudget);
        }
        finally { if (deepseekPendingBudget[index] == text) deepseekPendingBudget[index] = null; }
    }
    private static string DeepSeekBudgetText(double? amount) => amount?.ToString("0.##", CultureInfo.CurrentCulture) ?? "";
    private void RefreshDeepSeek()
    {
        if (deepseekEnabled == null || engine == null || deepseekSections == null) return;
        var snapshot = engine.LatestSnapshot; var settings = session.Current;
        var module = snapshot?.Modules?.FirstOrDefault(value => value.Provider == "deepseek"); string mode = settings.ProviderModes["deepseek"];
        bool enabled = module?.Enabled ?? (mode != "disabled" && snapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == "deepseek") == true);
        bool connected = !providerConnectionClosed && !engine.IsConnectionClosed;
        deepseekEnabled.IsChecked = enabled; deepseekEnabled.IsEnabled = !busy && !session.RequiresRestart && connected && snapshot != null;
        deepseekDetection!.Text = ui.Text(module?.Installed == false ? "windows.provider.not_detected" : module?.Installed == true ? "windows.provider.detected" : "provider.state.searching") + (mode == "automatic" ? " · " + ui.Text("provider.automatic") : "");
        deepseekAutomatic!.Visibility = mode == "automatic" ? Visibility.Collapsed : Visibility.Visible;
        deepseekSections.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        if (deepseekOff != null) deepseekOff.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        if (!enabled) deepseekKeyInput?.Clear();
        var wallet = connected ? snapshot?.Wallet : null; var reading = wallet?.Settings;
        deepseekClock!.Update(wallet); deepseekBalance!.Text = reading?.BalanceText ?? ""; deepseekRunway!.Text = reading?.RunwayText ?? "";
        deepseekPricing!.Update(reading?.PricingSpans);
        RefreshDeepSeekConnection(connected, wallet);
        foreach (var choice in deepseekChoices)
        {
            string[] parts = choice.Key.Split('.'); string selected = parts[0] switch { "mode" => settings.DeepSeekMode, "panel" => settings.DeepSeekPanelStyle, "speed" => settings.DeepSeekSpeedSource, _ => settings.DeepSeekRingPeriod };
            choice.Value.IsChecked = parts[1] == selected; choice.Value.IsEnabled = !busy && !session.RequiresRestart && connected && reading != null;
        }
        bool budget = settings.DeepSeekMode == "budget";
        deepseekBudgetRows!.Visibility = budget ? Visibility.Visible : Visibility.Collapsed;
        deepseekModeNote!.Text = ui.Text(budget ? "main.deepseek.budget_note" : "main.deepseek.balance_note");
        deepseekBalanceRow!.Visibility = deepseekBalance.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        deepseekRingRow!.Visibility = settings.DeepSeekDailyBudget != null && settings.DeepSeekWeeklyBudget != null ? Visibility.Visible : Visibility.Collapsed;
        var compact = ReadCompact();
        int ringSlot = compact.Components.Any(value => value.Id == "quotaGauge" && value.Shown)
            ? Array.FindIndex(compact.Rings, value => value.Provider == "deepseek") : -1;
        deepseekRingHint!.Text = ui.Text(ringSlot == 0 ? "deepseek.ring_hint.outer" : ringSlot == 1 ? "deepseek.ring_hint.inner" : "deepseek.ring_hint.none");
        deepseekRingLink!.Content = ui.Text(ringSlot < 0 ? "deepseek.ring_hint.choose" : "deepseek.ring_hint.change");
        AutomationProperties.SetName(deepseekRingLink, (string)deepseekRingLink.Content);
        deepseekRingLink.IsEnabled = !busy && !session.RequiresRestart && connected;
        if (deepseekDailyValue != settings.DeepSeekDailyBudget) { deepseekDailyValue = settings.DeepSeekDailyBudget; deepseekDaily!.Text = DeepSeekBudgetText(deepseekDailyValue); }
        if (deepseekWeeklyValue != settings.DeepSeekWeeklyBudget) { deepseekWeeklyValue = settings.DeepSeekWeeklyBudget; deepseekWeekly!.Text = DeepSeekBudgetText(deepseekWeeklyValue); }
        deepseekDailyReference!.Text = reading?.DailyReference ?? ""; deepseekWeeklyReference!.Text = reading?.WeeklyReference ?? "";
        deepseekTurnCost!.IsChecked = settings.DeepSeekShowsTurnCost;
        deepseekProgress!.IsChecked = settings.DeepSeekProgressRing;
        deepseekProgress.IsEnabled = !busy && !session.RequiresRestart && connected && snapshot != null;
        var setup = snapshot?.DeepSeekProgressSetup;
        bool setupFailed = setup is "failed" or "conflict";
        // A failed removal stays visible after the switch is off, with Retry.
        deepseekProgressStatus!.Visibility = !demo && setup != null && (settings.DeepSeekProgressRing || setupFailed) ? Visibility.Visible : Visibility.Collapsed;
        deepseekProgressState!.Text = setup == null ? "" : ui.Text((settings.DeepSeekProgressRing ? "deepseek.progress_setup." : "deepseek.progress_cleanup.") + setup);
        AutomationProperties.SetName(deepseekProgressState, deepseekProgressState.Text);
        deepseekProgressRetry!.Visibility = setupFailed ? Visibility.Visible : Visibility.Collapsed;
        deepseekProgressRetry.IsEnabled = deepseekProgress.IsEnabled;
        deepseekDaily!.IsEnabled = deepseekWeekly!.IsEnabled = deepseekTurnCost.IsEnabled = !busy && !session.RequiresRestart && connected && reading != null;
        deepseekAutomatic.IsEnabled = !busy && !session.RequiresRestart && connected && snapshot != null;
        bool found = connected && snapshot?.Sources.Any(value => (value.Id is "deepseek:local-logs" or "deepseek:demo") && value.Available) == true;
        SetStatus(deepseekLocalDot, deepseekLocalState, ui.Text(!connected ? "provider.state.failed" : found ? "provider.state.found" : "provider.state.no_home"),
            !connected ? "attention" : found ? "positive" : "neutral");
        if (providerHomeLocations != null && session.Current.DeepseekHome.Length == 0) providerHomeLocations.Tag = deepseekLocalState!.Text;
    }
}
