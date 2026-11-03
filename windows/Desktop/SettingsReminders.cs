using System;
using System.Collections.Generic;
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
    private readonly Dictionary<string, CheckBox> reminderKinds = new();
    private StackPanel? reminderQuotaRows, reminderWalletRows;
    private FrameworkElement? reminderFooter;
    private Border? reminderGroupSeparator;
    private TextBox? reminderLow, reminderSpike;
    private TextBlock? reminderAmountIssue, notificationIssue;
    private CheckBox? notificationSwitch;
    private ComboBox? reminderRetention;
    private double? reminderLowValue, reminderSpikeValue;
    private readonly string?[] reminderPendingAmount = [null, null];

    private void ClearReminders()
    {
        reminderKinds.Clear(); reminderQuotaRows = reminderWalletRows = null; reminderFooter = null; reminderGroupSeparator = null;
        reminderLow = reminderSpike = null; reminderAmountIssue = notificationIssue = null; notificationSwitch = null; reminderRetention = null;
        reminderLowValue = reminderSpikeValue = null; Array.Clear(reminderPendingAmount);
    }
    private static Border ReminderSample(params UIElement[] marks)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (int index = 0; index < marks.Length; index++) { if (index > 0 && marks[index] is FrameworkElement child) child.Margin = new Thickness(3, 0, 0, 0); content.Children.Add(marks[index]); }
        var sample = new Border { Width = 44, Height = 28, Background = Brushes.Black, CornerRadius = new CornerRadius(8), Child = content, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        return sample;
    }
    private static WarningMark ReminderMark(string kind, string provider, bool solid, string? label = null, string? symbol = null)
        => new(new(kind, provider, solid, label, symbol, ""));
    private Grid ReminderRow(string kind, string title, string? detail, Border sample, FrameworkElement? amount = null)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var heading = new StackPanel { Orientation = Orientation.Horizontal }; heading.Children.Add(Label(title));
        if (amount != null) { amount.Margin = new Thickness(6, 0, 0, 0); heading.Children.Add(amount); }
        text.Children.Add(heading); if (detail != null) { var caption = Detail(detail); caption.MaxWidth = 352; caption.HorizontalAlignment = HorizontalAlignment.Left; text.Children.Add(caption); }
        var identity = new DockPanel { LastChildFill = true }; DockPanel.SetDock(sample, Dock.Left); identity.Children.Add(sample); identity.Children.Add(text);
        var check = new CheckBox { Style = (Style)FindResource("SettingsSwitch") };
        Identify(check, "settings.reminders." + kind, ui.Text("warning." + kind)); editors.Add(check); reminderKinds[kind] = check;
        if (detail != null) AutomationProperties.SetHelpText(check, detail);
        BindToggle(check, (p, value) => NativeCompactBar.Shared.EditAsync(p, ui.Language, NativeCompactBar.Providers(p, engine?.LatestSnapshot), new(value ? "warning" : "warningOff", kind)));
        // Native Reminders uses taller amount rows; captions can grow further
        // with localization without overlapping the trailing switch.
        return Row(identity, check, amount != null ? 74 : detail != null ? 52 : 48);
    }
    private void AddReminderRow(StackPanel group, UIElement row)
    {
        if (group.Children.Count > 0)
        {
            var line = new Border { Height = 1, Margin = new Thickness(10, 0, 10, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); group.Children.Add(line);
        }
        group.Children.Add(row);
    }
    private void BuildReminders()
    {
        form.Children.Add(SectionHeader("reminders.section.warnings"));
        reminderQuotaRows = new StackPanel(); reminderWalletRows = new StackPanel();
        AddReminderRow(reminderQuotaRows, ReminderRow("fiveHour", ui.Text("warning.fiveHour"), null, ReminderSample(ReminderMark("fiveHour", "codex", false, "5h"))));
        AddReminderRow(reminderQuotaRows, ReminderRow("ssh", ui.Text("warning.ssh"), null, ReminderSample(new IconGlyph { Symbol = "network.slash", Width = 11, Height = 11, Ink = PacerPalette.Attention })));
        reminderKinds["ssh"].ToolTip = ui.Text("windows.reminders.ssh_pending"); ToolTipService.SetShowOnDisabled(reminderKinds["ssh"], true);
        AddReminderRow(reminderQuotaRows, ReminderRow("quotaDelay", ui.Text("warning.quotaDelay"), null, ReminderSample(new IconGlyph { Symbol = "clock.arrow.circlepath", Width = 11, Height = 11, Ink = PacerPalette.Attention })));
        AddReminderRow(reminderWalletRows, ReminderRow("lowBalance", ui.Text("reminders.low_balance"), ui.Text("reminders.low_balance_detail"),
            ReminderSample(ReminderMark("lowBalance", "deepseek", false, "¥"), ReminderMark("exhausted", "deepseek", true, "¥")), ReminderAmount(true)));
        AddReminderRow(reminderWalletRows, ReminderRow("spendSpike", ui.Text("reminders.spike"), ui.Text("reminders.spike_detail"),
            ReminderSample(ReminderMark("spike", "deepseek", true, symbol: "flame.fill")), ReminderAmount(false)));
        AddReminderRow(reminderWalletRows, ReminderRow("budget", ui.Text("reminders.budget"), ui.Text("reminders.budget_detail"),
            ReminderSample(ReminderMark("nearingBudget", "deepseek", false, ui.Text("deepseek.alert.day")), ReminderMark("overBudget", "deepseek", true, ui.Text("deepseek.alert.week")))));
        var warnings = new StackPanel(); warnings.Children.Add(reminderQuotaRows);
        var groupSeparator = new Border { Height = 1, Margin = new Thickness(10, 0, 10, 0) }; groupSeparator.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); warnings.Children.Add(groupSeparator); warnings.Children.Add(reminderWalletRows);
        reminderGroupSeparator = groupSeparator; form.Children.Add(Card(warnings));
        var footer = new WrapPanel { Margin = new Thickness(10, 0, 10, 24) }; var footerText = Detail(ui.Text("reminders.one_at_a_time")); footerText.Margin = new Thickness(0, 0, 4, 0); footer.Children.Add(footerText);
        var budget = new Button { Content = ui.Text("reminders.budget_link"), Style = (Style)FindResource("SettingsLink"), FontSize = 11 };
        Identify(budget, "settings.reminders.budget_link", ui.Text("reminders.budget_link")); budget.Click += async (_, _) => await NavigateAsync("deepseek"); footer.Children.Add(budget); reminderFooter = footer; form.Children.Add(footer);
        reminderAmountIssue = Detail(""); reminderAmountIssue.Visibility = Visibility.Collapsed; reminderAmountIssue.Margin = new Thickness(10, 0, 10, 8); reminderAmountIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); Identify(reminderAmountIssue, "settings.reminders.amount.issue", ""); form.Children.Add(reminderAmountIssue);
        var notifications = Toggle("settings.system_notifications", "settings.system_notifications_detail", "settings.reminders.notifications", out var check); notificationSwitch = check;
        notifications.MinHeight = 66;
        var notificationIdentity = (FrameworkElement)notifications.Children[0]; notifications.Children.Remove(notificationIdentity);
        var withSample = new DockPanel(); var sample = ReminderSample(new IconGlyph { Symbol = "bell.badge", Width = 12, Height = 12, Ink = PacerPalette.Ink(255, 255, 255, 217) });
        DockPanel.SetDock(sample, Dock.Left); withSample.Children.Add(sample); withSample.Children.Add(notificationIdentity); notifications.Children.Insert(0, withSample);
        RoutedEventHandler toggleNotifications = async (_, _) =>
        {
            if (synchronizing || this.notifications == null) return;
            var result = await this.notifications.SetEnabledAsync(check.IsChecked == true);
            if (sourceClosed) return;
            if (result == NotificationChangeResult.SaveFailed) ShowIssue("windows.settings.save_failed");
            RefreshValues();
        };
        check.Checked += toggleNotifications; check.Unchecked += toggleNotifications; editors.Add(check);
        notificationIssue = Detail(""); notificationIssue.Margin = new Thickness(66, 0, 10, 10); notificationIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); Identify(notificationIssue, "settings.reminders.notifications.issue", "");
        var notificationRows = new StackPanel(); notificationRows.Children.Add(notifications); notificationRows.Children.Add(notificationIssue);
        var systemSettings = new Button { Content = ui.Text("common.open_settings"), Style = (Style)FindResource("SettingsLink"),
            HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(66, 0, 10, 10) };
        Identify(systemSettings, "settings.reminders.notifications.settings", ui.Text("settings.system_notifications") + ": " + ui.Text("common.open_settings"));
        systemSettings.Click += (_, _) =>
        {
            try { openNotificationSettings(); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or System.IO.IOException)
            { ShowIssue("windows.settings.notifications_failed"); }
        };
        notificationRows.Children.Add(systemSettings); form.Children.Add(Card(notificationRows));
        reminderRetention = new ComboBox { MinWidth = 140, VerticalAlignment = VerticalAlignment.Center, SelectedValuePath = "Tag" };
        foreach (var item in new[] { (5, "settings.five_minutes"), (15, "settings.fifteen_minutes"), (30, "settings.thirty_minutes"), (60, "settings.one_hour"), (240, "settings.four_hours"), (0, "settings.until_clicked") })
            reminderRetention.Items.Add(new ComboBoxItem { Tag = item.Item1, Content = ui.Text(item.Item2) });
        Identify(reminderRetention, "settings.reminders.retention", ui.Text("reminders.retention")); editors.Add(reminderRetention);
        reminderRetention.SelectionChanged += async (_, _) => { if (!synchronizing && reminderRetention.SelectedValue is int minutes) await Change(p => p with { RetentionMinutes = minutes }); };
        form.Children.Add(Card(Row(Label(ui.Text("reminders.retention")), reminderRetention, 40)));
    }
    private FrameworkElement ReminderAmount(bool low)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var currency = Label("¥"); currency.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); currency.Margin = new Thickness(0, 0, 3, 0); row.Children.Add(currency);
        var field = new TextBox { Width = 64, MaxLength = 320, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Style = (Style)FindResource("SettingsPathInput") };
        Identify(field, "settings.reminders." + (low ? "lowLine" : "spikeLine"), ui.Text(low ? "reminders.low_balance" : "reminders.spike"));
        field.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitReminderAmount(low, field); } };
        field.LostKeyboardFocus += async (_, _) => { if (!composing) await CommitReminderAmount(low, field); };
        if (low) reminderLow = field; else reminderSpike = field;
        editors.Add(field); row.Children.Add(field); return row;
    }
    private async Task CommitReminderAmount(bool low, TextBox field)
    {
        if (synchronizing || sourceClosed || activePane != "reminders") return;
        string text = field.Text.Trim(); int index = low ? 0 : 1;
        if (reminderPendingAmount[index] == text) return;
        double? value = null;
        if (text.Length > 0)
        {
            if (!double.TryParse(text, NumberStyles.Float | NumberStyles.AllowThousands, CultureInfo.CurrentCulture, out double amount) || !double.IsFinite(amount))
            {
                reminderAmountIssue!.Text = ui.Text("windows.reminders.invalid_amount"); reminderAmountIssue.Visibility = Visibility.Visible;
                AutomationProperties.SetName(reminderAmountIssue, reminderAmountIssue.Text); AutomationProperties.SetLiveSetting(reminderAmountIssue, AutomationLiveSetting.Assertive); return;
            }
            if (amount > 0) value = amount;
        }
        reminderAmountIssue!.Visibility = Visibility.Collapsed;
        if (value == (low ? session.Current.DeepSeekLowBalanceLine : session.Current.DeepSeekSpikeLimit)) { field.Text = DeepSeekBudgetText(value); return; }
        reminderPendingAmount[index] = text;
        try
        {
            var result = await Change(p => low ? p with { DeepSeekLowBalanceLine = value } : p with { DeepSeekSpikeLimit = value });
            if (!sourceClosed && activePane == "reminders" && ReferenceEquals(field, low ? reminderLow : reminderSpike) && result != PreferencesApplyResult.Applied)
                field.Text = DeepSeekBudgetText(low ? session.Current.DeepSeekLowBalanceLine : session.Current.DeepSeekSpikeLimit);
        }
        finally { if (reminderPendingAmount[index] == text) reminderPendingAmount[index] = null; }
    }
    private void OnNotificationsChanged() { if (!sourceClosed) RefreshValues(); }
    private void RefreshReminders()
    {
        if (reminderRetention == null) return;
        var preferences = session.Current; var snapshot = engine?.LatestSnapshot;
        bool connected = engine != null && !engine.IsConnectionClosed && !providerConnectionClosed && snapshot != null;
        bool enabled = !busy && !session.RequiresRestart;
        bool Module(string provider) => snapshot?.Modules?.FirstOrDefault(value => value.Provider == provider)?.Enabled
            ?? snapshot?.QuotaDashboard?.Providers.Any(value => value.Provider == provider) ?? preferences.ProviderModes[provider] != "disabled";
        var warnings = NativeCompactBar.Shared.Read(preferences, ui.Language, NativeCompactBar.Providers(preferences, snapshot)).Components.FirstOrDefault(value => value.Id == "warnings");
        foreach (var pair in reminderKinds) { pair.Value.IsChecked = warnings?.Shown == true && preferences.WarningKinds.Contains(pair.Key); pair.Value.IsEnabled = enabled && connected && warnings != null && pair.Key != "ssh"; }
        reminderQuotaRows!.Visibility = Module("codex") || Module("claude") ? Visibility.Visible : Visibility.Collapsed;
        reminderWalletRows!.Visibility = reminderFooter!.Visibility = Module("deepseek") ? Visibility.Visible : Visibility.Collapsed;
        reminderGroupSeparator!.Visibility = reminderQuotaRows.Visibility == Visibility.Visible && reminderWalletRows.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        if (reminderLowValue != preferences.DeepSeekLowBalanceLine) { reminderLowValue = preferences.DeepSeekLowBalanceLine; reminderLow!.Text = DeepSeekBudgetText(reminderLowValue); }
        if (reminderSpikeValue != preferences.DeepSeekSpikeLimit) { reminderSpikeValue = preferences.DeepSeekSpikeLimit; reminderSpike!.Text = DeepSeekBudgetText(reminderSpikeValue); }
        reminderLow!.Tag = snapshot?.Wallet?.Reminders?.LowPlaceholder ?? ""; reminderSpike!.Tag = snapshot?.Wallet?.Reminders?.SpikePlaceholder ?? "";
        reminderLow.IsEnabled = reminderSpike.IsEnabled = enabled && connected && snapshot?.Wallet != null;
        notificationSwitch!.IsChecked = notifications?.DesiredEnabled ?? preferences.SystemNotifications;
        notificationSwitch.IsEnabled = enabled && notifications != null;
        string? issueKey = notifications?.Availability switch { NotificationAvailability.Denied => "windows.settings.notification_denied", NotificationAvailability.Unsupported => "windows.settings.notifications_unsupported", NotificationAvailability.Failed => "windows.settings.notifications_failed", _ => null };
        notificationIssue!.Visibility = issueKey == null ? Visibility.Collapsed : Visibility.Visible;
        notificationIssue.Text = issueKey == null ? "" : ui.Text(issueKey); AutomationProperties.SetName(notificationIssue, notificationIssue.Text);
        reminderRetention.SelectedValue = preferences.RetentionMinutes; reminderRetention.IsEnabled = enabled && connected;
    }
}
