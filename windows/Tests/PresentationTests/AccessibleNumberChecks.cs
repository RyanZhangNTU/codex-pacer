using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using CodexPacer.Windows;
using static AccessibilityChecks;

internal static class AccessibleNumberChecks
{
    internal static void Run(string language)
    {
        var culture = CultureInfo.GetCultureInfo(language == "zh-Hans" ? "zh-Hans" : "en-US");
        foreach (string value in new[] { "100", "100.0", "99,999", "-12.34", "1.2k" })
        {
            var text = new TextBlock { FontFamily = PacerFonts.Interface, FontWeight = FontWeights.SemiBold, Language = XmlLanguage.GetLanguage(culture.Name) };
            // The strip's cell: 11.5-point values in the 22 points between its insets.
            IslandWindow.FitStripNumber(text, value);
            Check(text.Text == value && text.TextTrimming == TextTrimming.None, "Compact numeric fitting preserves every digit");
            foreach (double dpi in new[] { 1.0, 1.25, 1.5, 2.0 }) CheckWidth(text, culture, dpi, 22);
        }
        var quota = new AlternatingQuotaText { MaximumDisplayWidth = 26, FontSize = 11.5, Vertical = true, Language = XmlLanguage.GetLanguage(culture.Name) };
        quota.Update([("codex", "100.0"), ("claude", "99,999"), ("deepseek", "-12.34")], false);
        foreach (var layer in quota.Children.OfType<FrameworkElement>())
        {
            layer.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var text = SelfAndDescendants(layer).OfType<TextBlock>().Single();
            Check(text.TextTrimming == TextTrimming.None, "Alternating quota labels preserve their full numeric text");
            double scale = layer.LayoutTransform is ScaleTransform shrink ? shrink.ScaleX : 1;
            foreach (double dpi in new[] { 1.0, 1.25, 1.5, 2.0 }) CheckWidth(text, culture, dpi, 26 / scale);
        }
        Check(AutomationProperties.GetName(quota).Contains("99,999", StringComparison.Ordinal) && AutomationProperties.GetName(quota).Contains("-12.34", StringComparison.Ordinal),
            "Assistive technology receives full values for every provider");
        quota.Stop();
        Console.WriteLine("PASS numeric accessibility " + language + ": complete values and font measurements at 100/125/150/200 percent DPI");
    }
    private static void CheckWidth(TextBlock text, CultureInfo culture, double pixelsPerDip, double width)
    {
        var measured = new FormattedText(text.Text, culture, FlowDirection.LeftToRight,
            new Typeface(text.FontFamily, text.FontStyle, text.FontWeight, text.FontStretch), text.FontSize, Brushes.White, pixelsPerDip);
        Check(measured.WidthIncludingTrailingWhitespace <= width + .1, "Full numeric text must fit its logical width at DPI " + pixelsPerDip);
    }
}
