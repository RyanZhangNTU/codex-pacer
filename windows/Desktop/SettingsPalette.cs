using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class SettingsPalette
{
    internal static void Apply(ResourceDictionary resources, bool dark, bool active)
    {
        void Brush(string key, byte red, byte green, byte blue) => resources[key] = new SolidColorBrush(Color.FromRgb(red, green, blue));
        void Gray(string key, byte value) => Brush(key, value, value, value);
        Gray("SettingsBackground", dark ? (byte)31 : (byte)255);
        Gray("SettingsSidebar", dark ? (byte)35 : (byte)249);
        Gray("SettingsCard", dark ? (byte)36 : (byte)247);
        Gray("SettingsTile", dark ? (byte)45 : (byte)237);
        Gray("SettingsCompactChip", dark ? (byte)31 : (byte)251);
        Gray("SettingsSegment", dark ? (byte)70 : (byte)202);
        Gray("SettingsPrimary", dark ? (byte)222 : (byte)36);
        Gray("SettingsSecondary", dark ? (byte)157 : (byte)119);
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
        Brush("SettingsAccent", 0, 122, 255);
        Brush("SettingsWarning", dark ? (byte)255 : (byte)194, dark ? (byte)146 : (byte)95, dark ? (byte)48 : (byte)0);
        Brush("SettingsSuccess", 48, 186, 85);
        if (active) Brush("SettingsSwitchOn", 0, 122, 255);
        else Gray("SettingsSwitchOn", dark ? (byte)81 : (byte)210);
    }
}
