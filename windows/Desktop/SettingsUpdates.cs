using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private readonly WindowsUpdateService? updater;
    private CheckBox? automaticUpdates;
    private Button? updateCheck, updateNotesButton, updateInstall, updateDownloadPage;
    private TextBlock? updateStatus;
    private bool changingUpdates, readingUpdateNotes;
    internal event System.Action<string>? SignedReleaseNotesRequested;
    private void OnUpdateStatus(WindowsUpdateStatus value) { RefreshUpdates(); RefreshSidebar(); RefreshOverview(); RefreshBanner(); }
    // Checks, progress, cancel and failures started here show in the card, as on the Mac.
    private string? inlineUpdateText; private bool inlineUpdateFailed;
    private System.Threading.CancellationTokenSource? inlineDownload;
    private double? inlineFraction;
    private ProgressBar? updateProgress;
    private Button? updateCancel;
    /// Whether Help & Updates is showing, so a check started here reports here instead of in a window.
    internal bool ShowsUpdatesInline => IsVisible && !sourceClosed && activePane == "about" && updateStatus != null;
    internal void InlineUpdate(string phase)
    {
        inlineUpdateFailed = phase == "failed";
        inlineUpdateText = phase switch
        {
            "checking" => ui.Text("updates.checking"),
            "upToDate" => ui.Text("main.update.up_to_date"),
            "failed" => ui.Text("windows.updates.failed"),
            _ => null
        };
        RefreshUpdates(); RefreshSidebar(); RefreshOverview();
    }
    /// Update and Restart: download with real progress, verify, then hand off to the installer, which restarts Pacer.
    internal async System.Threading.Tasks.Task InstallInlineAsync()
    {
        if (updater?.CurrentOffer is not { } package || inlineDownload != null || sourceClosed) return;
        inlineDownload = new System.Threading.CancellationTokenSource(); inlineFraction = 0; inlineUpdateText = null; inlineUpdateFailed = false; RefreshUpdates();
        try
        {
            RefreshOverview(); RefreshBanner();
            var verified = await updater.DownloadAsync(new System.Progress<UpdateProgress>(value =>
            {
                if (value.Total > 0) inlineFraction = System.Math.Clamp((double)value.Received / value.Total, 0, 1);
                RefreshUpdates(); RefreshBanner();
            }), inlineDownload.Token);
            if (sourceClosed) return;
            inlineFraction = null; inlineUpdateText = ui.Text("main.update.installing"); RefreshUpdates();
            if (!updater.Install(verified)) { inlineUpdateText = ui.Text("windows.updates.failed"); inlineUpdateFailed = true; }
        }
        catch (System.OperationCanceledException) { inlineUpdateText = null; }
        catch (System.Exception error) when (WindowsUpdateService.Recoverable(error))
        { inlineUpdateText = ui.Text("main.update.failed").Replace("%@", ui.Text("windows.updates.failed"), System.StringComparison.Ordinal); inlineUpdateFailed = true; }
        finally { inlineDownload?.Dispose(); inlineDownload = null; inlineFraction = null; if (!sourceClosed) { RefreshUpdates(); RefreshOverview(); RefreshBanner(); } }
    }
    /// Idle, the card says when Pacer last checked, or nothing; other states say themselves.
    private string IdleUpdateText(string key)
    {
        if (key != "updates.policy") return ui.Text(key);
        if (updater?.LastCheck is not { } last) return "";
        var culture = System.Globalization.CultureInfo.GetCultureInfo(ui.Language == "zh-Hans" ? "zh-CN" : "en-US");
        return ui.Text("updates.last_check").Replace("%@", last.ToLocalTime().ToString("g", culture), System.StringComparison.Ordinal);
    }
    private void RefreshUpdates()
    {
        bool syncing = synchronizing; synchronizing = true;
        try
        {
            var status = updater?.Status ?? new WindowsUpdateStatus(false, false, demo ? "updates.demo_disabled" : "windows.updates.unconfigured");
            if (demo && status.MessageKey == "windows.updates.unconfigured") status = status with { MessageKey = "updates.demo_disabled" };
            bool available = status.Available && !status.Busy && !busy && !changingUpdates && !session.RequiresRestart;
            // The policy explains the switch; the card's line says what happened last, as on the Mac.
            if (automaticUpdates != null) { automaticUpdates.IsChecked = session.Current.AutomaticUpdates; automaticUpdates.IsEnabled = available; automaticUpdates.ToolTip = ui.Text("updates.policy"); }
            if (updateCheck != null) updateCheck.IsEnabled = available;
            if (updateNotesButton != null) { updateNotesButton.IsEnabled = available && !readingUpdateNotes; updateNotesButton.Visibility = updater?.CurrentOffer != null && inlineDownload == null ? Visibility.Visible : Visibility.Collapsed; }
            string? found = updater?.CurrentOffer?.Version;
            bool downloading = inlineDownload != null;
            if (updateStatus != null)
            {
                updateStatus.Text = downloading && inlineFraction is { } fraction
                    ? ui.Text("main.update.downloading_percent").Replace("%@", ((int)System.Math.Floor(fraction * 100)).ToString(System.Globalization.CultureInfo.CurrentCulture), System.StringComparison.Ordinal).Replace("%%", "%", System.StringComparison.Ordinal)
                    : inlineUpdateText ?? (found != null ? ui.Text("main.update.available").Replace("%@", found, System.StringComparison.Ordinal) : IdleUpdateText(status.MessageKey));
                updateStatus.SetResourceReference(TextBlock.ForegroundProperty, inlineUpdateFailed ? "SettingsWarning" : "SettingsSecondary");
                AutomationProperties.SetName(updateStatus, updateStatus.Text);
            }
            if (updateProgress != null)
            {
                updateProgress.Visibility = downloading ? Visibility.Visible : Visibility.Collapsed;
                updateProgress.IsIndeterminate = downloading && inlineFraction == null;
                if (inlineFraction is { } value) updateProgress.Value = value;
            }
            // A found version replaces the check with the one-click update; while it downloads, Cancel takes its place.
            if (updateCheck != null) updateCheck.Visibility = found == null && !downloading ? Visibility.Visible : Visibility.Collapsed;
            if (updateInstall != null) { updateInstall.Visibility = found != null && !downloading ? Visibility.Visible : Visibility.Collapsed; updateInstall.IsEnabled = !status.Busy && !busy; }
            if (updateCancel != null) updateCancel.Visibility = downloading ? Visibility.Visible : Visibility.Collapsed;
            if (updateDownloadPage != null) updateDownloadPage.Visibility = inlineUpdateFailed && !downloading ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { synchronizing = syncing; }
    }
    private async void ReadUpdateNotes(object sender, RoutedEventArgs args)
    {
        if (sourceClosed || updater == null || readingUpdateNotes) return;
        readingUpdateNotes = true; RefreshUpdates();
        try
        {
            string? notes = await updater.ReadReleaseNotesAsync();
            if (sourceClosed) return;
            if (string.IsNullOrEmpty(notes)) ShowIssue("windows.updates.notes_unavailable");
            else SignedReleaseNotesRequested?.Invoke(notes);
        }
        catch (System.Exception error) when (WindowsUpdateService.Recoverable(error)) { if (!sourceClosed) ShowIssue("windows.updates.failed"); }
        finally { readingUpdateNotes = false; if (!sourceClosed) RefreshUpdates(); }
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
