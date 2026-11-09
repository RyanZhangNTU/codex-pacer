using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// The collapsed bar's one typesetting: values in the primary colour with
/// tabular figures, units one step smaller at 60% white, glyphs in the unit colour.
internal static class CompactInk
{
    private static readonly Brush DarkUnit = PacerPalette.Ink(235, 235, 245, 153), LightUnit = PacerPalette.Ink(60, 60, 67, 184);
    internal static Brush Unit => PacerPalette.Light ? LightUnit : DarkUnit;
    internal static Brush Hairline => PacerPalette.Overlay(41);
    internal static Brush Faint => PacerPalette.Overlay(28);
    internal static readonly Geometry Stopwatch = Icon("M5.5 1.2v1.4M4.2 1.2h2.6M5.5 7.1V5M9 3.7l.8-.8M5.5 11.2a4.3 4.3 0 1 0 0-8.6 4.3 4.3 0 0 0 0 8.6Z");
    internal static readonly Geometry Hourglass = Icon("M1 .8h7M1 11.2h7M1.8.8c0 2.9 4.7 3.3 4.7 5.2S1.8 8.3 1.8 11.2M7.2.8c0 2.9-4.7 3.3-4.7 5.2s4.7 2.3 4.7 5.2");
    private static Geometry Icon(string data) { var value = Geometry.Parse(data); value.Freeze(); return value; }
    internal static Brush Tone(string? tone) => tone == "attention" ? PacerPalette.Attention : tone == "failed" ? PacerPalette.Danger : PacerPalette.Primary;
    internal static TextBlock Text(double size, FontWeight weight, Brush ink)
    {
        var text = new TextBlock { FontFamily = PacerFonts.Interface, FontSize = size, FontWeight = weight, Foreground = ink,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false };
        System.Windows.Documents.Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular); return text;
    }
    internal static double Measure(string text, double size, FontWeight weight) => MeasureSize(text, size, weight).Width;
    /// The text's natural size, including the taller line of a CJK fallback font.
    internal static Size MeasureSize(string text, double size, FontWeight weight)
    {
        var probe = Text(size, weight, PacerPalette.Primary); probe.Text = text;
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return probe.DesiredSize;
    }
    internal static Path Glyph(Geometry data, double width, double height, double scale) => new()
    {
        Data = data, Stroke = Unit, StrokeThickness = 1.2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round, Width = width * scale, Height = height * scale, Stretch = Stretch.None,
        LayoutTransform = new ScaleTransform(scale, scale), VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false
    };
}

/// One number with its unit, optionally after a glyph. In the strip the
/// parts stack in one cell.
internal sealed class CompactValueView : StackPanel
{
    private readonly TextBlock number = CompactInk.Text(13, FontWeights.SemiBold, PacerPalette.Primary);
    private readonly TextBlock unit = CompactInk.Text(10, FontWeights.Medium, CompactInk.Unit);
    private readonly Geometry? icon;
    private readonly double iconWidth, iconHeight;
    private Path? glyph;
    private double glyphScale;
    internal string Text => number.Text;
    internal string UnitText => unit.Visibility == Visibility.Visible ? unit.Text : "";
    internal CompactValueView(bool vertical, Geometry? icon = null, double iconWidth = 0, double iconHeight = 0)
    {
        Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center; HorizontalAlignment = HorizontalAlignment.Center; IsHitTestVisible = false;
        this.icon = icon; this.iconWidth = iconWidth; this.iconHeight = iconHeight;
        // A number sits right after its glyph or neighbour, at the bar's one gap.
        number.TextAlignment = vertical ? TextAlignment.Center : TextAlignment.Left;
        if (!vertical) { number.VerticalAlignment = unit.VerticalAlignment = VerticalAlignment.Bottom; }
        Children.Add(number); Children.Add(unit);
    }
    internal void Update(string? text, string? unitText, Brush ink, CompactMetrics sizes)
    {
        bool vertical = Orientation == Orientation.Vertical;
        double scale = sizes.Scale, value = vertical ? sizes.StripValue : sizes.Value, small = vertical ? sizes.StripUnit : sizes.Unit;
        if (icon != null && (glyph == null || glyphScale != scale))
        {
            if (glyph != null) Children.Remove(glyph);
            glyph = CompactInk.Glyph(icon, iconWidth, iconHeight, scale); glyphScale = scale;
            glyph.Margin = vertical ? new Thickness(0, 0, 0, 2 * scale) : new Thickness(0, 0, 4 * scale, 0);
            Children.Insert(0, glyph);
        }
        number.Text = text ?? "—"; number.FontSize = value; number.Foreground = ink;
        unit.Text = unitText ?? ""; unit.FontSize = small; unit.Foreground = CompactInk.Unit;
        if (glyph != null) glyph.Stroke = CompactInk.Unit;
        unit.Visibility = string.IsNullOrEmpty(unitText) ? Visibility.Collapsed : Visibility.Visible;
        unit.Margin = vertical ? new Thickness(0) : new Thickness(1.5 * scale, 0, 0, 0);
        // Baselines: the smaller unit sits on the number's baseline.
        if (!vertical) unit.Padding = new Thickness(0, 0, 0, Math.Max(0, (value - small) * 0.12));
    }
}

/// Status words that fade at their end instead of being cut, colour only what
/// needs the user, and slide in when they change. Changes that follow within
/// `Settle` of the previous one switch in place, so a burst never flickers and
/// nothing is held for later.
internal sealed class CompactStatusText : Decorator
{
    internal static readonly TimeSpan Settle = TimeSpan.FromSeconds(1.5);
    private readonly Grid stage = new() { ClipToBounds = true };
    private TextBlock current = CompactInk.Text(12.5, FontWeights.Medium, PacerPalette.Primary);
    private (string Text, string? Tone, double MaxWidth, double Size) shown = ("", null, 0, 0);
    private DateTime lastChange = DateTime.MinValue;
    private readonly List<AnimationLease> clocks = [];
    internal string Text => current.Text;
    internal string? Tone => shown.Tone;
    /// Repaints the shown words in the island's current tone.
    internal void Repaint() => current.Foreground = CompactInk.Tone(shown.Tone);
    internal bool Fades => current.OpacityMask != null;
    internal CompactStatusText()
    {
        IsHitTestVisible = false; VerticalAlignment = VerticalAlignment.Center; HorizontalAlignment = HorizontalAlignment.Left;
        current.HorizontalAlignment = HorizontalAlignment.Left; stage.Children.Add(current); Child = stage;
        Unloaded += (_, _) => { foreach (var clock in clocks) clock.Dispose(); clocks.Clear(); };
    }
    internal void Update(string? text, string? tone, double maxWidth, double size, bool animations)
    {
        var next = (text ?? "", tone, maxWidth > 0 ? maxWidth : 108, size);
        if (next == shown) return;
        bool words = next.Item1 != shown.Text || next.tone != shown.Tone;
        // Only a change after a settled moment slides; a burst switches in place.
        bool slide = animations && words && shown.Text.Length > 0 && DateTime.UtcNow - lastChange >= Settle;
        Apply(next, slide);
    }
    private void Apply((string Text, string? Tone, double MaxWidth, double Size) value, bool slide)
    {
        bool changed = value.Text != shown.Text || value.Tone != shown.Tone;
        shown = value; if (changed) lastChange = DateTime.UtcNow;
        var measured = CompactInk.MeasureSize(value.Text.Length > 0 ? value.Text : " ", value.Size, FontWeights.Medium);
        double natural = Math.Ceiling(measured.Width);
        Width = Math.Min(natural, value.MaxWidth); Height = Math.Ceiling(Math.Max(measured.Height, value.Size * 1.35));
        foreach (var clock in clocks) clock.Dispose(); clocks.Clear();
        // An interrupted change leaves only the words now shown, at rest.
        foreach (var stale in stage.Children.OfType<TextBlock>().Where(child => !ReferenceEquals(child, current)).ToArray()) stage.Children.Remove(stale);
        current.BeginAnimation(OpacityProperty, null); current.Opacity = 1; current.RenderTransform = null;
        var outgoing = current;
        var incoming = slide && changed ? CompactInk.Text(value.Size, FontWeights.Medium, PacerPalette.Primary) : current;
        incoming.HorizontalAlignment = HorizontalAlignment.Left;
        incoming.Text = value.Text; incoming.FontSize = value.Size; incoming.Foreground = CompactInk.Tone(value.Tone);
        incoming.TextTrimming = TextTrimming.None; incoming.Width = Math.Max(natural, 1);
        // Past the widest it may draw, the end fades out instead of being cut.
        incoming.OpacityMask = natural > value.MaxWidth + 0.5 ? new LinearGradientBrush(new GradientStopCollection
        {
            new(Colors.Black, 0), new(Colors.Black, Math.Max(0, (value.MaxWidth * 0.82) / natural)), new(Colors.Transparent, value.MaxWidth / natural)
        }, new Point(0, 0), new Point(1, 0)) : null;
        if (ReferenceEquals(incoming, outgoing)) return;
        current = incoming; stage.Children.Add(incoming);
        var rise = new TranslateTransform(0, 6); incoming.RenderTransform = rise; incoming.Opacity = 0;
        var fall = new TranslateTransform(0, 0); outgoing.RenderTransform = fall;
        TimeSpan duration = TimeSpan.FromSeconds(0.25);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        clocks.Add(new(new DoubleAnimation(6, 0, duration) { EasingFunction = ease }, clock => rise.ApplyAnimationClock(TranslateTransform.YProperty, clock)));
        clocks.Add(new(new DoubleAnimation(0, 1, duration), clock => incoming.ApplyAnimationClock(OpacityProperty, clock), () => { incoming.BeginAnimation(OpacityProperty, null); incoming.Opacity = 1; }));
        clocks.Add(new(new DoubleAnimation(0, -6, duration) { EasingFunction = ease }, clock => fall.ApplyAnimationClock(TranslateTransform.YProperty, clock)));
        clocks.Add(new(new DoubleAnimation(1, 0, duration), clock => outgoing.ApplyAnimationClock(OpacityProperty, clock), () => stage.Children.Remove(outgoing)));
    }
}
