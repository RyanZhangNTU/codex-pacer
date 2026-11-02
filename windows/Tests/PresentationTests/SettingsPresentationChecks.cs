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
            Check(window.ClientContent.ActualWidth == 780
                && window.ClientContent.ActualHeight == 600, "Settings must retain the original native client dimensions");
            Check(window.Title == ui.Text("menu.settings_title"), "The system window title must use the shared catalog");
            var update = Find<Button>(window, "settings.update.check");
            var automatic = Find<CheckBox>(window, "settings.update.automatic");
            Check(!update.IsEnabled && !automatic.IsEnabled, "The preview cannot expose unimplemented update actions");
            Check(Find<RadioButton>(window, "settings.pane.general").IsEnabled
                && Find<RadioButton>(window, "settings.pane.appearance").IsEnabled
                && Find<RadioButton>(window, "settings.pane.reminders").IsEnabled
                && !Find<RadioButton>(window, "settings.pane.connections").IsEnabled, "Implemented settings panes are available while pending connections remain disabled");
            var privacy = Find<CheckBox>(window, "settings.hide_projects");
            var apps = Find<CheckBox>(window, "settings.app_buttons");
            var login = Find<CheckBox>(window, "settings.startup");
            Check(privacy.ActualWidth == 36 && privacy.ActualHeight == 18 && privacy.IsChecked == false && apps.IsChecked == true,
                "Switch geometry and defaults must match the source preferences");
            string screenshot = Path.Combine(output, "settings-" + scenario + "-general.png");
            window.CapturePreview(screenshot); CheckOpaque(screenshot, window);

            Toggle(login); Check(startup.Enabled && startup.Calls == 1, "Accessible login toggles must reach only the injected startup service");
            startup.RejectNext = true; Toggle(login);
            Check(startup.Enabled && login.IsChecked == true && startup.Calls == 2, "Rejected startup changes must restore the switch");
            Toggle(privacy);
            await Until(() => session.Current.HideProjects && privacy.IsEnabled, "Accessible privacy changes must await the real engine acknowledgement");
            Check(latest?.Tasks.Count > 0 && latest.Tasks.All(value => value.Title == (language == "en" ? "Local task" : "本地任务")),
                "The settings switch must redact names before they cross the engine protocol");
            Toggle(apps);
            await Until(() => !session.Current.ShowAppButtons && apps.IsEnabled, "App button choices must commit immediately");
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
            expand.Collapse();
            await Until(() => session.Current.Language == alternate && picker.IsEnabled, "Accessible language selection must persist without replacing the running UI language");
            var restart = Find<Button>(window, "settings.restart");
            Check(restart.IsVisible && window.Title == ui.Text("menu.settings_title") && configureCalls == 1,
                "Changing language must offer restart and preserve the current UI and engine language until restart");
            Invoke(restart); await Until(() => restartRequests == 1, "The restart action must reach the application lifecycle owner");

            rejectSave = true; Toggle(privacy);
            await Until(() => configureCalls >= 3 && privacy.IsEnabled, "A failed disk write must finish its engine rollback");
            Check(session.Current.HideProjects && privacy.IsChecked == true && latest!.Tasks.All(value => value.Title == (language == "en" ? "Local task" : "本地任务"))
                && saved.Count == 3, "A failed save must leave both visible privacy state and persisted choices at their previous values");
            Select(Find<RadioButton>(window, "settings.pane.appearance"));
            await Until(() => session.Current.LastSettingsPane == "appearance" && Find<RadioButton>(window, "appearance.mode.notch").IsEnabled,
                "Appearance navigation must persist and expose the real position controls");
            Check(!Find<RadioButton>(window, "appearance.style.liquidGlass").IsEnabled
                && !Find<ComboBox>(window, "appearance.display").IsEnabled && !Find<CheckBox>(window, "appearance.fullscreen").IsEnabled,
                "Unsupported rendering, display and fullscreen choices must remain disabled");
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
            Check(fullscreen.TranslatePoint(new Point(0, fullscreen.ActualHeight), window.ClientContent).Y <= 600.01,
                "The overlay scroller must make the bottom setting reachable without narrowing the cards");
            if (scrolling.VerticallyScrollable) scrolling.SetScrollPercent(ScrollPatternIdentifiers.NoScroll, 0);
            Select(Find<RadioButton>(window, "appearance.mode.notch"));
            await Until(() => session.Current.DisplayMode == "notch", "The attached choice must save immediately");
            Check(!Find<RadioButton>(window, "appearance.position.center").IsVisible, "Attached mode must hide the custom-position choices");
            Select(Find<RadioButton>(window, "appearance.mode.custom"));
            await Until(() => session.Current.DisplayMode == "floating" && session.Current.Position == "bottomLeft", "The first custom choice over notch mode must use the original bottom-left default");
            foreach (string position in new[] { "center", "topLeft", "bottomLeft", "topRight", "bottomRight" })
            {
                Select(Find<RadioButton>(window, "appearance.position." + position));
                await Until(() => session.Current.Position == position, "Every native position target must commit");
                Check(session.Current.HasChosenPosition, "An explicit center or corner must survive future mode switches");
            }
            rejectSave = true; Select(Find<RadioButton>(window, "appearance.position.topLeft"));
            await Until(() => Find<RadioButton>(window, "appearance.position.bottomRight").IsChecked == true,
                "A failed position write must restore the last selected radio item");
            Check(session.Current.Position == "bottomRight" && configureCalls == 3,
                "Appearance choices and navigation cannot restart data collectors");
            Invoke(Find<Button>(window, "settings.quit")); await Until(() => quitRequests == 1, "Quit must use the application lifecycle callback");
            Escape(window); Check(!window.IsVisible, "Escape must close a settled settings window");
            var reopened = new SettingsWindow(ui, session, startup, true, dark) { ShowActivated = false, IsHitTestVisible = false };
            try
            {
                reopened.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                Check(Find<RadioButton>(reopened, "settings.pane.appearance").IsChecked == true
                    && Find<RadioButton>(reopened, "appearance.position.bottomRight").IsChecked == true,
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
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
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
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(25);
        Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class StartupFixture : IStartupRegistration
    {
        internal bool Enabled, RejectNext; internal int Calls;
        public StartupRegistrationState Read() => new(Enabled, true);
        public bool Set(bool value) { Calls++; if (RejectNext) { RejectNext = false; return false; } Enabled = value; return true; }
    }
}
