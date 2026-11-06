using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// The self-reported progress ring drawn around a task row's status icon.
/// Task rows are rebuilt whenever a snapshot changes them, so each ring
/// resumes from what the previous row for the same task was showing instead
/// of restarting its motion. Every animation is interruptible: a new value
/// starts from the currently displayed one.
public sealed class TaskProgressRing : Grid
{
    internal const double Diameter = 28, Stroke = 2, Radius = 13;
    internal enum Change { None, Appeared, Shown, Disappeared }

    public static readonly DependencyProperty DisplayFractionProperty = DependencyProperty.Register(nameof(DisplayFraction), typeof(double),
        typeof(TaskProgressRing), new PropertyMetadata(0.0, (owner, _) => ((TaskProgressRing)owner).UpdateArc()));
    public double DisplayFraction { get => (double)GetValue(DisplayFractionProperty); set => SetValue(DisplayFractionProperty, value); }
    public static readonly DependencyProperty GhostFractionProperty = DependencyProperty.Register(nameof(GhostFraction), typeof(double),
        typeof(TaskProgressRing), new PropertyMetadata(0.0, (owner, _) => ((TaskProgressRing)owner).UpdateGhost()));
    public double GhostFraction { get => (double)GetValue(GhostFractionProperty); set => SetValue(GhostFractionProperty, value); }
    /// 0...1 along the reported arc; the light dot shows that work moves on.
    public static readonly DependencyProperty DotPhaseProperty = DependencyProperty.Register(nameof(DotPhase), typeof(double),
        typeof(TaskProgressRing), new PropertyMetadata(0.0, (owner, _) => ((TaskProgressRing)owner).UpdateDot()));
    public double DotPhase { get => (double)GetValue(DotPhaseProperty); set => SetValue(DotPhaseProperty, value); }

    private static readonly Brush TrackInk = PacerPalette.Ink(255, 255, 255, 20);
    private static readonly Brush DotInk = PacerPalette.Ink(255, 255, 255, 235);
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static readonly Dictionary<string, Memory> Memories = new();
    private static double Now => Clock.Elapsed.TotalSeconds;
    private const double RotationPeriod = 6, DotTravel = 1.6, DotPeriod = 2, BreathPeriod = 2.4;
    /// A waiting ring breathes down to this share of its resting opacity.
    private const double BreathLow = 0.2;

    private readonly Ellipse pending = new()
    {
        StrokeThickness = Stroke, StrokeDashCap = PenLineCap.Round, Opacity = 0,
        // Dash and gap lengths are multiples of the stroke: 2.2 pt on, 4.6 pt off.
        StrokeDashArray = new DoubleCollection { 1.1, 2.3 }, RenderTransformOrigin = new Point(0.5, 0.5)
    };
    private readonly Ellipse track = new() { StrokeThickness = Stroke, Stroke = TrackInk, Opacity = 0 };
    private readonly Path ghost = new() { StrokeThickness = Stroke, Opacity = 0 };
    private readonly Path arc = new() { StrokeThickness = Stroke, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Ellipse dot = new() { Width = 3.6, Height = 3.6, Opacity = 0, Fill = DotInk };
    private readonly TranslateTransform dotShift = new();
    private readonly RotateTransform rotation = new();
    private readonly ScaleTransform scale = new(1, 1);
    private readonly SolidColorBrush ink = new(Colors.Transparent);
    private bool motion, pendingShown, dim, showing;
    /// Endless clocks are leased so stopping one removes it from WPF's clock
    /// manager; a clock only detached from its property ticks until a GC.
    private AnimationLease? spinLease, dotLease, breathLease;
    private bool dotting => dotLease != null;
    /// The element whose opacity breathes while the request waits, if any.
    private UIElement? breathingTarget;
    /// The request's lifecycle mode from the engine: working, longStep,
    /// attention, waiting, done, short, interrupted or failed.
    private string mode = "working";
    private double targetFraction;

    private sealed class Memory
    {
        public string State = "";
        public double From, To, Start, Duration;
        public IEasingFunction? Ease;
        public bool Stale, Full;
        /// The ring was breathing: a request waiting for its background work.
        public bool Breathing;
        public Color Color;
        public double Seen;
        public double Displayed(double now)
        {
            if (Duration <= 0 || now >= Start + Duration) return To;
            if (now <= Start) return From;
            double progress = (now - Start) / Duration;
            return From + (To - From) * (Ease?.Ease(progress) ?? progress);
        }
    }

    public TaskProgressRing()
    {
        Width = Height = Diameter; IsHitTestVisible = false; Visibility = Visibility.Collapsed;
        RenderTransformOrigin = new Point(0.5, 0.5); RenderTransform = scale;
        pending.RenderTransform = rotation; pending.Stroke = ink; ghost.Stroke = ink; arc.Stroke = ink; dot.RenderTransform = dotShift;
        Children.Add(pending); Children.Add(track); Children.Add(ghost); Children.Add(arc); Children.Add(dot);
        IsVisibleChanged += (_, _) => UpdateSpin();
        Unloaded += (_, _) => Halt();
    }

    /// Applies one row's ring. Returns how the ring changed for this task, so
    /// the row can shrink or restore its icon in step with it.
    internal Change Show(string id, string? state, string? lifecycle, double fraction, bool stale, Color color, bool animate)
    {
        // Making the ring visible raises IsVisibleChanged synchronously. Its
        // looping motion starts once, from the finished state: started midway,
        // it would read stale fields and a later opacity fade would cancel it.
        showing = true;
        try { StopBreathing(); return Apply(id, state, lifecycle, fraction, stale, color, animate); }
        finally { showing = false; UpdateSpin(); }
    }
    private Change Apply(string id, string? state, string? lifecycle, double fraction, bool stale, Color color, bool animate)
    {
        motion = animate; mode = lifecycle ?? "working";
        double now = Now;
        Prune(now);
        Memories.TryGetValue(id, out var previous);
        if (state is not ("pending" or "reported"))
        {
            Memories.Remove(id);
            if (previous == null) { Visibility = Visibility.Collapsed; return Change.None; }
            // The turn ended without an estimate, or the switch went off.
            ink.Color = previous.Color;
            if (previous.State == "pending") { pending.Opacity = 0.6; track.Opacity = 0; }
            else { track.Opacity = 1; DisplayFraction = previous.Displayed(now); }
            Visibility = Visibility.Visible;
            if (!animate) { Visibility = Visibility.Collapsed; return Change.Disappeared; }
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromSeconds(0.3)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn } };
            fade.Completed += (_, _) => { if (Memories.ContainsKey(id)) return; BeginAnimation(OpacityProperty, null); Visibility = Visibility.Collapsed; };
            BeginAnimation(OpacityProperty, fade);
            return Change.Disappeared;
        }
        Visibility = Visibility.Visible;
        bool appeared = previous == null || previous.State == "";
        // Colour follows the icon: provider, attention, failure or read.
        if (animate && previous != null && previous.Color != color)
        {
            ink.Color = previous.Color;
            ink.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(color, TimeSpan.FromSeconds(0.25)));
        }
        else ink.Color = color;
        if (appeared && animate && previous == null && state == "pending")
        {
            Opacity = 0; scale.ScaleX = scale.ScaleY = 0.85;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.85, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.85, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = ease });
        }
        // A working request without a new estimate for a while dims.
        bool dimmed = state == "reported" && stale;
        // Leaving the wait, the element eases from the breath's current opacity.
        bool leftBreath = animate && previous?.Breathing == true && mode != "waiting";
        var memory = new Memory { State = state, Color = color, Seen = now, Stale = dimmed, Breathing = mode == "waiting" };
        if (state == "pending")
        {
            double shown = previous?.State == "reported" ? previous.Displayed(now) : 0;
            pendingShown = true; arc.Opacity = 1; ghost.Opacity = 0; dim = false; targetFraction = 0;
            if (animate && shown > 0.0005)
            {
                // A new turn replaces an old estimate: retract it, then dash in.
                track.Opacity = 1; pending.Opacity = 0;
                Sweep(shown, 0, 0.3, new QuadraticEase { EasingMode = EasingMode.EaseIn }, 0);
                track.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, TimeSpan.FromSeconds(0.2)) { BeginTime = TimeSpan.FromSeconds(0.3) });
                pending.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 0.6, TimeSpan.FromSeconds(0.2)) { BeginTime = TimeSpan.FromSeconds(0.3) });
            }
            else
            {
                DisplayFraction = 0; track.Opacity = 0; pending.Opacity = 0.6;
                if (leftBreath && previous!.State == "pending") EaseOutOfBreath(pending, 0.6, 0.6, now);
            }
            Memories[id] = memory;
            return appeared ? Change.Appeared : Change.Shown;
        }
        // Reported.
        double target = Math.Clamp(fraction, 0, 1);
        dim = dimmed; targetFraction = target;
        if (previous?.State == "reported" && Math.Abs(previous.To - target) < 0.0005)
        {
            // The same estimate on a rebuilt row: finish whatever was running.
            double remaining = previous.Start + previous.Duration - now, shown = previous.Displayed(now);
            track.Opacity = 1; pending.Opacity = 0; pendingShown = false;
            if (animate && remaining > 0.02) Sweep(shown, target, remaining, previous.Ease, 0);
            else DisplayFraction = target;
            previous.Seen = now; previous.Color = color;
            Fade(previous.Stale, dimmed, animate);
            if (leftBreath) EaseOutOfBreath(arc, 1, dimmed ? 0.45 : 1, now);
            previous.Stale = dimmed; previous.Breathing = mode == "waiting"; Memories[id] = previous;
            return Change.Shown;
        }
        double from = previous?.State == "reported" ? previous.Displayed(now) : 0, delay = 0, duration;
        IEasingFunction ease2;
        if (previous?.State == "pending" && animate)
        {
            // The first estimate: the dashes close into the track, then the arc sweeps.
            pending.BeginAnimation(OpacityProperty, new DoubleAnimation(previous.Breathing ? BreathOpacity(now, 0.6) : pending.Opacity, 0, TimeSpan.FromSeconds(0.2)));
            track.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.2)));
            delay = 0.2; duration = 0.45; ease2 = new CubicEase { EasingMode = EasingMode.EaseOut };
        }
        else
        {
            pending.BeginAnimation(OpacityProperty, null); track.BeginAnimation(OpacityProperty, null);
            pending.Opacity = 0; track.Opacity = 1;
            bool falling = target < from;
            duration = falling ? 0.5 : 0.3 + 0.3 * Math.Abs(target - from);
            ease2 = falling ? new SineEase { EasingMode = EasingMode.EaseInOut } : new CubicEase { EasingMode = EasingMode.EaseOut };
            if (falling && animate)
            {
                // A lowered estimate leaves a fading trace of where it was.
                GhostFraction = from; ghost.BeginAnimation(OpacityProperty, new DoubleAnimation(0.35, 0, TimeSpan.FromSeconds(0.6)));
            }
        }
        pendingShown = false;
        if (animate && previous != null && Math.Abs(target - from) > 0.0005) Sweep(from, target, duration, ease2, delay);
        else { arc.BeginAnimation(OpacityProperty, null); BeginAnimation(DisplayFractionProperty, null); DisplayFraction = target; duration = 0; }
        Fade(previous?.Stale ?? false, dimmed, animate && previous != null);
        if (leftBreath && previous!.State == "reported") EaseOutOfBreath(arc, 1, dimmed ? 0.45 : 1, now);
        bool full = target >= 0.9995;
        if (full && animate && previous != null && previous.Full == false && mode is "working" or "done")
        {
            // Reaching 100% settles with one small pulse once the sweep ends.
            var pulse = new DoubleAnimationUsingKeyFrames { BeginTime = TimeSpan.FromSeconds(delay + duration + 0.05) };
            pulse.KeyFrames.Add(new EasingDoubleKeyFrame(1.06, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.18)), new QuadraticEase { EasingMode = EasingMode.EaseOut }));
            pulse.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.4)), new QuadraticEase { EasingMode = EasingMode.EaseInOut }));
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, pulse);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, pulse);
        }
        memory.From = from; memory.To = target; memory.Start = now + delay; memory.Duration = animate && previous != null ? duration : 0;
        memory.Ease = ease2; memory.Full = full || previous?.Full == true && target >= 0.9995;
        Memories[id] = memory;
        return appeared ? Change.Appeared : Change.Shown;
    }

    /// Motion follows the island: reduced motion, hidden or occluded panels
    /// show final values and never spin.
    internal void SetMotion(bool value) { motion = value; UpdateSpin(); }
    internal void Halt()
    {
        spinLease?.Dispose(); spinLease = null; dotLease?.Dispose(); dotLease = null;
        breathLease?.Dispose(); breathLease = null; breathingTarget = null;
        rotation.BeginAnimation(RotateTransform.AngleProperty, null);
        foreach (var element in new UIElement[] { this, pending, track, ghost, arc, dot }) element.BeginAnimation(OpacityProperty, null);
        BeginAnimation(DisplayFractionProperty, null); BeginAnimation(GhostFractionProperty, null); BeginAnimation(DotPhaseProperty, null);
        dot.Opacity = 0;
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, null); scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        ink.BeginAnimation(SolidColorBrush.ColorProperty, null);
    }

    private void Sweep(double from, double to, double seconds, IEasingFunction? ease, double delay)
    {
        DisplayFraction = from;
        var animation = new DoubleAnimation(from, to, TimeSpan.FromSeconds(Math.Max(0.01, seconds)))
            { EasingFunction = ease, BeginTime = TimeSpan.FromSeconds(delay) };
        BeginAnimation(DisplayFractionProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }
    private void Fade(bool wasStale, bool stale, bool animate)
    {
        double target = stale ? 0.45 : 1;
        if (!animate || wasStale == stale) { arc.BeginAnimation(OpacityProperty, null); arc.Opacity = target; return; }
        arc.BeginAnimation(OpacityProperty, new DoubleAnimation(wasStale ? 0.45 : 1, target, TimeSpan.FromSeconds(stale ? 0.6 : 0.2))
            { EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
    }
    /// Looping motion by lifecycle mode. The dashes turn while the request
    /// works without an estimate; a light dot runs along a reported arc while
    /// it works; a waiting request breathes; a long step, a request waiting
    /// for the user and an ended one keep still. Shared phases keep a rebuilt
    /// row's motion where the old one was.
    private void UpdateSpin()
    {
        if (showing) return;
        bool live = motion && IsVisible && Visibility == Visibility.Visible;
        bool spin = live && pendingShown && mode is "working" or "longStep";
        if (spin != (spinLease != null))
        {
            spinLease?.Dispose(); spinLease = null;
            if (spin)
            {
                double phase = Now % RotationPeriod / RotationPeriod * 360;
                spinLease = new AnimationLease(new DoubleAnimation(phase, phase + 360, TimeSpan.FromSeconds(RotationPeriod))
                    { RepeatBehavior = RepeatBehavior.Forever }, clock => rotation.ApplyAnimationClock(RotateTransform.AngleProperty, clock));
            }
        }
        bool travel = live && !pendingShown && !dim && mode == "working" && targetFraction is > 0.04 and < 0.9995;
        if (travel != dotting)
        {
            dotLease?.Dispose(); dotLease = null;
            if (!travel) DotPhase = 0;
            else
            {
                var run = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(DotPeriod), RepeatBehavior = RepeatBehavior.Forever,
                    BeginTime = TimeSpan.FromSeconds(-(Now % DotPeriod)) };
                run.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                run.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(DotTravel)), new SineEase { EasingMode = EasingMode.EaseInOut }));
                run.KeyFrames.Add(new DiscreteDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(DotPeriod))));
                dotLease = new AnimationLease(run, clock => ApplyAnimationClock(DotPhaseProperty, clock));
            }
            UpdateDot();
        }
        // The dashes breathe until the first estimate, the arc after it.
        UIElement? breath = !live || mode != "waiting" ? null : pendingShown ? pending : (UIElement)arc;
        if (breath != breathingTarget)
        {
            StopBreathing();
            if (breath is UIElement element)
            {
                double high = element == pending ? 0.6 : 1;
                breathLease = new AnimationLease(new DoubleAnimation(high, high * BreathLow, TimeSpan.FromSeconds(BreathPeriod / 2))
                    { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
                      BeginTime = TimeSpan.FromSeconds(-(Now % BreathPeriod)) }, clock => element.ApplyAnimationClock(OpacityProperty, clock));
                breathingTarget = element;
            }
        }
    }
    /// The opacity a breathing element shows at `now`. The breath runs from
    /// `high` to `high * BreathLow` and back on the shared clock, so a rebuilt
    /// row can pick it up exactly where the old one was.
    private static double BreathOpacity(double now, double high)
    {
        double t = now % BreathPeriod / (BreathPeriod / 2);
        double eased = (1 - Math.Cos(Math.PI * (t <= 1 ? t : 2 - t))) / 2;
        return high - (high - high * BreathLow) * eased;
    }
    private static void EaseOutOfBreath(UIElement element, double high, double target, double now) =>
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(BreathOpacity(now, high), target, TimeSpan.FromSeconds(0.3))
            { EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
    /// Ends the breath and leaves the element at its resting opacity.
    private void StopBreathing()
    {
        if (breathingTarget == null) return;
        breathLease?.Dispose(); breathLease = null;
        breathingTarget.BeginAnimation(OpacityProperty, null);
        if (breathingTarget == pending) pending.Opacity = pendingShown ? 0.6 : 0; else arc.Opacity = dim ? 0.45 : 1;
        breathingTarget = null;
    }
    /// Whether a waiting request's ring is breathing; read by the presentation checks.
    internal bool Breathing => breathLease?.IsActive == true && breathingTarget?.HasAnimatedProperties == true;
    /// Whether any endless clock is still leased; read by the presentation checks.
    internal bool HasEndlessClocks => spinLease != null || dotLease != null || breathLease != null;
    private void UpdateDot()
    {
        double phase = DotPhase;
        if (!dotting || phase <= 0 || phase >= 1) { dot.Opacity = 0; return; }
        double angle = phase * DisplayFraction * 2 * Math.PI;
        dotShift.X = Radius * Math.Sin(angle); dotShift.Y = -Radius * Math.Cos(angle);
        dot.Opacity = 0.9 * Math.Sin(Math.PI * phase);
    }
    private void UpdateArc() => arc.Data = ArcGeometry(DisplayFraction);
    private void UpdateGhost() => ghost.Data = ArcGeometry(GhostFraction);
    private static Geometry? ArcGeometry(double fraction)
    {
        if (fraction <= 0.0005) return null;
        var center = new Point(Diameter / 2, Diameter / 2);
        if (fraction >= 0.9995) return new EllipseGeometry(center, Radius, Radius);
        double angle = fraction * 2 * Math.PI;
        var start = new Point(center.X, center.Y - Radius);
        var end = new Point(center.X + Radius * Math.Sin(angle), center.Y - Radius * Math.Cos(angle));
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(start, false, false);
            context.ArcTo(end, new Size(Radius, Radius), 0, fraction > 0.5, SweepDirection.Clockwise, true, false);
        }
        geometry.Freeze();
        return geometry;
    }
    /// Rows that have not been rebuilt for ten minutes are gone for good.
    private static void Prune(double now)
    {
        if (Memories.Count < 64) return;
        var stale = new List<string>();
        foreach (var (key, value) in Memories) if (now - value.Seen > 600) stale.Add(key);
        foreach (var key in stale) Memories.Remove(key);
    }
}
