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
            // Whether WorkBuddy is installed depends on the machine, so the sidebar is checked against the engine's own answer.
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.Modules?.Any(value => value.Provider == "workbuddy") == true, "The engine lists WorkBuddy");
            await Pump();
            bool found = engine.LatestSnapshot!.Modules!.First(value => value.Provider == "workbuddy").IsProminent;
            var row = Find<RadioButton>(window, "settings.pane.workbuddy");
            Check(AutomationProperties.GetName(row) == "WorkBuddy" && row.IsEnabled && row.IsVisible == found,
                "A turned-off WorkBuddy shows in the Services sidebar once found on this computer, and otherwise only in the Module Library");
            Find<TextBox>(window, "settings.search").Text = "workbuddy";
            await Pump();
            var matches = window.SearchMatches();
            Check(matches.FirstOrDefault() == "workbuddy" && matches.Skip(1).All(value => value == "workbuddy-ai"),
                "Searching for WorkBuddy finds its service page first, and WorkBuddy AI's only after it");
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
            await PresentationWait.UntilAsync(() => row.IsVisible, "A module turned on shows in the Services sidebar even when it isn't found");
            Check(Descendants(row).OfType<Image>().Any(icon => icon.Source != null && ReferenceEquals(icon.Source, ProviderIcon.Source("workbuddy"))),
                "WorkBuddy has its official icon in the Services sidebar");
            Check(Find<TextBlock>(window, id + ".status").IsVisible && Find<Button>(window, id + ".accountUsage").IsVisible,
                "The enabled service has local task status and an account usage link");
            var detected = engine.LatestSnapshot?.Modules?.First(value => value.Provider == "workbuddy").Installed;
            string detection = ui.Text(detected switch { true => "windows.provider.detected", false => "windows.provider.not_detected", _ => "provider.state.searching" });
            Check(Descendants(window).OfType<TextBlock>().Any(value => value.Text == detection), "The header describes detection on a Windows PC");
            var progress = Find<CheckBox>(window, id + ".progress");
            Check(progress.IsEnabled && progress.IsChecked == true, "The progress ring is on by default, like the built-in services' rings");
            CheckProgressGuide(window, id);
            await CheckAppAutomation();
            Toggle(progress);
            await PresentationWait.UntilAsync(() => progress.IsEnabled && progress.IsChecked == false
                && session.Current.DisabledHarnessProgress.SequenceEqual(["workbuddy"]), "The progress switch saves independently of the module mode");
            await window.NavigateAsync("overview");
            Check(engine.LatestSnapshot?.QuotaDashboard?.Providers.Count == 0
                && !Descendants(window).OfType<TextBlock>().Any(value => value.Text == ui.Text("provider.none_enabled")),
                "An enabled task module appears in Overview without a quota card");
            Invoke(Find<Button>(window, "settings.overview.details.workbuddy"));
            await PresentationWait.UntilAsync(() => ModuleSwitch() is { IsEnabled: true, IsChecked: true }, "The Overview detail link opens WorkBuddy settings");
            progress = Find<CheckBox>(window, id + ".progress");
            Check(progress.IsChecked == false, "The progress choice survives navigation");
            Toggle(progress);
            await PresentationWait.UntilAsync(() => progress.IsEnabled && progress.IsChecked == true && session.Current.DisabledHarnessProgress.Length == 0,
                "Turning progress back on removes its module from the off list");
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
    /// The pointer finds an app's buttons by their names through UI Automation:
    /// a window of this process stands in for WorkBuddy's custom connectors.
    private static async Task CheckAppAutomation()
    {
        var custom = new Button { Content = "自定义连接器", Width = 160, Height = 36, HorizontalAlignment = HorizontalAlignment.Right };
        var trust = new Button { Content = "信任", Width = 80, Height = 32, HorizontalAlignment = HorizontalAlignment.Right };
        var other = new Button { Content = "信任", Width = 80, Height = 32, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 160, 0, 0) };
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(custom);
        var row = new DockPanel { Margin = new Thickness(0, 30, 0, 0) }; DockPanel.SetDock(trust, Dock.Right); row.Children.Add(trust); row.Children.Add(new TextBlock { Text = "pacer_progress" });
        panel.Children.Add(row); panel.Children.Add(other);
        var window = new Window { Width = 1400, Height = 1000, Left = 0, Top = 0, ShowActivated = false, ShowInTaskbar = false, Content = panel, Title = "Connector fixture" };
        try
        {
            window.Show(); await Pump();
            int[] self = [Environment.ProcessId];
            var (view, customRect, trustRect) = await Task.Run(() =>
            {
                var found = AppAutomation.MainWindow(self);
                return found == null ? (null, null, null) : (AppAutomation.View(found), AppAutomation.Target(found, "customConnector"), AppAutomation.Target(found, "trust"));
            });
            Point Screen(FrameworkElement element) => element.PointToScreen(new Point(element.ActualWidth / 2, element.ActualHeight / 2));
            bool Over(Rect? rect, FrameworkElement element) => rect is { } value && value.Contains(Screen(element));
            Check(view == "customConnectors", "Pacer's tool on the page means the custom connectors show");
            Check(Over(customRect, custom), "The pointer finds Custom Connector by its name");
            Check(Over(trustRect, trust) && !Over(trustRect, other), "The pointer picks the Trust button beside Pacer's tool");
            // Measured on WorkBuddy 5.9.3 at 150%: a 2172-wide window at 1326,114 had the button at 3247,183, 204 by 48.
            var estimate = AppAutomation.FromFrame(new Rect(1326, 114, 2172, 1356), 1.5);
            Check(Math.Abs(estimate.X - 3247) < 2 && Math.Abs(estimate.Y - 183) < 2 && Math.Abs(estimate.Width - 204) < 1 && Math.Abs(estimate.Height - 48) < 1,
                "Without the window's contents, the ring goes where WorkBuddy draws Custom Connector");
        }
        finally { window.Close(); }
    }

    /// Core words each stage; the page draws the steps with one picture and one
    /// action for the current click, one line for a problem, and only the chip once ready.
    private static void CheckProgressGuide(SettingsWindow window, string id)
    {
        static HarnessProgressGuide Guide(string stage, string tone, HarnessProgressStep[] steps, string? line, string? action, bool waiting, string? picture) =>
            new(stage, stage + " chip", tone, steps, line, action, action == null ? null : stage + " action", action != null, action == null ? null : "summary",
                waiting, "Why and how", Picture: picture);
        bool Shown(string field) => Descendants(window).OfType<FrameworkElement>().Any(value => AutomationProperties.GetAutomationId(value) == id + "." + field && value.Visibility == Visibility.Visible);
        var body = Find<StackPanel>(window, id + ".progress_guide");
        HarnessProgressStep[] Steps(int current) => Enumerable.Range(0, 6).Select(index => new HarnessProgressStep("Step " + index,
            index < current ? "done" : index == current ? "current" : "pending")).ToArray();
        window.RefreshHarnessProgressGuide("workbuddy", Guide("customConnector", "attention", Steps(3), null, "point", true, "customConnector"), true);
        Check(body.Visibility == Visibility.Visible && Find<Border>(window, id + ".progress_chip").Visibility == Visibility.Visible
            && AutomationProperties.GetName(Find<Border>(window, id + ".progress_chip")) == "customConnector chip"
            && Shown("progress_step0") && Shown("progress_step5") && Find<Button>(window, id + ".progress_action").Content as string == "customConnector action"
            && Shown("progress_waiting") && Descendants(body).OfType<DecorativeBorder>().Count() == 1,
            "Each click in the app is its own step, with one picture and one action under it");
        Check(Descendants(Find<Grid>(window, id + ".progress_step3")).OfType<DecorativeBorder>().Count() == 1,
            "The picture belongs to the current step only");
        Check(!Descendants(body).OfType<TextBlock>().Any(text => text.Text == "Why and how"), "The explanation stays behind the ⓘ");
        window.RefreshHarnessProgressGuide("workbuddy", Guide("trust", "attention", Steps(4), null, "point", true, "trust"), true);
        Check(Descendants(Find<Grid>(window, id + ".progress_step4")).OfType<DecorativeBorder>().Count() == 1
            && Descendants(body).OfType<DecorativeBorder>().Count() == 1, "The trust step swaps in its own picture");
        window.RefreshHarnessProgressGuide("workbuddy", Guide("turnedOff", "attention", [], "Turn it back on.", "openConnectors", true, null), true);
        Check(Find<TextBlock>(window, id + ".progress_line").Text == "Turn it back on." && !Shown("progress_step0") && Shown("progress_action")
            && !Descendants(body).OfType<DecorativeBorder>().Any(), "A problem is one line and its action");
        window.RefreshHarnessProgressGuide("workbuddy", Guide("ready", "success", [], null, null, false, null), true);
        Check(body.Visibility == Visibility.Collapsed && AutomationProperties.GetName(Find<Border>(window, id + ".progress_chip")) == "✓ ready chip",
            "Once ready, the card folds to the row and its chip");
        window.RefreshHarnessProgressGuide("workbuddy", null, true);
        Check(Find<Border>(window, id + ".progress_chip").Visibility == Visibility.Collapsed, "Without a guide the row is only the switch");
    }
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
