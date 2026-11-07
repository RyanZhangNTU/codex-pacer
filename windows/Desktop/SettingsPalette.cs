using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class SettingsPalette
{
    /// <param name="main">Pacer's main window: a gray page with white cards and a neutral sidebar selection, as on the Mac.</param>
    internal static void Apply(ResourceDictionary resources, bool dark, bool active, SystemAppearance? appearance = null, bool main = false)
    {
        if (appearance is { HighContrast: true })
        {
            var colors = appearance.Colors;
            foreach (string key in new[] { "SettingsBackground", "SettingsSidebar", "SettingsPopup", "SettingsInput", "SettingsChartMaterial" }) resources[key] = DesktopAppearance.Ink(colors.Window);
            foreach (string key in new[] { "SettingsCard", "SettingsTile", "SettingsCompactChip", "SettingsSegment", "SettingsButton", "SettingsSwitchOff", "SettingsSearchFill", "SettingsInfoFill" }) resources[key] = DesktopAppearance.Ink(colors.Control);
            foreach (string key in new[] { "SettingsPrimary", "SettingsSecondary", "SettingsChartReference", "SettingsChartSecondary", "SettingsSeparator", "SettingsCardBorder" }) resources[key] = DesktopAppearance.Ink(colors.Text);
            resources["SettingsDisabled"] = DesktopAppearance.Ink(colors.Disabled);
            foreach (string key in new[] { "SettingsAccent", "SettingsSwitchOn", "SettingsHover", "SettingsWarning", "SettingsSuccess", "SettingsSidebarSelection" }) resources[key] = DesktopAppearance.Ink(colors.Highlight);
            resources["SettingsAccentSoft"] = DesktopAppearance.Ink(colors.Control);
            resources["SettingsKnob"] = resources["SettingsSelectionText"] = DesktopAppearance.Ink(colors.HighlightText);
            resources["SettingsSidebarSelectionText"] = DesktopAppearance.Ink(colors.HighlightText); return;
        }
        void Brush(string key, byte red, byte green, byte blue) => resources[key] = new SolidColorBrush(Color.FromRgb(red, green, blue));
        void Gray(string key, byte value) => Brush(key, value, value, value);
        void Overlay(string key, byte alpha, byte value) => resources[key] = new SolidColorBrush(Color.FromArgb(alpha, value, value, value));
        Gray("SettingsBackground", dark ? (byte)31 : (byte)255);
        Gray("SettingsSidebar", dark ? (byte)35 : (byte)249);
        Gray("SettingsCard", dark ? (byte)36 : (byte)247);
        if (main)
        {
            Brush("SettingsBackground", dark ? (byte)27 : (byte)244, dark ? (byte)27 : (byte)244, dark ? (byte)30 : (byte)246);
            Brush("SettingsSidebar", dark ? (byte)37 : (byte)234, dark ? (byte)37 : (byte)234, dark ? (byte)40 : (byte)237);
            Brush("SettingsCard", dark ? (byte)36 : (byte)255, dark ? (byte)36 : (byte)255, dark ? (byte)40 : (byte)255);
        }
        Overlay("SettingsCardBorder", main ? dark ? (byte)18 : (byte)20 : (byte)0, dark ? (byte)255 : (byte)0);
        Overlay("SettingsSidebarSelection", dark ? (byte)36 : (byte)23, dark ? (byte)255 : (byte)0);
        Overlay("SettingsSearchFill", dark ? (byte)20 : (byte)15, dark ? (byte)255 : (byte)0);
        Overlay("SettingsInfoFill", dark ? (byte)13 : (byte)10, dark ? (byte)255 : (byte)0);
        Gray("SettingsSidebarSelectionText", dark ? (byte)222 : (byte)36);
        Gray("SettingsTile", dark ? (byte)45 : (byte)237);
        Gray("SettingsCompactChip", dark ? (byte)31 : (byte)251);
        Gray("SettingsSegment", dark ? (byte)70 : (byte)202);
        Gray("SettingsPrimary", dark ? (byte)222 : (byte)36);
        Gray("SettingsSecondary", dark ? (byte)157 : main ? (byte)108 : (byte)119);
        Gray("SettingsDisabled", dark ? (byte)105 : (byte)174);
        Gray("SettingsSeparator", dark ? (byte)51 : (byte)230);
        Gray("SettingsButton", dark ? (byte)50 : (byte)235);
        Gray("SettingsHover", dark ? (byte)61 : (byte)226);
        Gray("SettingsPopup", dark ? (byte)44 : (byte)252);
        Gray("SettingsInput", dark ? (byte)29 : (byte)255);
        Gray("SettingsChartReference", dark ? (byte)255 : (byte)0);
        Gray("SettingsChartSecondary", dark ? (byte)140 : (byte)128);
        resources["SettingsChartMaterial"] = new SolidColorBrush(Color.FromArgb(205, dark ? (byte)55 : (byte)229, dark ? (byte)55 : (byte)229, dark ? (byte)55 : (byte)229));
        Gray("SettingsSwitchOff", dark ? (byte)49 : (byte)224);
        Gray("SettingsKnob", dark ? (byte)224 : (byte)255);
        Gray("SettingsSelectionText", 255);
        Brush("SettingsAccent", 0, 122, 255);
        resources["SettingsAccentSoft"] = new SolidColorBrush(Color.FromArgb(36, 0, 122, 255));
        Brush("SettingsWarning", dark ? (byte)255 : (byte)194, dark ? (byte)146 : (byte)95, dark ? (byte)48 : (byte)0);
        Brush("SettingsSuccess", 48, 186, 85);
        if (active) Brush("SettingsSwitchOn", 0, 122, 255);
        else Gray("SettingsSwitchOn", dark ? (byte)81 : (byte)210);
    }
}
