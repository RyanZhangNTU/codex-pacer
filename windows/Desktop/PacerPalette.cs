using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class PacerPalette
{
    internal static readonly Brush Primary = Ink(245, 245, 245);
    internal static readonly Brush Secondary = Ink(158, 158, 158);
    internal static readonly Brush Tertiary = Ink(107, 107, 107);
    internal static readonly Brush Attention = Ink(255, 189, 97);
    // Resolved from the original Legacy Color.orange under dark Aqua.
    internal static readonly Brush LegacyPace = Ink(255, 146, 48);
    internal static readonly Brush Danger = Ink(255, 115, 107);
    internal static readonly Brush Paused = Ink(219, 196, 153);
    internal static readonly Brush Hairline = Ink(255, 255, 255, 20);
    internal static readonly Brush Hover = Ink(255, 255, 255, 20);
    internal static Brush Provider(string? provider) => provider switch
    {
        "claude" => Claude,
        "deepseek" => DeepSeek,
        _ => Codex
    };
    internal static readonly Brush Codex = Ink(125, 214, 196);
    internal static readonly Brush Claude = Ink(242, 156, 107);
    internal static readonly Brush DeepSeek = Ink(123, 147, 255);
    internal static SolidColorBrush Ink(byte red, byte green, byte blue, byte alpha = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(alpha, red, green, blue));
        brush.Freeze();
        return brush;
    }
}
