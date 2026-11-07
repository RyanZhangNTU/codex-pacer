using System;
using System.Collections.Generic;
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
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class ProviderHomeSettingsChecks
{
    internal static async Task Run(string provider, string language, bool dark, string output)
    {
        var previous = CultureInfo.CurrentUICulture; CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
        string root = Path.Combine(Path.GetTempPath(), "pacer-home-中文 space-" + Guid.NewGuid().ToString("N"));
        string first = Path.Combine(root, "first"), second = Path.Combine(root, "second"), third = Path.Combine(root, "third"), file = Path.Combine(root, "file");
        foreach (string directory in new[] { first, second, third }) Directory.CreateDirectory(directory);
        File.WriteAllText(file, "synthetic fixture");
        await using var engine = new EngineClient(); bool rejectSave = false; int configurations = 0;
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = provider,
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = provider == "claude" ? "enabled" : "disabled", ["deepseek"] = provider == "deepseek" ? "enabled" : "disabled" } };
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => { if (!rejectSave) return true; rejectSave = false; return false; });
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = new SettingsWindow(UiText.For(language == "zh-Hans"), session, new Startup(), true, dark, engine, ready.Task) { IsHitTestVisible = false, ShowActivated = false };
        string prefix = "settings." + provider, scenario = provider + "-" + language + (dark ? "-dark" : "-light");
        string Saved() => provider == "claude" ? session.Current.ClaudeHome : session.Current.DeepseekHome;
        try
        {
            window.Show(); await Pump();
            Check(!Find<CheckBox>(window, prefix + ".enabled").IsEnabled, "An initializing source page must wait for an engine snapshot");
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, configuration: preferences.EngineConfiguration(), referenceFixture: true);
            ready.SetResult(); await window.WaitForSourceInspectionAsync(); await Pump();
            var module = Find<CheckBox>(window, prefix + ".enabled");
            Check(module.IsEnabled && module.IsChecked == true && Math.Abs(window.ClientContent.ActualWidth - SettingsWindow.DefaultWidth) < 0.5 && Math.Abs(window.ClientContent.ActualHeight - SettingsWindow.DefaultHeight) < 0.5,
                "The provider page must retain native canvas geometry and acknowledged module state");
            if (provider == "claude")
            {
                var ui = UiText.For(language == "zh-Hans");
                var setup = new ClaudeHookSetup("ready", true, true, true, false, false, "powershell");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup) == ui.Text("windows.claude.setup_ready") + " " + ui.Text("windows.claude.setup_slow"), "A slow launcher must explain its per-event startup cost");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup with { LaunchMode = "direct" }) == ui.Text("windows.claude.setup_ready"), "The direct route must retain its ready message");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup with { LaunchMode = "shortPath" }) == ui.Text("windows.claude.setup_ready"), "The 8.3 route must retain its ready message");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup with { TelemetryConflict = true }).Contains(ui.Text("windows.claude.setup_conflict")), "The cost notice must retain the existing telemetry conflict");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "failed", setup) == ui.Text("windows.claude.setup_failed"), "A failed setup must retain its actionable error");
                Check(Find<TextBlock>(window, "settings.claude.setup").Text == UiText.For(language == "zh-Hans").Text("windows.claude.setup_ready"),
                    "The demo must show the localized Claude setup state");
                Check(!Find<Button>(window, "settings.claude.retry_setup").IsEnabled,
                    "A demo must never invoke the live hook installer");
            }
            if (provider == "claude") window.CapturePreview(Path.Combine(output, "settings-" + scenario + ".png"));
            var disclosure = Find<Expander>(window, prefix + ".locations"); disclosure.IsExpanded = true; await Pump();
            var field = Find<TextBox>(window, prefix + ".home"); field.BringIntoView(); await Pump();
            var issue = Find<TextBlock>(window, prefix + ".home.issue");
            int beforeInvalid = configurations;
            foreach (string invalid in new[] { "relative/folder", Path.Combine(root, "missing"), file })
            {
                field.Text = invalid; Enter(window, field); await Until(() => issue.IsVisible);
                Check(Saved() == "" && configurations == beforeInvalid && field.Text == invalid, "Invalid drafts must not change the engine or saved source");
            }
            field.Text = " \"" + first + "\" "; Enter(window, field); Enter(window, field);
            await Until(() => Saved() == first && field.IsEnabled);
            Check(field.Text == first && configurations == beforeInvalid + 1, "A duplicate Enter must commit the normalized Unicode folder only once");
            Check((await engine.QueryAsync<ProviderHomeReport>("inspectProviderHome", new { provider })).EffectiveHome == first, "The actual engine must acknowledge the selected folder");
            field.Text = second; Enter(window, field); field.Text = third; Enter(window, field);
            await Until(() => Saved() == third && field.IsEnabled);
            Check(configurations == beforeInvalid + 2, "A late validation must not apply a superseded draft");
            rejectSave = true; field.Text = second; Enter(window, field);
            await Until(() => !rejectSave && field.IsEnabled && field.Text == third);
            Check(Saved() == third && (await engine.QueryAsync<ProviderHomeReport>("inspectProviderHome", new { provider })).EffectiveHome == third,
                "A rejected preference write must restore both engine source and editor");
            field.Text = ""; Enter(window, field); await Until(() => Saved() == "" && field.IsEnabled);
            var restored = await engine.QueryAsync<ProviderHomeReport>("inspectProviderHome", new { provider, sourceHome = "" });
            Check(restored.EffectiveHome.Contains("Demo", StringComparison.OrdinalIgnoreCase), "Clearing must restore the isolated demo default");
            await CheckEmbedding(window, provider, session);
            window.CapturePreview(Path.Combine(output, "settings-" + scenario + "-locations.png"));
            Toggle(module); await Until(() => session.Current.ProviderModes[provider] == "disabled" && module.IsEnabled);
            Check(!field.IsVisible && !field.IsEnabled, "A disabled module must hide and disable source editors");
            Toggle(module); await Until(() => session.Current.ProviderModes[provider] == "enabled" && module.IsEnabled);
            CheckEmbeddingEnabled(window, provider);
            var automatic = Find<Button>(window, prefix + ".automatic"); Invoke(automatic);
            await Until(() => session.Current.ProviderModes[provider] == "automatic" && automatic.Visibility == Visibility.Collapsed);
            int beforeNavigation = configurations;
            await window.NavigateAsync("general"); field.Text = second; Enter(window, field); await Pump();
            Check(Saved() == "" && configurations == beforeNavigation, "Detached controls cannot change a source after navigation");
            await window.NavigateAsync(provider); await window.WaitForSourceInspectionAsync(); await Pump();
            disclosure = Find<Expander>(window, prefix + ".locations"); disclosure.IsExpanded = true; await Pump();
            field = Find<TextBox>(window, prefix + ".home");
            Check(field.Text == "", "Reopening must restore the acknowledged source");
            await engine.SendAsync("shutdown"); await Until(() => !field.IsEnabled && !Find<CheckBox>(window, prefix + ".enabled").IsEnabled);
            Check(!Find<Button>(window, prefix + ".choose_home").IsEnabled, "A closed engine must also disable the folder picker");
            if (provider == "claude")
            {
                Check(Find<TextBlock>(window, "settings.claude.setup").Text == UiText.For(language == "zh-Hans").Text("windows.claude.setup_failed") &&
                    !Find<Button>(window, "settings.claude.retry_setup").IsEnabled,
                    "Engine exit must show a setup error and disable retries without a synchronous request");
            }
            Console.WriteLine("PASS provider home " + scenario + ": initialization, existing/missing/file/relative paths, normalized Unicode, duplicate/stale drafts, engine/save rollback, default restoration, module modes, navigation and closed connection");
        }
        finally { ready.TrySetResult(); window.AllowClose = true; window.Close(); Directory.Delete(root, true); CultureInfo.CurrentUICulture = previous; }
    }
    private static async Task CheckEmbedding(Window window, string provider, PreferencesSession session)
    {
        if (provider != "claude") return;
        CheckEmbeddingEnabled(window, provider);
        var toggle = Find<CheckBox>(window, "settings.claude.embedded");
        Check(toggle.IsChecked == true && session.Current.ShowEmbeddedCodexSessions, "The provider switches default to visible independently");
        Toggle(toggle); await Until(() => !session.Current.ShowEmbeddedClaudeSessions && toggle.IsEnabled);
        Check(toggle.IsChecked == false && session.Current.ShowEmbeddedCodexSessions, "Hiding Claude embedding must leave the Codex preference visible");
        Toggle(toggle); await Until(() => session.Current.ShowEmbeddedClaudeSessions && toggle.IsEnabled);
        Check(toggle.IsChecked == true, "Restoring Claude embedding must await the engine and restore the acknowledged switch");
    }
    private static void CheckEmbeddingEnabled(Window window, string provider)
    {
        if (provider != "claude") return;
        Check(Find<CheckBox>(window, "settings.claude.cloud_projects").IsEnabled && Find<CheckBox>(window, "settings.claude.embedded").IsEnabled,
            "Cloud Projects remains connected and the implemented embedding control is enabled");
    }
    private static void Enter(Window window, TextBox field) => field.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Enter) { RoutedEvent = Keyboard.KeyDownEvent });
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().SingleOrDefault(value => AutomationProperties.GetAutomationId(value) == id)
        ?? throw new InvalidOperationException("Missing element: " + id);
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed.TotalSeconds < PresentationWait.Limit.TotalSeconds) await Task.Delay(20); Check(condition(), "The bounded provider source action must finish"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool value) => true; }
}
