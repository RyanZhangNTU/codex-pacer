using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class StorageRecoveryChecks
{
    internal static async Task Run()
    {
        var previous = CultureInfo.CurrentUICulture;
        string root = Path.Combine(Path.GetTempPath(), "pacer-recovery-ui-中文-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        SettingsWindow? window = null;
        try
        {
            foreach (string language in new[] { "en", "zh-Hans" })
            {
                CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language); var ui = UiText.For(language == "zh-Hans");
                string file = Path.Combine(root, "preferences.json"); const string damaged = "synthetic-private-damage"; File.WriteAllText(file, damaged);
                var store = new PreferencesStore(file); var loaded = store.Load();
                var session = new PreferencesSession(loaded.Value, _ => Task.CompletedTask, store.Save);
                window = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, preferencesStore: store) { ShowActivated = false };
                window.Show(); await Pump();
                var message = Find<TextBlock>(window, "settings.storage_message");
                Check(message.IsVisible && message.Text.Contains("preferences.json.damaged-") && !message.Text.Contains(root) && !message.Text.Contains(damaged), "Recovery notice shows the backup name without its directory or bytes");
                window.AllowClose = true; window.Close();
                window = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, preferencesStore: store) { ShowActivated = false };
                window.Show(); await Pump();
                Check(!Find<TextBlock>(window, "settings.storage_message").IsVisible, "The damaged-preferences notice appears only once");
                window.AllowClose = true; window.Close();
                const string future = "{\"schemaVersion\":999,\"synthetic\":true}"; File.WriteAllText(file, future);
                store = new PreferencesStore(file); loaded = store.Load();
                var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                bool waiting = false;
                session = new PreferencesSession(loaded.Value, _ => Task.CompletedTask, store.Save, async value => { waiting = true; await gate.Task; return value; });
                window = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, preferencesStore: store) { ShowActivated = false };
                window.Show(); await Pump();
                message = Find<TextBlock>(window, "settings.storage_message"); var reset = Find<Button>(window, "settings.storage_reset");
                Check(message.Text == ui.Text("windows.storage.future") && reset.IsVisible && reset.IsEnabled, "Future-version protection explains the explicit recovery action");
                Check(File.ReadAllText(file) == future, "Opening Settings never modifies a future profile");
                ((IInvokeProvider)new ButtonAutomationPeer(reset).GetPattern(PatternInterface.Invoke)).Invoke();
                await Until(() => waiting);
                bool responsive = false; await window.Dispatcher.InvokeAsync(() => responsive = true, DispatcherPriority.Input);
                Check(responsive && !reset.IsEnabled && File.ReadAllText(file) == future, "Confirmation leaves the UI responsive and original bytes intact while awaiting acknowledgement");
                gate.SetResult(); await Until(() => reset.IsEnabled && !store.HasFutureVersion);
                Check(!session.Current.HideProjects, "Confirmed recovery applies normal defaults");
                Check(Directory.GetFiles(root, "preferences.json.damaged-*").Any(path => File.ReadAllText(path) == future), "The future profile survives in its backup");
                Check(!Find<Button>(window, "settings.storage_reset").IsVisible && Find<TextBlock>(window, "settings.storage_message").Text.Contains("preferences.json.damaged-"), "Successful recovery replaces the action with the backup notice");
                Check(await session.ChangeAsync(value => value with { Language = language }) == PreferencesApplyResult.Applied && new PreferencesStore(file).Load().Value.Language == language, "Settings edits work after recovery");
                window.AllowClose = true; window.Close(); window = null;
            }
        }
        finally
        {
            if (window != null) { window.AllowClose = true; window.Close(); }
            CultureInfo.CurrentUICulture = previous;
            foreach (string file in Directory.EnumerateFiles(root)) File.Delete(file); Directory.Delete(root);
        }
    }
    private static T Find<T>(DependencyObject parent, string id) where T : DependencyObject
        => Walk(parent).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static System.Collections.Generic.IEnumerable<DependencyObject> Walk(DependencyObject parent)
    {
        yield return parent;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) foreach (var item in Walk(VisualTreeHelper.GetChild(parent, i))) yield return item;
    }
    private static async Task Pump() { await Dispatcher.Yield(DispatcherPriority.ContextIdle); await Task.Delay(60); }
    private static async Task Until(Func<bool> condition)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < PresentationWait.Limit) await Task.Delay(20); Check(condition(), "Recovery did not settle"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
