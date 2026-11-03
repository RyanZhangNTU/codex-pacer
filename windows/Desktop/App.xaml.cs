using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace CodexPacer.Windows;

public partial class App : Application
{
    private Mutex? instance;
    private WindowsInstanceActivation? instanceActivation;
    private EngineClient? engine;
    private DeepSeekConnectionCoordinator? webConnection;
    private ClaudeConnectionCoordinator? claudeConnection;
    private Forms.NotifyIcon? tray;
    private System.Drawing.Icon? trayIcon;
    private IslandWindow? island;
    private bool quitting;
    private DesktopPreferences preferences = new();
    private PreferencesStore? preferencesStore;
    private PreferencesSession? settingsSession;
    private NotificationSession? notifications;
    private NotificationActions? notificationActions;
    private readonly CancellationTokenSource notificationLifetime = new();
    private SettingsWindow? settings;
    private IStartupRegistration? startupRegistration;
    private UiText? ui;
    private bool demo;
    private string? demoPreferencesFile;
    private Guid? demoPreferencesScope;
    private bool? demoDark;
    private string engineExecutable = "";
    private readonly TaskCompletionSource engineReady = new(TaskCreationOptions.RunContinuationsAsynchronously);

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args is ["--uninstall-notifications"])
        {
            try { _ = WindowsInstallationIdentity.ForApp(AppContext.BaseDirectory); Shutdown(await WindowsNotificationCleanup.UninstallAsync() ? 0 : 1); }
            catch { Shutdown(1); }
            return;
        }
        if (e.Args is ["--qa-register-notifications"])
        {
            try
            {
                var identity = WindowsInstallationIdentity.ForApp(AppContext.BaseDirectory);
                if (identity.QaScope == null) { Shutdown(2); return; }
                using var probe = new WindowsSystemNotifications(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"), identity.DisplayName, suppressDisplay: true);
                var availability = await probe.EnableAsync().WaitAsync(TimeSpan.FromSeconds(10));
                Shutdown(availability is NotificationAvailability.Failed or NotificationAvailability.Unsupported ? 1 : 0);
            }
            catch { Shutdown(1); }
            return;
        }
        demo = e.Args.Contains("--demo");
        int themeIndex = Array.IndexOf(e.Args, "--theme");
        if (themeIndex >= 0)
        {
            if (!demo || themeIndex + 1 >= e.Args.Length || e.Args[themeIndex + 1] is not ("light" or "dark"))
                throw new ArgumentException("Theme previews require demo mode and light or dark.");
            demoDark = e.Args[themeIndex + 1] == "dark";
        }

        int restartIndex = Array.IndexOf(e.Args, "--restart-from");
        if (restartIndex >= 0)
        {
            if (restartIndex + 1 >= e.Args.Length || !int.TryParse(e.Args[restartIndex + 1], out int parent) || parent <= 0 || parent == Environment.ProcessId)
                throw new ArgumentException("Invalid relaunch process.");
            try
            {
                using var previous = Process.GetProcessById(parent);
                await previous.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            }
            catch (ArgumentException) { /* The previous app already exited. */ }
            catch (TimeoutException) { Shutdown(); return; }
        }
        bool referenceFixture = e.Args.Contains("--reference-fixture");
        if (referenceFixture && !demo) throw new ArgumentException("Reference fixtures require demo mode.");
        // Bitmap-only reference exports cannot sample another native HWND.
        // Material acceptance uses protected desktop captures in BackdropTests.
        if (referenceFixture) preferences = preferences with { IslandAppearance = "classic" };
        int quotaStyleIndex = Array.IndexOf(e.Args, "--expanded-quota-style");
        if (quotaStyleIndex >= 0)
        {
            if (!demo || quotaStyleIndex + 1 >= e.Args.Length || e.Args[quotaStyleIndex + 1] is not ("split" or "classic"))
                throw new ArgumentException("Quota style fixtures require demo mode and a supported style.");
            preferences = preferences with { ExpandedQuotaStyle = e.Args[quotaStyleIndex + 1] };
        }
        int providersIndex = Array.IndexOf(e.Args, "--demo-providers");
        if (providersIndex >= 0)
        {
            if (!demo || providersIndex + 1 >= e.Args.Length) throw new ArgumentException("Provider fixtures require demo mode.");
            string[] providers = e.Args[providersIndex + 1] == "all" ? ["codex", "claude", "deepseek"] : e.Args[providersIndex + 1].Split(',');
            if (providers.Length is < 1 or > 3 || providers.Distinct().Count() != providers.Length || providers.Any(value => value is not ("codex" or "claude" or "deepseek")))
                throw new ArgumentException("Unknown demo providers.");
            preferences = preferences with { ProviderModes = preferences.ProviderModes.ToDictionary(pair => pair.Key, pair => providers.Contains(pair.Key) ? "enabled" : "disabled") };
        }
        string[] positions = ["center", "topLeft", "bottomLeft", "topRight", "bottomRight"];
        int position = 0, positionIndex = Array.IndexOf(e.Args, "--position");
        if (positionIndex >= 0)
        {
            position = positionIndex + 1 < e.Args.Length ? Array.IndexOf(positions, e.Args[positionIndex + 1]) : -1;
            if (position < 0) throw new ArgumentException("Unknown island position.");
        }
        int stage = 0, stageIndex = Array.IndexOf(e.Args, "--stage");
        if (stageIndex >= 0 && (!demo || stageIndex + 1 >= e.Args.Length || !int.TryParse(e.Args[stageIndex + 1], out stage) || stage < 0 || stage > 3))
            throw new ArgumentException("Demo stage must be between zero and three.");
        int capture = Array.IndexOf(e.Args, "--capture-preview");
        bool captureSettings = e.Args.Contains("--settings-preview");
        if (captureSettings && (!demo || capture < 0)) throw new ArgumentException("Settings capture requires a demo preview destination.");
        int paneIndex = Array.IndexOf(e.Args, "--settings-pane");
        if (paneIndex >= 0)
        {
            if (!demo || !captureSettings || paneIndex + 1 >= e.Args.Length || e.Args[paneIndex + 1] is not ("general" or "appearance" or "collapsed" or "codex" or "claude" or "deepseek" or "reminders"))
                throw new ArgumentException("Settings pane fixtures require a supported demo preview.");
            preferences = preferences with { LastSettingsPane = e.Args[paneIndex + 1] };
        }
        if (capture >= 0 && (!demo || capture + 1 >= e.Args.Length || !Path.IsPathFullyQualified(e.Args[capture + 1])))
            throw new ArgumentException("Preview capture requires demo mode and an absolute output path.");
        Guid? activationQa = null;
        int activationQaIndex = Array.IndexOf(e.Args, "--activation-qa");
        if (activationQaIndex >= 0)
        {
            if (!demo || !referenceFixture || activationQaIndex + 1 >= e.Args.Length || !Guid.TryParse(e.Args[activationQaIndex + 1], out var scope))
                throw new ArgumentException("Instance fixtures require demo mode, reference inputs and a unique scope.");
            activationQa = scope;
        }
        if (e.Args.Contains("--hide-before-activation") && activationQa == null) throw new ArgumentException("Hidden activation fixtures require an isolated demo scope.");
        int activationStartupDelay = 0, activationDelayIndex = Array.IndexOf(e.Args, "--activation-startup-delay");
        if (activationDelayIndex >= 0 && (activationQa == null || capture < 0 || activationDelayIndex + 1 >= e.Args.Length ||
            !int.TryParse(e.Args[activationDelayIndex + 1], out activationStartupDelay) || activationStartupDelay is < 0 or > 5000))
            throw new ArgumentException("Startup delays require an isolated first-instance capture and at most five seconds.");
        string instanceName = "Local\\CodexPacer.Windows" + (activationQa is Guid fixtureScope ? ".QA." + fixtureScope.ToString("N") : capture >= 0 ? ".Preview." + Environment.ProcessId : "");
        instance = new Mutex(true, instanceName, out bool created);
        if (!created)
        {
            if (e.Args.Contains("----AppNotificationActivated:"))
            {
                // COM can race the first process's HWND/registration. Let the
                // SDK deliver its opaque ref, then forward it for validation.
                using var pendingNotification = new WindowsSystemNotifications(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"));
                var forwarded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                pendingNotification.Activated += arguments => forwarded.TrySetResult(WindowsInstanceActivation.TryActivateNotification(arguments));
                await pendingNotification.EnableAsync();
                bool delivered = false;
                try { delivered = await forwarded.Task.WaitAsync(TimeSpan.FromSeconds(10)); } catch (TimeoutException) { }
                instance.Dispose(); Shutdown(delivered ? 0 : 1); return;
            }
            bool sent = WindowsInstanceActivation.TryActivate(e.Args.Contains("--settings") ? InstanceAction.Settings : InstanceAction.Show, activationQa);
            if (!sent && activationQa == null)
                MessageBox.Show(UiText.For(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh").Text("windows.instance.already_running"), "Codex Pacer", MessageBoxButton.OK, MessageBoxImage.Information);
            instance.Dispose(); Shutdown(sent ? 0 : 1); return;
        }
        if (activationStartupDelay > 0) await Task.Delay(activationStartupDelay);
        var activationForCapture = new TaskCompletionSource<InstanceAction>(TaskCreationOptions.RunContinuationsAsynchronously);
        bool preferencesUnavailable = false;
        int preferencesQaIndex = Array.IndexOf(e.Args, "--demo-preferences");
        if (preferencesQaIndex >= 0)
        {
            if (!demo || !referenceFixture || (activationQa == null && capture < 0) || preferencesQaIndex + 1 >= e.Args.Length
                || !Path.IsPathFullyQualified(e.Args[preferencesQaIndex + 1])) throw new ArgumentException("Persistent demo preferences require an isolated reference fixture.");
            demoPreferencesFile = Path.GetFullPath(e.Args[preferencesQaIndex + 1]);
            if (string.Equals(demoPreferencesFile, PreferencesStore.DefaultFile, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("A demo cannot use production preferences.");
            demoPreferencesScope = activationQa;
        }
        if (!demo || demoPreferencesFile != null)
        {
            preferencesStore = new PreferencesStore(demoPreferencesFile);
            (preferences, preferencesUnavailable) = preferencesStore.Load();
            if (positionIndex < 0) position = Array.IndexOf(positions, preferences.Position);
        }
        string language = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh-Hans" : "en";
        if (preferencesStore != null && preferences.Language != "system") language = preferences.Language;
        int languageIndex = Array.IndexOf(e.Args, "--language");
        if (languageIndex >= 0 && languageIndex + 1 < e.Args.Length && e.Args[languageIndex + 1] is "en" or "zh-Hans") language = e.Args[languageIndex + 1];
        ui = UiText.For(language == "zh-Hans");
        engine = new EngineClient();
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        ShellProjection.Client = engine;
        webConnection = new DeepSeekConnectionCoordinator(engine, demo ? new OfflineDeepSeekWebSession() : new DeepSeekWebSession(ui),
            Dispatcher, bridgeEnabled: !demo);
        claudeConnection = new ClaudeConnectionCoordinator(engine, demo ? new OfflineClaudeWebSession() : new ClaudeWebSession(ui),
            Dispatcher, bridgeEnabled: !demo, newSession: async () => settingsSession != null &&
                await settingsSession.ChangeAsync(value => value with { ClaudeOrganization = "" }) == PreferencesApplyResult.Applied);
        Activated += async (_, _) =>
        {
            if (quitting || !engineReady.Task.IsCompletedSuccessfully) return;
            try { await webConnection.StartAsync(); await claudeConnection.StartAsync(); }
            catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (!quitting) island?.SetStatus(ui.Text("windows.connection.refresh_failed")); }
        };
        var applications = demo ? new WindowsDesktopApplications(_ => true, _ => true) : new WindowsDesktopApplications();
        island = new IslandWindow(engine, demo, language == "zh-Hans", position, desktopApplications: applications,
            displayMode: positionIndex >= 0 ? 2 : Array.IndexOf(new[] { "automatic", "notch", "floating" }, preferences.DisplayMode),
            canConnectDeepSeekWeb: () => webConnection.Available);
        if (capture < 0 || activationQa != null)
            instanceActivation = new WindowsInstanceActivation(island, action =>
            {
                if (quitting) return;
                bool wasVisible = island.IsVisible, wasExpanded = island.LogicalTarget.Height > 38;
                if (action == InstanceAction.Settings) OpenSettings();
                else { island.Reveal(); island.Activate(); }
                if (activationQa != null && capture >= 0)
                {
                    File.WriteAllText(Path.ChangeExtension(e.Args[capture + 1], ".activation.json"), System.Text.Json.JsonSerializer.Serialize(new {
                        schemaVersion = 1, syntheticOnly = true, receiver = Environment.ProcessId, action = action.ToString(),
                        wasVisible, wasExpanded, visible = island.IsVisible, expanded = island.LogicalTarget.Height > 38,
                        settingsVisible = settings?.IsVisible == true }));
                    activationForCapture.TrySetResult(action);
                }
            }, activationQa, Quit, arguments => { if (!quitting && notifications?.DesiredEnabled == true) _ = notificationActions?.HandleReferenceAsync(arguments); });
        if (activationQa != null && capture >= 0) { island.IsHitTestVisible = false; island.ShowActivated = false; }
        try { startupRegistration = demo ? new DemoStartupRegistration() : WindowsInstallationIdentity.ForApp(AppContext.BaseDirectory).Startup(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or ArgumentException)
        { startupRegistration = new UnavailableStartupRegistration(); }
        settingsSession = new PreferencesSession(preferences, async configuration =>
        {
            await engineReady.Task;
            await engine.SendAsync("configure", configuration);
        }, value => preferencesStore?.Save(value) ?? demo, async value =>
        {
            await engineReady.Task.WaitAsync(TimeSpan.FromSeconds(15));
            return await PreferencesAcknowledgement.ValidateAsync(engine, value);
        });
        notificationActions = new NotificationActions(engineReady.Task, () => quitting || settingsSession.Current.SystemNotifications != true, island.Reveal,
            () => engine.SendAsync("snoozeDeepSeekSpike"), OpenNotificationLink, notificationLifetime.Token, () => applications.Open("deepseek"),
            (kind, reference) => engine.QueryAsync<EngineNotificationActivation>("activateNotification", new { context = reference, notificationAction = kind }),
            async link =>
            {
                var plan = await engine.QueryAsync<EngineNavigationPlan>("prepareActivityOpen", new { context = link.Context });
                if (quitting || !settingsSession.Current.SystemNotifications || plan.Context != link.Context || plan.Provider != link.Provider || !await applications.OpenConversationAsync(plan)) return false;
                await engine.SendAsync("completeActivityOpen", new { context = link.Context }); return true;
            });
        notifications = new NotificationSession(settingsSession,
            demo ? new DemoSystemNotifications() : new WindowsSystemNotifications(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico")),
            action => Dispatcher.InvokeAsync(action), action => _ = notificationActions.HandleReferenceAsync(action), demo, () => applications.CanOpenHarness);
        engine.Snapshot += notifications.Receive;
        await notifications.RefreshAsync();
        int? launchPosition = positionIndex >= 0 ? position : null;
        settingsSession.Changed += value =>
        {
            if (value.Position != preferences.Position || value.DisplayMode != preferences.DisplayMode) launchPosition = null;
            preferences = value;
            island.ApplyPreferences(launchPosition is int forced ? value with { Position = positions[forced], DisplayMode = "floating" } : value);
        };
        island.ApplyPreferences(positionIndex >= 0 ? preferences with { Position = positions[position], DisplayMode = "floating" } : preferences);
        MainWindow = island;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(ui.Text("windows.show_island"), null, (_, _) => Dispatcher.Invoke(island.Reveal));
        menu.Items.Add(ui.Text("common.settings"), null, (_, _) => Dispatcher.Invoke(OpenSettings));
        menu.Items.Add(ui.Text("common.quit"), null, (_, _) => Dispatcher.Invoke(Quit));
        trayIcon = new System.Drawing.Icon(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"), 32, 32);
        tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "Codex Pacer", ContextMenuStrip = menu, Visible = capture < 0 };
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(island.Reveal);
        island.QuitRequested += Quit;
        island.SettingsRequested += OpenSettings;
        island.ProviderSettingsRequested += OpenProviderSettings;
        island.DeepSeekWebSignInRequested += async context =>
        {
            try { if (webConnection != null) await webConnection.ConnectAsync(context); }
            catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (!quitting) island.SetStatus(ui.Text("windows.connection.refresh_failed")); }
        };
        island.Show();
        if (activationQa != null && e.Args.Contains("--hide-before-activation")) island.Hide();
        if (capture < 0 && e.Args.Contains("--settings")) OpenSettings();
        string executable = Path.Combine(AppContext.BaseDirectory, "Engine", "PacerEngine.exe");
        int index = Array.IndexOf(e.Args, "--engine");
        if (index >= 0 && index + 1 < e.Args.Length) executable = e.Args[index + 1];
        engineExecutable = executable;
        try
        {
            string? runtimeRoot = null;
            if (!demo)
                try { runtimeRoot = Path.Combine(WindowsInstallationIdentity.ForApp(AppContext.BaseDirectory).DataRoot, "ClaudeRuntime"); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
            await engine.StartAsync(executable, demo, language, configuration: preferences.EngineConfiguration(), referenceFixture: referenceFixture, claudeRuntimeRoot: runtimeRoot);
            ShellProjection.Ready();
            engineReady.TrySetResult();
            await webConnection.StartAsync();
            await claudeConnection.StartAsync();
            await island.SynchronizeExpansionAsync();
            if (preferencesUnavailable) island.SetStatus(ui.Text("windows.settings.read_failed"));
            if (demo && stage != 0) await engine.SendAsync("demoStage", new { demoStage = stage });
            if (demo && !e.Args.Contains("--collapsed")) island.Reveal();
            if (capture < 0 && !preferencesUnavailable) await BeginGuidesAsync(e.Args);
            if (capture >= 0)
            {
                if (activationQa != null)
                {
                    var action = await activationForCapture.Task.WaitAsync(TimeSpan.FromSeconds(15));
                    if (action == InstanceAction.Settings) captureSettings = true;
                    else { island.Reveal(); await island.SynchronizeExpansionAsync(); }
                }
                if (captureSettings)
                {
                    OpenSettings(); await System.Windows.Threading.Dispatcher.Yield(System.Windows.Threading.DispatcherPriority.ContextIdle);
                    await settings!.WaitForSourceInspectionAsync();
                    settings!.CapturePreview(e.Args[capture + 1]);
                }
                else
                {
                    await island.WaitForPresentationAsync();
                    island.CapturePreview(e.Args[capture + 1]);
                }
                Quit();
            }
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or System.ComponentModel.Win32Exception)
        {
            engineReady.TrySetException(new IOException("Engine initialization failed."));
            island.SetStatus(ui.Text("windows.engine.start_failed"));
        }
    }

    private void OpenSettings()
    {
        if (quitting || settingsSession == null || startupRegistration == null || ui == null) return;
        island?.DismissForSettings();
        if (settings == null)
        {
            settings = new SettingsWindow(ui, settingsSession, startupRegistration, demo, darkOverride: demoDark, engine: engine, sourceReady: engineReady.Task, notifications: notifications,
                webConnection: webConnection, claudeConnection: claudeConnection, surfaceWindow: island, preferencesStore: preferencesStore);
            settings.QuitRequested += Quit; settings.RestartRequested += Restart;
            settings.WelcomeRequested += () => _ = ShowGuideAsync(true);
            settings.Closed += (_, _) => settings = null;
        }
        settings.Show(); settings.Activate();
    }

    private async void OpenProviderSettings(string provider)
    {
        if (provider is not ("codex" or "claude" or "deepseek")) return;
        OpenSettings();
        if (settings != null) await settings.NavigateAsync(provider);
    }

    private bool OpenNotificationLink(Uri uri)
    {
        try { using var process = Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); return true; }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { OpenProviderSettings("deepseek"); return false; }
    }

    private async void Restart()
    {
        if (quitting || settingsSession == null || ui == null) return;
        await settingsSession.WaitForChangesAsync();
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, WorkingDirectory = AppContext.BaseDirectory };
        start.ArgumentList.Add("--restart-from"); start.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        start.ArgumentList.Add("--engine"); start.ArgumentList.Add(engineExecutable);
        if (demo)
        {
            start.ArgumentList.Add("--demo"); start.ArgumentList.Add("--language");
            start.ArgumentList.Add(preferences.Language == "system" ? (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh-Hans" : "en") : preferences.Language);
        }
        if (demoPreferencesFile != null)
        {
            start.ArgumentList.Add("--reference-fixture"); start.ArgumentList.Add("--demo-preferences"); start.ArgumentList.Add(demoPreferencesFile);
            if (demoPreferencesScope is Guid scope) { start.ArgumentList.Add("--activation-qa"); start.ArgumentList.Add(scope.ToString("D")); }
            if (demoDark is bool dark) { start.ArgumentList.Add("--theme"); start.ArgumentList.Add(dark ? "dark" : "light"); }
        }
        try
        {
            using var next = Process.Start(start) ?? throw new IOException("The relaunch process could not start.");
            Quit();
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or InvalidOperationException)
        { island?.SetStatus(ui.Text("windows.restart_failed")); }
    }

    private async void Quit()
    {
        if (quitting) return;
        quitting = true;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        instanceActivation?.Dispose();
        notificationLifetime.Cancel();
        guideWindow?.Close();
        if (settingsSession != null) await settingsSession.WaitForChangesAsync();
        if (settings != null) { settings.AllowClose = true; settings.Close(); }
        if (webConnection != null) await webConnection.DisposeAsync();
        if (claudeConnection != null) await claudeConnection.DisposeAsync();
        island?.StopPresentation();
        if (engine != null && notifications != null) engine.Snapshot -= notifications.Receive;
        notifications?.Dispose();
        notificationLifetime.Dispose();
        if (engine != null) await engine.DisposeAsync();
        tray?.Dispose();
        trayIcon?.Dispose();
        if (island != null) island.AllowClose = true;
        instance?.Dispose();
        Shutdown();
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs change)
    {
        string? method = change.Mode switch { PowerModes.Suspend => "prepareForSleep", PowerModes.Resume => "resumeAfterSleep", _ => null };
        if (method == null) return;
        Dispatcher.BeginInvoke(new Action(async () =>
        {
            if (quitting || !engineReady.Task.IsCompletedSuccessfully || engine == null) return;
            try { await engine.SendAsync(method); }
            catch (Exception error) when (DeepSeekLoginWindow.Recoverable(error) || error is EngineCommandException)
            { if (!quitting && ui != null) island?.SetStatus(ui.Text("windows.connection.refresh_failed")); }
        }));
    }
}
