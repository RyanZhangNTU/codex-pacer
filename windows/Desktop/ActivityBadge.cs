using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Interop;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

public sealed class ActivityBadge : Grid
{
    private readonly Border track = new() { BorderThickness = new Thickness(1.5), BorderBrush = PacerPalette.Ink(255, 255, 255, 26), CornerRadius = new CornerRadius(10) };
    private readonly Grid clipped = new();
    private readonly OrbitPaint paint = new();
    private readonly Border core = new() { Height = 15, MinWidth = 15, CornerRadius = new CornerRadius(7.5), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border ending = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), BorderBrush = PacerPalette.Ink(0, 0, 0, 217), BorderThickness = new Thickness(1.5),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -1, -1, 0) };
    private readonly RotateTransform rotation = new();
    private readonly ScaleTransform bloom = new(1, 1);
    private System.Windows.Shapes.Path? ripple;
    private bool blooming;
    internal (bool Ripple, bool Bloom, double Scale) TransientMotion => (ripple != null, blooming, bloom.ScaleX);
    private EngineHeader? previous;
    private bool rotating;
    private bool canAnimate = true;
    private ComposedBadgeOrbit? orbit;
    private bool compositionFailed;
    private AnimationLease? spin;
    private readonly List<AnimationLease> rippleClocks = [], bloomClocks = [];
    private HwndSource? orbitSource;
    /// With one task reporting an estimate, the orbit gives way to an arc from
    /// the top with the task rows' motion, as on the Mac.
    private readonly Grid estimate = new() { Width = 20, Height = 20, Opacity = 0, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    private readonly EstimatePaint estimateArc = new(EstimatePaint.Layer.Arc, 9, 2, 4) { Width = 20, Height = 20 };
    private readonly EstimatePaint estimateFlow = new(EstimatePaint.Layer.Flow, 9, 2, 0) { Width = 20, Height = 20 };
    private readonly EstimatePaint estimateStep = new(EstimatePaint.Layer.Step, 9, 2, 0) { Width = 20, Height = 20, Opacity = 0 };
    private AnimationLease? estimateSweep, estimateFlowLoop, estimateStepLoop;
    private double? estimateFlowTo;
    /// Ink on a solid ending, as in the task rows.
    private static readonly Brush EndingMarkInk = PacerPalette.Ink(0, 0, 0, 189);
    internal bool ShowsEstimate => estimate.Visibility == Visibility.Visible && previous?.ProgressFraction != null;
    internal double EstimateFraction => estimateArc.Fraction;
    /// Whether everything ended and the core is a solid disc; read by the presentation checks.
    internal bool CoreIsSolid => core.Background is LinearGradientBrush;
    /// The estimate's loops, such as flow or step; read by the presentation checks.
    internal string EstimateLoops => string.Join(",", new[] { estimateFlowLoop != null ? "flow" : null, estimateStepLoop != null ? "step" : null }.Where(value => value != null));
    internal (bool Composed, bool FallbackClock, long Uploads, IntPtr Window) RotationScheduling => (orbit != null && rotating, spin != null, orbit?.Uploads ?? 0, orbit?.WindowHandle ?? IntPtr.Zero);
    internal void InjectOrbitDeviceLoss() => orbit?.InjectDeviceLoss();
    internal bool HasEndingMarker => ending.Visibility == Visibility.Visible;
    public ActivityBadge()
    {
        Width = Height = 20; IsHitTestVisible = false;
        RenderTransform = bloom; RenderTransformOrigin = new Point(0.5, 0.5);
        paint.HorizontalAlignment = HorizontalAlignment.Center; paint.VerticalAlignment = VerticalAlignment.Center;
        paint.RenderTransform = rotation; paint.RenderTransformOrigin = new Point(0.5, 0.5); paint.CacheMode = new BitmapCache(2);
        clipped.Children.Add(paint);
        estimate.Children.Add(estimateArc); estimate.Children.Add(estimateFlow); estimate.Children.Add(estimateStep);
        Children.Add(track); Children.Add(clipped); Children.Add(estimate); Children.Add(core); Children.Add(ending);
        SizeChanged += (_, _) => UpdateClip();
        IsVisibleChanged += (_, _) => { UpdateRotation(); if (!IsVisible) StopTransient(); };
        Loaded += (_, _) =>
        {
            orbitSource = PresentationSource.FromVisual(this) as HwndSource; orbitSource?.AddHook(OrbitMessage);
            compositionFailed = false; UpdateRotation();
        };
        Unloaded += (_, _) =>
        {
            StopRotation(); StopTransient(); StopEstimate(); orbit?.Dispose(); orbit = null;
            if (orbitSource is { IsDisposed: false }) orbitSource.RemoveHook(OrbitMessage); orbitSource = null;
        };
    }
    internal void Update(EngineHeader value, bool? animations = null)
    {
        Width = value.CoreSymbol == null && value.ActiveCount >= 10 ? 27 : 20;
        canAnimate = animations ?? SystemParameters.ClientAreaAnimation;
        bool reduce = !canAnimate;
        paint.Update(value.Orbit, !reduce);
        bool hasOrbit = value.Orbit.Values.Any(count => count > 0) && value.ProgressFraction == null;
        track.Visibility = clipped.Visibility = hasOrbit ? Visibility.Visible : Visibility.Collapsed;
        UpdateEstimate(value, !reduce);
        // Everything ended: a solid disc in the ending's colour under a dark mark, as the rows draw it.
        Brush ink = value.Attention != null ? PacerPalette.Ink(66, 38, 5) : value.EndingIsCore ? EndingMarkInk : PacerPalette.Primary;
        if (value.CoreSymbol is string symbol)
            core.Child = new IconGlyph { Symbol = symbol.EndsWith(".circle", StringComparison.Ordinal) ? symbol[..^7] : symbol, Ink = ink, Width = 11, Height = 11,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        else if (value.ActiveCount > 0)
            core.Child = new TextBlock { Text = value.ActiveCountText ?? "—", FontSize = 10, FontWeight = FontWeights.Bold,
                Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        else core.Child = new Ellipse { Fill = PacerPalette.Tertiary, Width = 5, Height = 5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        if (value.EndingIsCore && value.Attention == null)
        {
            var tint = ((SolidColorBrush)EndingInk(value)).Color;
            core.Background = new LinearGradientBrush(Color.FromRgb((byte)(tint.R + (255 - tint.R) * 0.28), (byte)(tint.G + (255 - tint.G) * 0.28), (byte)(tint.B + (255 - tint.B) * 0.28)), tint, 90);
            // Lit from the top, as a row's disc.
            var sheen = new Border { CornerRadius = new CornerRadius(7.5), IsHitTestVisible = false,
                Background = new LinearGradientBrush(new GradientStopCollection { new(Color.FromArgb(66, 255, 255, 255), 0), new(Color.FromArgb(0, 255, 255, 255), 0.5) }, 90) };
            var mark = core.Child; core.Child = null;
            var face = new Grid(); face.Children.Add(sheen); if (mark != null) face.Children.Add(mark); core.Child = face;
        }
        else core.Background = value.Attention != null ? PacerPalette.Attention : Brushes.Transparent;
        core.BorderBrush = Brushes.Transparent; core.BorderThickness = new Thickness(0);
        ending.Background = EndingInk(value);
        ending.Visibility = value.Ending != null && !value.EndingIsCore ? Visibility.Visible : Visibility.Collapsed;
        if (reduce) StopTransient();
        else if (IsVisible && previous != null)
        {
            if (previous.Attention == null && value.Attention != null) Pulse();
            if (previous.Ending == null && value.Ending != null) Bloom();
        }
        previous = value;
        UpdateClip(); UpdateRotation();
    }
    /// The arc eases from the value shown to the new estimate and fades in over the orbit; light runs
    /// along a working estimate, and the stretch past its head breathes during a long step.
    private void UpdateEstimate(EngineHeader value, bool animate)
    {
        bool shows = value.ProgressFraction != null, showed = previous?.ProgressFraction != null;
        string? provider = value.Orbit.Where(pair => pair.Value > 0).Select(pair => pair.Key).FirstOrDefault();
        var tint = provider != null && PacerPalette.Provider(provider) is SolidColorBrush brush ? brush.Color : Colors.White;
        estimateArc.Ink = estimateStep.Ink = tint;
        if (!shows)
        {
            if (!showed) { estimate.Visibility = Visibility.Collapsed; return; }
            StopEstimate();
            if (!animate) { estimate.Visibility = Visibility.Collapsed; estimate.Opacity = 0; return; }
            var fade = new DoubleAnimation(estimate.Opacity, 0, TimeSpan.FromSeconds(0.3));
            fade.Completed += (_, _) => { if (previous?.ProgressFraction == null) { estimate.BeginAnimation(OpacityProperty, null); estimate.Opacity = 0; estimate.Visibility = Visibility.Collapsed; } };
            estimate.BeginAnimation(OpacityProperty, fade); return;
        }
        estimate.Visibility = Visibility.Visible;
        if (!showed && animate) estimate.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.3)));
        else { estimate.BeginAnimation(OpacityProperty, null); }
        estimate.Opacity = 1;
        bool stale = value.ProgressStale == true, longStep = value.ProgressLongStep == true;
        estimateArc.Stale = stale; estimateArc.Opacity = stale ? 0.45 : 1;
        double target = Math.Clamp(value.ProgressFraction!.Value, 0, 1), shown = showed ? estimateArc.Fraction : 0;
        estimateSweep?.Dispose(); estimateSweep = null;
        estimateArc.BeginAnimation(EstimatePaint.FractionProperty, null); estimateArc.Fraction = target;
        if (animate && Math.Abs(target - shown) > 0.0005)
        {
            var sweep = new DoubleAnimationUsingKeyFrames();
            sweep.KeyFrames.Add(new DiscreteDoubleKeyFrame(shown, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            sweep.KeyFrames.Add(new SplineDoubleKeyFrame(target, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.3 + 0.3 * Math.Abs(target - shown))), new KeySpline(0.33, 1, 0.68, 1)));
            estimateSweep = new AnimationLease(sweep, clock => estimateArc.ApplyAnimationClock(EstimatePaint.FractionProperty, clock), () => estimateSweep = null);
        }
        estimateFlow.Fraction = estimateStep.Fraction = target; estimateFlow.Limit = target;
        double now = TaskProgressRing.Now;
        bool live = animate && IsVisible;
        double? flow = live && !longStep && !stale && target is > 0.04 and < 0.9995 ? target : null;
        if (flow != estimateFlowTo)
        {
            estimateFlowLoop?.Dispose(); estimateFlowLoop = null; estimateFlow.BeginAnimation(EstimatePaint.FrontProperty, null);
            estimateFlowTo = flow; estimateFlow.Flowing = flow != null;
            if (flow is double fraction)
            {
                double reach = fraction + EstimatePaint.FlowLengths[0];
                var run = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(EstimatePaint.FlowPeriod), RepeatBehavior = RepeatBehavior.Forever,
                    BeginTime = TimeSpan.FromSeconds(-(now % EstimatePaint.FlowPeriod)) };
                run.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                run.KeyFrames.Add(new LinearDoubleKeyFrame(reach, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.FlowTravel))));
                run.KeyFrames.Add(new DiscreteDoubleKeyFrame(reach, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.FlowPeriod))));
                Timeline.SetDesiredFrameRate(run, 30);
                estimateFlowLoop = new AnimationLease(run, clock => estimateFlow.ApplyAnimationClock(EstimatePaint.FrontProperty, clock));
            }
        }
        bool step = longStep && target < 0.9995;
        if (live && step != (estimateStepLoop != null) || !live && estimateStepLoop != null)
        {
            estimateStepLoop?.Dispose(); estimateStepLoop = null; estimateStep.BeginAnimation(OpacityProperty, null);
            if (live && step)
            {
                var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
                var breath = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(EstimatePaint.StepPeriod), RepeatBehavior = RepeatBehavior.Forever,
                    BeginTime = TimeSpan.FromSeconds(-(now % EstimatePaint.StepPeriod)) };
                breath.KeyFrames.Add(new LinearDoubleKeyFrame(0.2, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                breath.KeyFrames.Add(new EasingDoubleKeyFrame(0.85, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.StepPeriod / 2)), ease));
                breath.KeyFrames.Add(new EasingDoubleKeyFrame(0.2, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.StepPeriod)), ease));
                Timeline.SetDesiredFrameRate(breath, 30);
                estimateStepLoop = new AnimationLease(breath, clock => estimateStep.ApplyAnimationClock(OpacityProperty, clock));
            }
        }
        if (estimateStepLoop == null) estimateStep.Opacity = step ? 0.55 : 0;
    }
    private void StopEstimate()
    {
        estimateSweep?.Dispose(); estimateSweep = null; estimateFlowLoop?.Dispose(); estimateFlowLoop = null; estimateStepLoop?.Dispose(); estimateStepLoop = null;
        estimateFlowTo = null; estimateFlow.Flowing = false; estimateFlow.BeginAnimation(EstimatePaint.FrontProperty, null); estimateStep.BeginAnimation(OpacityProperty, null);
    }
    private static Brush EndingInk(EngineHeader value) => value.Ending == "xmark.circle" ? PacerPalette.Danger
        : value.Ending == "pause.circle" ? PacerPalette.Paused : PacerPalette.Provider(value.EndingProvider);
    private static Brush WithAlpha(Brush ink, byte alpha)
    {
        var color = ((SolidColorBrush)ink).Color;
        return PacerPalette.Ink(color.R, color.G, color.B, alpha);
    }
    private void UpdateClip()
    {
        double width = Width;
        var shape = new GeometryGroup { FillRule = FillRule.EvenOdd };
        shape.Children.Add(new RectangleGeometry(new Rect(0, 0, width, 20), 10, 10));
        shape.Children.Add(new RectangleGeometry(new Rect(1.5, 1.5, width - 3, 17), 8.5, 8.5));
        shape.Freeze(); clipped.Clip = shape;
        paint.Width = paint.Height = Math.Ceiling(Math.Sqrt(width * width + 400)) + 2;
    }
    private void UpdateRotation()
    {
        bool animate = IsLoaded && IsVisible && canAnimate && previous?.Orbit.Values.Any(count => count > 0) == true && previous.ProgressFraction == null;
        if (animate == rotating) return;
        if (!animate) { StopRotation(); return; }
        if (!compositionFailed && IsLoaded)
        {
            try { orbit ??= new(this, paint, OrbitUnavailable); orbit.Set(true); }
            catch (Exception error) when (ComposedBadgeOrbit.Recoverable(error)) { OrbitUnavailable(); }
        }
        rotating = true;
        paint.Opacity = orbit == null ? 1 : 0;
        if (orbit != null) return;
        var animation = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.8)) { RepeatBehavior = RepeatBehavior.Forever };
        Timeline.SetDesiredFrameRate(animation, 30);
        spin = new(animation, clock => rotation.ApplyAnimationClock(RotateTransform.AngleProperty, clock));
    }
    private void StopRotation() { spin?.Dispose(); spin = null; orbit?.Set(false); paint.Opacity = 1; rotating = false; }
    private void OrbitUnavailable()
    {
        compositionFailed = true; orbit?.Dispose(); orbit = null; rotating = false;
        // Retry on a display/device notification, never in an idle timer.
        Dispatcher.BeginInvoke(UpdateRotation);
    }
    private IntPtr OrbitMessage(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message is 0x007E or 0x031E && compositionFailed)
        { StopRotation(); compositionFailed = false; UpdateRotation(); }
        return IntPtr.Zero;
    }
    private void Pulse()
    {
        StopRipple();
        var scale = new ScaleTransform(1, 1);
        var ring = new System.Windows.Shapes.Path { Width = Width - 5, Height = 15,
            Data = new RectangleGeometry(new Rect(0, 0, Width - 5, 15), 7.5, 7.5),
            Stroke = PacerPalette.Attention, StrokeThickness = 1.5, Opacity = 0,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            RenderTransform = scale, RenderTransformOrigin = new Point(0.5, 0.5), IsHitTestVisible = false };
        ripple = ring; Children.Add(ring);
        var fade = NativeBadgeCurves.Ripple.Animation(opacity: true);
        rippleClocks.Add(new(NativeBadgeCurves.Ripple.Animation(), clock => scale.ApplyAnimationClock(ScaleTransform.ScaleXProperty, clock)));
        rippleClocks.Add(new(NativeBadgeCurves.Ripple.Animation(), clock => scale.ApplyAnimationClock(ScaleTransform.ScaleYProperty, clock)));
        rippleClocks.Add(new(fade, clock => ring.ApplyAnimationClock(OpacityProperty, clock), () => { if (ReferenceEquals(ripple, ring)) StopRipple(); }));
    }
    private void Bloom()
    {
        blooming = true;
        foreach (var clock in bloomClocks) clock.Dispose(); bloomClocks.Clear();
        var animation = NativeBadgeCurves.Bloom.Animation();
        bloomClocks.Add(new(animation, clock => bloom.ApplyAnimationClock(ScaleTransform.ScaleXProperty, clock), () => blooming = false));
        bloomClocks.Add(new(NativeBadgeCurves.Bloom.Animation(), clock => bloom.ApplyAnimationClock(ScaleTransform.ScaleYProperty, clock)));
    }
    private void StopRipple()
    {
        foreach (var clock in rippleClocks.ToArray()) clock.Dispose(); rippleClocks.Clear();
        if (ripple == null) return;
        ripple.BeginAnimation(OpacityProperty, null);
        if (ripple.RenderTransform is ScaleTransform scale)
        {
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        }
        Children.Remove(ripple); ripple = null;
    }
    private void StopTransient()
    {
        StopRipple(); blooming = false;
        foreach (var clock in bloomClocks.ToArray()) clock.Dispose(); bloomClocks.Clear();
        bloom.BeginAnimation(ScaleTransform.ScaleXProperty, null); bloom.BeginAnimation(ScaleTransform.ScaleYProperty, null);
    }
}

/// <summary>A cached conic gradient; rotation runs independently from stop changes.</summary>
internal sealed class OrbitPaint : FrameworkElement
{
    private readonly record struct Stop(double Position, Color Color);
    private static readonly DependencyProperty ProgressProperty = DependencyProperty.Register("Progress", typeof(double), typeof(OrbitPaint),
        new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender, (sender, _) => ((OrbitPaint)sender).Changed?.Invoke()));
    private Stop[] from = [], to = [];
    private IReadOnlyDictionary<string, int>? weights;
    private bool animated;
    private AnimationLease? transition;
    internal event Action? Changed;
    internal OrbitPaint() { SizeChanged += (_, _) => Changed?.Invoke(); Unloaded += (_, _) => { transition?.Dispose(); transition = null; }; }
    internal void Update(IReadOnlyDictionary<string, int> values, bool animate)
    {
        if (weights != null && animated == animate && weights.Count == values.Count && weights.All(pair => values.TryGetValue(pair.Key, out int count) && count == pair.Value)) return;
        var shown = Current();
        var next = Stops(values, animate);
        bool ease = animated && animate && shown.Length == next.Length && shown.Length > 0;
        weights = values; animated = animate; from = shown; to = next;
        transition?.Dispose(); transition = null;
        SetValue(ProgressProperty, 1.0);
        if (ease)
        {
            var change = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.35) };
            change.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            change.KeyFrames.Add(new SplineDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.35)), new KeySpline(0.42, 0, 0.58, 1)));
            transition = new(change, clock => ApplyAnimationClock(ProgressProperty, clock));
        }
        InvalidateVisual(); Changed?.Invoke();
    }
    private Stop[] Current()
    {
        double progress = (double)GetValue(ProgressProperty);
        if (from.Length != to.Length || progress >= 1) return to;
        return to.Select((stop, index) => new Stop(from[index].Position + (stop.Position - from[index].Position) * progress,
            Mix(from[index].Color, stop.Color, progress))).ToArray();
    }
    private static Color Mix(Color a, Color b, double t) => Color.FromArgb(
        (byte)Math.Clamp(Math.Round(a.A + (b.A - a.A) * t), 0, 255), (byte)Math.Clamp(Math.Round(a.R + (b.R - a.R) * t), 0, 255),
        (byte)Math.Clamp(Math.Round(a.G + (b.G - a.G) * t), 0, 255), (byte)Math.Clamp(Math.Round(a.B + (b.B - a.B) * t), 0, 255));
    private static Stop[] Stops(IReadOnlyDictionary<string, int> weights, bool animate)
    {
        string[] providers = ["codex", "claude", "deepseek"];
        int Weight(string provider) => weights.TryGetValue(provider, out int count) ? Math.Max(0, count) : 0;
        int count = providers.Count(p => Weight(p) > 0), total = Math.Max(1, providers.Sum(Weight));
        double span = count > 1 ? 0.5 : 0.34, slot = 1.0 / Math.Max(1, count), last = 0;
        int rank = 0;
        var stops = new List<Stop>();
        foreach (string provider in providers)
        {
            var color = ((SolidColorBrush)PacerPalette.Provider(provider)).Color;
            var clear = Color.FromArgb(0, color.R, color.G, color.B);
            int weight = Weight(provider);
            if (!animate)
            {
                if (weight == 0) continue;
                color.A = 191; stops.Add(new(last, color)); last += (double)weight / total; stops.Add(new(last, color)); continue;
            }
            if (weight == 0) { for (int index = 0; index < 3; index++) stops.Add(new(last, clear)); continue; }
            double head = rank * slot, tail = head + Math.Min(span * weight / total, slot * 0.9);
            rank++; last = tail;
            stops.Add(new(head, clear)); stops.Add(new(head, color)); stops.Add(new(tail, clear));
        }
        return stops.ToArray();
    }
    protected override void OnRender(DrawingContext drawing)
        => Draw(drawing, ActualWidth, ActualHeight);
    internal RenderTargetBitmap Bitmap(double scale)
    {
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen()) Draw(drawing, Width, Height);
        var bitmap = new RenderTargetBitmap(Math.Max(1, (int)Math.Ceiling(Width * scale)), Math.Max(1, (int)Math.Ceiling(Height * scale)),
            96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(visual); bitmap.Freeze(); return bitmap;
    }
    private void Draw(DrawingContext drawing, double width, double height)
    {
        Stop[] stops = Current();
        if (stops.Length == 0) return;
        Color At(double fraction)
        {
            int index = 0;
            while (index + 1 < stops.Length && stops[index + 1].Position <= fraction) index++;
            if (index + 1 == stops.Length) return stops[index].Color;
            double span = stops[index + 1].Position - stops[index].Position;
            return Mix(stops[index].Color, stops[index + 1].Color, span <= 0 ? 1 : Math.Clamp((fraction - stops[index].Position) / span, 0, 1));
        }
        var centre = new Point(width / 2, height / 2);
        double radius = Math.Max(width, height);
        Point Point(double fraction) => new(centre.X + radius * Math.Cos((-90 - fraction * 360) * Math.PI / 180),
            centre.Y + radius * Math.Sin((-90 - fraction * 360) * Math.PI / 180));
        for (int step = 0; step < 360; step++)
        {
            Color color = At((step + 0.5) / 360);
            if (color.A == 0) continue;
            var path = new StreamGeometry();
            using (var geometry = path.Open()) { geometry.BeginFigure(centre, true, true); geometry.LineTo(Point(step / 360.0), true, false); geometry.LineTo(Point((step + 1.02) / 360.0), true, false); }
            path.Freeze();
            var ink = new SolidColorBrush(color); ink.Freeze(); drawing.DrawGeometry(ink, null, path);
        }
    }
}
