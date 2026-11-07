using System;
using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// One layer of a reported estimate, as the Mac draws it on the task icon and
/// the collapsed badge: the arc from the top with its soft glow, the band of
/// light that runs along it, or the stretch past its head that breathes during
/// a long step. Each layer is its own element so its opacity can animate alone.
internal sealed class EstimatePaint : FrameworkElement
{
    internal enum Layer { Arc, Flow, Step }
    /// The band lengths of the running light and the breathing tail, as shares of the circle.
    internal static readonly double[] FlowLengths = [0.22, 0.08], StepLengths = [0.1, 0.066, 0.033];
    internal const double FlowPeriod = 2.6, FlowTravel = 2.1, StepPeriod = 2.6;

    public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(nameof(Fraction), typeof(double), typeof(EstimatePaint),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Fraction { get => (double)GetValue(FractionProperty); set => SetValue(FractionProperty, value); }
    /// Where the running light's front is, from 0 to the estimate plus the long band.
    public static readonly DependencyProperty FrontProperty = DependencyProperty.Register(nameof(Front), typeof(double), typeof(EstimatePaint),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Front { get => (double)GetValue(FrontProperty); set => SetValue(FrontProperty, value); }

    private readonly Layer layer;
    private readonly double radius, stroke, glow;
    private Color ink = Colors.White;
    private bool stale, flowing;
    /// The light runs only to the estimate even while the arc still sweeps there.
    internal double Limit { get; set; } = 1;

    internal EstimatePaint(Layer layer, double radius, double stroke, double glow)
    {
        this.layer = layer; this.radius = radius; this.stroke = stroke; this.glow = glow;
        IsHitTestVisible = false; SnapsToDevicePixels = false;
    }
    internal Color Ink { get => ink; set { if (ink == value) return; ink = value; InvalidateVisual(); } }
    internal bool Stale { get => stale; set { if (stale == value) return; stale = value; InvalidateVisual(); } }
    internal bool Flowing { get => flowing; set { if (flowing == value) return; flowing = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext drawing)
    {
        double f = Math.Clamp(Fraction, 0, 1);
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        switch (layer)
        {
            case Layer.Arc:
                if (f <= 0.0005) return;
                // The glow goes once the estimate is stale, as on the Mac.
                if (!stale && glow > 0) drawing.DrawGeometry(null, Pen(WithAlpha(ink, 0.22), glow, PenLineCap.Round), Arc(center, radius, 0, f));
                drawing.DrawGeometry(null, Pen(ink, stroke, PenLineCap.Round), Arc(center, radius, 0, f));
                break;
            case Layer.Flow:
                if (!flowing) return;
                double limit = Math.Min(f, Limit), front = Front;
                foreach (var (length, alpha) in new[] { (FlowLengths[0], 0.3), (FlowLengths[1], 0.45) })
                {
                    double start = Math.Clamp(front - length, 0, limit), end = Math.Clamp(front, 0, limit);
                    if (end - start > 0.0005) drawing.DrawGeometry(null, Pen(WithAlpha(Colors.White, alpha), stroke, PenLineCap.Flat), Arc(center, radius, start, end));
                }
                break;
            case Layer.Step:
                if (f >= 0.9995) return;
                // Three stacked stretches past the head fade it out.
                foreach (double length in StepLengths)
                    drawing.DrawGeometry(null, Pen(WithAlpha(ink, 0.38), stroke, PenLineCap.Flat), Arc(center, radius, f, Math.Min(1, f + length)));
                break;
        }
    }
    private static Pen Pen(Color color, double width, PenLineCap cap) => new(new SolidColorBrush(color), width) { StartLineCap = cap, EndLineCap = cap };
    internal static Color WithAlpha(Color color, double share) => Color.FromArgb((byte)Math.Round(color.A * share), color.R, color.G, color.B);
    /// An arc clockwise from `from` to `to`, as shares of the circle measured from the top.
    internal static Geometry Arc(Point center, double radius, double from, double to)
    {
        if (to - from >= 0.9995) return new EllipseGeometry(center, radius, radius);
        Point At(double share) => new(center.X + radius * Math.Sin(share * 2 * Math.PI), center.Y - radius * Math.Cos(share * 2 * Math.PI));
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(At(from), false, false);
            context.ArcTo(At(to), new Size(radius, radius), 0, to - from > 0.5, SweepDirection.Clockwise, true, false);
        }
        geometry.Freeze(); return geometry;
    }
}

/// The Mac's comet: a head with a hard edge and a small dot leading it, a tail
/// that fades to nothing behind it and a soft glow, over a faint track. It turns
/// through its element's rotation. Still, it is a whole circle at half strength.
internal sealed class CometPaint : FrameworkElement
{
    public static readonly DependencyProperty TailProperty = DependencyProperty.Register(nameof(Tail), typeof(double), typeof(CometPaint),
        new FrameworkPropertyMetadata(0.5, FrameworkPropertyMetadataOptions.AffectsRender));
    /// The tail as a share of the circle.
    public double Tail { get => (double)GetValue(TailProperty); set => SetValue(TailProperty, value); }
    private static readonly Brush TrackInk = PacerPalette.Ink(255, 255, 255, 20);
    private readonly double radius, stroke;
    private Color ink = Colors.White;
    private bool still;
    internal CometPaint(double radius, double stroke) { this.radius = radius; this.stroke = stroke; IsHitTestVisible = false; }
    internal Color Ink { get => ink; set { if (ink == value) return; ink = value; InvalidateVisual(); } }
    internal bool Still { get => still; set { if (still == value) return; still = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext drawing)
    {
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        if (still) { drawing.DrawEllipse(null, new Pen(new SolidColorBrush(EstimatePaint.WithAlpha(ink, 0.5)), stroke), center, radius, radius); return; }
        drawing.DrawEllipse(null, new Pen(TrackInk, stroke), center, radius, radius);
        double tail = Math.Clamp(Tail, 0.005, 1);
        int count = Math.Max(4, (int)Math.Ceiling(tail * 72));
        for (int pass = 0; pass < 2; pass++)
        {
            // The glow first, wider and fainter, then the tail itself.
            double width = pass == 0 ? 4.5 : stroke, strength = pass == 0 ? 0.3 : 1;
            for (int index = 0; index < count; index++)
            {
                double near = -tail * index / count, far = -tail * (index + 1) / count - 0.002;
                double alpha = strength * (1 - index / (double)count);
                if (alpha <= 0.004) continue;
                drawing.DrawGeometry(null, new Pen(new SolidColorBrush(EstimatePaint.WithAlpha(ink, alpha)), width) { StartLineCap = PenLineCap.Flat, EndLineCap = PenLineCap.Flat },
                    EstimatePaint.Arc(center, radius, far, near));
            }
        }
        // The head leads with a small dot.
        drawing.DrawEllipse(new SolidColorBrush(ink), null, new Point(center.X, center.Y - radius), stroke / 2 + 0.2, stroke / 2 + 0.2);
    }
}
