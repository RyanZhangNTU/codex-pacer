using System;
using System.Collections.Generic;
using System.Diagnostics;
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

internal static class GuidePageChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        var ui = UiText.For(language == "zh-Hans"); await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
        await PresentationWait.UntilAsync(() => engine.LatestSnapshot != null, "Guide samples require the first acknowledged demo snapshot");
        Task<GuideCatalog> Query(string? seen, bool welcome = false) => engine.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide = new GuideRequest("4.2.4", seen, 4, language, true, false, welcome, !welcome) } }, TimeSpan.FromSeconds(3));
        var catalog = await Query(null, true); int configured = 0, saved = 0; bool reject = false;
        var session = new PreferencesSession(new(), async value => { configured++; await engine.SendAsync("configure", value); }, _ => { saved++; if (!reject) return true; reject = false; return false; });
        var startup = new Startup(); var links = new List<Uri>(); var settingsActions = new List<string>(); int welcomeActions = 0;
        using var notifications = new NotificationSession(session, new DemoSystemNotifications(), action => action(), _ => { }, true);
        EngineSnapshot? snapshot = engine.LatestSnapshot;
        GuideContent Body(GuideCatalog value) => new(ui, session, startup, value, settingsActions.Add, () => welcomeActions++, engine, notifications, uri => { links.Add(uri); return true; }, () => snapshot);
        var body = Body(catalog); var window = new GuideWindow(ui, body, catalog, dark) { ShowActivated = false, IsHitTestVisible = false };
        try
        {
            window.Show(); await Pump();
            Check(window.Title == ui.Text("welcome.window_title") && AutomationProperties.GetName(Find<StackPanel>(window, "welcome.progress")) == window.StepName(0), "Welcome title and first page are localized and announced");
            var highlights = Find<ScrollViewer>(window, "guide.highlights");
            var highlightsPeer = UIElementAutomationPeer.CreatePeerForElement(highlights);
            Check(highlightsPeer.GetName() == window.StepName(0), "The welcome content UIA name identifies the first page");
            Check(SelfAndDescendants(body).OfType<ActivityBadge>().Any() && SelfAndDescendants(body).OfType<CompactQuotaGlyph>().Any()
                && SelfAndDescendants(body).OfType<WarningMark>().Any(), "The island map uses production components");
            Check(Find<Button>(window, "welcome.next").IsDefault && !Has(window, "welcome.back"), "The first page offers only Continue");
            Capture(window.ClientContent, Path.Combine(output, "pages-welcome-1-" + language + (dark ? "-dark" : "-light") + ".png"));
            Space(Find<Button>(window, "welcome.next")); await Pump();
            Check(AutomationProperties.GetName(Find<StackPanel>(window, "welcome.progress")) == window.StepName(1) && highlightsPeer.GetName() == window.StepName(1),
                "Space on the focused Continue reaches the display mode page on the same content peer");
            Check(SelfAndDescendants(body).OfType<WelcomeGestureScene>().Any() && SelfAndDescendants(body).OfType<WelcomeMoveScene>().Any(), "Both display modes are shown moving");
            Select(Find<RadioButton>(window, "welcome.mode.notch")); await Until(() => session.Current.DisplayMode == "notch");
            Check(Find<RadioButton>(window, "welcome.mode.notch").IsChecked == true && Find<RadioButton>(window, "welcome.mode.free").IsChecked == false, "Choosing the island mode saves at once");
            Select(Find<RadioButton>(window, "welcome.mode.free")); await Until(() => session.Current.DisplayMode == "floating");
            Capture(window.ClientContent, Path.Combine(output, "pages-welcome-2-" + language + (dark ? "-dark" : "-light") + ".png"));
            Invoke(Find<Button>(window, "welcome.next")); await Pump();
            Check(AutomationProperties.GetName(Find<StackPanel>(window, "welcome.progress")) == window.StepName(2), "Continue reaches the services page");
            foreach (string provider in new[] { "codex", "claude", "deepseek" })
            {
                var toggle = Find<CheckBox>(window, "welcome.module." + provider); Toggle(toggle);
                await Until(() => !toggle.IsEnabled || session.Current.ProviderModes[provider] != "automatic");
                await Until(() => toggle.IsEnabled);
                Check(session.Current.ProviderModes[provider] == (toggle.IsChecked == true ? "enabled" : "disabled"), "Each module saves an explicit enabled or disabled choice");
            }
            var codex = Find<CheckBox>(window, "welcome.module.codex"); var beforeRejected = session.Current;
            reject = true; Toggle(codex); await Until(() => !reject && codex.IsEnabled);
            Check(session.Current == beforeRejected && Find<TextBlock>(body, "guide.issue").Text == ui.Text("windows.settings.save_failed"), "Rejected module changes restore the acknowledged profile and show an accessible error");
            await session.ChangeAsync(p => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = "enabled", ["claude"] = "enabled", ["deepseek"] = "enabled" } });
            snapshot = engine.LatestSnapshot! with { Modules = new[] { new EngineModule("codex", "enabled", false, true), new EngineModule("claude", "enabled", true, true), new EngineModule("deepseek", "enabled", true, true) },
                ClaudeConnection = new("qa-context", true, false, false, true, "workspaceNeeded", null), Wallet = null };
            body.Refresh();
            Check(Find<TextBlock>(window, "welcome.module.codex.status").Text == ui.Text("welcome.module.codex_missing")
                && Find<Button>(window, "welcome.module.claude.action").Content!.ToString() == ui.Text("claude.quota.choose_workspace"), "Missing installation and workspace states each show the matching single action");
            Invoke(Find<Button>(window, "welcome.module.claude.action")); await Pump(); Check(settingsActions.Last() == "claude", "Workspace actions dispatch to the provider coordinator boundary");
            Capture(window.ClientContent, Path.Combine(output, "pages-welcome-3-" + language + (dark ? "-dark" : "-light") + ".png"));
            Invoke(Find<Button>(window, "welcome.next")); await Pump();
            Check(AutomationProperties.GetName(Find<StackPanel>(window, "welcome.progress")) == window.StepName(3) && Has(window, "guide.done") && !Has(window, "welcome.next"),
                "The last page finishes with Done");
            var rings = Find<CheckBox>(window, "welcome.rings"); Toggle(rings);
            await Until(() => !session.Current.ClaudeProgressRing && !session.Current.CodexProgressRing && !session.Current.DeepSeekProgressRing && rings.IsEnabled);
            Toggle(rings);
            await Until(() => session.Current.ClaudeProgressRing && session.Current.CodexProgressRing && session.Current.DeepSeekProgressRing && rings.IsEnabled);
            Check(rings.IsChecked == true, "One switch turns every service's progress ring on or off");
            Toggle(Find<CheckBox>(window, "welcome.notifications")); await Until(() => notifications.DesiredEnabled && !notifications.IsChanging);
            Check(session.Current.SystemNotifications, "The welcome notification switch uses the existing permission and preference coordinator");
            Toggle(Find<CheckBox>(window, "welcome.startup")); Check(startup.Enabled && startup.Calls == 1, "Open at Login uses the injected OS registration without an invented preference");
            startup.Blocked = true; body.Refresh(); Check(Find<TextBlock>(window, "welcome.system.status").Text == ui.Text("windows.settings.startup_disabled"), "Blocked OS startup state remains visible");
            Invoke(Find<Button>(window, "welcome.collapsed")); await Pump(); Check(settingsActions.Last() == "collapsed", "The collapsed-bar shortcut navigates to its settings pane");
            Capture(window.ClientContent, Path.Combine(output, "pages-welcome-4-" + language + (dark ? "-dark" : "-light") + ".png"));
            Invoke(Find<Button>(window, "welcome.back")); await Pump(); Check(AutomationProperties.GetName(Find<StackPanel>(window, "welcome.progress")) == window.StepName(2), "Back returns one page");
            Check(highlightsPeer.GetName() == window.StepName(2), "Returning updates the retained content peer");
            Invoke(Find<Button>(window, "welcome.next")); await Pump();
            Invoke(Find<Button>(window, "guide.done")); await Pump(); Check(!window.IsVisible, "The default Done action closes the guide");
        }
        finally { window.Close(); }
        var note = await Query("3.0.0"); var noteBody = Body(note); var noteWindow = new GuideWindow(ui, noteBody, note, dark) { ShowActivated = false, IsHitTestVisible = false };
        try
        {
            noteWindow.Show(); await Pump(); var scroll = Find<ScrollViewer>(noteWindow, "guide.highlights");
            Check(noteWindow.ClientContent.ActualHeight <= 640.1 && scroll.ScrollableHeight > 0, "Cumulative highlights obey the 640-point cap and scroll inside the fixed chrome");
            Capture(noteWindow.ClientContent, Path.Combine(output, "pages-whats-new-" + language + (dark ? "-dark" : "-light") + ".png"));
            var done = Find<Button>(noteWindow, "guide.done"); double footerBefore = done.TranslatePoint(new Point(), noteWindow).Y;
            scroll.ScrollToEnd(); await Pump(); Check(Math.Abs(done.TranslatePoint(new Point(), noteWindow).Y - footerBefore) < .1, "Scrolling highlights cannot move the title or footer");
            int beforeHostControl = configured; Toggle(Find<CheckBox>(noteWindow, "guide.control.showAppButtons")); await Until(() => !session.Current.ShowAppButtons);
            Check(configured == beforeHostControl && session.Current.WhatsNewVersion == null, "A release control applies its setting without configuring collectors or marking notes as read");
            var embedded = Find<CheckBox>(noteWindow, "guide.control.showEmbeddedSessions");
            Check(embedded.IsEnabled && AutomationProperties.GetName(embedded).Length > 0
                && AutomationProperties.GetHelpText(embedded) == note.Releases.SelectMany(value => value.Items).Single(value => value.Control == "showEmbeddedSessions").Detail,
                "The combined embedded-session switch retains its accessible title and release detail after becoming available");
            Toggle(embedded); await Until(() => !session.Current.ShowEmbeddedCodexSessions && !session.Current.ShowEmbeddedClaudeSessions && embedded.IsEnabled);
            Check(embedded.IsChecked == false && session.Current.WhatsNewVersion == null, "The combined release switch disables both providers without marking the note seen");
            Toggle(embedded); await Until(() => session.Current.ShowEmbeddedCodexSessions && session.Current.ShowEmbeddedClaudeSessions && embedded.IsEnabled);
            Check(embedded.IsChecked == true, "The same control restores both independent provider choices");
            Check(SelfAndDescendants(noteBody).OfType<TextBlock>().Any(text => text.Text == ui.Text("windows.settings.open_at_login_detail")),
                "The login highlight uses the existing Windows caption while retaining the shared release entry");
            Invoke(Find<Button>(noteWindow, "guide.releaseNotes")); await Pump(); Check(links.Last().AbsoluteUri == note.Links["releaseNotes"], "Release Notes reaches the public default-browser boundary");
            Check(note.Releases[0].Version == "4.2.4" && SelfAndDescendants(noteBody).OfType<TextBlock>().Any(text => text.Text == ui.Text("whats_new.free_move")),
                "The upgrade window leads with the shared Free Move highlight");
            Escape(noteWindow); Check(!noteWindow.IsVisible, "Escape closes What's New");
        }
        finally { noteWindow.Close(); }
        string? copied = null;
        using var appearance = new AppearanceFixture();
        var settings = new SettingsWindow(ui, session, startup, true, dark, engine, notifications: notifications, guideLinkLauncher: uri => { links.Add(uri); return true; }, guideCopyLink: value => copied = value, appearanceSource: appearance) { ShowActivated = false, IsHitTestVisible = false };
        settings.WelcomeRequested += () => welcomeActions++;
        try
        {
            settings.Show(); await Pump();
            // Help & Updates is a remembered page; its tabs, links and Support write nothing more.
            Select(Find<RadioButton>(settings, "settings.pane.about")); await Until(() => session.Current.LastSettingsPane == "about" && Has(settings, "settings.about.help"));
            await session.WaitForChangesAsync(); int beforeReadOnly = saved; string beforeBytes = JsonSerializer.Serialize(session.Current);
            Select(Find<RadioButton>(settings, "settings.about.help")); await Until(() => Has(settings, "help.module.codex"));
            Check(Find<RadioButton>(settings, "help.module.codex").IsChecked == true, "Help opens with the common legend and Codex details");
            Check(Has(settings, "help.move"), "Help explains dragging, snapping and reset");
            CheckHelpProviderText(settings, ((SolidColorBrush)settings.Resources["SettingsPrimary"]).Color);
            foreach (string provider in new[] { "claude", "deepseek", "codex" })
            { Select(Find<RadioButton>(settings, "help.module." + provider)); await Pump(); Check(Has(settings, "help." + provider + (provider == "deepseek" ? ".balance" : ".quota")), "Module legend selection replaces only local samples"); }
            appearance.Set(appearance.Current with { HighContrast = true }); await Pump(); settings.UpdateLayout();
            CheckHelpProviderText(settings, appearance.Current.Colors.Text);
            appearance.Set(appearance.Current with { HighContrast = false }); await Pump(); settings.UpdateLayout();
            CheckHelpProviderText(settings, ((SolidColorBrush)settings.Resources["SettingsPrimary"]).Color);
            Invoke(Find<Button>(settings, "help.welcome")); await Pump(); Check(welcomeActions == 1, "Help can reopen the two-step guide");
            foreach (string action in new[] { "manual", "issues" }) { Invoke(Find<Button>(settings, "guide.link." + action)); await Pump(); }
            settings.CapturePreview(Path.Combine(output, "pages-help-" + language + (dark ? "-dark" : "-light") + ".png"));
            Find<Button>(settings, "guide.link.issues").BringIntoView(); await Pump();
            settings.CapturePreview(Path.Combine(output, "pages-help-end-" + language + (dark ? "-dark" : "-light") + ".png"));
            Select(Find<RadioButton>(settings, "settings.pane.support")); await Until(() => Has(settings, "guide.link.star"));
            foreach (string action in new[] { "star", "feature", "bug", "donate" }) { var button = Find<Button>(settings, "guide.link." + action); Check(button.Focusable, "Support links remain keyboard reachable"); Invoke(button); await Pump(); }
            var copy = Find<Button>(settings, "support.copy"); Invoke(copy); await Pump();
            Check(copied == note.Links["repository"] && copy.Content!.ToString() == ui.Text("support.share.copied"), "Copy dispatches the public project URL and shows localized feedback without reading the clipboard");
            var support = SelfAndDescendants(settings).OfType<GuideContent>().Single(); Invoke(Find<Button>(settings, "support.wechat")); await Pump();
            Check(support.SupportCodePopup?.IsOpen == true && SelfAndDescendants(support.SupportCodePopup.Child).OfType<Image>().Single().ActualWidth == 220, "The packaged WeChat QR code opens only on request");
            var qrClose = Find<Button>(support.SupportCodePopup!.Child, "support.wechat.close"); Space(qrClose); await Pump();
            Check(support.SupportCodePopup.IsOpen == false && settings.IsVisible, "Keyboard closes the QR layer while preserving Settings");
            Invoke(Find<Button>(settings, "support.wechat")); await Pump(); Escape(Find<Button>(support.SupportCodePopup.Child, "support.wechat.close")); await Pump();
            Check(!support.SupportCodePopup.IsOpen && settings.IsVisible, "Escape belongs to the QR layer before the settings window");
            Check(saved == beforeReadOnly && JsonSerializer.Serialize(session.Current) == beforeBytes, "Help tabs, public links and Support never write any preferences");
            settings.CapturePreview(Path.Combine(output, "pages-support-" + language + (dark ? "-dark" : "-light") + ".png"));
            Select(Find<RadioButton>(settings, "settings.pane.about")); await Until(() => Has(settings, "settings.about.whatsNew"));
            Select(Find<RadioButton>(settings, "settings.about.whatsNew")); await Until(() => SelfAndDescendants(settings).OfType<GuideContent>().Any(value => SelfAndDescendants(value).OfType<TextBlock>().Count(text => note.History.Any(release => release.Title == text.Text)) == note.History.Count));
            Check(session.Current.WhatsNewVersion == null, "Settings lists all release history without marking it seen");
            Check(links.Count == 7 && links.All(uri => uri.Scheme == "https"), "All seven requested public links dispatch once without page network access");
            Escape(settings); Check(!settings.IsVisible, "Escape closes the auxiliary settings pages");
        }
        finally { settings.AllowClose = true; settings.Close(); }
        Console.WriteLine("PASS guide pages " + language + (dark ? "-dark" : "-light") + ": welcome, history, read-only help/support, links, keyboard and UIA");
    }
    private static void CheckHelpProviderText(SettingsWindow window, Color expected)
    {
        var background = ((SolidColorBrush)window.Resources["SettingsBackground"]).Color;
        foreach (string provider in new[] { "codex", "claude", "deepseek" })
        {
            var tab = Find<RadioButton>(window, "help.module." + provider); tab.ApplyTemplate();
            var label = SelfAndDescendants(tab).OfType<TextBlock>().SingleOrDefault();
            Check(label != null && label.Text == AutomationProperties.GetName(tab), "Help provider names render as the segmented choice's own text");
            // The caller switches high contrast on and off; matching colors after each switch prove the label follows the theme live.
            Check(label!.Foreground is SolidColorBrush brush && brush.Color == expected && brush.Color.A == 255
                && Contrast(brush.Color, background) >= 4.5, "Help provider names remain readable in light, dark and system high-contrast colors");
        }
    }
    private static double Contrast(Color first, Color second)
    {
        static double Channel(byte value) { double normalized = value / 255.0; return normalized <= 0.04045 ? normalized / 12.92 : Math.Pow((normalized + 0.055) / 1.055, 2.4); }
        static double Luminance(Color value) => 0.2126 * Channel(value.R) + 0.7152 * Channel(value.G) + 0.0722 * Channel(value.B);
        double a = Luminance(first), b = Luminance(second); return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }
    private static async Task Pump() { await Dispatcher.Yield(DispatcherPriority.ContextIdle); }
    private static void Capture(FrameworkElement value, string file)
    {
        value.UpdateLayout(); var bitmap = new RenderTargetBitmap((int)Math.Ceiling(value.ActualWidth), (int)Math.Ceiling(value.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(value);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(file); encoder.Save(stream);
    }
    private static bool Has(DependencyObject root, string id) => SelfAndDescendants(root).OfType<FrameworkElement>().Any(value => AutomationProperties.GetAutomationId(value) == id);
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => SelfAndDescendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Select(RadioButton value) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(value).GetPattern(PatternInterface.SelectionItem)).Select();
    private static void Space(Button value)
    {
        var source = PresentationSource.FromVisual(value); value.Focus();
        foreach (bool down in new[] { true, false }) value.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Space) { RoutedEvent = down ? Keyboard.KeyDownEvent : Keyboard.KeyUpEvent });
    }
    private static void Escape(UIElement value)
    {
        var key = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(value), 0, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        value.RaiseEvent(key); if (!key.Handled) { key.RoutedEvent = Keyboard.KeyDownEvent; value.RaiseEvent(key); }
    }
    private static async Task Until(Func<bool> predicate)
    { var clock = Stopwatch.StartNew(); while (!predicate() && clock.Elapsed.TotalSeconds < PresentationWait.Limit.TotalSeconds) await Task.Delay(20); Check(predicate(), "Guide page state did not settle"); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration
    {
        internal bool Enabled, Blocked; internal int Calls;
        public StartupRegistrationState Read() => new(Enabled, true, Blocked ? StartupBlockReason.Disabled : StartupBlockReason.None);
        public bool Set(bool value) { Calls++; Enabled = value; return true; }
    }
}
