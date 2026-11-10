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
    private readonly Dictionary<string, CheckBox> reminderKinds = new(), reminderFollows = new();
    private StackPanel? reminderQuotaRows, reminderWalletRows;
    private FrameworkElement? reminderFooter;
    private TextBox? reminderLow, reminderSpike;
    private TextBlock? reminderAmountIssue, notificationIssue;
    private CheckBox? notificationSwitch;
    private Button? reminderRetention;
    private double? reminderLowValue, reminderSpikeValue;
    private readonly string?[] reminderPendingAmount = [null, null];

    private void ClearReminders()
    {
        reminderKinds.Clear(); reminderFollows.Clear(); reminderQuotaRows = reminderWalletRows = null; reminderFooter = null;
        reminderLow = reminderSpike = null; reminderAmountIssue = notificationIssue = null; notificationSwitch = null; reminderRetention = null;
        reminderLowValue = reminderSpikeValue = null; Array.Clear(reminderPendingAmount);
    }
    private const double NotifyColumn = 76;

    /// One event: its title (with a note or an amount), then where it reminds
    /// you: the collapsed bar and system notifications, as on the Mac.
    private Grid MatrixRow(string title, UIElement bar, UIElement system, string? note = null, FrameworkElement? field = null)
    {
        var row = new Grid { MinHeight = 44, Margin = new Thickness(14, 0, 14, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(NotifyColumn) }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(NotifyColumn) });
        var left = new WrapPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 8, 8, 8) };
        var label = Label(title); label.Margin = new Thickness(0, 0, 10, 0); left.Children.Add(label);
        if (note != null) { var detail = Detail(note); detail.FontSize = 11.5; detail.Margin = new Thickness(0, 1, 10, 0); detail.VerticalAlignment = VerticalAlignment.Center; left.Children.Add(detail); }
        if (field != null) { field.VerticalAlignment = VerticalAlignment.Center; left.Children.Add(field); }
        row.Children.Add(left);
        foreach (var (cell, column) in new[] { (bar, 1), (system, 2) })
        { if (cell is FrameworkElement element) { element.HorizontalAlignment = HorizontalAlignment.Center; element.VerticalAlignment = VerticalAlignment.Center; } Grid.SetColumn(cell, column); row.Children.Add(cell); }
        return row;
    }
    private TextBlock AlwaysCell() { var text = Label(ui.Text("main.notify.always"), 12); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); return text; }
    private TextBlock NoneCell()
    { var text = Label("—", 13); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsDisabled"); AutomationProperties.SetName(text, ui.Text("main.notify.unavailable")); return text; }
    /// A collapsed-bar warning the user chooses here; Collapsed Bar's warnings
    /// card keeps their style and limit and links back to this page.
    private CheckBox BarCell(string kind, string title)
    {
        var check = new CheckBox { Style = (Style)FindResource("SettingsCheck") };
        Identify(check, "settings.reminders." + kind, title + " · " + ui.Text("main.notify.bar")); editors.Add(check); reminderKinds[kind] = check;
        BindToggle(check, (p, value) => NativeCompactBar.Shared.EditAsync(p, ui.Language, NativeCompactBar.Providers(p, engine?.LatestSnapshot), new(value ? "warning" : "warningOff", kind)));
        return check;
    }
    /// System notifications still follow their one switch (DeepSeek's also its
    /// collapsed-bar warning), so this column only shows the result.
    private CheckBox FollowsCell(string kind, string title)
    {
        var check = new CheckBox { Style = (Style)FindResource("SettingsCheck"), IsEnabled = false, ToolTip = ui.Text("main.notify.follows") };
        ToolTipService.SetShowOnDisabled(check, true);
        Identify(check, "settings.reminders." + kind + ".system", title + " · " + ui.Text("settings.system_notifications"));
        AutomationProperties.SetHelpText(check, ui.Text("main.notify.follows")); reminderFollows[kind] = check; return check;
    }
    private Grid MatrixHeader(string title)
    {
        var header = new Grid { Margin = new Thickness(4, 0, 15, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(NotifyColumn) }); header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(NotifyColumn) });
        var name = SectionTitle(title, 0); name.Margin = new Thickness(0); header.Children.Add(name);
        foreach (var (key, column) in new[] { ("main.notify.bar", 1), ("settings.system_notifications", 2) })
        {
            var label = Label(ui.Text(key), 11.5, FontWeights.Medium); label.HorizontalAlignment = HorizontalAlignment.Center; label.TextTrimming = TextTrimming.CharacterEllipsis;
            label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); Grid.SetColumn(label, column); header.Children.Add(label);
        }
        return header;
    }
    private void BuildReminders()
    {
        paneSubtitle.Text = ui.Text("main.subtitle.notifications"); paneSubtitle.Visibility = Visibility.Visible;
        var notifications = Toggle("settings.system_notifications", null, "settings.reminders.notifications", out var check); notificationSwitch = check;
        RoutedEventHandler toggleNotifications = async (_, _) =>
        {
            if (synchronizing || this.notifications == null) return;
            var result = await this.notifications.SetEnabledAsync(check.IsChecked == true);
            if (sourceClosed) return;
            if (result == NotificationChangeResult.SaveFailed) ShowIssue("windows.settings.save_failed");
            RefreshValues();
        };
        check.Checked += toggleNotifications; check.Unchecked += toggleNotifications; editors.Add(check);
        notificationIssue = Label("", 12); notificationIssue.TextWrapping = TextWrapping.Wrap; notificationIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); Identify(notificationIssue, "settings.reminders.notifications.issue", "");
        var systemSettings = new Button { Content = ui.Text("common.open_settings") };
        Identify(systemSettings, "settings.reminders.notifications.settings", ui.Text("settings.system_notifications") + ": " + ui.Text("common.open_settings"));
        systemSettings.Click += (_, _) =>
        {
            try { openNotificationSettings(); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or System.IO.IOException)
            { ShowIssue("windows.settings.notifications_failed"); }
        };
        // When Windows blocks notifications, the reason and a way to Settings take a row of their own.
        var issueRow = Row(notificationIssue, systemSettings);
        issueRow.SetBinding(VisibilityProperty, new System.Windows.Data.Binding(nameof(Visibility)) { Source = notificationIssue });
        form.Children.Add(Card(notifications, issueRow));

        form.Children.Add(MatrixHeader(ui.Text("main.notify.group.tasks")));
        form.Children.Add(Card(MatrixRow(ui.Text("main.notify.reply"), AlwaysCell(), FollowsCell("reply", ui.Text("main.notify.reply"))),
            MatrixRow(ui.Text("main.notify.end"), AlwaysCell(), FollowsCell("end", ui.Text("main.notify.end")))));

        reminderQuotaRows = new StackPanel();
        reminderQuotaRows.Children.Add(SectionTitle(ui.Text("main.notify.group.quota")));
        reminderQuotaRows.Children.Add(Card(MatrixRow(ui.Text("warning.fiveHour"), BarCell("fiveHour", ui.Text("warning.fiveHour")), FollowsCell("fiveHour", ui.Text("warning.fiveHour")), ui.Text("main.notify.low_quota_note")),
            MatrixRow(ui.Text("warning.quotaDelay"), BarCell("quotaDelay", ui.Text("warning.quotaDelay")), NoneCell())));
        reminderQuotaRows.Children.Add(SectionTitle(ui.Text("main.pane.remote")));
        reminderQuotaRows.Children.Add(Card(MatrixRow(ui.Text("warning.ssh"), BarCell("ssh", ui.Text("warning.ssh")), NoneCell())));
        form.Children.Add(reminderQuotaRows);

        reminderWalletRows = new StackPanel();
        reminderWalletRows.Children.Add(SectionTitle("DeepSeek"));
        var budget = new Button { Content = ui.Text("main.notify.budget_link"), Style = (Style)FindResource("SettingsLink"), FontSize = 12.5 };
        Identify(budget, "settings.reminders.budget_link", ui.Text("main.notify.budget_link")); budget.Click += async (_, _) => await NavigateAsync("deepseek");
        reminderAmountIssue = Detail(""); reminderAmountIssue.Visibility = Visibility.Collapsed; reminderAmountIssue.Margin = new Thickness(14, 0, 14, 10);
        reminderAmountIssue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); Identify(reminderAmountIssue, "settings.reminders.amount.issue", "");
        var wallet = new StackPanel();
        wallet.Children.Add(MatrixRow(ui.Text("main.notify.low_balance"), BarCell("lowBalance", ui.Text("main.notify.low_balance")), FollowsCell("lowBalance", ui.Text("main.notify.low_balance")), field: ReminderAmount(true)));
        wallet.Children.Add(Hairline(14));
        wallet.Children.Add(MatrixRow(ui.Text("main.notify.spike"), BarCell("spendSpike", ui.Text("main.notify.spike")), FollowsCell("spendSpike", ui.Text("main.notify.spike")), field: ReminderAmount(false)));
        wallet.Children.Add(Hairline(14));
        wallet.Children.Add(MatrixRow(ui.Text("main.notify.budget"), BarCell("budget", ui.Text("main.notify.budget")), FollowsCell("budget", ui.Text("main.notify.budget")), field: budget));
        wallet.Children.Add(reminderAmountIssue);
        reminderWalletRows.Children.Add(Card(wallet));
        var footer = CardFooter(ui.Text("main.notify.deepseek_one")); reminderFooter = footer; reminderWalletRows.Children.Add(footer);
        form.Children.Add(reminderWalletRows);

        // How long ended tasks stay is the task list's choice now; this row leads there, as on the Mac.
        reminderRetention = LinkRow(ui.Text("main.notifications.retention_moved"), ui.Text("main.panel.open"), "settings.reminders.retention",
            async () => { if (activePane == "notifications") await NavigateToPanelBlockAsync("tasks"); });
        form.Children.Add(Card(reminderRetention));
    }
    private FrameworkElement ReminderAmount(bool low)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var currency = Label("¥"); currency.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); currency.Margin = new Thickness(0, 0, 3, 0); row.Children.Add(currency);
        var field = new TextBox { Width = 76, MaxLength = 320, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Style = (Style)FindResource("SettingsPathInput"), FontSize = 12 };
        Identify(field, "settings.reminders." + (low ? "lowLine" : "spikeLine"), ui.Text(low ? "reminders.low_balance" : "reminders.spike"));
        field.KeyDown += async (_, e) => { if (e.Key == Key.Enter && !composing) { e.Handled = true; await CommitReminderAmount(low, field); } };
        field.LostKeyboardFocus += async (_, _) => { if (!composing) await CommitReminderAmount(low, field); };
        if (low) reminderLow = field; else reminderSpike = field;
        editors.Add(field); row.Children.Add(field); return row;
    }
    private async Task CommitReminderAmount(bool low, TextBox field)
    {
        if (synchronizing || sourceClosed || activePane != "notifications") return;
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
            if (!sourceClosed && activePane == "notifications" && ReferenceEquals(field, low ? reminderLow : reminderSpike) && result != PreferencesApplyResult.Applied)
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
        foreach (var pair in reminderKinds) { pair.Value.IsChecked = warnings?.Shown == true && preferences.WarningKinds.Contains(pair.Key); pair.Value.IsEnabled = enabled && connected && warnings != null; }
        reminderQuotaRows!.Visibility = Module("codex") || Module("claude") ? Visibility.Visible : Visibility.Collapsed;
        reminderWalletRows!.Visibility = Module("deepseek") ? Visibility.Visible : Visibility.Collapsed;
        bool system = notifications?.DesiredEnabled ?? preferences.SystemNotifications;
        foreach (var pair in reminderFollows)
            pair.Value.IsChecked = system && (pair.Key is not ("lowBalance" or "spendSpike" or "budget") || reminderKinds.TryGetValue(pair.Key, out var bar) && bar.IsChecked == true);
        if (reminderLowValue != preferences.DeepSeekLowBalanceLine) { reminderLowValue = preferences.DeepSeekLowBalanceLine; reminderLow!.Text = DeepSeekBudgetText(reminderLowValue); }
        if (reminderSpikeValue != preferences.DeepSeekSpikeLimit) { reminderSpikeValue = preferences.DeepSeekSpikeLimit; reminderSpike!.Text = DeepSeekBudgetText(reminderSpikeValue); }
        reminderLow!.Tag = snapshot?.Wallet?.Reminders?.LowPlaceholder ?? ""; reminderSpike!.Tag = snapshot?.Wallet?.Reminders?.SpikePlaceholder ?? "";
        reminderLow.IsEnabled = reminderSpike.IsEnabled = enabled && connected && snapshot?.Wallet != null;
        notificationSwitch!.IsChecked = notifications?.DesiredEnabled ?? preferences.SystemNotifications;
        notificationSwitch.IsEnabled = enabled && notifications != null;
        string? issueKey = notifications?.Availability switch { NotificationAvailability.Denied => "windows.settings.notification_denied", NotificationAvailability.Unsupported => "windows.settings.notifications_unsupported", NotificationAvailability.Failed => "windows.settings.notifications_failed", _ => null };
        notificationIssue!.Visibility = issueKey == null ? Visibility.Collapsed : Visibility.Visible;
        notificationIssue.Text = issueKey == null ? "" : ui.Text(issueKey); AutomationProperties.SetName(notificationIssue, notificationIssue.Text);
        reminderRetention.IsEnabled = enabled;
    }
}
