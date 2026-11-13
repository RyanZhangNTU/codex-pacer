using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// A task row's 28-pt status icon, as the Mac draws it: the progress ring, and
/// inside it the task's state. A working stage shows a soft orb and a glyph
/// whose parts light in turn; a request for the user or an ending fills a solid
/// disc, grey once read, with a dark mark; an unknown state shows a moon. Each
/// arrival plays once: the disc fills from the ring inwards after the arc
/// closes, a check draws itself and the icon pops; a request for the user
/// bounces and rings twice; a failure shakes; resumed work empties the disc.
/// A first sight or a rebuilt row draws the final state.
public sealed class TaskStatusIcon : Grid
{
    internal const double Diameter = 28, GlyphSide = 14, OrbSide = 20, DiscSide = 26, FillDuration = 0.42;
    private static readonly Color DarkInk = Color.FromArgb(189, 0, 0, 0);
    // A read ending is a faint disc in the island's tone.
    private static Color ReadDisc => PacerPalette.Light ? Color.FromArgb(31, 0, 0, 0) : Color.FromArgb(38, 255, 255, 255);
    private static Color ReadInk => PacerPalette.Light ? Color.FromArgb(158, 29, 29, 31) : Color.FromArgb(158, 255, 255, 255);
    private static readonly KeySpline Launch = new(0.22, 1, 0.36, 1);
    /// What each task's face last showed, so a state's arrival plays once.
    private static readonly Dictionary<string, (string Face, double Seen)> Faces = new();

    internal TaskProgressRing Ring { get; } = new();
    private readonly Grid ringHost = new() { Width = Diameter, Height = Diameter };
    private readonly Ellipse orb = new() { Width = OrbSide, Height = OrbSide, Opacity = 0, IsHitTestVisible = false };
    private readonly Grid disc = new() { Width = DiscSide, Height = DiscSide, Visibility = Visibility.Collapsed };
    private readonly Path discFill = new(), discSheen = new();
    private readonly Ellipse[] ripples = [new(), new()];
    private readonly Grid glyphHost = new() { Width = GlyphSide, Height = GlyphSide };
    private Canvas glyph = new();
    private readonly List<(UIElement Part, TaskGlyphArt.Rhythm? Rhythm)> parts = new();
    private readonly List<AnimationLease> rhythms = new();
    private readonly ScaleTransform pop = new(1, 1);
    private readonly TranslateTransform shift = new();
    private string? id, faceKey, glyphKey;
    private Color color = Colors.White;
    private bool motion;

    /// The disc's hole: the disc's radius when empty, 0 when full.
    public static readonly DependencyProperty HoleProperty = DependencyProperty.Register(nameof(Hole), typeof(double), typeof(TaskStatusIcon),
        new PropertyMetadata(DiscSide / 2, (owner, _) => ((TaskStatusIcon)owner).UpdateDisc()));
    public double Hole { get => (double)GetValue(HoleProperty); set => SetValue(HoleProperty, value); }

    public TaskStatusIcon()
    {
        Width = Height = Diameter; IsHitTestVisible = false;
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = new TransformGroup { Children = { pop, shift } };
        ringHost.Children.Add(Ring); Children.Add(ringHost);
        Children.Add(orb);
        disc.Children.Add(discFill); disc.Children.Add(discSheen); Children.Add(disc);
        foreach (var ripple in ripples)
        {
            ripple.Width = ripple.Height = Diameter - 2; ripple.StrokeThickness = 1.6; ripple.Opacity = 0;
            ripple.RenderTransformOrigin = new Point(0.5, 0.5); ripple.RenderTransform = new ScaleTransform(1, 1); Children.Add(ripple);
        }
        glyphHost.Children.Add(glyph); Children.Add(glyphHost);
        Unloaded += (_, _) => Halt();
        // Loops run only while the row is on screen, as the ring's do.
        IsVisibleChanged += (_, _) => { if (IsVisible && motion) StartRhythms(); else StopRhythms(); };
        UpdateDisc();
    }

    /// The face a row shows: a working stage, a solid request or ending (read greys it), or a plain moon.
    internal static string FaceOf(string symbol, bool read) =>
        TaskGlyphArt.IsSolid(symbol) ? "solid:" + symbol + (read ? ":read" : "") : TaskGlyphArt.IsWorking(symbol) ? "working:" + symbol : "plain:moon";

    /// Applies one row: its ring, then its face, playing a new state's arrival once.
    internal void Show(EngineTaskRow row, Color ink, bool animate)
    {
        id = row.Id; color = ink; motion = animate;
        Ring.Show(row.Id, row.ProgressState, row.ProgressMode, row.ProgressFraction ?? 0, row.ProgressStale == true, ink, animate,
            completionPulseOnly: row.Provider == "codex");
        ApplyFace(FaceOf(row.Symbol, row.Dimmed), animate);
    }
    internal void SetMotion(bool value) { motion = value; Ring.SetMotion(value); if (value) StartRhythms(); else { StopRhythms(); Settle(); } }

    private void ApplyFace(string next, bool animate)
    {
        double now = TaskProgressRing.Now;
        string? previous = Faces.TryGetValue(id!, out var memory) ? memory.Face : null;
        Faces[id!] = (next, now); Prune(now);
        bool arriving = animate && previous != null && previous != next;
        bool solid = next.StartsWith("solid:", StringComparison.Ordinal), wasSolid = previous?.StartsWith("solid:", StringComparison.Ordinal) == true;
        bool read = next.EndsWith(":read", StringComparison.Ordinal);
        string symbol = next.Split(':')[1];
        // A request that ends with an estimate closes its arc before the disc fills.
        double fillDelay = arriving && symbol == "checkmark.circle" ? TaskProgressRing.SweepRemaining(id!) : 0;
        faceKey = next;

        // The orb sits under a working glyph only.
        bool working = next.StartsWith("working:", StringComparison.Ordinal);
        orb.Fill = new RadialGradientBrush(new GradientStopCollection { new(EstimatePaint.WithAlpha(color, 0.32), 0), new(EstimatePaint.WithAlpha(color, 0.1), 0.72) })
            { Center = new Point(0.5, 0.28), GradientOrigin = new Point(0.5, 0.28), RadiusX = 1.06, RadiusY = 1.06 };
        Fade(orb, working ? 1 : 0, arriving && (orb.Opacity > 0) != working ? 0.3 : 0, working ? 0 : fillDelay);

        // The disc fills from the ring inwards, and empties back out.
        if (solid)
        {
            var top = read ? ReadDisc : Lighten(color, 0.28); var bottom = read ? ReadDisc : color;
            discFill.Fill = new LinearGradientBrush(top, bottom, 90);
            discSheen.Fill = new LinearGradientBrush(new GradientStopCollection { new(Color.FromArgb(66, 255, 255, 255), 0), new(Color.FromArgb(0, 255, 255, 255), 0.62) }, 90);
            discSheen.Visibility = read ? Visibility.Collapsed : Visibility.Visible;
            disc.Visibility = Visibility.Visible;
            if (arriving && !wasSolid) Animate(HoleProperty, DiscSide / 2, 0, FillDuration, fillDelay);
            else { BeginAnimation(HoleProperty, null); Hole = 0; }
        }
        else if (disc.Visibility == Visibility.Visible)
        {
            if (arriving && wasSolid)
            {
                var empty = Animate(HoleProperty, 0, DiscSide / 2, 0.32, 0);
                empty.Completed += (_, _) => { if (faceKey == next) disc.Visibility = Visibility.Collapsed; };
            }
            else { BeginAnimation(HoleProperty, null); Hole = DiscSide / 2; disc.Visibility = Visibility.Collapsed; }
        }

        // The ring hides under a solid face once it is full, and returns with work.
        bool ringShown = !solid;
        Fade(ringHost, ringShown ? 1 : 0, arriving && (ringHost.Opacity > 0) != ringShown ? 0.25 : 0, ringShown ? 0.12 : fillDelay + FillDuration * 0.8);

        // Filling, the old glyph stays until the disc reaches it, and the new one is drawn on the full disc.
        bool fills = solid && !wasSolid;
        RebuildGlyph(next, symbol, solid, read, arriving, fills ? fillDelay + FillDuration * 0.3 : 0, fills ? fillDelay + FillDuration * 0.55 : 0);

        if (arriving && next == "solid:checkmark.circle" && !wasSolid) Pop(fillDelay + FillDuration);
        bool asks = solid && !read && TaskGlyphArt.AsksUser(symbol), asked = previous != null && previous.StartsWith("solid:", StringComparison.Ordinal)
            && !previous.EndsWith(":read", StringComparison.Ordinal) && TaskGlyphArt.AsksUser(previous.Split(':')[1]);
        if (arriving && asks && !asked) { Bounce(); Ripple(); }
        if (arriving && next == "solid:xmark.circle") Shake();
        if (!animate) Settle();
    }

    private void RebuildGlyph(string face, string symbol, bool solid, bool read, bool animate, double exitDelay, double drawDelay)
    {
        Color ink = solid ? read ? ReadInk : DarkInk : color;
        string key = face + "|" + ink;
        if (key == glyphKey) return;
        bool wasDrawn = glyphKey != null; glyphKey = key;
        var old = glyph;
        StopRhythms(); parts.Clear();
        glyph = new Canvas { Width = GlyphSide, Height = GlyphSide, RenderTransformOrigin = new Point(0.5, 0.5) };
        var art = solid ? TaskGlyphArt.Solid(symbol) : face.StartsWith("working:", StringComparison.Ordinal) ? TaskGlyphArt.Parts(symbol) : [new TaskGlyphArt.Part(TaskGlyphArt.Moon, false)];
        if (art.Count == 0) art = [new TaskGlyphArt.Part(TaskGlyphArt.Moon, false)];
        var scale = new ScaleTransform(GlyphSide / 24, GlyphSide / 24);
        Path? check = null;
        foreach (var part in art)
        {
            double width = solid ? symbol is "checkmark.circle" or "xmark.circle" ? 2.9 : 2.1 : part.Filled ? 0.6 : 2.1;
            // A filled part on a disc keeps the disc's colour for its inner stroke, as the question mark does.
            bool innerMark = solid && symbol == "questionmark.bubble" && !part.Filled;
            var brush = new SolidColorBrush(innerMark ? read ? ReadDisc : color : ink);
            var path = new Path { Data = part.Path, RenderTransform = scale, Stroke = brush, StrokeThickness = width,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
                Fill = part.Filled ? new SolidColorBrush(ink) : null };
            glyph.Children.Add(path); parts.Add((path, part.Rhythm));
            if (solid && symbol == "checkmark.circle") check = path;
        }
        glyphHost.Children.Add(glyph);
        if (!animate || !wasDrawn) { glyphHost.Children.Remove(old); StartRhythms(); return; }
        // The old glyph leaves; the new one arrives, or a check draws itself.
        var leaving = new ScaleTransform(1, 1); old.RenderTransformOrigin = new Point(0.5, 0.5); old.RenderTransform = leaving;
        double outSeconds = exitDelay > 0 ? 0.2 : 0.32;
        var fadeOut = Spline(1, 0, outSeconds, exitDelay); fadeOut.Completed += (_, _) => glyphHost.Children.Remove(old);
        old.BeginAnimation(OpacityProperty, fadeOut);
        leaving.BeginAnimation(ScaleTransform.ScaleXProperty, Spline(1, 0.6, outSeconds, exitDelay));
        leaving.BeginAnimation(ScaleTransform.ScaleYProperty, Spline(1, 0.6, outSeconds, exitDelay));
        if (check != null)
        {
            // The check's length in its own units, drawn from nothing.
            double length = 4.4 + 8.98; check.StrokeDashArray = new DoubleCollection { length / check.StrokeThickness + 1, 100 };
            check.BeginAnimation(Shape.StrokeDashOffsetProperty, Spline(length / check.StrokeThickness + 1, 0, 0.34, drawDelay));
        }
        else
        {
            var arriving = new ScaleTransform(0.6, 0.6); glyph.RenderTransform = arriving;
            glyph.BeginAnimation(OpacityProperty, Spline(0, 1, 0.32, drawDelay));
            arriving.BeginAnimation(ScaleTransform.ScaleXProperty, Spline(0.6, 1, 0.32, drawDelay));
            arriving.BeginAnimation(ScaleTransform.ScaleYProperty, Spline(0.6, 1, 0.32, drawDelay));
        }
        StartRhythms();
    }

    /// Each lit part loops on the shared clock, so a rebuilt row continues in step.
    private void StartRhythms()
    {
        StopRhythms();
        if (!motion || !IsVisible) return;
        double now = TaskProgressRing.Now;
        foreach (var (part, rhythm) in parts)
        {
            if (rhythm == null) continue;
            var loop = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(rhythm.Period), RepeatBehavior = RepeatBehavior.Forever,
                BeginTime = TimeSpan.FromSeconds(rhythm.Offset - now % rhythm.Period), FillBehavior = FillBehavior.HoldEnd };
            for (int index = 0; index < rhythm.Values.Length; index++)
            {
                var time = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(rhythm.Times[index] * rhythm.Period));
                loop.KeyFrames.Add(rhythm.Stepped || index == 0 ? new DiscreteDoubleKeyFrame(rhythm.Values[index], time)
                    : new EasingDoubleKeyFrame(rhythm.Values[index], time, new SineEase { EasingMode = EasingMode.EaseInOut }));
            }
            if (rhythm.Stepped) loop.KeyFrames.Add(new DiscreteDoubleKeyFrame(rhythm.Values[0], KeyTime.FromTimeSpan(TimeSpan.FromSeconds(rhythm.Period))));
            // Each tick repaints the whole layered island; a slow pulse reads the same at a low rate.
            Timeline.SetDesiredFrameRate(loop, TaskProgressRing.PulseFrameRate);
            part.Opacity = rhythm.Values[0];
            rhythms.Add(new AnimationLease(loop, clock => part.ApplyAnimationClock(OpacityProperty, clock)));
        }
    }
    private void StopRhythms()
    {
        foreach (var lease in rhythms) lease.Dispose();
        rhythms.Clear();
        foreach (var (part, _) in parts) { part.BeginAnimation(OpacityProperty, null); part.Opacity = 1; }
    }
    /// Whether the glyph's parts are looping; read by the presentation checks.
    internal bool RhythmsRunning => rhythms.Count > 0;
    /// How many glyphs are drawn: two while one hands over to the next.
    internal int GlyphLayers => glyphHost.Children.Count;
    /// The face drawn now, such as working:sparkle or solid:checkmark.circle; read by the presentation checks.
    internal string? Face => faceKey;
    /// Whether an arrival is still playing; read by the presentation checks.
    internal bool Arriving => HasAnimatedProperties || pop.HasAnimatedProperties || shift.HasAnimatedProperties || ripples.Any(value => value.HasAnimatedProperties);

    /// The final drawing, with nothing in motion.
    private void Settle()
    {
        if (faceKey == null) return;
        bool solid = faceKey.StartsWith("solid:", StringComparison.Ordinal);
        foreach (var element in new UIElement[] { orb, ringHost, glyph }) element.BeginAnimation(OpacityProperty, null);
        BeginAnimation(HoleProperty, null);
        orb.Opacity = faceKey.StartsWith("working:", StringComparison.Ordinal) ? 1 : 0;
        disc.Visibility = solid ? Visibility.Visible : Visibility.Collapsed; Hole = solid ? 0 : DiscSide / 2;
        ringHost.Opacity = solid ? 0 : 1; glyph.Opacity = 1; glyph.RenderTransform = null;
        foreach (UIElement child in glyphHost.Children.Cast<UIElement>().ToArray()) if (child != glyph) glyphHost.Children.Remove(child);
        foreach (var (part, _) in parts) if (part is Path path) { path.BeginAnimation(Shape.StrokeDashOffsetProperty, null); path.StrokeDashArray = null; }
        foreach (var ripple in ripples) { ripple.BeginAnimation(OpacityProperty, null); ripple.Opacity = 0; }
        pop.BeginAnimation(ScaleTransform.ScaleXProperty, null); pop.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        shift.BeginAnimation(TranslateTransform.XProperty, null); shift.BeginAnimation(TranslateTransform.YProperty, null);
    }
    private void Halt() { StopRhythms(); Settle(); Ring.Halt(); }

    private void Pop(double after)
    {
        var bump = new DoubleAnimationUsingKeyFrames { BeginTime = TimeSpan.FromSeconds(after) };
        bump.KeyFrames.Add(new EasingDoubleKeyFrame(1.06, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.16)), new QuadraticEase { EasingMode = EasingMode.EaseOut }));
        bump.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.4)), new QuadraticEase { EasingMode = EasingMode.EaseInOut }));
        pop.BeginAnimation(ScaleTransform.ScaleXProperty, bump); pop.BeginAnimation(ScaleTransform.ScaleYProperty, bump);
    }
    private void Bounce()
    {
        var bounce = new DoubleAnimationUsingKeyFrames { BeginTime = TimeSpan.FromSeconds(0.15), Duration = TimeSpan.FromSeconds(0.55) };
        foreach (var (value, at) in new[] { (0.0, 0.0), (-3.4, 0.35), (0.0, 0.7), (-1.1, 0.85), (0.0, 1.0) })
            bounce.KeyFrames.Add(new EasingDoubleKeyFrame(value, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.55 * at)), new QuadraticEase { EasingMode = EasingMode.EaseOut }));
        shift.BeginAnimation(TranslateTransform.YProperty, bounce);
    }
    private void Ripple()
    {
        for (int index = 0; index < ripples.Length; index++)
        {
            var ripple = ripples[index]; ripple.Stroke = new SolidColorBrush(color);
            var after = TimeSpan.FromSeconds(0.8 * index);
            var grow = new DoubleAnimation(1, 1.75, TimeSpan.FromSeconds(0.8)) { BeginTime = after, EasingFunction = new SplineEase(new KeySpline(0.2, 0.6, 0.4, 1)) };
            var fade = new DoubleAnimation(0.75, 0, TimeSpan.FromSeconds(0.8)) { BeginTime = after, EasingFunction = new SplineEase(new KeySpline(0.2, 0.6, 0.4, 1)) };
            fade.Completed += (_, _) => { ripple.BeginAnimation(OpacityProperty, null); ripple.Opacity = 0; };
            var scale = (ScaleTransform)ripple.RenderTransform;
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow); scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            ripple.BeginAnimation(OpacityProperty, fade);
        }
    }
    private void Shake()
    {
        var shake = new DoubleAnimationUsingKeyFrames { BeginTime = TimeSpan.FromSeconds(FillDuration * 0.7), Duration = TimeSpan.FromSeconds(0.5) };
        foreach (var (value, at) in new[] { (0.0, 0.0), (-2.5, 0.2), (2.2, 0.4), (-1.4, 0.6), (0.8, 0.8), (0.0, 1.0) })
            shake.KeyFrames.Add(new LinearDoubleKeyFrame(value, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.5 * at))));
        shift.BeginAnimation(TranslateTransform.XProperty, shake);
    }

    private void UpdateDisc()
    {
        // An annulus: the disc minus a centred hole, so a fill closes from the ring inwards.
        var outer = new EllipseGeometry(new Point(DiscSide / 2, DiscSide / 2), DiscSide / 2, DiscSide / 2);
        double hole = Math.Clamp(Hole, 0, DiscSide / 2);
        Geometry shape = hole <= 0.01 ? outer : new CombinedGeometry(GeometryCombineMode.Exclude, outer, new EllipseGeometry(new Point(DiscSide / 2, DiscSide / 2), hole, hole));
        discFill.Data = shape; discSheen.Data = shape;
    }
    private AnimationTimeline Animate(DependencyProperty property, double from, double to, double seconds, double delay)
    {
        var animation = Spline(from, to, seconds, delay);
        SetValue(property, to); BeginAnimation(property, animation);
        return animation;
    }
    private static void Fade(UIElement element, double to, double seconds, double delay)
    {
        if (seconds <= 0) { element.BeginAnimation(OpacityProperty, null); element.Opacity = to; return; }
        double from = element.Opacity;
        element.Opacity = to;
        element.BeginAnimation(OpacityProperty, Held(from, to, seconds, delay, new EasingDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(delay + seconds)),
            new SineEase { EasingMode = EasingMode.EaseInOut })));
    }
    /// A motion on the Mac's launch curve that holds its start through any delay.
    private static DoubleAnimationUsingKeyFrames Spline(double from, double to, double seconds, double delay) =>
        Held(from, to, seconds, delay, new SplineDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(delay + seconds)), Launch));
    private static DoubleAnimationUsingKeyFrames Held(double from, double to, double seconds, double delay, DoubleKeyFrame last)
    {
        var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(delay + seconds) };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        if (delay > 0) animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(delay))));
        animation.KeyFrames.Add(last); return animation;
    }
    private static Color Lighten(Color color, double amount) =>
        Color.FromArgb(color.A, (byte)(color.R + (255 - color.R) * amount), (byte)(color.G + (255 - color.G) * amount), (byte)(color.B + (255 - color.B) * amount));
    private static void Prune(double now)
    {
        if (Faces.Count < 64) return;
        foreach (var key in Faces.Where(pair => now - pair.Value.Seen > 600).Select(pair => pair.Key).ToArray()) Faces.Remove(key);
    }

    /// An easing function from a cubic Bézier, as Core Animation's timing functions.
    private sealed class SplineEase : EasingFunctionBase
    {
        private readonly KeySpline spline;
        // Ease-in mode hands the curve the time as it is.
        internal SplineEase(KeySpline spline) { this.spline = spline; EasingMode = EasingMode.EaseIn; }
        protected override double EaseInCore(double normalizedTime) => spline.GetSplineProgress(normalizedTime);
        protected override Freezable CreateInstanceCore() => new SplineEase(spline);
    }
}
