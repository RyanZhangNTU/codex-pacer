using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class CodexSettingsChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        await using var engine = new EngineClient();
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "codex", ProviderModes = new()
            { ["codex"] = "enabled", ["claude"] = "enabled", ["deepseek"] = "enabled" } };
        bool rejectSave = false, rejectEngine = false; int configurations = 0;
        var session = new PreferencesSession(preferences, async value =>
        { configurations++; if (rejectEngine) throw new IOException("Synthetic lost acknowledgement and restore failure"); await engine.SendAsync("configure", value); }, _ =>
        { if (!rejectSave) return true; rejectSave = false; return false; });
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        UiText ui = UiText.For(language == "zh-Hans");
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine, ready.Task) { ShowActivated = false, IsHitTestVisible = false };
        string name = language + (dark ? "-dark" : "-light");
        try
        {
            window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(Find<TextBlock>(window, "settings.codex.cli.status").Text == ui.Text("provider.state.searching"),
                "Opening settings before engine initialization must wait instead of reporting a failed source check");
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
                preferences.EngineConfiguration(), referenceFixture: true);
            ready.TrySetResult();
            await Until(() => Find<TextBlock>(window, "settings.codex.cli.status").Text == ui.Text("provider.state.found"), "The provider page must inspect its saved CLI source");
            Check(Math.Abs(window.ClientContent.ActualWidth - SettingsWindow.DefaultWidth) < 0.5 && Math.Abs(window.ClientContent.ActualHeight - SettingsWindow.DefaultHeight) < 0.5,
                "The provider page must keep the original Mac client and sidebar dimensions");
            var module = Find<CheckBox>(window, "settings.codex.enabled");
            Check(module.IsChecked == true && module.ActualWidth == 38 && module.ActualHeight == 22,
                "The module switch must use the original settings geometry and actual module state");
            var embedded = Find<CheckBox>(window, "settings.codex.embedded");
            Check(embedded.IsEnabled && embedded.IsChecked == true, "The source page must expose the acknowledged embedded-session preference");
            Toggle(embedded);
            await Until(() => !session.Current.ShowEmbeddedCodexSessions && embedded.IsEnabled, "Hiding embedded sessions must await the real engine configuration");
            Toggle(embedded);
            await Until(() => session.Current.ShowEmbeddedCodexSessions && embedded.IsEnabled, "The embedded-session choice must restore immediately");
            var progress = Find<CheckBox>(window, "settings.codex.progress_ring");
            Check(progress.IsEnabled && progress.IsChecked == true, "Codex progress is on by default, as on the Mac");
            Toggle(progress);
            await Until(() => !session.Current.CodexProgressRing && session.Current.ClaudeProgressRing && progress.IsEnabled &&
                engine.LatestSnapshot?.Presentation?.Rows.All(row => row.Provider != "codex" || row.ProgressState == null) == true,
                "Disabling Codex progress must remove only its rings after acknowledgement");
            Toggle(progress);
            await Until(() => session.Current.CodexProgressRing && session.Current.ClaudeProgressRing &&
                engine.LatestSnapshot?.Presentation?.Rows.Any(row => row.Provider == "codex" && row.ProgressState == "pending") == true,
                "Enabling Codex progress must reach the engine and show the dashed ring");
            Toggle(progress);
            await Until(() => !session.Current.CodexProgressRing && progress.IsEnabled, "Codex progress can be turned off again");
            // Remote Control lives on Remote, as on the Mac.
            await window.NavigateAsync("remote"); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var remote = Find<CheckBox>(window, "settings.connections.remote_control");
            Check(remote.IsEnabled && remote.IsChecked == true, "Remote Control defaults to the Mac preference's enabled state");
            Toggle(remote);
            await Until(() => !session.Current.MonitorRemoteControl && remote.IsEnabled, "Remote Control changes must await engine acknowledgement");
            Toggle(remote);
            await Until(() => session.Current.MonitorRemoteControl && remote.IsEnabled, "Re-enabling Remote Control restores monitoring");
            await window.NavigateAsync("codex"); await window.WaitForSourceInspectionAsync(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            module = Find<CheckBox>(window, "settings.codex.enabled");
            int sourceConfigurations = configurations;
            Check(Find<RadioButton>(window, "settings.pane.codex").IsChecked == true
                && Find<RadioButton>(window, "settings.pane.claude").IsEnabled
                && Find<RadioButton>(window, "settings.pane.deepseek").IsEnabled
                && Find<RadioButton>(window, "settings.pane.remote").IsEnabled,
                "Implemented provider and connection panes must be reachable");
            window.CapturePreview(Path.Combine(output, "settings-" + name + "-codex.png"));
            var expander = Find<Expander>(window, "settings.codex.locations");
            var disclosureTitle = Descendants(expander).OfType<TextBlock>().Single(value => value.Text == ui.Text("provider.custom_locations"));
            Check(((SolidColorBrush)disclosureTitle.Foreground).Color == ((SolidColorBrush)window.Resources["SettingsPrimary"]).Color,
                "The disclosure title must retain readable settings text in both themes instead of inheriting island white");
            ((IExpandCollapseProvider)new ExpanderAutomationPeer(expander).GetPattern(PatternInterface.ExpandCollapse)).Expand();
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var executable = Find<TextBox>(window, "settings.codex.executable");
            var home = Find<TextBox>(window, "settings.codex.home");
            Check(executable.IsVisible && home.IsVisible, "Keyboard and accessibility expansion must expose both source fields");
            Edit(executable, "relative\\codex.exe");
            await Until(() => Find<TextBlock>(window, "settings.codex.executable.issue").IsVisible,
                "An invalid executable must keep a readable inline issue");
            Check(configurations == sourceConfigurations && session.Current.CodexExecutable == "" && executable.Text == "relative\\codex.exe",
                "Invalid drafts must remain editable without changing the saved or active source");
            window.CapturePreview(Path.Combine(output, "settings-" + name + "-codex-invalid.png"));
            Edit(executable, " \"C:\\Demo\\中文 tools\\codex.exe\" "); Enter(executable);
            await Until(() => session.Current.CodexExecutable == @"C:\Demo\中文 tools\codex.exe" && executable.IsEnabled,
                "A valid source must normalize and await engine acknowledgement");
            Check(configurations == sourceConfigurations + 1 && executable.Text == session.Current.CodexExecutable,
                "Repeated Enter during the same validation cannot configure twice");
            Edit(home, @"C:\Demo\alternate Codex home");
            await Until(() => session.Current.CodexHome == @"C:\Demo\alternate Codex home" && home.IsEnabled, "The selected source home must save immediately");
            Check((await engine.QueryAsync<CodexSourceReport>("inspectCodexSource")).EffectiveHome == session.Current.CodexHome,
                "The settings field must describe the source actually used by the engine");
            Edit(home, "");
            await Until(() => session.Current.CodexHome == "" && home.IsEnabled && configurations == sourceConfigurations + 3,
                "Clearing an override must explicitly restore the default home");
            string fallback = (await engine.QueryAsync<CodexSourceReport>("inspectCodexSource")).EffectiveHome;
            Check(fallback != @"C:\Demo\alternate Codex home", "The old source cannot survive a cleared path");
            rejectSave = true; Edit(home, @"C:\Demo\rejected-home");
            await Until(() => configurations == sourceConfigurations + 5 && home.IsEnabled && home.Text == "", "A failed save must restore the field after engine rollback");
            Check(session.Current.CodexHome == "" && (await engine.QueryAsync<CodexSourceReport>("inspectCodexSource")).EffectiveHome == fallback,
                "Rollback to a default source must restore the actual engine source as well as preferences");
            Toggle(module);
            await Until(() => session.Current.ProviderModes["codex"] == "disabled" && module.IsEnabled, "The module switch must disable Codex in the actual engine");
            Check(!home.IsVisible && engine.LatestSnapshot!.QuotaDashboard!.Providers.All(value => value.Provider != "codex"),
                "Disabling a module must hide its local controls and remove its quota work");
            Toggle(module);
            await Until(() => session.Current.ProviderModes["codex"] == "enabled" && module.IsEnabled, "The provider must be re-enabled through its saved module mode");
            Invoke(Find<Button>(window, "settings.codex.automatic"));
            await Until(() => session.Current.ProviderModes["codex"] == "automatic" && module.IsEnabled, "Use Automatic must restore installation-based selection");
            Check(!Find<Button>(window, "settings.codex.automatic").IsVisible && module.IsChecked == true
                && engine.LatestSnapshot!.Modules!.Single(value => value.Provider == "codex").Mode == "automatic",
                "The footer, switch and actual module mode must agree after restoring Automatic");
            window.CapturePreview(Path.Combine(output, "settings-" + name + "-codex-expanded.png"));
            await window.NavigateAsync("general");
            var link = new QuotaConnectionView("codex", new("unavailable", null, [new("settings", ui.Text("common.settings"), true)]),
                ui, null, () => _ = window.NavigateAsync("codex"));
            var linkWindow = new Window { Content = link, Width = 360, Height = 90, Background = Brushes.Black, ShowActivated = false, IsHitTestVisible = false };
            try
            {
                linkWindow.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                var action = Find<Button>(linkWindow, "quota.codex.settings"); Check(action.IsEnabled, "Codex recovery settings must expose an enabled action"); Invoke(action);
                await Until(() => session.Current.LastSettingsPane == "codex" && Find<RadioButton>(window, "settings.pane.codex").IsChecked == true,
                    "The recovery action must select the actual Codex source pane");
            }
            finally { linkWindow.Close(); }
            await Until(() => Find<TextBlock>(window, "settings.codex.cli.status").Text == ui.Text("provider.state.found"), "Reopening must reload the acknowledged source");
            Check(Find<TextBox>(window, "settings.codex.executable").Text == session.Current.CodexExecutable,
                "Provider navigation must retain the saved normalized executable");
            int beforeConcurrentEdit = configurations;
            Edit(Find<TextBox>(window, "settings.codex.executable"), @"C:\Demo\second-cli\codex.exe");
            Edit(Find<TextBox>(window, "settings.codex.home"), @"C:\Demo\second-home");
            await Until(() => session.Current.CodexExecutable == @"C:\Demo\second-cli\codex.exe" && session.Current.CodexHome == @"C:\Demo\second-home"
                && Find<TextBox>(window, "settings.codex.home").IsEnabled,
                "Validation of a second field cannot discard the first field's pending edit");
            Check(configurations == beforeConcurrentEdit + 2, "Independent path edits must each be applied once through the serialized session");
            var concurrent = await engine.QueryAsync<CodexSourceReport>("inspectCodexSource");
            Check(concurrent.Executable == session.Current.CodexExecutable && concurrent.EffectiveHome == session.Current.CodexHome,
                "Both continuous source edits must reach the actual engine configuration");
            int restarts = 0; window.RestartRequested += () => restarts++;
            rejectEngine = true; Edit(Find<TextBox>(window, "settings.codex.home"), @"C:\Demo\unacknowledged-home");
            await Until(() => session.RequiresRestart && Find<Button>(window, "settings.recovery_restart").IsVisible,
                "An unconfirmed source and failed restore must offer restart on the current provider pane");
            Check(!Find<TextBox>(window, "settings.codex.home").IsEnabled,
                "An uncertain engine state must prevent further source edits");
            Invoke(Find<Button>(window, "settings.recovery_restart")); await Until(() => restarts == 1, "The recovery restart must reach the lifecycle owner without requiring navigation");
            await engine.SendAsync("shutdown");
            await Until(() => engine.IsConnectionClosed && !Descendants(window).OfType<QuotaHistoryChart>().Any()
                && Find<TextBlock>(window, "settings.codex.cli.status").Text == ui.Text("provider.state.failed"),
                "A stopped engine cannot leave a fresh chart or a successful source check on screen");
            await engine.DisposeAsync();
            var offlineSession = new PreferencesSession(preferences, _ => Task.CompletedTask, _ => true);
            var offline = new SettingsWindow(ui, offlineSession, new Startup(), true, dark, engine) { ShowActivated = false, IsHitTestVisible = false };
            try
            {
                offline.Show(); await offline.WaitForSourceInspectionAsync();
                Check(Find<TextBlock>(offline, "settings.codex.cli.status").Text == ui.Text("provider.state.failed")
                    && Find<Button>(offline, "settings.codex.rescan").IsVisible,
                    "A stopped engine must report a failed check and permit retry without claiming that the CLI is missing");
                Check(!Descendants(offline).OfType<QuotaHistoryChart>().Any()
                    && Descendants(offline).OfType<TextBlock>().Any(value => value.Text == ui.Text("windows.connection.closed")),
                    "Reopening settings after disconnection must hide old account and chart values immediately");
            }
            finally { offline.AllowClose = true; offline.Close(); }
            Console.WriteLine("PASS Codex settings " + name + ": source inspection, UI Automation, validation, default restoration, rollback, module modes and recovery navigation");
        }
        catch
        {
            try { window.CapturePreview(Path.Combine(output, "failed-settings-" + name + "-codex.png")); } catch { }
            throw;
        }
        finally { window.AllowClose = true; window.Close(); ready.TrySetCanceled(); }
    }
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement
        => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Edit(TextBox field, string value)
    { ((IValueProvider)new TextBoxAutomationPeer(field).GetPattern(PatternInterface.Value)).SetValue(value); Enter(field); }
    private static void Enter(TextBox field) => field.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(field), Environment.TickCount, Key.Enter) { RoutedEvent = Keyboard.KeyDownEvent });
    private static void Toggle(CheckBox check) => ((IToggleProvider)new CheckBoxAutomationPeer(check).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Until(Func<bool> condition, string message)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < PresentationWait.Limit) await Task.Delay(25); Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration
    { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
