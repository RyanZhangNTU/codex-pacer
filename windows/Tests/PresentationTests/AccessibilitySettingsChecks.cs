using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using CodexPacer.Windows;
using static AccessibilityChecks;

internal static class AccessibilitySettingsChecks
{
    internal static async Task Run(string language, AppearanceFixture appearance, EngineClient engine, IslandWindow island)
    {
        int saves = 0, configurations = 0, subscribers = appearance.Subscribers;
        // General holds the switches and picker this audit drives; Overview is checked with the other pages below.
        var session = new PreferencesSession(new() { LastSettingsPane = "general" }, _ => { configurations++; return Task.CompletedTask; }, _ => { saves++; return true; });
        var window = new SettingsWindow(UiText.For(language == "zh-Hans"), session, new Startup(), true, engine: engine,
            surfaceWindow: island, appearanceSource: appearance) { ShowActivated = false, IsHitTestVisible = false };
        try
        {
            window.Show(); await Drain();
            appearance.Set(appearance.Current with { Dark = false }); await Drain();
            Check(ColorOf(window.Resources["SettingsBackground"]) == Color.FromRgb(244, 244, 246), "An injected light theme immediately repaints settings");
            appearance.Set(appearance.Current with { Dark = true }); await Drain();
            Check(ColorOf(window.Resources["SettingsBackground"]) == Color.FromRgb(27, 27, 30), "An injected dark theme immediately repaints settings");
            appearance.Set(appearance.Current with { HighContrast = true }); await Drain();
            Check(ColorOf(window.Resources["SettingsBackground"]) == appearance.Current.Colors.Window
                && ColorOf(window.Resources["SettingsAccent"]) == appearance.Current.Colors.Highlight
                && ColorOf(window.Resources["SettingsDisabled"]) == appearance.Current.Colors.Disabled,
                "High contrast uses semantic background, selection and disabled colors: " + ColorOf(window.Resources["SettingsBackground"]) + "/" + appearance.Current.Colors.Window
                + " " + ColorOf(window.Resources["SettingsAccent"]) + "/" + appearance.Current.Colors.Highlight + " " + ColorOf(window.Resources["SettingsDisabled"]) + "/" + appearance.Current.Colors.Disabled);
            var selected = Find<RadioButton>(window, "settings.pane.general");
            Check(ColorOf(selected.Foreground) == appearance.Current.Colors.HighlightText, "The selected navigation choice uses semantic selection text");
            Check(saves == 0 && configurations == 0, "System appearance changes do not save preferences or configure collectors");
            await Audit(window, "settings.general");
            var languageChoice = Find<ComboBox>(window, "settings.language");
            window.Activate(); languageChoice.Focus(); languageChoice.IsDropDownOpen = true; await Drain();
            var selectedItem = (ComboBoxItem)languageChoice.ItemContainerGenerator.ContainerFromIndex(languageChoice.SelectedIndex);
            Check(selectedItem.Focus(), "The open choice list supports keyboard focus"); await Drain();
            Check(selectedItem.IsHighlighted && ColorOf(selectedItem.Foreground) == appearance.Current.Colors.HighlightText,
                "Popup selection text uses semantic high-contrast colors");
            // WPF exposes selection through ComboBox data peers; popup wrappers supply the visual tree.
            var choicePeer = (ComboBoxAutomationPeer)UIElementAutomationPeer.CreatePeerForElement(languageChoice);
            var options = choicePeer.GetChildren()!.Where(value => value.GetAutomationControlType() == AutomationControlType.ListItem).ToArray();
            Check(options.Length == languageChoice.Items.Count, "The ComboBox exposes every choice to assistive technology");
            foreach (var option in options) Check(!string.IsNullOrWhiteSpace(option.GetName()) && option.GetPattern(PatternInterface.SelectionItem) is ISelectionItemProvider,
                "Each logical choice exposes its name, ListItem role and SelectionItem action");
            var currentChoice = (ISelectionItemProvider)options[languageChoice.SelectedIndex].GetPattern(PatternInterface.SelectionItem)!;
            Check(currentChoice.IsSelected, "The current choice reports its selected state"); currentChoice.Select();
            Check(PresentationSource.FromVisual(selectedItem) is HwndSource, "The dropdown has a real owned popup HWND");
            await AuditHandle(((HwndSource)PresentationSource.FromVisual(selectedItem)!).Handle, "settings.language.popup");
            languageChoice.IsDropDownOpen = false; await Drain();
            Check(saves == 0 && configurations == 0, "Inspecting and closing the current choice does not commit a preference");
            // The window theme overrides Windows, and a single accent tints controls and shades the services, as on the Mac.
            appearance.Set(appearance.Current with { Dark = false, HighContrast = false }); await Drain();
            await session.ChangeAsync(p => p with { AppTheme = "dark", AccentColor = "purple" }); await Drain();
            Check(ColorOf(window.Resources["SettingsBackground"]) == Color.FromRgb(27, 27, 30) && ColorOf(window.Resources["SettingsAccent"]) == Color.FromRgb(0xBF, 0x5A, 0xF2),
                "The dark theme overrides a light Windows and the accent tints the controls");
            Check(((SolidColorBrush)PacerPalette.Codex).Color == Color.FromRgb(0xBF, 0x5A, 0xF2) && ((SolidColorBrush)PacerPalette.Claude).Color == AccentPalette.Lighten(Color.FromRgb(0xBF, 0x5A, 0xF2), .42),
                "A single accent turns the services into its shades");
            // On light glass every accent keeps readable shades, darkest for Codex, with the Mac's values.
            var lightFace = Color.FromRgb(0xEC, 0xEC, 0xF0);
            foreach (string accent in AccentPalette.Choices.Where(value => AccentPalette.Fixed(value) != null))
            {
                var shades = new[] { "codex", "claude", "deepseek" }.Select(provider => AccentPalette.ProviderShade(accent, provider, light: true)!.Value).ToArray();
                Check(shades.All(shade => SettingsPalette.Contrast(shade, lightFace) >= 3.5)
                    && SettingsPalette.Contrast(shades[0], Colors.Black) < SettingsPalette.Contrast(shades[1], Colors.Black)
                    && SettingsPalette.Contrast(shades[1], Colors.Black) < SettingsPalette.Contrast(shades[2], Colors.Black),
                    "The " + accent + " accent keeps readable shades on light glass, lightening from Codex to DeepSeek");
            }
            Check(AccentPalette.ProviderShade("yellow", "codex", true) == Color.FromRgb(89, 74, 1) && AccentPalette.ProviderShade("blue", "deepseek", true) == Color.FromRgb(8, 122, 236)
                && AccentPalette.ProviderShade("graphite", "claude", true) == Color.FromRgb(97, 97, 100), "The light shades match the Mac's");
            PacerPalette.ApplyTone(true);
            bool lightPurple = ((SolidColorBrush)PacerPalette.Codex).Color == Color.FromRgb(107, 47, 137);
            PacerPalette.ApplyTone(false);
            Check(lightPurple, "Light glass shades the services from the accent");
            await session.ChangeAsync(p => p with { AppTheme = "light" }); await Drain();
            Check(ColorOf(window.Resources["SettingsBackground"]) == Color.FromRgb(244, 244, 246), "The light theme applies at once");
            Check(SettingsPalette.Contrast(ColorOf(window.Resources["SettingsLinkText"]), ColorOf(window.Resources["SettingsCard"])) >= 4.5, "Links keep readable contrast on light cards");
            // A dim Windows accent (a dark warm gray) still gives links readable text on dark cards, without changing the control fill.
            var dim = Color.FromRgb(0x58, 0x4B, 0x46); var probe = new ResourceDictionary();
            SettingsPalette.Apply(probe, true, true, main: true, accent: dim);
            Check(ColorOf(probe["SettingsAccent"]) == dim && SettingsPalette.Contrast(ColorOf(probe["SettingsLinkText"]), ColorOf(probe["SettingsCard"])) >= 4.5
                && SettingsPalette.Contrast(ColorOf(probe["SettingsLinkText"]), Colors.Black) >= 4.5, "A dim accent's links are lightened until readable on dark and island cards");
            await session.ChangeAsync(p => p with { AppTheme = "auto", AccentColor = "multicolor" }); await Drain();
            Check(ColorOf(window.Resources["SettingsAccent"]) == Color.FromRgb(0, 122, 255) && ((SolidColorBrush)PacerPalette.Codex).Color == ((SolidColorBrush)PacerPalette.BrandCodex).Color,
                "Multicolor restores the brand colors, and checks keep the classic blue");
            appearance.Set(appearance.Current with { Dark = true }); await Drain();
            appearance.Set(appearance.Current with { HighContrast = false }); await Drain();
            Check(ColorOf(window.Resources["SettingsBackground"]) == Color.FromRgb(27, 27, 30), "Leaving high contrast restores the selected system theme");
            var privacy = Find<CheckBox>(window, "settings.hide_projects");
            window.Activate(); Check(privacy.Focus(), "A settings switch accepts keyboard focus");
            CheckFocusOrder(window, privacy); privacy.Focus();
            PostKey(window, Key.Space); await PresentationWait.UntilAsync(() => session.Current.HideProjects, "Space toggles a focused settings choice");
            await session.WaitForChangesAsync();
            foreach (string page in new[] { "overview", "history", "appearance", "collapsed", "notifications", "codex", "claude", "deepseek", "remote", "whatsNew", "help", "support", "general" })
            {
                // What's New and Help are tabs of Help & Updates.
                string pane = SettingsWindow.CanonicalPane(page);
                await window.NavigateAsync(page); await ShellProjection.WhenIdleAsync(); await Drain(); window.UpdateLayout();
                if (pane is "about" or "support")
                    await PresentationWait.UntilAsync(() => Descendants(window).OfType<GuideContent>().Any(value => value.Children.Count > 1), "The guide pane publishes its local catalog");
                Check(Find<RadioButton>(window, "settings.pane." + pane).IsChecked == true, "Keyboard-accessible navigation selects " + pane);
                await Audit(window, "settings." + page);
                var choice = Find<RadioButton>(window, "settings.pane." + pane); window.Activate(); choice.Focus();
                int beforeTheme = saves;
                appearance.Set(appearance.Current with { HighContrast = true }); await Drain();
                Check(ColorOf(choice.Foreground) == appearance.Current.Colors.HighlightText && Keyboard.FocusedElement == choice && !island.IsActive,
                    "New pages inherit semantic colors without moving keyboard focus to the island");
                appearance.Set(appearance.Current with { HighContrast = false }); await Drain();
                Check(saves == beforeTheme && Keyboard.FocusedElement == choice, "Restoring theme does not save preferences or change focus");
                if (pane == "appearance")
                {
                    Check(!privacy.IsEnabled, "A departed settings page disables retained controls");
                    bool rejected = false;
                    try { ((IToggleProvider)new CheckBoxAutomationPeer(privacy).GetPattern(PatternInterface.Toggle)!).Toggle(); }
                    catch (ElementNotEnabledException) { rejected = true; }
                    Check(rejected && session.Current.HideProjects, "A cached UIA peer cannot toggle a departed settings page");
                }
                if (pane == "collapsed")
                {
                    var state = await NativeCompactBar.Shared.ReadAsync(session.Current, language, ["codex", "claude", "deepseek"]);
                    string[] lane = state.EditorLeading.Length > 1 ? state.EditorLeading : state.EditorTrailing;
                    Check(lane.Length > 1, "The sorting fixture contains adjacent components");
                    var grip = Find<FrameworkElement>(window, "compact.chip." + lane[0]);
                    grip.BringIntoView(); await Drain(); Check(grip.Focus(), "The named sort handle accepts keyboard focus");
                    int before = saves, beforeConfigurations = configurations; string? layout = session.Current.CompactLayout;
                    PostKey(window, Key.Right); await PresentationWait.UntilAsync(() => saves == before + 1, "Right arrow commits one keyboard reorder");
                    await session.WaitForChangesAsync();
                    Check(session.Current.CompactLayout != layout && configurations == beforeConfigurations, "Keyboard sorting updates presentation without configuring collectors");
                }
            }
            window.Activate(); Find<CheckBox>(window, "settings.hide_projects").Focus(); PostKey(window, Key.Escape);
            await PresentationWait.UntilAsync(() => !window.IsVisible, "Escape closes the current settings window");
            Check(!window.IsEnabled, "Closed settings cannot retain actionable UIA controls");
        }
        finally { window.AllowClose = true; window.Close(); }
        Check(appearance.Subscribers == subscribers && !appearance.Disposed, "Settings releases its borrowed theme subscription on close");
    }
    private static Color ColorOf(object value) => ((SolidColorBrush)value).Color;
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject
        => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private sealed class Startup : IStartupRegistration
    { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
