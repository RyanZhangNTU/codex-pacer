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
            foreach (string key in new[] { "SettingsCard", "SettingsTile", "SettingsCompactChip", "SettingsSegment", "SettingsFill", "SettingsSelectedFill", "SettingsTileStroke", "SettingsButton", "SettingsSwitchOff", "SettingsSearchFill", "SettingsInfoFill", "SettingsPickerFill" }) resources[key] = DesktopAppearance.Ink(colors.Control);
            foreach (string key in new[] { "SettingsPickerStroke", "SettingsPickerHover" }) resources[key] = DesktopAppearance.Ink(colors.Text);
            foreach (string key in new[] { "SettingsPrimary", "SettingsSecondary", "SettingsChartReference", "SettingsChartSecondary", "SettingsSeparator", "SettingsCardBorder" }) resources[key] = DesktopAppearance.Ink(colors.Text);
            resources["SettingsDisabled"] = DesktopAppearance.Ink(colors.Disabled);
            foreach (string key in new[] { "SettingsAccent", "SettingsLinkText", "SettingsIslandLink", "SettingsSwitchOn", "SettingsHover", "SettingsWarning", "SettingsExpiry", "SettingsSuccess", "SettingsSidebarSelection" }) resources[key] = DesktopAppearance.Ink(colors.Highlight);
            resources["SettingsAccentSoft"] = DesktopAppearance.Ink(colors.Control);
            foreach (string key in new[] { "SettingsTileAdded", "SettingsNoticeFill" }) resources[key] = DesktopAppearance.Ink(colors.Control);
            resources["SettingsTileIdle"] = DesktopAppearance.Ink(colors.Window);
            foreach (string key in new[] { "SettingsTileRing", "SettingsNoticeText" }) resources[key] = DesktopAppearance.Ink(colors.Text);
            foreach (string key in new[] { "SettingsTileRemove", "SettingsChipOn", "SettingsChipOnStroke" }) resources[key] = DesktopAppearance.Ink(colors.Highlight);
            resources["SettingsTileLocked"] = DesktopAppearance.Ink(colors.Disabled);
            resources["SettingsChipOnText"] = DesktopAppearance.Ink(colors.HighlightText);
            foreach (string name in new[] { "Codex", "Claude", "DeepSeek", "Neutral" })
            { resources["SettingsTint" + name] = DesktopAppearance.Ink(colors.Text); resources["SettingsTint" + name + "Soft"] = DesktopAppearance.Ink(colors.Control); }
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
        // The Mac's primary at 9%.
        Overlay("SettingsSidebarSelection", 23, dark ? (byte)255 : (byte)0);
        // The Mac's control fill (white 7% / black 5%) and the raised choice on it (white 16% / white).
        Overlay("SettingsFill", dark ? (byte)18 : (byte)13, dark ? (byte)255 : (byte)0);
        // A picture choice's outline: primary at 10%.
        Overlay("SettingsTileStroke", 26, dark ? (byte)255 : (byte)0);
        if (dark) Overlay("SettingsSelectedFill", 41, 255); else Gray("SettingsSelectedFill", 255);
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
        // The Mac's small button: white 12% in dark, black 7% in light, a little stronger under the pointer.
        Overlay("SettingsButton", dark ? (byte)31 : (byte)18, dark ? (byte)255 : (byte)0);
        Overlay("SettingsHover", dark ? (byte)46 : (byte)28, dark ? (byte)255 : (byte)0);
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
        // Links take the Mac's link blue, not the accent, kept readable on the cards; the island's dark cards always use the dark blue.
        Color link = dark ? Color.FromRgb(64, 156, 255) : Color.FromRgb(0, 104, 218);
        resources["SettingsLinkText"] = new SolidColorBrush(Readable(link, dark ? (main ? Color.FromRgb(36, 36, 40) : Color.FromRgb(36, 36, 36)) : Colors.White, dark));
        Brush("SettingsIslandLink", 64, 156, 255);
        // Light accents such as yellow need dark text on their fill.
        if (0.299 * tint.R + 0.587 * tint.G + 0.114 * tint.B > 186) Gray("SettingsSelectionText", 20);
        Brush("SettingsWarning", dark ? (byte)255 : (byte)194, dark ? (byte)146 : (byte)95, dark ? (byte)48 : (byte)0);
        // Expiring resets: the Mac's soft amber on dark, a deeper one that reads on white.
        Brush("SettingsExpiry", dark ? (byte)232 : (byte)176, dark ? (byte)191 : (byte)118, dark ? (byte)122 : (byte)24);
        Brush("SettingsSuccess", 48, 186, 85);
        if (active) Brush("SettingsSwitchOn", tint.R, tint.G, tint.B);
        else Gray("SettingsSwitchOn", dark ? (byte)81 : (byte)210);
        // Library tiles: plain until added, then a light wash; the round button's
        // ring while it adds, its gray while it removes, and gray when it cannot.
        if (dark) Overlay("SettingsTileIdle", 10, 255); else Gray("SettingsTileIdle", 255);
        if (dark) Overlay("SettingsTileAdded", 20, 255); else Brush("SettingsTileAdded", 242, 242, 245);
        Overlay("SettingsTileRing", dark ? (byte)77 : (byte)56, dark ? (byte)255 : (byte)0);
        if (dark) Brush("SettingsTileRemove", 99, 99, 102); else Brush("SettingsTileRemove", 110, 110, 115);
        if (dark) Brush("SettingsTileLocked", 72, 72, 74); else Brush("SettingsTileLocked", 199, 199, 204);
        // A component that is not added yet: a soft amber note.
        if (dark) resources["SettingsNoticeFill"] = new SolidColorBrush(Color.FromArgb(41, 255, 159, 10)); else Brush("SettingsNoticeFill", 255, 244, 229);
        if (dark) Brush("SettingsNoticeText", 255, 179, 92); else Brush("SettingsNoticeText", 138, 75, 0);
        // A chosen chip: a tint of the accent with readable accent text.
        Color card = dark ? main ? Color.FromRgb(36, 36, 40) : Color.FromRgb(36, 36, 36) : Colors.White;
        Color chip = Blend(tint, dark ? 0.25 : 0.12, card);
        resources["SettingsChipOn"] = new SolidColorBrush(chip);
        resources["SettingsChipOnStroke"] = new SolidColorBrush(Color.FromArgb(89, tint.R, tint.G, tint.B));
        resources["SettingsChipOnText"] = new SolidColorBrush(Readable(tint, chip, dark));
        // Each service's ink on the cards, deeper than the island's so it reads on white, and its soft tile.
        void Tint(string name, Color light, Color night)
        {
            Color ink = dark ? night : light;
            resources["SettingsTint" + name] = new SolidColorBrush(ink);
            resources["SettingsTint" + name + "Soft"] = new SolidColorBrush(dark ? Color.FromArgb(51, ink.R, ink.G, ink.B) : Blend(ink, 0.12, Colors.White));
        }
        Tint("Codex", Color.FromRgb(14, 140, 120), Color.FromRgb(125, 214, 196));
        Tint("Claude", Color.FromRgb(196, 88, 31), Color.FromRgb(242, 156, 107));
        Tint("DeepSeek", Color.FromRgb(62, 91, 219), Color.FromRgb(123, 147, 255));
        Tint("Neutral", Color.FromRgb(110, 110, 115), Color.FromRgb(157, 157, 162));
    }

    private static Color Blend(Color top, double alpha, Color under)
    {
        byte Mix(byte over, byte below) => (byte)Math.Round(below + (over - below) * alpha);
        return Color.FromRgb(Mix(top.R, under.R), Mix(top.G, under.G), Mix(top.B, under.B));
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
