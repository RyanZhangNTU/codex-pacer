using System;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private readonly StackPanel storageRecovery = new() { Margin = new Thickness(28, 12, 28, 0), Visibility = Visibility.Collapsed };
    private readonly TextBlock storageMessage = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button storageReset = new() { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
    private PreferencesStore? recoveryStore;
    private string? recoveredBackup;
    private bool futureHistory, futurePreferences, recoveryClosed, recoveryQuery;
    private readonly CancellationTokenSource recoveryLifetime = new();

    private void InitializeStorageRecovery(DockPanel pane, PreferencesStore? store)
    {
        recoveryStore = store; recoveredBackup = store?.TakeRecoveryFileName(); futurePreferences = store?.HasFutureVersion == true;
        AutomationProperties.SetAutomationId(storageMessage, "settings.storage_message");
        Identify(storageReset, "settings.storage_reset", ui.Text("windows.storage.use_defaults"));
        storageReset.Content = ui.Text("windows.storage.use_defaults");
        storageRecovery.Children.Add(storageMessage); storageRecovery.Children.Add(storageReset);
        DockPanel.SetDock(storageRecovery, Dock.Top); pane.Children.Add(storageRecovery);
        RefreshStorageMessage();
        storageReset.Click += async (_, _) => await ResetStorageAsync();
        Loaded += async (_, _) => await RefreshStorageRecoveryAsync();
        Activated += async (_, _) => await RefreshStorageRecoveryAsync();
        Closed += (_, _) => { recoveryClosed = true; recoveryLifetime.Cancel(); recoveryLifetime.Dispose(); };
    }

    private void RefreshStorageMessage()
    {
        bool future = futurePreferences || recoveryStore?.HasFutureVersion == true || futureHistory;
        storageMessage.Text = future ? ui.Text("windows.storage.future") : recoveredBackup == null ? "" :
            string.Format(CultureInfo.CurrentCulture, ui.Text("windows.storage.restored"), recoveredBackup);
        storageRecovery.Visibility = future || recoveredBackup != null ? Visibility.Visible : Visibility.Collapsed;
        storageReset.Visibility = future ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task RefreshStorageRecoveryAsync()
    {
        if (engine == null || recoveryQuery || recoveryClosed) return;
        recoveryQuery = true;
        CancellationToken token = recoveryLifetime.Token;
        try
        {
            await sourceReady.WaitAsync(TimeSpan.FromSeconds(15), token);
            if (recoveryClosed) return;
            var status = await engine.QueryAsync<JsonElement>("storageRecoveryStatus", timeout: TimeSpan.FromSeconds(3), cancellation: token);
            if (recoveryClosed) return;
            futureHistory = status.ValueKind == JsonValueKind.Object && status.TryGetProperty("futureFiles", out var files) && files.ValueKind == JsonValueKind.Array && files.GetArrayLength() > 0;
            RefreshStorageMessage();
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or TimeoutException or EngineCommandException)
        { /* Keep the local notice and the existing engine error UI. */ }
        finally { recoveryQuery = false; }
    }

    private async Task ResetStorageAsync()
    {
        storageReset.IsEnabled = false;
        try
        {
            if (futureHistory && engine != null)
                await engine.QueryAsync<JsonElement>("recoverFutureStorage", timeout: TimeSpan.FromSeconds(15), cancellation: recoveryLifetime.Token);
            if (recoveryClosed) return;
            futureHistory = false;
            if (recoveryStore != null && (futurePreferences || recoveryStore.HasFutureVersion))
            {
                var result = await session.RecoverDefaultsAsync(recoveryStore.BackupAndUseDefaults);
                if (result != PreferencesApplyResult.Applied) throw new IOException("Storage recovery did not commit.");
                recoveredBackup = recoveryStore.TakeRecoveryFileName();
                futurePreferences = false;
            }
            RefreshStorageMessage();
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or TimeoutException or EngineCommandException)
        { if (!recoveryClosed) storageMessage.Text = ui.Text("windows.storage.failed"); }
        finally { if (!recoveryClosed) storageReset.IsEnabled = true; }
    }
}
