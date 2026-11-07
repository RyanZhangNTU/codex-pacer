using System;
using System.Linq;
using System.Windows.Media;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// The Mac's accent choice: Multicolor keeps each service's own color and lets
/// the window's controls follow the system accent; a single color tints the
/// controls and turns the services into three shades of it. Amber and red keep
/// their meaning either way.
internal static class AccentPalette
{
    internal static string[] Choices => DesktopPreferences.AccentChoices;
    internal static bool Valid(string? value) => DesktopPreferences.ValidAccent(value);

    /// The single colors, in the Mac's order and values.
    internal static Color? Fixed(string? accent) => accent switch
    {
        "blue" => Color.FromRgb(0x0A, 0x84, 0xFF),
        "purple" => Color.FromRgb(0xBF, 0x5A, 0xF2),
        "pink" => Color.FromRgb(0xFF, 0x6B, 0xB5),
        "red" => Color.FromRgb(0xFF, 0x5A, 0x52),
        "orange" => Color.FromRgb(0xFF, 0x9F, 0x0A),
        "yellow" => Color.FromRgb(0xFF, 0xD6, 0x0A),
        "green" => Color.FromRgb(0x32, 0xD7, 0x4B),
        "graphite" => Color.FromRgb(0xA1, 0xA1, 0xA6),
        _ => null
    };

    /// Windows' own accent color, the counterpart of the Mac's system accent.
    internal static Color SystemAccent()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM");
            // AccentColor is stored as 0xAABBGGRR.
            if (key?.GetValue("AccentColor") is int value)
                return Color.FromRgb((byte)(value & 0xFF), (byte)((value >> 8) & 0xFF), (byte)((value >> 16) & 0xFF));
        }
        catch (Exception error) when (error is System.IO.IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        return Color.FromRgb(0, 122, 255);
    }

    /// The color of the main window's buttons, switches and selections.
    /// Synthetic previews and checks keep the classic blue instead of reading this PC's accent.
    internal static Color Controls(string? accent, bool followSystem = true) => Fixed(accent) ?? (followSystem ? SystemAccent() : Color.FromRgb(0, 122, 255));

    /// A service's color: its brand color with Multicolor, otherwise a shade of
    /// the accent. Codex takes the accent itself, Claude 42% and DeepSeek 66%
    /// of the way to white.
    internal static Color? ProviderShade(string? accent, string provider) => Fixed(accent) is { } color
        ? provider switch { "claude" => Lighten(color, .42), "deepseek" => Lighten(color, .66), _ => color }
        : null;

    internal static Color Lighten(Color color, double amount)
    {
        byte Mix(byte value) => (byte)Math.Round(value + (255 - value) * amount);
        return Color.FromRgb(Mix(color.R), Mix(color.G), Mix(color.B));
    }

    /// The window theme: Auto follows Windows; Light and Dark override it.
    internal static bool Dark(string? theme, bool system) => theme switch { "light" => false, "dark" => true, _ => system };
}
