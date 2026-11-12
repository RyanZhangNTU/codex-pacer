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

/// The badge's component choices: what the core shows for one task and what
/// the ring shows while several run.
internal sealed record BadgeOptions(bool SinglePercent = false, string MultiRing = "service", string MultiCore = "count", bool EndMark = true)
{
    internal static BadgeOptions Default { get; } = new();
}

public sealed class ActivityBadge : Grid
{
    private readonly Border track = new() { BorderThickness = new Thickness(1.5), BorderBrush = PacerPalette.Overlay(26), CornerRadius = new CornerRadius(10) };
    private readonly Grid clipped = new();
    private readonly OrbitPaint paint = new();
    private readonly Border core = new() { Height = 15, MinWidth = 15, CornerRadius = new CornerRadius(7.5), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border ending = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), BorderBrush = PacerPalette.Ink(0, 0, 0, 217), BorderThickness = new Thickness(1.5),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -1, -1, 0) };
    private readonly RotateTransform rotation = new();
    private readonly ScaleTransform bloom = new(1, 1);
    // A failed ending shakes the badge once from side to side.
    private readonly TranslateTransform shake = new();
    private readonly List<AnimationLease> shakeClocks = [];
    // A request keeps a faint second ring around the amber disc after its ripples.
    private readonly Ellipse halo = new() { Width = 21.8, Height = 21.8, StrokeThickness = 1.1, Opacity = 0.4, Margin = new Thickness(-0.9),
        Visibility = Visibility.Collapsed, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    // One arc per running task, filled to its estimate.
    private readonly SegmentPaint segments = new() { Width = 20, Height = 20, Visibility = Visibility.Collapsed, IsHitTestVisible = false,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    // The whole segments of tasks without an estimate, breathing together over their tracks.
    private readonly SegmentPaint segmentBreath = new() { Breathing = true, Width = 20, Height = 20, Opacity = 0, Visibility = Visibility.Collapsed,
        IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private AnimationLease? segmentBreathLoop;
    private bool segmentBreathWanted;
    private static Brush SoftCore => PacerPalette.Overlay(18);
    private string? estimateProvider;
    private bool estimateWhite, segmentsShown;
    /// How the ring reads now: orbit, estimate, average, segments or none; read by the presentation checks.
    internal string RingMode { get; private set; } = "none";
    /// Codex's shade in the orbit now, which follows the accent and the island's tone; read by the presentation checks.
    internal Color OrbitCodexShade => paint.CodexShade;
    internal string CoreText => core.Child is TextBlock text ? text.Text : "";
    internal bool ShowsHalo => halo.Visibility == Visibility.Visible;
    internal int SegmentCount => segmentsShown ? segments.Count : 0;
    /// Whether segments of tasks without an estimate are breathing; read by the presentation checks.
    internal bool SegmentBreathing => segmentBreathLoop != null;
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
    private static readonly Brush Sheen = Frozen(new LinearGradientBrush(new GradientStopCollection { new(Color.FromArgb(66, 255, 255, 255), 0), new(Color.FromArgb(0, 255, 255, 255), 0.5) }, 90));
    private static Brush Frozen(Brush brush) { brush.Freeze(); return brush; }
    internal bool ShowsEstimate => estimate.Visibility == Visibility.Visible && previous?.ProgressFraction != null;
    internal double EstimateFraction => estimateArc.Fraction;
    /// Whether everything ended and the core is a solid disc; read by the presentation checks.
    internal bool CoreIsSolid => core.Background is LinearGradientBrush;
    /// The estimate's loops, such as flow or step; read by the presentation checks.
    internal string EstimateLoops => string.Join(",", new[] { estimateFlowLoop != null ? "flow" : null, estimateStepLoop != null ? "step" : null }.Where(value => value != null));
    internal (bool Composed, bool FallbackClock, long Uploads, IntPtr Window) RotationScheduling => (orbit != null && rotating, spin != null, orbit?.Uploads ?? 0, orbit?.WindowHandle ?? IntPtr.Zero);
    internal void InjectOrbitDeviceLoss() => orbit?.InjectDeviceLoss();
    internal bool HasEndingMarker => ending.Visibility == Visibility.Visible;
    /// The endless loops' rate: full while the panel is open, a recognisable but
    /// cheaper rate while only the collapsed bar shows them.
    internal const int OpenFrameRate = 30, CollapsedFrameRate = 12;
    private const double SpinPeriod = 1.8;
    private int frameRate = OpenFrameRate;
    private EngineHeader? lastValue;
    private BadgeOptions? lastOptions;
    private object? coreKey;
    private double clipWidth = double.NaN;
    internal int FrameRate
    {
        get => frameRate;
        set
        {
            if (frameRate == value) return;
            frameRate = value;
            // Each running loop restarts on the shared clock, so its phase carries over.
            if (estimateFlowLoop != null && estimateFlowTo is double flow) { estimateFlowLoop.Dispose(); estimateFlowLoop = FlowLoop(flow); }
            if (estimateStepLoop != null) { estimateStepLoop.Dispose(); estimateStepLoop = BreathLoop(estimateStep); }
            if (segmentBreathLoop != null) { segmentBreathLoop.Dispose(); segmentBreathLoop = BreathLoop(segmentBreath); }
            if (spin != null) { spin.Dispose(); spin = SpinLoop(); }
        }
    }
    /// The desired rate of the running loops; read by the presentation checks.
    internal int LoopFrameRate => frameRate;
    /// Applies the island's motion policy to the header shown last, without a new snapshot.
    internal void SetAnimations(bool value)
    {
        if (lastValue != null && canAnimate != value) Update(lastValue, value, lastOptions);
    }
    public ActivityBadge()
    {
        Width = Height = 20; IsHitTestVisible = false;
        RenderTransform = new TransformGroup { Children = { bloom, shake } }; RenderTransformOrigin = new Point(0.5, 0.5);
        estimateArc.Track = estimateArc.Head = true;
        paint.HorizontalAlignment = HorizontalAlignment.Center; paint.VerticalAlignment = VerticalAlignment.Center;
        paint.RenderTransform = rotation; paint.RenderTransformOrigin = new Point(0.5, 0.5); paint.CacheMode = new BitmapCache(2);
        clipped.Children.Add(paint);
        estimate.Children.Add(estimateArc); estimate.Children.Add(estimateFlow); estimate.Children.Add(estimateStep);
        Children.Add(halo); Children.Add(track); Children.Add(clipped); Children.Add(segments); Children.Add(segmentBreath); Children.Add(estimate); Children.Add(core); Children.Add(ending);
        SizeChanged += (_, _) => UpdateClip();
        IsVisibleChanged += (_, _) => { UpdateRotation(); if (!IsVisible) StopTransient(); UpdateSegmentBreath(); };
        Loaded += (_, _) =>
        {
            orbitSource = PresentationSource.FromVisual(this) as HwndSource; orbitSource?.AddHook(OrbitMessage);
            compositionFailed = false; UpdateRotation();
        };
        Unloaded += (_, _) =>
        {
            StopRotation(); StopTransient(); StopEstimate(); segmentBreathWanted = false; UpdateSegmentBreath(); orbit?.Dispose(); orbit = null;
            if (orbitSource is { IsDisposed: false }) orbitSource.RemoveHook(OrbitMessage); orbitSource = null;
        };
    }
    /// Draws the badge at `points` square; the drawing keeps its 20-point
    /// geometry, so the composed orbit scales with it.
    internal void SetSize(double points)
    {
        double scale = Math.Clamp(double.IsFinite(points) ? points : 20, 10, 80) / 20;
        if (LayoutTransform is ScaleTransform current && Math.Abs(current.ScaleX - scale) < 0.0001) return;
        if (Math.Abs(scale - 1) < 0.0001 && LayoutTransform == Transform.Identity) return;
        LayoutTransform = Math.Abs(scale - 1) < 0.0001 ? Transform.Identity : new ScaleTransform(scale, scale);
    }
    internal void Update(EngineHeader value, bool? animations = null, BadgeOptions? options = null)
    {
        var choice = options ?? BadgeOptions.Default;
        lastValue = value; lastOptions = options;
        canAnimate = animations ?? SystemParameters.ClientAreaAnimation;
        bool reduce = !canAnimate;
        // Several running tasks can show their estimates instead of the services:
        // the average as one arc, or one arc per task. A request keeps the amber
        // disc. As Core's HeaderActivity.multiTaskRing: tasks without an estimate
        // never count toward the average and breathe in their segment; with no
        // estimate at all the ring shows the services; more tasks than segments
        // give way to the average.
        bool several = value.ActiveCount > 1 && value.Attention == null;
        bool estimates = several && choice.MultiRing != "service" && value.ProgressAverage != null;
        segmentsShown = estimates && choice.MultiRing == "segments" && value.ProgressSegments == true && value.ProgressTasks is { Count: > 1 };
        bool average = estimates && !segmentsShown;
        estimateProvider = average ? value.ProgressAverageProvider : null;
        estimateWhite = average && value.ProgressAverageProvider == null;
        var shown = average ? value with { ProgressFraction = value.ProgressAverage, ProgressStale = value.ProgressAverageStale, ProgressLongStep = false } : value;
        // Only the chosen average shows its percent; segments that give way to it keep the count.
        string? percent = average && choice.MultiRing == "average" && choice.MultiCore == "percent" ? Percent(value.ProgressAverage!.Value)
            : choice.SinglePercent && value.ActiveCount == 1 && value.Attention == null && value.ProgressFraction is double single ? Percent(single) : null;
        Width = percent == null && value.CoreSymbol == null && value.ActiveCount >= 10 ? 27 : 20;
        paint.Update(value.Orbit, !reduce);
        track.BorderBrush = PacerPalette.Overlay(26);
        segments.Update(segmentsShown ? value.ProgressTasks : null); segmentBreath.Update(segmentsShown ? value.ProgressTasks : null);
        segments.Visibility = segmentBreath.Visibility = segmentsShown ? Visibility.Visible : Visibility.Collapsed;
        segmentBreathWanted = segmentsShown && !reduce && value.ProgressTasks!.Any(task => task.Fraction == null);
        UpdateSegmentBreath();
        bool hasOrbit = value.Orbit.Values.Any(count => count > 0) && shown.ProgressFraction == null && !segmentsShown;
        track.Visibility = clipped.Visibility = hasOrbit ? Visibility.Visible : Visibility.Collapsed;
        UpdateEstimate(shown, !reduce);
        RingMode = segmentsShown ? "segments" : average ? "average" : shown.ProgressFraction != null ? "estimate" : hasOrbit ? "orbit" : "none";
        // Everything ended: a solid disc in the ending's colour under a dark mark, as the rows draw it.
        Brush ink = value.Attention != null ? PacerPalette.Ink(66, 38, 5) : value.EndingIsCore ? EndingMarkInk : PacerPalette.Primary;
        bool solid = value.Attention != null || value.EndingIsCore;
        core.Height = core.MinWidth = solid ? 17 : 15; core.CornerRadius = new CornerRadius(solid ? 8.5 : 7.5);
        // The core is rebuilt only when what it draws changes; a new rate or
        // estimate leaves its text, mark and disc as they are.
        string? symbol = percent == null ? value.CoreSymbol : null;
        string? count = percent == null && symbol == null && value.ActiveCount > 0 ? value.ActiveCountText ?? "—" : null;
        Color? endingTint = value.EndingIsCore && value.Attention == null ? ((SolidColorBrush)EndingInk(value)).Color : null;
        var key = (percent, symbol, count, (ink as SolidColorBrush)?.Color, endingTint, several, value.Attention != null, PacerPalette.Light);
        if (!Equals(coreKey, key))
        {
            coreKey = key;
            if (percent != null)
                core.Child = new TextBlock { Text = percent, FontSize = 8, FontWeight = FontWeights.Bold, Foreground = ink,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            else if (symbol != null)
                core.Child = new IconGlyph { Symbol = symbol.EndsWith(".circle", StringComparison.Ordinal) ? symbol[..^7] : symbol, Ink = ink, Width = 11, Height = 11,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            else if (count != null)
                core.Child = new TextBlock { Text = count, FontSize = 10, FontWeight = FontWeights.Bold,
                    Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            else core.Child = new Ellipse { Fill = PacerPalette.Tertiary, Width = 5, Height = 5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            if (endingTint is Color tint)
            {
                core.Background = new LinearGradientBrush(Color.FromRgb((byte)(tint.R + (255 - tint.R) * 0.28), (byte)(tint.G + (255 - tint.G) * 0.28), (byte)(tint.B + (255 - tint.B) * 0.28)), tint, 90);
                // Lit from the top, as a row's disc.
                var sheen = new Border { CornerRadius = new CornerRadius(7.5), IsHitTestVisible = false, Background = Sheen };
                var mark = core.Child; core.Child = null;
                var face = new Grid(); face.Children.Add(sheen); if (mark != null) face.Children.Add(mark); core.Child = face;
            }
            // Several tasks: the count sits on a faint disc so it reads steadily over the ring.
            else core.Background = value.Attention != null ? PacerPalette.Attention : several && core.Child is TextBlock ? SoftCore : Brushes.Transparent;
        }
        core.BorderBrush = Brushes.Transparent; core.BorderThickness = new Thickness(0);
        halo.Stroke = PacerPalette.Attention;
        halo.Visibility = value.Attention != null ? Visibility.Visible : Visibility.Collapsed;
        ending.Background = EndingInk(value);
        ending.Visibility = choice.EndMark && value.Ending != null && !value.EndingIsCore ? Visibility.Visible : Visibility.Collapsed;
        if (reduce) StopTransient();
        else if (IsVisible && previous != null)
        {
            if (previous.Attention == null && value.Attention != null) Pulse();
            if (previous.Ending == null && value.Ending != null) Bloom();
            if (previous.Ending != "xmark.circle" && value.Ending == "xmark.circle") Shake();
        }
        previous = shown;
        UpdateClip(); UpdateRotation();
    }
    private static string Percent(double fraction) => ((int)Math.Round(Math.Clamp(fraction, 0, 1) * 100)).ToString(System.Globalization.CultureInfo.InvariantCulture);
    /// The arc eases from the value shown to the new estimate and fades in over the orbit; light runs
    /// along a working estimate, and the stretch past its head breathes during a long step.
    private void UpdateEstimate(EngineHeader value, bool animate)
    {
        bool shows = value.ProgressFraction != null, showed = previous?.ProgressFraction != null;
        // The average of several services is white; one service keeps its colour.
        string? provider = estimateWhite ? null : estimateProvider ?? value.Orbit.Where(pair => pair.Value > 0).Select(pair => pair.Key).FirstOrDefault();
        var tint = provider != null && PacerPalette.Provider(provider) is SolidColorBrush brush ? brush.Color : PacerPalette.Neutral;
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
        bool live = animate && IsVisible;
        double? flow = live && !longStep && !stale && target is > 0.04 and < 0.9995 ? target : null;
        if (flow != estimateFlowTo)
        {
            estimateFlowLoop?.Dispose(); estimateFlowLoop = null; estimateFlow.BeginAnimation(EstimatePaint.FrontProperty, null);
            estimateFlowTo = flow; estimateFlow.Flowing = flow != null;
            if (flow is double fraction) estimateFlowLoop = FlowLoop(fraction);
        }
        bool step = longStep && target < 0.9995;
        if (live && step != (estimateStepLoop != null) || !live && estimateStepLoop != null)
        {
            estimateStepLoop?.Dispose(); estimateStepLoop = null; estimateStep.BeginAnimation(OpacityProperty, null);
            if (live && step) estimateStepLoop = BreathLoop(estimateStep);
        }
        if (estimateStepLoop == null) estimateStep.Opacity = step ? 0.55 : 0;
    }
    /// One run of light from the arc's start out through its head, then a rest, on the shared clock.
    private AnimationLease FlowLoop(double fraction)
    {
        double reach = fraction + EstimatePaint.FlowLengths[0];
        var run = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(EstimatePaint.FlowPeriod), RepeatBehavior = RepeatBehavior.Forever,
            BeginTime = TimeSpan.FromSeconds(-(TaskProgressRing.Now % EstimatePaint.FlowPeriod)) };
        run.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        run.KeyFrames.Add(new LinearDoubleKeyFrame(reach, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.FlowTravel))));
        run.KeyFrames.Add(new DiscreteDoubleKeyFrame(reach, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.FlowPeriod))));
        Timeline.SetDesiredFrameRate(run, frameRate);
        return new AnimationLease(run, clock => estimateFlow.ApplyAnimationClock(EstimatePaint.FrontProperty, clock));
    }
    private AnimationLease BreathLoop(UIElement target) => new(StepBreath(TaskProgressRing.Now, frameRate), clock => target.ApplyAnimationClock(OpacityProperty, clock));
    /// The fallback rotation without the compositor, on the shared clock.
    private AnimationLease SpinLoop()
    {
        var animation = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(SpinPeriod)) { RepeatBehavior = RepeatBehavior.Forever,
            BeginTime = TimeSpan.FromSeconds(-(TaskProgressRing.Now % SpinPeriod)) };
        Timeline.SetDesiredFrameRate(animation, frameRate);
        return new(animation, clock => rotation.ApplyAnimationClock(RotateTransform.AngleProperty, clock));
    }
    /// The long step's breath, 0.2 to 0.85 and back over its period, in phase
    /// with every other breath on the shared clock.
    private static DoubleAnimationUsingKeyFrames StepBreath(double now, int frameRate)
    {
        var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
        var breath = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(EstimatePaint.StepPeriod), RepeatBehavior = RepeatBehavior.Forever,
            BeginTime = TimeSpan.FromSeconds(-(now % EstimatePaint.StepPeriod)) };
        breath.KeyFrames.Add(new LinearDoubleKeyFrame(0.2, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        breath.KeyFrames.Add(new EasingDoubleKeyFrame(0.85, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.StepPeriod / 2)), ease));
        breath.KeyFrames.Add(new EasingDoubleKeyFrame(0.2, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.StepPeriod)), ease));
        Timeline.SetDesiredFrameRate(breath, frameRate);
        return breath;
    }
    /// Segments of tasks without an estimate breathe together while the badge
    /// shows; reduced motion leaves their tracks, and a hidden badge stops.
    private void UpdateSegmentBreath()
    {
        bool live = segmentBreathWanted && IsVisible;
        if (live == (segmentBreathLoop != null)) return;
        segmentBreathLoop?.Dispose(); segmentBreathLoop = null; segmentBreath.BeginAnimation(OpacityProperty, null); segmentBreath.Opacity = 0;
        if (live) segmentBreathLoop = BreathLoop(segmentBreath);
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
        if (width == clipWidth) return;
        clipWidth = width;
        var shape = new GeometryGroup { FillRule = FillRule.EvenOdd };
        shape.Children.Add(new RectangleGeometry(new Rect(0, 0, width, 20), 10, 10));
        shape.Children.Add(new RectangleGeometry(new Rect(1.5, 1.5, width - 3, 17), 8.5, 8.5));
        shape.Freeze(); clipped.Clip = shape;
        paint.Width = paint.Height = Math.Ceiling(Math.Sqrt(width * width + 400)) + 2;
    }
    private void UpdateRotation()
    {
        bool animate = IsLoaded && IsVisible && canAnimate && previous?.Orbit.Values.Any(count => count > 0) == true && previous.ProgressFraction == null && !segmentsShown;
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
        spin = SpinLoop();
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
    private void Shake()
    {
        foreach (var clock in shakeClocks) clock.Dispose(); shakeClocks.Clear();
        var motion = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.6) };
        foreach (var (time, offset) in new[] { (0.0, 0.0), (0.1, -2.0), (0.2, 2.0), (0.3, -2.0), (0.4, 2.0), (0.5, -0.9), (0.6, 0.0) })
            motion.KeyFrames.Add(new LinearDoubleKeyFrame(offset, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(time))));
        shakeClocks.Add(new(motion, clock => shake.ApplyAnimationClock(TranslateTransform.XProperty, clock), () => shakeClocks.Clear()));
    }
    private void Pulse()
    {
        StopRipple();
        var scale = new ScaleTransform(1, 1);
        var ring = new System.Windows.Shapes.Path { Width = Width - 3, Height = 17,
            Data = new RectangleGeometry(new Rect(0, 0, Width - 3, 17), 8.5, 8.5),
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
        foreach (var clock in shakeClocks.ToArray()) clock.Dispose(); shakeClocks.Clear();
        shake.BeginAnimation(TranslateTransform.XProperty, null); shake.X = 0;
        foreach (var clock in bloomClocks.ToArray()) clock.Dispose(); bloomClocks.Clear();
        bloom.BeginAnimation(ScaleTransform.ScaleXProperty, null); bloom.BeginAnimation(ScaleTransform.ScaleYProperty, null);
    }
}

/// <summary>One arc per running task, in the task list's order, each filled to
/// its estimate over a track in its service's colour.</summary>
internal sealed class SegmentPaint : FrameworkElement
{
    private EngineTaskShare[] tasks = [];
    internal int Count => tasks.Length;
    /// The breathing layer: only the whole segments of tasks without an estimate.
    internal bool Breathing { get; init; }
    internal void Update(IReadOnlyList<EngineTaskShare>? value)
    {
        var next = value?.ToArray() ?? [];
        if (next.SequenceEqual(tasks)) return;
        tasks = next; InvalidateVisual();
    }
    protected override void OnRender(DrawingContext drawing)
    {
        int count = tasks.Length;
        if (count < 2) return;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        const double radius = 8.6, stroke = 1.8, gap = 18.0 / 360;
        double span = (1 - gap * count) / count;
        for (int index = 0; index < count; index++)
        {
            var color = PacerPalette.Provider(tasks[index].Provider) is SolidColorBrush brush ? brush.Color : PacerPalette.Neutral;
            double start = gap / 2 + index * (span + gap);
            if (Breathing)
            {
                if (tasks[index].Fraction == null) drawing.DrawGeometry(null, Pen(color), EstimatePaint.Arc(center, radius, start, start + span));
                continue;
            }
            drawing.DrawGeometry(null, Pen(EstimatePaint.WithAlpha(color, 0.26)), EstimatePaint.Arc(center, radius, start, start + span));
            if (tasks[index].Fraction is not double fraction || fraction <= 0.002) continue;
            // An estimate that has not changed for two minutes fades.
            drawing.PushOpacity(tasks[index].Stale ? 0.45 : 1);
            drawing.DrawGeometry(null, Pen(color), EstimatePaint.Arc(center, radius, start, start + span * Math.Clamp(fraction, 0, 1)));
            drawing.Pop();
        }
        static Pen Pen(Color color) => DrawingCache.Pen(color, stroke);
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
    private (Color Codex, Color Claude, Color DeepSeek) shades;
    private AnimationLease? transition;
    internal event Action? Changed;
    /// While a change of services eases between its stops.
    internal bool Transitioning => (double)GetValue(ProgressProperty) < 1;
    internal OrbitPaint() { SizeChanged += (_, _) => Changed?.Invoke(); Unloaded += (_, _) => { transition?.Dispose(); transition = null; }; }
    internal void Update(IReadOnlyDictionary<string, int> values, bool animate)
    {
        // The services' shades follow the accent and the island's tone, so a new shade redraws the same weights.
        var now = (Shade("codex"), Shade("claude"), Shade("deepseek"));
        if (weights != null && animated == animate && shades == now && weights.Count == values.Count && weights.All(pair => values.TryGetValue(pair.Key, out int count) && count == pair.Value)) return;
        shades = now;
        var shown = Current();
        CodexShade = now.Item1;
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
    /// Codex's shade in the orbit now; read by the presentation checks.
    internal Color CodexShade { get; private set; }
    private static Color Shade(string provider) => ((SolidColorBrush)PacerPalette.Provider(provider)).Color;
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
