using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CodexPacer.Windows;
using static AccessibilityChecks;

internal static class AccessibilityGuideChecks
{
    internal static async Task Run(string language, AppearanceFixture appearance, EngineClient engine)
    {
        int subscribers = appearance.Subscribers;
        var ui = UiText.For(language == "zh-Hans");
        var session = new PreferencesSession(new(), _ => throw new Exception("Guide appearance configured collectors"), _ => throw new Exception("Guide appearance saved preferences"));
        foreach (bool welcome in new[] { true, false })
        {
            var catalog = await engine.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide = new GuideRequest("4.2.0", null, 4, language, true, false, welcome, !welcome) } }, TimeSpan.FromSeconds(3));
            var body = new GuideContent(ui, session, new Startup(), catalog, _ => { }, () => { }, engine, launch: _ => true, copyLink: _ => { });
            var window = new GuideWindow(ui, body, catalog, appearanceSource: appearance) { ShowActivated = false, IsHitTestVisible = false };
            try
            {
                window.Show(); await Drain();
                appearance.Set(appearance.Current with { Dark = false, HighContrast = false }); await Drain();
                // What's New reads like the main window's gray page; the welcome guide keeps its plain page.
                Check(((SolidColorBrush)window.Resources["SettingsBackground"]).Color == (window.IsWelcome ? Colors.White : Color.FromRgb(244, 244, 246)), "Guide windows follow the injected light theme");
                appearance.Set(appearance.Current with { Dark = true }); await Drain();
                Check(((SolidColorBrush)window.Resources["SettingsBackground"]).Color == (window.IsWelcome ? Color.FromRgb(31, 31, 31) : Color.FromRgb(27, 27, 30)), "Guide windows follow the injected dark theme");
                await Audit(window, welcome ? "welcome" : "whatsNew");
                if (welcome)
                {
                    var oldNext = Find<Button>(window, "welcome.next"); Invoke(oldNext);
                    await PresentationWait.UntilAsync(() => Descendants(window).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "welcome.back"), "The next action replaces the welcome step");
                    Check(!oldNext.IsEnabled, "A replaced welcome footer immediately disables its old action"); RejectDisabled(oldNext);
                    await Audit(window, "welcome.step2");
                    Invoke(Find<Button>(window, "welcome.back")); await Drain();
                    Check(Find<Button>(window, "welcome.next").IsDefault, "Reversing a welcome step restores its current default action");
                }
                appearance.Set(appearance.Current with { HighContrast = true }); await Drain();
                Check(((SolidColorBrush)window.Resources["SettingsSelectionText"]).Color == appearance.Current.Colors.HighlightText,
                    "Guide actions use semantic selection text under high contrast");
                window.Hide(); await Drain();
                Check(new VisibleWindowAutomationPeer(window).GetChildren()?.Count is null or 0 && !body.IsEnabled, "Hidden guides have no accessible actions");
                window.Show(); window.Activate(); await Drain();
                var close = Find<Button>(window, welcome ? "welcome.next" : "guide.done"); close.Focus();
                PostKey(window, Key.Escape); await PresentationWait.UntilAsync(() => !window.IsVisible, "Escape closes either guide window");
                Check(!window.IsEnabled, "Closed guides disable retained controls");
            }
            finally { window.Close(); }
            Check(appearance.Subscribers == subscribers && !appearance.Disposed, "Each guide releases its borrowed system subscription");
        }
        appearance.Set(appearance.Current with { HighContrast = false });
    }
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject
        => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private sealed class Startup : IStartupRegistration
    { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
