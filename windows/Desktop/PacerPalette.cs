using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The island's inks. Light Liquid Glass turns the whole island light, so the
/// neutral inks, the services' shades and the overlays switch to their light
/// tone together; Settings keeps its own theme and only its island previews
/// follow. Views read these when they draw, and the island redraws on a switch.
internal static class PacerPalette
{
    private static readonly Brush DarkPrimary = Ink(245, 245, 245), DarkSecondary = Ink(158, 158, 158), DarkTertiary = Ink(107, 107, 107);
    private static readonly Brush LightPrimary = Ink(29, 29, 31), LightSecondary = Ink(60, 60, 67, 184), LightTertiary = Ink(60, 60, 67, 120);
    private static readonly Brush DarkAttention = Ink(255, 189, 97), LightAttention = Ink(178, 106, 0);
    private static readonly Brush DarkDanger = Ink(255, 115, 107), LightDanger = Ink(211, 58, 47);
    private static readonly Brush DarkPaused = Ink(219, 196, 153), LightPaused = Ink(140, 109, 46);
    private static readonly Dictionary<(bool, byte), Brush> Overlays = new();
    /// Whether the island draws its light tone, for Light Liquid Glass.
    internal static bool Light { get; private set; }
    internal static Brush Primary { get; private set; } = DarkPrimary;
    internal static Brush Secondary { get; private set; } = DarkSecondary;
    internal static Brush Tertiary { get; private set; } = DarkTertiary;
    internal static Brush Attention { get; private set; } = DarkAttention;
    // Resolved from the original Legacy Color.orange under dark Aqua.
    internal static Brush LegacyPace => Light ? LightAttention : DarkLegacyPace;
    private static readonly Brush DarkLegacyPace = Ink(255, 146, 48);
    internal static Brush Danger { get; private set; } = DarkDanger;
    internal static Brush Paused { get; private set; } = DarkPaused;
    internal static Brush Hairline => Overlay(20);
    internal static Brush Hover => Overlay(20);
    /// A neutral wash over the island: white on the dark tone, black on the light one.
    internal static Brush Overlay(byte alpha)
    {
        lock (Overlays)
        {
            if (!Overlays.TryGetValue((Light, alpha), out var brush))
                Overlays[(Light, alpha)] = brush = Light ? Ink(0, 0, 0, alpha) : Ink(255, 255, 255, alpha);
            return brush;
        }
    }
    /// The colour of marks drawn over the arcs, such as the pace tick and the clock hand.
    internal static Color Neutral => Light ? Color.FromRgb(29, 29, 31) : Colors.White;
    internal static Brush Tick => Light ? LightPrimary : Brushes.White;
    /// The island's own opaque face, for previews of it elsewhere.
    internal static Brush Surface => Light ? LightSurface : Brushes.Black;
    private static readonly Brush LightSurface = Ink(236, 236, 240);
    internal static Brush Provider(string? provider) => provider switch
    {
        null or "codex" => Codex,
        "claude" => Claude,
        "deepseek" => DeepSeek,
        "workbuddy" => LocalHarness,
        _ => Primary
    };
    internal static readonly Brush BrandCodex = Ink(125, 214, 196);
    internal static readonly Brush BrandClaude = Ink(242, 156, 107);
    internal static readonly Brush BrandDeepSeek = Ink(123, 147, 255);
    private static readonly Brush BrandLocalHarness = Ink(195, 171, 241), LightLocalHarness = Ink(105, 66, 162);
    // A shade darker on light glass, so each service keeps its contrast.
    private static readonly Brush LightCodex = Ink(14, 140, 120), LightClaude = Ink(196, 88, 31), LightDeepSeek = Ink(62, 91, 219);
    // The services' colors follow the accent choice; Multicolor keeps the brands.
    internal static Brush Codex { get; private set; } = BrandCodex;
    internal static Brush Claude { get; private set; } = BrandClaude;
    internal static Brush DeepSeek { get; private set; } = BrandDeepSeek;
    private static Brush LocalHarness { get; set; } = BrandLocalHarness;
    internal static string Accent { get; private set; } = "multicolor";
    /// Returns whether the services' colors changed, so drawn views can repaint.
    internal static bool ApplyAccent(string? accent)
    {
        accent = AccentPalette.Valid(accent) ? accent! : "multicolor";
        if (accent == Accent) return false;
        Accent = accent; Shade();
        return true;
    }
    /// Switches the island between its dark and light tone. Returns whether
    /// anything changed, so the island can redraw what it built earlier.
    internal static bool ApplyTone(bool light)
    {
        if (light == Light) return false;
        Light = light;
        Primary = light ? LightPrimary : DarkPrimary; Secondary = light ? LightSecondary : DarkSecondary; Tertiary = light ? LightTertiary : DarkTertiary;
        Attention = light ? LightAttention : DarkAttention; Danger = light ? LightDanger : DarkDanger; Paused = light ? LightPaused : DarkPaused;
        Shade();
        if (Application.Current?.Resources is { } resources)
        {
            resources["Island.Primary"] = Primary; resources["Island.Secondary"] = Secondary; resources["Island.Tertiary"] = Tertiary;
            resources["Island.Soft"] = light ? Ink(29, 29, 31, 200) : Ink(211, 211, 211);
            resources["Island.Attention"] = Attention;
            resources["Island.Overlay05"] = Overlay(13); resources["Island.Overlay08"] = Overlay(20); resources["Island.Overlay16"] = Overlay(41);
            resources["Island.Focus"] = Overlay(153);
        }
        return true;
    }
    /// Codex's shade in either tone, for a preview of a material that is not the current one.
    internal static Brush CodexShade(bool light) => AccentPalette.ProviderShade(Accent, "codex", light) is { } color ? Ink(color.R, color.G, color.B) : light ? LightCodex : BrandCodex;
    private static void Shade()
    {
        Brush Pick(string provider, Brush brand, Brush light) => AccentPalette.ProviderShade(Accent, provider, Light) is { } color ? Ink(color.R, color.G, color.B) : Light ? light : brand;
        Codex = Pick("codex", BrandCodex, LightCodex); Claude = Pick("claude", BrandClaude, LightClaude); DeepSeek = Pick("deepseek", BrandDeepSeek, LightDeepSeek);
        LocalHarness = Pick("workbuddy", BrandLocalHarness, LightLocalHarness);
    }
    internal static SolidColorBrush Ink(byte red, byte green, byte blue, byte alpha = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(alpha, red, green, blue));
        brush.Freeze();
        return brush;
    }
}
