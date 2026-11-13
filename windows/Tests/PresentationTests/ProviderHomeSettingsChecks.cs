using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
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
    internal static async Task RunTaskModule(string language, bool dark)
    {
        await using var engine = new EngineClient();
        var ui = UiText.For(language == "zh-Hans");
        var initial = new DesktopPreferences
        {
            LastSettingsPane = "overview", MonitorSSH = false,
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled",
                ["workbuddy"] = "disabled", ["future-harness"] = "enabled" }
        };
        var session = new PreferencesSession(initial, value => engine.SendAsync("configure", value), _ => true);
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), false, language,
            configuration: initial.EngineConfiguration(), readOnlyDiagnostics: true);
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine) { IsHitTestVisible = false, ShowActivated = false };
        const string id = "settings.workbuddy";
        CheckBox? ModuleSwitch() => Descendants(window).OfType<CheckBox>().FirstOrDefault(value => AutomationProperties.GetAutomationId(value) == id + ".enabled");
        try
        {
            window.Show();
            var row = Find<RadioButton>(window, "settings.pane.workbuddy");
            Check(AutomationProperties.GetName(row) == "WorkBuddy" && row.IsEnabled &&
                Descendants(row).OfType<Image>().Any(icon => icon.Source != null && ReferenceEquals(icon.Source, ProviderIcon.Source("workbuddy"))),
                "WorkBuddy appears with its official icon in the Services sidebar while disabled");
            Find<TextBox>(window, "settings.search").Text = "workbuddy";
            await Pump();
            Check(window.SearchMatches().SequenceEqual(["workbuddy"]), "Searching for WorkBuddy finds the service page");
            Invoke(Find<Button>(window, "settings.search.result.workbuddy"));
            await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: true, IsChecked: false },
                "The search result opens the disabled module’s settings page");
            Check(session.Current.LastSettingsPane == "harness.workbuddy" && row.IsChecked == true, "The selected service is saved");
            var toggle = Find<CheckBox>(window, id + ".enabled");
            Check(AutomationProperties.GetName(toggle) == "WorkBuddy", "The module has an accessible label from its descriptor");
            Toggle(toggle);
            await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: true, IsChecked: true }
                && session.Current.ProviderModes["workbuddy"] == "enabled"
                && engine.LatestSnapshot?.Modules?.Any(module => module.Provider == "workbuddy" && module.Enabled) == true,
                "The service page can enable a task module and keeps unknown choices out of the engine handshake");
            Check(Find<TextBlock>(window, id + ".status").IsVisible && Find<Button>(window, id + ".accountUsage").IsVisible,
                "The enabled service has local task status and an account usage link");
            var detected = engine.LatestSnapshot?.Modules?.First(value => value.Provider == "workbuddy").Installed;
            string detection = ui.Text(detected switch { true => "windows.provider.detected", false => "windows.provider.not_detected", _ => "provider.state.searching" });
            Check(Descendants(window).OfType<TextBlock>().Any(value => value.Text == detection), "The header describes detection on a Windows PC");
            var progress = Find<CheckBox>(window, id + ".progress");
            Check(progress.IsEnabled && progress.IsChecked == false, "The external reporting tool is opt-in");
            Toggle(progress);
            await PresentationWait.UntilAsync(() => progress.IsEnabled && progress.IsChecked == true
                && session.Current.EnabledHarnessProgress.SequenceEqual(["workbuddy"]), "The progress switch saves independently of the module mode");
            await window.NavigateAsync("overview");
            Check(engine.LatestSnapshot?.QuotaDashboard?.Providers.Count == 0
                && !Descendants(window).OfType<TextBlock>().Any(value => value.Text == ui.Text("provider.none_enabled")),
                "An enabled task module appears in Overview without a quota card");
            Invoke(Find<Button>(window, "settings.overview.details.workbuddy"));
            await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: true, IsChecked: true }, "The Overview detail link opens WorkBuddy settings");
            progress = Find<CheckBox>(window, id + ".progress");
            Check(progress.IsChecked == true, "The progress choice survives navigation");
            Toggle(progress);
            await PresentationWait.UntilAsync(() => progress.IsEnabled && progress.IsChecked == false && session.Current.EnabledHarnessProgress.Length == 0,
                "Turning off progress removes its provider choice");
            Invoke(Find<Button>(window, id + ".automatic"));
            await PresentationWait.UntilAsync(() => session.Current.ProviderModes["workbuddy"] == "automatic"
                && engine.LatestSnapshot?.Modules?.Any(module => module.Provider == "workbuddy" && module.Mode == "automatic") == true,
                "Automatic detection can be restored from the service header");
            if (Find<CheckBox>(window, id + ".enabled").IsChecked != true)
            {
                Toggle(Find<CheckBox>(window, id + ".enabled"));
                await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: true, IsChecked: true }
                    && session.Current.ProviderModes["workbuddy"] == "enabled", "The module can be explicitly enabled after automatic detection");
            }
            Toggle(Find<CheckBox>(window, id + ".enabled"));
            await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: true, IsChecked: false }
                && session.Current.ProviderModes["workbuddy"] == "disabled"
                && engine.LatestSnapshot?.Modules?.Any(module => module.Provider == "workbuddy" && !module.Enabled) == true,
                "The service page can disable the task module again");
            Check(session.Current.ProviderModes["future-harness"] == "enabled", "Editing WorkBuddy keeps unrecognized module choices");
            await engine.SendAsync("shutdown");
            await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: false }, "A disconnected engine disables module controls");
        }
        finally { window.Close(); }
    }

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
                Check(SettingsWindow.JoinSentences("甲。", "乙。") == "甲。乙。" && SettingsWindow.JoinSentences("A.", "B.") == "A. B.",
                    "Chinese sentences join without a space after a full-width stop; other languages keep one");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup) == SettingsWindow.JoinSentences(ui.Text("windows.claude.setup_ready"), ui.Text("windows.claude.setup_slow")), "A slow launcher must explain its per-event startup cost");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup with { LaunchMode = "direct" }) == ui.Text("windows.claude.setup_ready"), "The direct route must retain its ready message");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup with { LaunchMode = "shortPath" }) == ui.Text("windows.claude.setup_ready"), "The 8.3 route must retain its ready message");
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", setup with { TelemetryConflict = true }) == SettingsWindow.JoinSentences(ui.Text("claude.telemetry.kept_existing"), ui.Text("windows.claude.setup_slow")),
                    "The cost notice must follow the existing telemetry note");
                var direct = setup with { LaunchMode = "direct" };
                Check(!SettingsWindow.ClaudeSetupVisible("ready", direct) && SettingsWindow.ClaudeSetupVisible("ready", setup) && SettingsWindow.ClaudeSetupVisible("failed", direct),
                    "A ready direct setup stays silent; the PowerShell cost and failures stay visible");
                var existing = direct with { TelemetryConflict = true, TelemetryConflictReason = "existing" };
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", existing) == ui.Text("claude.telemetry.kept_existing") && SettingsWindow.ClaudeSetupVisible("ready", existing),
                    "Existing telemetry settings show the Mac's note: TPS is estimated");
                var managed = direct with { TelemetryConflict = true, TelemetryConflictReason = "managed" };
                Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", managed) == ui.Text("claude.telemetry.managed") && SettingsWindow.ClaudeSetupVisible("ready", managed),
                    "Organization-managed telemetry must name its source");
                Check(ui.Text("claude.telemetry.managed") != ui.Text("claude.telemetry.kept_existing")
                    && !ui.Text("claude.telemetry.kept_existing").Contains(ui.Text("windows.claude.setup_ready")) && !ui.Text("claude.telemetry.managed").Contains(ui.Text("windows.claude.setup_ready")),
                    "Managed and existing telemetry need distinct notices without repeating the Ready state");
                foreach (var exact in new[] { existing with { ExactRequestSpans = true }, managed with { ExactRequestSpans = true } })
                    Check(SettingsWindow.ClaudeSetupDescription(ui, "ready", exact) == ui.Text("windows.claude.setup_ready") && !SettingsWindow.ClaudeSetupVisible("ready", exact),
                        "An exact request span means speeds are exact, so the estimate notice hides");
                Check(SettingsWindow.ClaudeSetupVisible("ready", managed with { ExactRequestSpans = false }), "Spans not yet seen keep the estimate notice");
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
