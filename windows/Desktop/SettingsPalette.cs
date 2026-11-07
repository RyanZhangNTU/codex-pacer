using System;
using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class SettingsPalette
{
    /// <param name="main">Pacer's main window: a gray page with white cards and a neutral sidebar selection, as on the Mac.</param>
    /// <param name="accent">The accent for buttons, switches and selections; null keeps the classic blue.</param>
    internal static void Apply(ResourceDictionary resources, bool dark, bool active, SystemAppearance? appearance = null, bool main = false, Color? accent = null)
    {
        if (appearance is { HighContrast: true })
        {
            var colors = appearance.Colors;
            foreach (string key in new[] { "SettingsBackground", "SettingsSidebar", "SettingsPopup", "SettingsInput", "SettingsChartMaterial" }) resources[key] = DesktopAppearance.Ink(colors.Window);
            foreach (string key in new[] { "SettingsCard", "SettingsTile", "SettingsCompactChip", "SettingsSegment", "SettingsButton", "SettingsSwitchOff", "SettingsSearchFill", "SettingsInfoFill", "SettingsPickerFill" }) resources[key] = DesktopAppearance.Ink(colors.Control);
            foreach (string key in new[] { "SettingsPickerStroke", "SettingsPickerHover" }) resources[key] = DesktopAppearance.Ink(colors.Text);
            foreach (string key in new[] { "SettingsPrimary", "SettingsSecondary", "SettingsChartReference", "SettingsChartSecondary", "SettingsSeparator", "SettingsCardBorder" }) resources[key] = DesktopAppearance.Ink(colors.Text);
            resources["SettingsDisabled"] = DesktopAppearance.Ink(colors.Disabled);
            foreach (string key in new[] { "SettingsAccent", "SettingsLinkText", "SettingsSwitchOn", "SettingsHover", "SettingsWarning", "SettingsSuccess", "SettingsSidebarSelection" }) resources[key] = DesktopAppearance.Ink(colors.Highlight);
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
        // The outline picker: a 16% stroke that rises to 28% with a 5% wash on hover, as on the Mac.
        byte ink = dark ? (byte)222 : (byte)36;
        Overlay("SettingsPickerStroke", 41, ink); Overlay("SettingsPickerHover", 71, ink); Overlay("SettingsPickerFill", 13, ink);
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
        Color tint = accent ?? Color.FromRgb(0, 122, 255);
        Brush("SettingsAccent", tint.R, tint.G, tint.B);
        resources["SettingsAccentSoft"] = new SolidColorBrush(Color.FromArgb(36, tint.R, tint.G, tint.B));
        // Links stay readable on cards: a dim Windows accent is lightened in dark mode, a pale one darkened in light mode.
        resources["SettingsLinkText"] = new SolidColorBrush(Readable(tint, dark ? (main ? Color.FromRgb(36, 36, 40) : Color.FromRgb(36, 36, 36)) : Colors.White, dark));
        // Light accents such as yellow need dark text on their fill.
        if (0.299 * tint.R + 0.587 * tint.G + 0.114 * tint.B > 186) Gray("SettingsSelectionText", 20);
        Brush("SettingsWarning", dark ? (byte)255 : (byte)194, dark ? (byte)146 : (byte)95, dark ? (byte)48 : (byte)0);
        Brush("SettingsSuccess", 48, 186, 85);
        if (active) Brush("SettingsSwitchOn", tint.R, tint.G, tint.B);
        else Gray("SettingsSwitchOn", dark ? (byte)81 : (byte)210);
    }

    /// The accent moved toward white (or black) just far enough for 4.5:1 text contrast on the background.
    internal static Color Readable(Color tint, Color background, bool lighten)
    {
        Color value = tint;
        for (int step = 1; step <= 20 && Contrast(value, background) < 4.5; step++)
        {
            double amount = step / 20.0;
            byte Mix(byte channel) => (byte)Math.Round(lighten ? channel + (255 - channel) * amount : channel * (1 - amount));
            value = Color.FromRgb(Mix(tint.R), Mix(tint.G), Mix(tint.B));
        }
        return value;
    }
    internal static double Contrast(Color first, Color second)
    {
        static double Channel(byte value) { double normalized = value / 255.0; return normalized <= 0.04045 ? normalized / 12.92 : Math.Pow((normalized + 0.055) / 1.055, 2.4); }
        static double Luminance(Color value) => 0.2126 * Channel(value.R) + 0.7152 * Channel(value.G) + 0.0722 * Channel(value.B);
        double a = Luminance(first), b = Luminance(second); return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
    }
}
