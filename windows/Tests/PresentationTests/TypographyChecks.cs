using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using CodexPacer.Windows;

internal static class TypographyChecks
{
    internal static void Run()
    {
        foreach (var weight in new[] { FontWeights.Normal, FontWeights.Medium, FontWeights.SemiBold, FontWeights.Bold }) Check(PacerFonts.Interface, weight);
        Check(new AlternatingQuotaText().FontFamily, FontWeights.SemiBold);
        var dial = new QuotaDial("codex", null, null);
        Check(dial.DetailTypeface, FontWeights.Medium); Check(dial.ValueTypeface, FontWeights.SemiBold);
        var heading = new LegacyQuotaHeading(new("synthetic", "7d", 40, 50, 80, "40", "Synthetic", "Synthetic", "Synthetic", "Synthetic"));
        Check(heading.FontFace, FontWeights.SemiBold);
        Console.WriteLine("PASS actual font faces: embedded Inter regular/medium/semibold/bold bytes, code dials and collapsed labels resolve without system fallback");
    }
    internal static void Check(FontFamily family, FontWeight weight) => Check(new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal), weight);
    private static void Check(Typeface face, FontWeight weight)
    {
        if (!face.TryGetGlyphTypeface(out var glyph) || glyph.Weight != weight || !glyph.FamilyNames.Values.Contains("Inter")
            || !glyph.FontUri.AbsoluteUri.StartsWith("pack://application:,,,/CodexPacer;component/Assets/Fonts/", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The actual UI face must resolve to the embedded Inter weight, without a system fallback.");
        CheckRenderedFace(glyph);
    }
    internal static void CheckRenderedFace(GlyphTypeface glyph)
    {
        if (!glyph.FamilyNames.Values.Contains("Inter") || !glyph.FontUri.AbsoluteUri.StartsWith("pack://application:,,,/CodexPacer;component/Assets/Fonts/", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Rendered Latin glyphs must use the embedded Inter face.");
        using var stream = Application.GetResourceStream(glyph.FontUri).Stream;
        if (stream.Length == 0) throw new InvalidOperationException("The embedded font resource must contain data.");
    }
}
