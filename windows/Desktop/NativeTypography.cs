using System.Globalization;
using System.Windows;
using System.Windows.Media;
namespace CodexPacer.Windows;
internal static class NativeTypography
{
    internal static double RateUnitWidth => Measure("t/s", 9);
    internal static double? CompactWidth(string text, double size) => size == 12 && text.Length > 0 ? Measure(text, size) : null;
    private static double Measure(string text, double size) => new FormattedText(text, CultureInfo.InvariantCulture,
        FlowDirection.LeftToRight, new Typeface(PacerFonts.Interface, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
        size, Brushes.White, 1).WidthIncludingTrailingWhitespace;
}
