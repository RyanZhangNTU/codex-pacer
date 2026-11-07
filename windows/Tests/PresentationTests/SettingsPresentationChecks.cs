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
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class SettingsPresentationChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        CultureInfo previousCulture = CultureInfo.CurrentUICulture;
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
        await using var engine = new EngineClient();
        EngineSnapshot? latest = null;
        engine.Snapshot += value => latest = value;
        var saved = new List<DesktopPreferences>(); bool rejectSave = false;
        int configureCalls = 0;
        var session = new PreferencesSession(new(), async value => { configureCalls++; await engine.SendAsync("configure", value); }, value =>
        {
            if (rejectSave) { rejectSave = false; return false; }
            saved.Add(value); return true;
        });
        var startup = new StartupFixture(); UiText ui = UiText.For(language == "zh-Hans");
        var window = new SettingsWindow(ui, session, startup, true, dark, engine) { ShowActivated = false, IsHitTestVisible = false };
        string scenario = language + (dark ? "-dark" : "-light");
        int restartRequests = 0, quitRequests = 0;
        window.RestartRequested += () => restartRequests++; window.QuitRequested += () => quitRequests++;
        try
        {
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle); window.UpdateLayout();
            Check(WindowRendering.Mode(window) == "SoftwareOnly", "Opaque Settings must use software rendering in multi-adapter and virtual-display sessions");
            TypographyChecks.Check(window.FontFamily, FontWeights.Normal);
            Check(Math.Abs(window.ClientContent.ActualWidth - SettingsWindow.DefaultWidth) < 0.5
                && Math.Abs(window.ClientContent.ActualHeight - SettingsWindow.DefaultHeight) < 0.5, "The main window opens at the Mac's default size");
            Check(window.ResizeMode == ResizeMode.CanResize && window.MinWidth >= SettingsWindow.MinimumWidth && window.MinHeight >= SettingsWindow.MinimumHeight,
                "The main window resizes down to the Mac's minimum client size");
            Check(Find<RadioButton>(window, "settings.pane.overview").IsChecked == true && Find<RadioButton>(window, "settings.pane.history").IsEnabled,
                "The main window opens on Overview, with History beside it, as on the Mac");
            await window.NavigateAsync("about"); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(window.Title == ui.Text("menu.settings_title"), "The system window title must use the shared catalog");
            var update = Find<Button>(window, "settings.update.check");
            var automatic = Find<CheckBox>(window, "settings.update.automatic");
            Check(!update.IsEnabled && !automatic.IsEnabled, "The preview cannot expose unimplemented update actions");
            Check(Find<TextBlock>(window, "settings.about.version").Text.Length > 0, "Help & Updates shows the installed version in the sidebar");
            // A check started from Help & Updates reports in its card, as on the Mac.
            Check(window.ShowsUpdatesInline, "Help & Updates takes over update reports while it shows");
            window.InlineUpdate("checking"); Check(Find<TextBlock>(window, "settings.update.status").Text == ui.Text("updates.checking"), "Checking shows in the card");
            window.InlineUpdate("upToDate"); Check(Find<TextBlock>(window, "settings.update.status").Text == ui.Text("main.update.up_to_date"), "An up-to-date result shows in the card");
            window.InlineUpdate("failed"); Check(Find<TextBlock>(window, "settings.update.status").Text == ui.Text("windows.updates.failed")
                && !Find<ProgressBar>(window, "settings.update.progress").IsVisible, "A failure shows in the card without a stale progress bar");
            window.InlineUpdate("offer");
            await window.NavigateAsync("general"); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            // Opening Help & Updates and returning to General each saved the page.
            int navigationSaves = saved.Count;
            Check(Find<RadioButton>(window, "settings.pane.general").IsEnabled
                && Find<RadioButton>(window, "settings.pane.appearance").IsEnabled
                && Find<RadioButton>(window, "settings.pane.notifications").IsEnabled
                && Find<RadioButton>(window, "settings.pane.remote").IsEnabled, "Implemented settings and connection panes are available");
            var search = Find<TextBox>(window, "settings.search");
            search.Text = ui.Text("main.search.remote").Split(' ')[0]; window.UpdateLayout();
            Check(window.SearchMatches().Contains("remote") && Find<Button>(window, "settings.search.result.remote").IsVisible
                && !Find<RadioButton>(window, "settings.pane.general").IsVisible, "Search lists pages by their shared search words in place of the groups");
            search.Text = ui.Text("main.pane.overview"); window.UpdateLayout();
            Check(window.SearchMatches().Contains("overview"), "Search finds a page by its own title");
            search.Text = "␀"; window.UpdateLayout();
            Check(window.SearchMatches().Count == 0 && Find<TextBlock>(window, "settings.search.empty").IsVisible, "Search says when nothing matches");
            search.Clear(); window.UpdateLayout();
            Check(Find<RadioButton>(window, "settings.pane.general").IsVisible && Find<RadioButton>(window, "settings.pane.general").IsChecked == true,
                "Clearing the search restores the grouped pages and keeps the current one");
            var privacy = Find<CheckBox>(window, "settings.hide_projects");
            var login = Find<CheckBox>(window, "settings.startup");
            Check(privacy.ActualWidth == 36 && privacy.ActualHeight == 18 && privacy.IsChecked == false && session.Current.ShowAppButtons,
                "Switch geometry and defaults must match the source preferences");
            string screenshot = Path.Combine(output, "settings-" + scenario + "-general.png");
            window.CapturePreview(screenshot); CheckOpaque(screenshot, window);

            Toggle(login); Check(startup.Enabled && startup.Calls == 1, "Accessible login toggles must reach only the injected startup service");
            foreach (var blocked in new[] { (StartupBlockReason.Disabled, "windows.settings.startup_disabled"),
                (StartupBlockReason.Policy, "windows.settings.startup_policy"), (StartupBlockReason.Unknown, "windows.settings.startup_unknown") })
            {
                startup.BlockReason = blocked.Item1; window.RefreshSystemState();
                var status = Find<TextBlock>(window, "settings.startup.status");
                Check(login.IsChecked == true && status.Text == ui.Text(blocked.Item2) &&
                    new TextBlockAutomationPeer(status).GetName() == status.Text,
                    "A registered but blocked entry must stay requested and expose its actual OS state accessibly");
            }
            var startupSettings = Find<Button>(window, "settings.startup.settings");
            startup.RejectOpen = true; Invoke(startupSettings);
            await Until(() => startup.OpenCalls == 1, "The system settings entry must use the injected launcher");
            Check(Find<TextBlock>(window, "settings.issue").Text == ui.Text("windows.settings.startup_settings_failed") && login.IsChecked == true,
                "Opening Windows Settings can fail without changing the startup choice");
            startup.RejectOpen = false; Invoke(startupSettings);
            await Until(() => startup.OpenCalls == 2, "The system settings entry must remain usable after failure");
            startup.BlockReason = StartupBlockReason.None; window.RefreshSystemState();
            startup.RejectNext = true; Toggle(login);
            Check(startup.Enabled && login.IsChecked == true && startup.Calls == 2, "Rejected startup changes must restore the switch");
            Toggle(privacy);
            await Until(() => session.Current.HideProjects && privacy.IsEnabled, "Accessible privacy changes must await the real engine acknowledgement");
            Check(latest?.Tasks.Count > 0 && latest.Tasks.All(value => value.Title == (language == "en" ? "Local task" : "本地任务")),
                "The settings switch must redact names before they cross the engine protocol");
            // App buttons moved to Appearance's expanded panel, as on the Mac.
            await window.NavigateAsync("appearance"); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var apps = Find<CheckBox>(window, "settings.app_buttons");
            Check(apps.IsChecked == true, "App buttons default on under Appearance");
            Toggle(apps);
            await Until(() => !session.Current.ShowAppButtons && apps.IsEnabled, "App button choices must commit immediately");
            await window.NavigateAsync("general"); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            navigationSaves += 2;
            // Returning rebuilt General, so its switches are new controls.
            privacy = Find<CheckBox>(window, "settings.hide_projects"); login = Find<CheckBox>(window, "settings.startup");
            Check(configureCalls == 1, "Host-only choices cannot restart or reconfigure data collectors");

            var picker = Find<ComboBox>(window, "settings.language");
            var pickerPeer = (ComboBoxAutomationPeer)UIElementAutomationPeer.CreatePeerForElement(picker);
            var expand = (IExpandCollapseProvider)pickerPeer.GetPattern(PatternInterface.ExpandCollapse);
            expand.Expand(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(picker.IsDropDownOpen, "The custom language selector must expose its native expand pattern");
            Escape(window); Check(window.IsVisible, "Escape belongs to an open selector before the settings window");
            string alternate = language == "en" ? "zh-Hans" : "en";
            var choice = picker.Items.OfType<ComboBoxItem>().Single(item => (string)item.Tag == alternate);
            var choicePeer = pickerPeer.GetChildren().Single(peer => peer.GetName() == (string)choice.Content);
            Check(choicePeer.GetPattern(PatternInterface.SelectionItem) is ISelectionItemProvider, "Language items must expose selection through the real ComboBox accessibility tree");
            ((ISelectionItemProvider)choicePeer.GetPattern(PatternInterface.SelectionItem)).Select();
            await Until(() => session.Current.Language == alternate && picker.IsEnabled, "Accessible language selection must persist without replacing the running UI language");
            expand.Collapse();
            var restart = Find<Button>(window, "settings.restart");
            Check(restart.IsVisible && window.Title == ui.Text("menu.settings_title") && configureCalls == 1,
                "Changing language must offer restart and preserve the current UI and engine language until restart");
            Invoke(restart); await Until(() => restartRequests == 1, "The restart action must reach the application lifecycle owner");

            rejectSave = true; Toggle(privacy);
            await Until(() => configureCalls >= 3 && privacy.IsEnabled, "A failed disk write must finish its engine rollback");
            Check(session.Current.HideProjects && privacy.IsChecked == true && latest!.Tasks.All(value => value.Title == (language == "en" ? "Local task" : "本地任务"))
                && saved.Count == navigationSaves + 3, "A failed save must leave both visible privacy state and persisted choices at their previous values");
            Select(Find<RadioButton>(window, "settings.pane.appearance"));
            await Until(() => session.Current.LastSettingsPane == "appearance" && Find<RadioButton>(window, "appearance.mode.notch").IsEnabled,
                "Appearance navigation must persist and expose the real position controls");
            Check(Find<RadioButton>(window, "appearance.style.liquidGlass").IsEnabled == (Environment.OSVersion.Version.Build >= 22621)
                && Find<ComboBox>(window, "appearance.display").IsEnabled && Find<CheckBox>(window, "appearance.fullscreen").IsEnabled,
                "Glass availability follows the OS minimum while display and fullscreen controls are available");
            var solidSurface = Find<RadioButton>(window, "appearance.style.classic");
            Select(solidSurface); await Until(() => session.Current.IslandAppearance == "classic" && solidSurface.IsEnabled,
                "Classic surface selection persists through its accessible radio control");
            Check(configureCalls == 3 && Find<TextBlock>(window, "appearance.status").Text == ui.Text("windows.appearance.surface_classic"),
                "Surface selection shows its effective state without reconfiguring collectors");
            if (Environment.OSVersion.Version.Build >= 22621)
            {
                var glassSurface = Find<RadioButton>(window, "appearance.style.liquidGlass");
                Select(glassSurface); await Until(() => session.Current.IslandAppearance == "liquidGlass" && glassSurface.IsEnabled,
                    "Liquid Glass can be restored through the same preference");
                rejectSave = true; Select(solidSurface);
                await Until(() => glassSurface.IsChecked == true && glassSurface.IsEnabled, "A failed surface save restores the acknowledged choice");
            }
            string appearanceImage = Path.Combine(output, "settings-" + scenario + "-appearance.png");
            window.CapturePreview(appearanceImage); CheckOpaque(appearanceImage, window);
            var classic = Find<RadioButton>(window, "appearance.quota.classic");
            Check(classic.IsEnabled, "The classic quota style must be available through the original segmented choice");
            Select(classic); await Until(() => session.Current.ExpandedQuotaStyle == "classic" && classic.IsEnabled,
                "Classic selection must save immediately without reconfiguring data sources");
            Check(configureCalls == 3, "The quota style belongs only to the desktop presentation");
            rejectSave = true; Select(Find<RadioButton>(window, "appearance.quota.split"));
            await Until(() => classic.IsChecked == true && classic.IsEnabled, "A failed quota-style save must restore the acknowledged selection");
            Select(Find<RadioButton>(window, "appearance.quota.split"));
            await Until(() => session.Current.ExpandedQuotaStyle == "split", "Split Ring must remain selectable after rollback");
            var scroller = Find<ScrollViewer>(window, "settings.content");
            var scrolling = (IScrollProvider)new ScrollViewerAutomationPeer(scroller).GetPattern(PatternInterface.Scroll);
            if (scrolling.VerticallyScrollable) scrolling.SetScrollPercent(ScrollPatternIdentifiers.NoScroll, 100);
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var fullscreen = Find<CheckBox>(window, "appearance.fullscreen");
            Check(fullscreen.TranslatePoint(new Point(0, fullscreen.ActualHeight), window.ClientContent).Y <= SettingsWindow.DefaultHeight + 0.01,
                "The overlay scroller must make the bottom setting reachable without narrowing the cards");
            if (scrolling.VerticallyScrollable) scrolling.SetScrollPercent(ScrollPatternIdentifiers.NoScroll, 0);
            Select(Find<RadioButton>(window, "appearance.mode.notch"));
            await Until(() => session.Current.DisplayMode == "notch", "The attached choice must save immediately");
            var resetPosition = Find<Button>(window, "appearance.position.reset");
            Check(!resetPosition.IsVisible, "Attached mode hides the free-position reset");
            rejectSave = true; Select(Find<RadioButton>(window, "appearance.mode.free"));
            await Until(() => Find<RadioButton>(window, "appearance.mode.notch").IsChecked == true && !rejectSave,
                "A failed mode write restores the selected appearance");
            Select(Find<RadioButton>(window, "appearance.mode.free"));
            await Until(() => session.Current.DisplayMode == "floating" && resetPosition.IsVisible && resetPosition.IsEnabled,
                "Free Move starts at the untouched center and offers a reset");
            Check(!session.Current.HasChosenPosition && session.Current.IslandPlacement == null,
                "Toggling modes does not invent a position");
            var placement = new IslandPlacement(IslandEdge.Right, 1, .62);
            await session.ChangeAsync(p => p with { IslandPlacement = placement });
            rejectSave = true; Invoke(resetPosition);
            await Until(() => !rejectSave && resetPosition.IsEnabled, "A failed position reset must settle");
            Check(session.Current.IslandPlacement == placement, "A failed reset retains the last saved placement");
            Invoke(resetPosition);
            await Until(() => session.Current.IslandPlacement == null && resetPosition.IsEnabled, "Reset returns to the untouched center");
            Check(session.Current.Position == "center" && configureCalls == 3,
                "Appearance choices and navigation cannot restart data collectors");
            Select(Find<RadioButton>(window, "settings.pane.remote"));
            await Until(() => session.Current.LastSettingsPane == "remote" && Descendants(window).OfType<FrameworkElement>().Any(value =>
                AutomationProperties.GetAutomationId(value) == "settings.connections.summary"), "Connections opens with its live summary");
            // SSH monitoring moved to Remote's SSH card, as on the Mac.
            var remoteSSH = Find<CheckBox>(window, "settings.connections.ssh");
            Check(remoteSSH.IsChecked == true, "SSH monitoring uses the shared default");
            Toggle(remoteSSH); await Until(() => !session.Current.MonitorSSH && remoteSSH.IsEnabled, "The SSH switch awaits engine acknowledgement");
            Toggle(remoteSSH); await Until(() => session.Current.MonitorSSH && remoteSSH.IsEnabled, "SSH monitoring can be enabled again");
            string connectionsImage = Path.Combine(output, "settings-" + scenario + "-connections.png");
            window.CapturePreview(connectionsImage); CheckOpaque(connectionsImage, window);
            Select(Find<RadioButton>(window, "settings.pane.appearance"));
            await Until(() => session.Current.LastSettingsPane == "appearance", "Appearance can be reopened after Connections");
            Invoke(Find<Button>(window, "settings.quit")); await Until(() => quitRequests == 1, "Quit must use the application lifecycle callback");
            Escape(window); Check(!window.IsVisible, "Escape must close a settled settings window");
            var reopened = new SettingsWindow(ui, session, startup, true, dark) { ShowActivated = false, IsHitTestVisible = false };
            try
            {
                reopened.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                Check(Find<RadioButton>(reopened, "settings.pane.appearance").IsChecked == true
                    && Find<RadioButton>(reopened, "appearance.mode.free").IsChecked == true,
                    "Reopening settings must restore the last pane and position");
            }
            finally { reopened.AllowClose = true; reopened.Close(); }
            Console.WriteLine("PASS settings " + scenario + ": General/Appearance bounds, captures, UI Automation, position rules, rollback and lifecycle actions");
        }
        catch
        {
            try { window.CapturePreview(Path.Combine(output, "failed-settings-" + scenario + ".png")); }
            catch (Exception error) { Console.WriteLine("Settings diagnostic capture unavailable: " + error.Message); }
            throw;
        }
        finally { window.AllowClose = true; window.Close(); CultureInfo.CurrentUICulture = previousCulture; }
    }
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement
        => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Toggle(CheckBox check) => ((IToggleProvider)new CheckBoxAutomationPeer(check).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Select(RadioButton choice) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(choice).GetPattern(PatternInterface.SelectionItem)).Select();
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Escape(Window window) => window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.KeyDownEvent });
    private static void CheckOpaque(string path, SettingsWindow window)
    {
        Check(File.Exists(path) && new FileInfo(path).Length > 0, "The demo export must contain an image");
        Check(window.Background is SolidColorBrush brush && brush.Color.A == 255,
            "The actual settings surface must remain opaque");
    }
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < PresentationWait.Limit) await Task.Delay(25);
        Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class StartupFixture : IStartupRegistration
    {
        internal bool Enabled, RejectNext, RejectOpen; internal int Calls, OpenCalls;
        internal StartupBlockReason BlockReason;
        public StartupRegistrationState Read() => new(Enabled, true, BlockReason);
        public bool Set(bool value) { Calls++; if (RejectNext) { RejectNext = false; return false; } Enabled = value; return true; }
        public bool OpenSettings() { OpenCalls++; return !RejectOpen; }
    }
}
