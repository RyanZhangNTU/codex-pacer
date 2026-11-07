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
    private FrameworkElement? deepseekPanelSection, deepseekBalanceHelp, deepseekRingRow;
    private Border? deepseekBudgetSeparator, deepseekBalanceSeparator;
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
        deepseekSections = deepseekBudgetRows = null; deepseekPanelSection = deepseekBalanceHelp = deepseekRingRow = null;
        deepseekDaily = deepseekWeekly = null; deepseekBudgetSeparator = deepseekBalanceSeparator = null; deepseekClock = null; deepseekPricing = null;
        deepseekDailyValue = deepseekWeeklyValue = null; deepseekChoices.Clear(); Array.Clear(deepseekPendingBudget);
        deepseekAccountHelp = deepseekConnectionDot = null;
    }
    private void BuildDeepSeek()
    {
        var tile = new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(9.88), Background = new SolidColorBrush(Color.FromRgb(126, 150, 255)), Margin = new Thickness(0, 0, 12, 0),
            Child = new IconGlyph { Symbol = "water.waves", Width = 25, Height = 25, Ink = new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)) } };
        var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; name.Children.Add(Label("DeepSeek", 14, FontWeights.SemiBold)); deepseekDetection = Detail(""); name.Children.Add(deepseekDetection);
        var identity = new StackPanel { Orientation = Orientation.Horizontal }; identity.Children.Add(tile); identity.Children.Add(name);
        var summary = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        deepseekClock = new DeepSeekPriceClock { Width = 24, Height = 24 };
        summary.Children.Add(new Border { Child = deepseekClock, Padding = new Thickness(4), Background = Brushes.Black, CornerRadius = new CornerRadius(7), Margin = new Thickness(0, 0, 8, 0) });
        var readings = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; deepseekBalance = Label("", 14, FontWeights.SemiBold); deepseekRunway = Detail(""); readings.Children.Add(deepseekBalance); readings.Children.Add(deepseekRunway); summary.Children.Add(readings);
        deepseekEnabled = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), Margin = new Thickness(12, 0, 0, 0) }; Identify(deepseekEnabled, "settings.deepseek.enabled", "DeepSeek"); editors.Add(deepseekEnabled); summary.Children.Add(deepseekEnabled);
        BindToggle(deepseekEnabled, (p, value) => p with { ProviderModes = new(p.ProviderModes) { ["deepseek"] = value ? "enabled" : "disabled" } });
        form.Children.Add(Card(Row(identity, summary, 62)));
        deepseekAutomatic = new Button { Content = ui.Text("provider.restore_automatic"), Style = (Style)FindResource("SettingsLink"), HorizontalAlignment = HorizontalAlignment.Right, FontSize = 11, Margin = new Thickness(0, 0, 10, 16) };
        Identify(deepseekAutomatic, "settings.deepseek.automatic", ui.Text("provider.restore_automatic")); editors.Add(deepseekAutomatic);
        deepseekAutomatic.Click += async (_, _) => await Change(p => p with { ProviderModes = new(p.ProviderModes) { ["deepseek"] = "automatic" } }); form.Children.Add(deepseekAutomatic);
        deepseekSections = new StackPanel(); form.Children.Add(deepseekSections);
        deepseekSections.Children.Add(SectionHeader("deepseek.section.balance", 10));
        deepseekSections.Children.Add(BuildDeepSeekConnection());
        deepseekSections.Children.Add(SectionHeader("deepseek.section.mode", 22));
        var mode = DeepSeekSegments("mode", new[] { ("balance", "deepseek.mode.balance"), ("budget", "deepseek.mode.budget") }, async value =>
        {
            await sourceReady;
            var suggestion = engine?.LatestSnapshot?.Wallet?.Settings;
            if (value == "budget" && suggestion == null) { ShowIssue("windows.settings.apply_failed"); RefreshValues(); return; }
            await Change(p => p with { DeepSeekMode = value,
                DeepSeekDailyBudget = value == "budget" && p.DeepSeekDailyBudget == null && p.DeepSeekWeeklyBudget == null ? suggestion!.SuggestedDaily : p.DeepSeekDailyBudget,
                DeepSeekWeeklyBudget = value == "budget" && p.DeepSeekDailyBudget == null && p.DeepSeekWeeklyBudget == null ? suggestion!.SuggestedWeekly : p.DeepSeekWeeklyBudget });
        });
        deepseekBudgetRows = new StackPanel(); deepseekRingHint = Detail(""); deepseekRingHint.Margin = new Thickness(10, 7, 4, 4);
        Identify(deepseekRingHint, "settings.deepseek.ring_hint", "");
        deepseekRingLink = new Button { Style = (Style)FindResource("SettingsLink"), FontSize = 11, Margin = new Thickness(0, 7, 10, 4) };
        Identify(deepseekRingLink, "settings.deepseek.ring_link", ""); deepseekRingLink.Click += async (_, _) => await NavigateToQuotaGaugeAsync();
        var ringHint = new StackPanel { Orientation = Orientation.Horizontal }; ringHint.Children.Add(deepseekRingHint); ringHint.Children.Add(deepseekRingLink); deepseekBudgetRows.Children.Add(ringHint);
        deepseekBudgetRows.Children.Add(DeepSeekBudgetField(true)); deepseekBudgetRows.Children.Add(DeepSeekBudgetField(false));
        deepseekRingRow = Row(Label(ui.Text("deepseek.budget.ring")), DeepSeekSegments("ring", new[] { ("day", "deepseek.budget.day"), ("week", "deepseek.budget.week") }, value => ChangeDeepSeek(p => p with { DeepSeekRingPeriod = value })), 36);
        deepseekBudgetRows.Children.Add(deepseekRingRow);
        deepseekBudgetRows.Children.Add(DeepSeekCaption(ui.Text("windows.deepseek.budget_help")));
        var reminders = new Button { Content = ui.Text("settings.reminders"), Style = (Style)FindResource("SettingsLink"), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(10, 0, 10, 8) };
        Identify(reminders, "settings.deepseek.reminders", ui.Text("settings.reminders")); reminders.Click += async (_, _) => await NavigateAsync("notifications"); deepseekBudgetRows.Children.Add(reminders);
        deepseekBudgetIssue = Detail(""); deepseekBudgetIssue.Margin = new Thickness(10, 0, 10, 8); deepseekBudgetIssue.Visibility = Visibility.Collapsed; Identify(deepseekBudgetIssue, "settings.deepseek.budget.issue", ""); deepseekBudgetRows.Children.Add(deepseekBudgetIssue);
        deepseekBudgetIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        deepseekBalanceHelp = DeepSeekCaption(ui.Text("deepseek.mode.balance_help"));
        var modeCard = Card(Row(Label(ui.Text("deepseek.mode")), mode, 40), deepseekBudgetRows, deepseekBalanceHelp);
        deepseekBudgetSeparator = (Border)((Panel)modeCard.Child).Children[1]; deepseekBalanceSeparator = (Border)((Panel)modeCard.Child).Children[3]; deepseekSections.Children.Add(modeCard);
        var panel = new StackPanel(); panel.Children.Add(SectionHeader("deepseek.section.panel", 22));
        panel.Children.Add(Card(Row(Label(ui.Text("deepseek.panel_style")), DeepSeekSegments("panel", new[] { ("simple", "deepseek.panel_style.simple"), ("detailed", "deepseek.panel_style.detailed") }, value => ChangeDeepSeek(p => p with { DeepSeekPanelStyle = value })), 40), DeepSeekCaption(ui.Text("deepseek.panel_style_help"))));
        deepseekPanelSection = panel; deepseekSections.Children.Add(panel);
        deepseekSections.Children.Add(SectionHeader("deepseek.speed", 22));
        deepseekSections.Children.Add(Card(Row(Label(ui.Text("deepseek.speed_basis")), DeepSeekSegments("speed", new[] { ("local", "windows.deepseek.speed_source.local"), ("account", "deepseek.speed_source.account") }, value => ChangeDeepSeek(p => p with { DeepSeekSpeedSource = value })), 40), DeepSeekCaption(ui.Text("windows.deepseek.speed_basis_help"))));
        deepseekSections.Children.Add(SectionHeader("deepseek.section.display", 22));
        var costs = Toggle("deepseek.turn_cost", "deepseek.turn_cost_help", "settings.deepseek.turn_cost", out var cost);
        deepseekTurnCost = cost; editors.Add(cost); BindToggle(cost, (p, value) => p with { DeepSeekShowsTurnCost = value });
        var progress = Toggle("deepseek.progress_ring", "deepseek.progress_ring_help", "settings.deepseek.progress_ring", out var progressSwitch);
        deepseekProgress = progressSwitch; editors.Add(progressSwitch); BindToggle(progressSwitch, (p, value) => p with { DeepSeekProgressRing = value });
        deepseekProgressState = Detail(""); deepseekProgressState.TextWrapping = TextWrapping.Wrap;
        Identify(deepseekProgressState, "settings.deepseek.progress_state", "");
        deepseekProgressRetry = new Button { Content = ui.Text("connections.retry"), Style = (Style)FindResource("SettingsLink") };
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
        deepseekProgressStatus = Row(deepseekProgressState, deepseekProgressRetry, 36);
        deepseekSections.Children.Add(Card(costs, progress, deepseekProgressStatus));
        deepseekSections.Children.Add(SectionHeader("deepseek.section.pricing", 22));
        var pricing = new Button { Content = ui.Text("deepseek.price_list"), Style = (Style)FindResource("SettingsLink"), HorizontalAlignment = HorizontalAlignment.Left, FontSize = 12, Margin = new Thickness(10, 5, 10, 8) };
        Identify(pricing, "settings.deepseek.pricing", ui.Text("deepseek.price_list"));
        pricing.Click += (_, _) =>
        {
            if (!SettingsPagePolicy.OpenPricing(ui.Language, guideLinkLauncher)) ShowIssue("windows.pages.open_failed");
        };
        deepseekPricing = new DeepSeekPricingTimeline(ui);
        var pricingContent = new StackPanel(); pricingContent.Children.Add(deepseekPricing); pricingContent.Children.Add(DeepSeekCaption(ui.Text("windows.deepseek.pricing_note"))); pricingContent.Children.Add(pricing);
        deepseekSections.Children.Add(Card(pricingContent));
        deepseekSections.Children.Add(SectionHeader("windows.provider.local", 22)); deepseekLocalState = Detail("");
        Identify(deepseekLocalState, "settings.deepseek.local_state", "");
        deepseekSections.Children.Add(Card(Row(Label(ui.Text("windows.deepseek.sessions")), deepseekLocalState, 36), ProviderHomeEditor("deepseek")));
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
        var border = new Border { Child = row, Padding = new Thickness(2), CornerRadius = new CornerRadius(7), VerticalAlignment = VerticalAlignment.Center }; border.SetResourceReference(Border.BackgroundProperty, "SettingsButton"); return border;
    }
    private Grid DeepSeekBudgetField(bool daily)
    {
        string key = daily ? "deepseek.budget.daily" : "deepseek.budget.weekly";
        var field = new TextBox { Width = 64, MaxLength = 320, TextAlignment = TextAlignment.Right, Tag = ui.Text("deepseek.budget.off"), VerticalAlignment = VerticalAlignment.Center };
        Identify(field, "settings.deepseek.budget." + (daily ? "daily" : "weekly"), ui.Text(key)); editors.Add(field);
        field.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitDeepSeekBudget(daily, field); } };
        field.LostKeyboardFocus += async (_, _) => { if (!composing) await CommitDeepSeekBudget(daily, field); };
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var reference = Detail(""); reference.Margin = new Thickness(0, 0, 10, 0); reference.VerticalAlignment = VerticalAlignment.Center; content.Children.Add(reference);
        var currency = Label("¥"); currency.Margin = new Thickness(0, 0, 4, 0); currency.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); content.Children.Add(currency); content.Children.Add(field);
        if (daily) { deepseekDaily = field; deepseekDailyReference = reference; } else { deepseekWeekly = field; deepseekWeeklyReference = reference; }
        return Row(Label(ui.Text(key)), content, 36);
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
        deepseekBudgetRows!.Visibility = deepseekBudgetSeparator!.Visibility = budget ? Visibility.Visible : Visibility.Collapsed;
        deepseekBalanceHelp!.Visibility = deepseekBalanceSeparator!.Visibility = budget ? Visibility.Collapsed : Visibility.Visible;
        deepseekPanelSection!.Visibility = snapshot?.QuotaDashboard?.Providers.Count == 1 ? Visibility.Visible : Visibility.Collapsed;
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
        deepseekLocalState!.Text = ui.Text(!connected ? "provider.state.failed" : snapshot?.Sources.Any(value =>
            (value.Id is "deepseek:local-logs" or "deepseek:demo") && value.Available) == true ? "provider.state.found" : "provider.state.no_home");
    }
}
