using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace CodexPacer.Windows;

/// Frozen pens and brushes shared by the drawn rings. A running light draws
/// every frame, and each frame used to allocate its own pens.
internal static class DrawingCache
{
    [ThreadStatic] private static Dictionary<(Color, double, PenLineCap), Pen>? colorPens;
    [ThreadStatic] private static Dictionary<(Brush, double, PenLineCap, bool), Pen>? brushPens;
    [ThreadStatic] private static Dictionary<Color, Brush>? brushes;
    private const int Capacity = 1024;
    internal static Brush Solid(Color color)
    {
        var cache = brushes ??= new();
        if (cache.TryGetValue(color, out var brush)) return brush;
        if (cache.Count >= Capacity) cache.Clear();
        brush = new SolidColorBrush(color); brush.Freeze();
        return cache[color] = brush;
    }
    internal static Pen Pen(Color color, double width, PenLineCap cap = PenLineCap.Flat)
    {
        var cache = colorPens ??= new();
        var key = (color, width, cap);
        if (cache.TryGetValue(key, out var pen)) return pen;
        if (cache.Count >= Capacity) cache.Clear();
        pen = new Pen(Solid(color), width) { StartLineCap = cap, EndLineCap = cap }; pen.Freeze();
        return cache[key] = pen;
    }
    /// A pen over a frozen brush is shared; a brush that can still change gets its own.
    internal static Pen Pen(Brush brush, double width, PenLineCap cap = PenLineCap.Flat, bool dashed = false)
    {
        Pen Make()
        {
            var made = new Pen(brush, width) { StartLineCap = cap, EndLineCap = cap };
            if (dashed) made.DashStyle = new DashStyle(new[] { 2 / width, 5 / width }, 0);
            return made;
        }
        if (!brush.IsFrozen) return Make();
        var cache = brushPens ??= new();
        var key = (brush, width, cap, dashed);
        if (cache.TryGetValue(key, out var pen)) return pen;
        if (cache.Count >= Capacity) cache.Clear();
        pen = Make(); pen.Freeze();
        return cache[key] = pen;
    }
}

/// One layer of a reported estimate, as the Mac draws it on the task icon and
/// the collapsed badge: the arc from the top with its soft glow, the light that
/// runs along it, or the stretch past its head that breathes during a long step.
/// Each layer is its own element so its opacity can animate alone.
internal sealed class EstimatePaint : FrameworkElement
{
    internal enum Layer { Arc, Flow, Step }
    /// The stretches past the head that breathe during a long step, as shares of the circle.
    internal static readonly double[] StepLengths = [0.1, 0.066, 0.033];
    internal const double FlowPeriod = 2.6, FlowTravel = 2.1, StepPeriod = 2.6;
    /// The running light's fading tail and soft front, as shares of the circle (the Mac's ArcLight).
    internal const double FlowTail = 0.22, FlowFront = 0.025;

    public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(nameof(Fraction), typeof(double), typeof(EstimatePaint),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Fraction { get => (double)GetValue(FractionProperty); set => SetValue(FractionProperty, value); }
    /// Where the running light's bright head is, as a share of the circle; see `Travel`.
    public static readonly DependencyProperty FlowHeadProperty = DependencyProperty.Register(nameof(FlowHead), typeof(double), typeof(EstimatePaint),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double FlowHead { get => (double)GetValue(FlowHeadProperty); set => SetValue(FlowHeadProperty, value); }

    private readonly Layer layer;
    private readonly double radius, stroke, glow;
    private Color ink = Colors.White;
    private bool stale, flowing, track, head, still;
    private double start, limit = 1, peak = 0.6;
    /// Where the light's stretch begins; an estimate's light starts at the top.
    internal double Start { get => start; set { if (start == value) return; start = value; InvalidateVisual(); } }
    /// Where the light's stretch ends: it runs only to the estimate even while the arc still sweeps there.
    internal double Limit { get => limit; set { if (limit == value) return; limit = value; InvalidateVisual(); } }
    /// The light's strength at its head: white over an arc is soft, Codex's own light full.
    internal double Peak { get => peak; set { if (peak == value) return; peak = value; InvalidateVisual(); } }
    /// Without motion the flow layer keeps a still, faint tint over its stretch instead.
    internal bool Still { get => still; set { if (still == value) return; still = value; InvalidateVisual(); } }

    internal EstimatePaint(Layer layer, double radius, double stroke, double glow)
    {
        this.layer = layer; this.radius = radius; this.stroke = stroke; this.glow = glow;
        IsHitTestVisible = false; SnapsToDevicePixels = false;
    }
    internal Color Ink { get => ink; set { if (ink == value) return; ink = value; InvalidateVisual(); } }
    internal bool Stale { get => stale; set { if (stale == value) return; stale = value; InvalidateVisual(); } }
    internal bool Flowing { get => flowing; set { if (flowing == value) return; flowing = value; InvalidateVisual(); } }
    /// The arc layer also draws the faint full circle under the estimate.
    internal bool Track { get => track; set { if (track == value) return; track = value; InvalidateVisual(); } }
    /// The arc layer also marks its head with a small white dot.
    internal bool Head { get => head; set { if (head == value) return; head = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext drawing)
    {
        double f = Math.Clamp(Fraction, 0, 1);
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        switch (layer)
        {
            case Layer.Arc:
                if (track) drawing.DrawEllipse(null, Pen(WithAlpha(PacerPalette.Neutral, 0.11), stroke, PenLineCap.Flat), center, radius, radius);
                if (f <= 0.0005) return;
                // The glow goes once the estimate is stale, as on the Mac.
                if (!stale && glow > 0) drawing.DrawGeometry(null, Pen(WithAlpha(ink, 0.22), glow, PenLineCap.Round), Arc(center, radius, 0, f));
                drawing.DrawGeometry(null, Pen(ink, stroke, PenLineCap.Round), Arc(center, radius, 0, f));
                if (head && f is > 0.02 and < 0.9995)
                    drawing.DrawEllipse(Brushes.White, null, new Point(center.X + radius * Math.Sin(f * 2 * Math.PI), center.Y - radius * Math.Cos(f * 2 * Math.PI)), 1.25, 1.25);
                break;
            case Layer.Flow:
                double end = Math.Min(f, limit), begin = Math.Min(start, end);
                if (still)
                {
                    if (end - begin > 0.0005) drawing.DrawGeometry(null, Pen(WithAlpha(ink, 0.4), stroke, PenLineCap.Flat), Arc(center, radius, begin, end));
                    return;
                }
                if (!flowing) return;
                // Only the light's own reach shows, and never outside its stretch. The
                // drawing turns to the head, so one cached pen serves every frame.
                double lit = FlowHead, from = Math.Max(begin, lit - FlowTail), to = Math.Min(end, lit + FlowFront);
                if (to - from <= 0.0005) return;
                var turn = new RotateTransform(lit * 360, center.X, center.Y); turn.Freeze();
                drawing.PushTransform(turn);
                drawing.DrawGeometry(null, LightPen(center), Arc(center, radius, from - lit, to - lit));
                drawing.Pop();
                break;
            case Layer.Step:
                if (f >= 0.9995) return;
                // Three stacked stretches past the head fade it out.
                foreach (double length in StepLengths)
                    drawing.DrawGeometry(null, Pen(WithAlpha(ink, 0.38), stroke, PenLineCap.Flat), Arc(center, radius, f, Math.Min(1, f + length)));
                break;
        }
    }
    /// The light as one smooth gradient: a conic picture of it with its head at
    /// the top, seen only through the stroke of its reach.
    private Pen LightPen(Point center)
    {
        double side = radius + stroke;
        var viewport = new Rect(center.X - side, center.Y - side, 2 * side, 2 * side);
        var cache = lightBrushes ??= new();
        if (!cache.TryGetValue((ink, peak, viewport), out var brush))
        {
            if (cache.Count >= 64) cache.Clear();
            brush = new ImageBrush(ConicLight(ink, peak)) { Stretch = Stretch.Fill, ViewportUnits = BrushMappingMode.Absolute, Viewport = viewport };
            brush.Freeze(); cache[(ink, peak, viewport)] = brush;
        }
        return DrawingCache.Pen(brush, stroke);
    }
    [ThreadStatic] private static Dictionary<(Color, double, Rect), Brush>? lightBrushes;
    /// How bright the light is at `offset` from its head, clockwise in circle
    /// shares: a soft front ahead, and behind it a tail that fades away.
    internal static double LightShare(double offset)
    {
        if (offset >= 0) return offset >= FlowFront ? 0 : 1 - offset / FlowFront;
        double along = -offset / FlowTail;
        if (along >= 1) return 0;
        for (int index = 1; index < TailFade.Length; index++)
        {
            var (share, alpha) = TailFade[index];
            if (along > share) continue;
            var (before, from) = TailFade[index - 1];
            return from + (alpha - from) * (along - before) / (share - before);
        }
        return 0;
    }
    private static readonly (double Share, double Alpha)[] TailFade = [(0, 1), (0.2, 0.62), (0.5, 0.28), (0.8, 0.08), (1, 0)];
    [ThreadStatic] private static Dictionary<(Color, double), BitmapSource>? lights;
    private static BitmapSource ConicLight(Color color, double strength)
    {
        var cache = lights ??= new();
        if (cache.TryGetValue((color, strength), out var cached)) return cached;
        if (cache.Count >= 64) cache.Clear();
        const int side = 128;
        var pixels = new byte[side * side * 4];
        for (int y = 0; y < side; y++)
            for (int x = 0; x < side; x++)
            {
                // Clockwise from the top on screen, as every ring here measures.
                double share = Math.Atan2(x + 0.5 - side / 2.0, side / 2.0 - y - 0.5) / (2 * Math.PI);
                double alpha = color.A / 255.0 * strength * LightShare(share);
                int at = (y * side + x) * 4;
                pixels[at] = (byte)Math.Round(color.B * alpha); pixels[at + 1] = (byte)Math.Round(color.G * alpha);
                pixels[at + 2] = (byte)Math.Round(color.R * alpha); pixels[at + 3] = (byte)Math.Round(255 * alpha);
            }
        var bitmap = BitmapSource.Create(side, side, 96, 96, PixelFormats.Pbgra32, null, pixels, side * 4);
        bitmap.Freeze();
        return cache[(color, strength)] = bitmap;
    }
    /// One run of the light on the shared clock: its head enters just before
    /// `from`, leaves past `to` with its tail within `FlowTravel`, then rests
    /// unseen until `FlowPeriod` ends, so every light in Pacer moves together.
    internal static DoubleAnimationUsingKeyFrames Travel(double from, double to, double now, int frameRate)
    {
        double first = from - FlowFront, last = to + FlowTail;
        var run = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(FlowPeriod), RepeatBehavior = RepeatBehavior.Forever,
            BeginTime = TimeSpan.FromSeconds(-(now % FlowPeriod)) };
        run.KeyFrames.Add(new LinearDoubleKeyFrame(first, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        run.KeyFrames.Add(new LinearDoubleKeyFrame(last, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(FlowTravel))));
        run.KeyFrames.Add(new DiscreteDoubleKeyFrame(last, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(FlowPeriod))));
        Timeline.SetDesiredFrameRate(run, frameRate);
        return run;
    }
    private static Pen Pen(Color color, double width, PenLineCap cap) => DrawingCache.Pen(color, width, cap);
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

/// Codex for Claude runs over an estimate: Codex's light travels the stretch of
/// the ring the estimate has not reached, from just past its head to just before
/// the top (or the end of a task's segment), on the clock of the light along the
/// estimate's arc, so the two move together. Without motion the stretch keeps a
/// still, faint Codex tint.
internal sealed class HelperLight
{
    /// Kept clear past the estimate's head and before the stretch's end, as a share of the circle.
    internal const double Gap = 0.035;
    internal EstimatePaint Paint { get; }
    private AnimationLease? loop;
    private int loopRate;
    /// The stretch the light travels, in circle shares, or null; read by the presentation checks.
    internal (double Start, double End)? Stretch { get; private set; }
    internal bool Travels => loop != null;
    internal bool Tinted => Stretch != null && Paint.Still;
    internal HelperLight(double radius, double stroke)
        => Paint = new(EstimatePaint.Layer.Flow, radius, stroke, 0) { Width = 20, Height = 20, Peak = 1, Fraction = 1 };
    /// The stretch after `head` up to `end`, both in circle shares, or null when too short to read.
    internal static (double Start, double End)? Free(double head, double end)
    {
        double from = Math.Max(0, head) + Gap, to = end - Gap;
        return to - from < 2 * Gap ? null : (from, to);
    }
    internal void Set((double Start, double End)? stretch, bool animate, bool live, int frameRate)
    {
        Paint.Ink = PacerPalette.Provider("codex") is SolidColorBrush brush ? brush.Color : PacerPalette.Neutral;
        Paint.Start = stretch?.Start ?? 0; Paint.Limit = stretch?.End ?? 0;
        Paint.Still = stretch != null && !animate;
        bool travel = stretch != null && animate && live;
        if (travel == (loop != null) && stretch == Stretch && (!travel || frameRate == loopRate)) { Stretch = stretch; return; }
        Stretch = stretch;
        loop?.Dispose(); loop = null; Paint.BeginAnimation(EstimatePaint.FlowHeadProperty, null);
        Paint.Flowing = travel;
        if (stretch is not { } run || !travel) return;
        loopRate = frameRate;
        loop = new AnimationLease(EstimatePaint.Travel(run.Start, run.End, TaskProgressRing.Now, frameRate),
            clock => Paint.ApplyAnimationClock(EstimatePaint.FlowHeadProperty, clock));
    }
    internal void Stop() => Set(null, false, false, loopRate);
    /// A new loop rate restarts a travelling light on the shared clock, so its phase carries over.
    internal void Retime(int frameRate)
    {
        if (loop == null || Stretch is not { } run || frameRate == loopRate) return;
        loop.Dispose(); loopRate = frameRate;
        loop = new AnimationLease(EstimatePaint.Travel(run.Start, run.End, TaskProgressRing.Now, frameRate),
            clock => Paint.ApplyAnimationClock(EstimatePaint.FlowHeadProperty, clock));
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
    private static Brush TrackInk => PacerPalette.Overlay(20);
    private readonly double radius, stroke;
    private Color ink = Colors.White;
    private bool still;
    internal CometPaint(double radius, double stroke) { this.radius = radius; this.stroke = stroke; IsHitTestVisible = false; }
    internal Color Ink { get => ink; set { if (ink == value) return; ink = value; InvalidateVisual(); } }
    internal bool Still { get => still; set { if (still == value) return; still = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext drawing)
    {
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        if (still) { drawing.DrawEllipse(null, DrawingCache.Pen(EstimatePaint.WithAlpha(ink, 0.5), stroke), center, radius, radius); return; }
        drawing.DrawEllipse(null, DrawingCache.Pen(TrackInk, stroke), center, radius, radius);
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
                drawing.DrawGeometry(null, DrawingCache.Pen(EstimatePaint.WithAlpha(ink, alpha), width), EstimatePaint.Arc(center, radius, far, near));
            }
        }
        // The head leads with a small dot.
        drawing.DrawEllipse(DrawingCache.Solid(ink), null, new Point(center.X, center.Y - radius), stroke / 2 + 0.2, stroke / 2 + 0.2);
    }
}
