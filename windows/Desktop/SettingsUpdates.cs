using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private readonly WindowsUpdateService? updater;
    private CheckBox? automaticUpdates;
    private Button? updateCheck;
    private TextBlock? updateStatus;
    private bool changingUpdates;
    private void OnUpdateStatus(WindowsUpdateStatus value) => RefreshUpdates();
    private void RefreshUpdates()
    {
        bool syncing = synchronizing; synchronizing = true;
        try
        {
            var status = updater?.Status ?? new WindowsUpdateStatus(false, false, demo ? "updates.demo_disabled" : "windows.updates.unconfigured");
            if (demo && status.MessageKey == "windows.updates.unconfigured") status = status with { MessageKey = "updates.demo_disabled" };
            bool available = status.Available && !status.Busy && !busy && !changingUpdates && !session.RequiresRestart;
            if (automaticUpdates != null) { automaticUpdates.IsChecked = session.Current.AutomaticUpdates; automaticUpdates.IsEnabled = available; automaticUpdates.ToolTip = ui.Text(status.MessageKey); }
            if (updateCheck != null) updateCheck.IsEnabled = available;
            if (updateStatus != null) { updateStatus.Text = ui.Text(status.MessageKey); AutomationProperties.SetName(updateStatus, updateStatus.Text); }
        }
        finally { synchronizing = syncing; }
    }
    private async void ChangeAutomaticUpdates(object sender, RoutedEventArgs args)
    {
        if (synchronizing || changingUpdates || updater == null || automaticUpdates == null) return;
        bool value = automaticUpdates.IsChecked == true;
        changingUpdates = true; RefreshUpdates();
        try { if (!await updater.ApplyAutomaticAsync(value, session) && !sourceClosed) ShowIssue("windows.updates.failed"); }
        finally { changingUpdates = false; if (!sourceClosed) RefreshUpdates(); }
    }
}
