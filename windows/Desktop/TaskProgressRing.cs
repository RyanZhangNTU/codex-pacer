using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// The self-reported progress ring drawn around a task row's status icon, as
/// the Mac's TaskStatusIconNSView draws it: a comet circles while a request
/// works without an estimate, slower with a shorter tail during a long step; a
/// reported estimate is an arc with a soft glow and a band of light running
/// along it; during a long step the light stops and the stretch past the head
/// breathes; a request waiting for its background work breathes as a whole.
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
    private static readonly Brush TrackInk = PacerPalette.Ink(255, 255, 255, 20);
    internal static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static readonly Dictionary<string, Memory> Memories = new();
    internal static double Now => Clock.Elapsed.TotalSeconds;
    /// The comet's turn: a working request, and a long step.
    internal const double WorkingPeriod = 2.0, LongStepPeriod = 3.2;
    /// The comet's tail as a share of the circle; a new request's grows from a point.
    internal const double WorkingTail = 0.5, LongStepTail = 0.26, LaunchTail = 0.015;
    /// A waiting ring breathes down to this share of its resting opacity.
    private const double BreathPeriod = 4, BreathLow = 0.3;
    /// The comet's resting opacity; the arc's is 1, or 0.45 once stale.
    private const double PendingOpacity = 1, StaleOpacity = 0.45;

    private readonly CometPaint pending = new(Radius, Stroke) { Width = Diameter, Height = Diameter, Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
    private readonly Ellipse track = new() { StrokeThickness = Stroke, Stroke = TrackInk, Opacity = 0 };
    private readonly Path ghost = new() { StrokeThickness = Stroke, Opacity = 0 };
    private readonly EstimatePaint arc = new(EstimatePaint.Layer.Arc, Radius, Stroke, 4.5) { Width = Diameter, Height = Diameter };
    private readonly EstimatePaint flow = new(EstimatePaint.Layer.Flow, Radius, Stroke, 0) { Width = Diameter, Height = Diameter };
    private readonly EstimatePaint step = new(EstimatePaint.Layer.Step, Radius, Stroke, 0) { Width = Diameter, Height = Diameter, Opacity = 0 };
    private readonly RotateTransform rotation = new();
    private readonly ScaleTransform scale = new(1, 1);
    private readonly SolidColorBrush ink = new(Colors.Transparent);
    private bool motion, pendingShown, dim, showing;
    /// Endless clocks are leased so stopping one removes it from WPF's clock
    /// manager; a clock only detached from its property ticks until a GC.
    private AnimationLease? spinLease, flowLease, stepLease, breathLease;
    private AnimationLease? sweepLease, tailLease;
    private double? spinningPeriod, flowingTo;
    /// The element whose opacity breathes while the request waits, if any.
    private UIElement? breathingTarget;
    /// The request's lifecycle mode from the engine: working, longStep,
    /// attention, waiting, done, interrupted or failed.
    private string mode = "working";
    private double targetFraction;
    private string? taskID;

    private sealed class Memory
    {
        public string State = "";
        public double From, To, Start, Duration;
        public IEasingFunction? Ease;
        public bool Stale, Full, Done;
        /// The ring was breathing: a request waiting for its background work.
        public bool Breathing;
        public Color Color;
        public double Seen;
        public WeakReference<AnimationLease>? Sweep;
        public int SweepGeneration;
        /// The comet's turn: its angle at `SpinEpoch` and its period. A long
        /// step changes the period from the angle shown at that moment.
        public double SpinOrigin, SpinEpoch, SpinPeriod = WorkingPeriod;
        public double SpinAngle(double now) => (SpinOrigin + (now - SpinEpoch) / SpinPeriod * 360) % 360;
        public double Elapsed(double now)
        {
            // A live renderer is authoritative even if its last tick is old.
            // Keep only a weak lease so remembered rows cannot retain clocks.
            if (Sweep?.TryGetTarget(out var sweep) == true && sweep.IsActive)
                return sweep.CurrentTime?.TotalSeconds ?? Math.Min(0, now - Start);
            return now - Start;
        }
        public double Displayed(double now)
        {
            double elapsed = Elapsed(now);
            if (Duration <= 0 || elapsed >= Duration) return To;
            if (elapsed <= 0) return From;
            double progress = elapsed / Duration;
            return From + (To - From) * (Ease?.Ease(progress) ?? progress);
        }
    }

    public TaskProgressRing()
    {
        Width = Height = Diameter; IsHitTestVisible = false; Visibility = Visibility.Collapsed;
        RenderTransformOrigin = new Point(0.5, 0.5); RenderTransform = scale;
        pending.RenderTransform = rotation; ghost.Stroke = ink;
        // The colour animates through one brush; the drawn layers follow it.
        ink.Changed += (_, _) => { pending.Ink = arc.Ink = step.Ink = ink.Color; };
        Children.Add(track); Children.Add(pending); Children.Add(ghost); Children.Add(arc); Children.Add(flow); Children.Add(step);
        IsVisibleChanged += (_, _) => UpdateSpin();
        Unloaded += (_, _) => Halt();
    }

    /// Applies one row's ring. Returns how the ring changed for this task, so
    /// the row can shrink or restore its icon in step with it.
    internal Change Show(string id, string? state, string? lifecycle, double fraction, bool stale, Color color, bool animate,
                         bool completionPulseOnly = false)
    {
        taskID = id;
        // Making the ring visible raises IsVisibleChanged synchronously. Its
        // looping motion starts once, from the finished state: started midway,
        // it would read stale fields and a later opacity fade would cancel it.
        showing = true;
        try { StopBreathing(); return Apply(id, state, lifecycle, fraction, stale, color, animate, completionPulseOnly); }
        finally { showing = false; UpdateSpin(); }
    }
    private Change Apply(string id, string? state, string? lifecycle, double fraction, bool stale, Color color, bool animate,
                         bool completionPulseOnly)
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
            if (previous.State == "pending") { pending.Opacity = PendingOpacity; track.Opacity = 0; }
            else { track.Opacity = 1; SetFraction(previous.Displayed(now)); }
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
            // A new request's comet grows its tail from a point, as on the Mac.
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            AnimateTail(LaunchTail, WorkingTail, 0.9);
        }
        else if (previous == null) { tailLease?.Dispose(); tailLease = null; pending.BeginAnimation(CometPaint.TailProperty, null); pending.Tail = Tail(lifecycle); }
        // A working request without a new estimate for a while dims.
        bool dimmed = state == "reported" && stale;
        // Leaving the wait, the element eases from the breath's current opacity.
        bool leftBreath = animate && previous?.Breathing == true && mode != "waiting";
        bool justCompleted = completionPulseOnly && mode == "done" && previous?.Done == false;
        if (completionPulseOnly && previous?.Done == true && mode != "done")
        {
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        }
        var memory = new Memory { State = state, Color = color, Seen = now, Stale = dimmed, Breathing = mode == "waiting", Done = mode == "done" };
        // The comet keeps its turn across rebuilt rows.
        if (previous != null) { memory.SpinOrigin = previous.SpinOrigin; memory.SpinEpoch = previous.SpinEpoch; memory.SpinPeriod = previous.SpinPeriod; }
        else { memory.SpinOrigin = 0; memory.SpinEpoch = now; memory.SpinPeriod = WorkingPeriod; }
        if (state == "pending")
        {
            double shown = previous?.State == "reported" ? previous.Displayed(now) : 0;
            pendingShown = true; arc.Opacity = 1; ghost.Opacity = 0; dim = false; targetFraction = 0;
            if (animate && shown > 0.0005)
            {
                // A new turn replaces an old estimate: retract it, then the comet comes in.
                track.Opacity = 1; pending.Opacity = 0;
                Sweep(shown, 0, 0.3, new QuadraticEase { EasingMode = EasingMode.EaseIn }, 0);
                track.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, TimeSpan.FromSeconds(0.2)) { BeginTime = TimeSpan.FromSeconds(0.3) });
                pending.BeginAnimation(OpacityProperty, new DoubleAnimation(0, PendingOpacity, TimeSpan.FromSeconds(0.2)) { BeginTime = TimeSpan.FromSeconds(0.3) });
            }
            else
            {
                SetFraction(0); track.Opacity = 0; pending.Opacity = PendingOpacity;
                if (leftBreath && previous!.State == "pending") EaseOutOfBreath(pending, PendingOpacity, PendingOpacity, now);
            }
            // A long step slows the comet and shortens its tail from the angle shown.
            if (previous?.State == "pending" && Tail(previous.Breathing ? "working" : mode) != Tail(lifecycle) && animate && !appeared)
                AnimateTail(pending.Tail, Tail(lifecycle), 0.4);
            else if (!(appeared && animate && previous == null)) { tailLease?.Dispose(); tailLease = null; pending.BeginAnimation(CometPaint.TailProperty, null); pending.Tail = Tail(lifecycle); }
            Memories[id] = memory;
            return appeared ? Change.Appeared : Change.Shown;
        }
        // Reported.
        double target = Math.Clamp(fraction, 0, 1);
        dim = dimmed; targetFraction = target;
        if (previous?.State == "reported" && Math.Abs(previous.To - target) < 0.0005)
        {
            // The same estimate on a rebuilt row: finish whatever was running.
            double elapsed = previous.Elapsed(now), remaining = previous.Duration - elapsed;
            track.Opacity = 1; pending.Opacity = 0; pendingShown = false;
            if (animate && remaining > 0.02)
                Sweep(previous.From, target, previous.Duration, previous.Ease, Math.Max(0, -elapsed), Math.Max(0, elapsed), previous);
            else SetFraction(target);
            previous.Seen = now; previous.Color = color;
            Fade(previous.Stale, dimmed, animate);
            if (leftBreath) EaseOutOfBreath(arc, 1, dimmed ? StaleOpacity : 1, now);
            if (animate && justCompleted) Pulse(Math.Max(0, remaining));
            previous.Done = memory.Done;
            previous.Stale = dimmed; previous.Breathing = mode == "waiting"; Memories[id] = previous;
            return Change.Shown;
        }
        double from = previous?.State == "reported" ? previous.Displayed(now) : 0, delay = 0, duration;
        IEasingFunction ease2;
        if (previous?.State == "pending" && animate)
        {
            // The first estimate, or the ending of a request that never reported
            // (a cloud one): the dashes close into the track, then the arc sweeps.
            pending.BeginAnimation(OpacityProperty, new DoubleAnimation(previous.Breathing ? BreathOpacity(now, PendingOpacity) : pending.Opacity, 0, TimeSpan.FromSeconds(0.2)));
            track.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.2)));
            delay = 0.2; duration = 0.3 + 0.3 * target; ease2 = new CubicEase { EasingMode = EasingMode.EaseOut };
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
        memory.From = from; memory.To = target; memory.Start = now + delay; memory.Duration = animate && previous != null ? duration : 0;
        memory.Ease = ease2;
        if (animate && previous != null && Math.Abs(target - from) > 0.0005) Sweep(from, target, duration, ease2, delay, memory: memory);
        else { arc.BeginAnimation(OpacityProperty, null); SetFraction(target); duration = 0; memory.Duration = 0; }
        Fade(previous?.Stale ?? false, dimmed, animate && previous != null);
        if (leftBreath && previous!.State == "reported") EaseOutOfBreath(arc, 1, dimmed ? StaleOpacity : 1, now);
        bool full = target >= 0.9995;
        if (full && animate && (justCompleted || !completionPulseOnly && previous?.Full == false && mode is ("working" or "done")))
            Pulse(delay + duration);
        memory.Full = full || previous?.Full == true && target >= 0.9995;
        Memories[id] = memory;
        return appeared ? Change.Appeared : Change.Shown;
    }

    private void Pulse(double after)
    {
        var pulse = new DoubleAnimationUsingKeyFrames { BeginTime = TimeSpan.FromSeconds(after + 0.05) };
        pulse.KeyFrames.Add(new EasingDoubleKeyFrame(1.06, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.18)), new QuadraticEase { EasingMode = EasingMode.EaseOut }));
        pulse.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.4)), new QuadraticEase { EasingMode = EasingMode.EaseInOut }));
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, pulse);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, pulse);
    }

    /// Motion follows the island: reduced motion, hidden or occluded panels
    /// show final values and never spin.
    internal void SetMotion(bool value)
    {
        motion = value;
        if (!value)
        {
            SetFraction(targetFraction);
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            // A rebuilt row inherits the settled value after reduced motion.
            if (taskID != null && Memories.TryGetValue(taskID, out var memory))
            { memory.From = memory.To; memory.Start = Now; memory.Duration = 0; }
        }
        UpdateSpin();
    }
    internal void Halt()
    {
        sweepLease?.Dispose(); sweepLease = null; tailLease?.Dispose(); tailLease = null;
        spinLease?.Dispose(); spinLease = null; flowLease?.Dispose(); flowLease = null; stepLease?.Dispose(); stepLease = null;
        breathLease?.Dispose(); breathLease = null; breathingTarget = null; spinningPeriod = null; flowingTo = null;
        rotation.BeginAnimation(RotateTransform.AngleProperty, null);
        foreach (var element in new UIElement[] { this, pending, track, ghost, arc, flow, step }) element.BeginAnimation(OpacityProperty, null);
        BeginAnimation(DisplayFractionProperty, null); BeginAnimation(GhostFractionProperty, null);
        flow.BeginAnimation(EstimatePaint.FrontProperty, null); flow.Flowing = false; pending.BeginAnimation(CometPaint.TailProperty, null);
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, null); scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        ink.BeginAnimation(SolidColorBrush.ColorProperty, null);
    }
    /// The comet's tail for a lifecycle mode.
    private static double Tail(string? lifecycle) => lifecycle == "longStep" ? LongStepTail : WorkingTail;
    private void AnimateTail(double from, double to, double seconds)
    {
        tailLease?.Dispose(); pending.Tail = to;
        // The Mac's launch curve, cubic-bezier(.22, 1, .36, 1).
        var grow = new DoubleAnimationUsingKeyFrames();
        grow.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        grow.KeyFrames.Add(new SplineDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(seconds)), new KeySpline(0.22, 1, 0.36, 1)));
        tailLease = new AnimationLease(grow, clock => pending.ApplyAnimationClock(CometPaint.TailProperty, clock), () => { tailLease = null; pending.Tail = to; });
    }

    private void SetFraction(double value)
    {
        sweepLease?.Dispose(); sweepLease = null;
        BeginAnimation(DisplayFractionProperty, null); DisplayFraction = value;
    }
    private void Sweep(double from, double to, double seconds, IEasingFunction? ease, double delay, double elapsed = 0, Memory? memory = null)
    {
        SetFraction(from);
        var animation = new DoubleAnimation(from, to, TimeSpan.FromSeconds(Math.Max(0.01, seconds)))
            { EasingFunction = ease, BeginTime = TimeSpan.FromSeconds(delay) };
        int generation = memory == null ? 0 : ++memory.SweepGeneration;
        sweepLease = new AnimationLease(animation, clock => ApplyAnimationClock(DisplayFractionProperty, clock),
            () =>
            {
                sweepLease = null; DisplayFraction = to;
                if (memory != null && memory.SweepGeneration == generation)
                { memory.Duration = 0; memory.From = to; memory.Sweep = null; }
            }, clock =>
            {
                // WPF may start a new clock at an earlier time-manager tick.
                // Calibrate from its real local time instead of Show's time.
                if (memory != null && memory.SweepGeneration == generation && clock.CurrentTime is TimeSpan time)
                    memory.Start = Now - time.TotalSeconds;
            });
        if (memory != null) memory.Sweep = new WeakReference<AnimationLease>(sweepLease);
        if (elapsed > 0) sweepLease.Seek(TimeSpan.FromSeconds(elapsed));
    }
    private void Fade(bool wasStale, bool stale, bool animate)
    {
        double target = stale ? StaleOpacity : 1;
        arc.Stale = stale;
        if (!animate || wasStale == stale) { arc.BeginAnimation(OpacityProperty, null); arc.Opacity = target; return; }
        arc.BeginAnimation(OpacityProperty, new DoubleAnimation(wasStale ? StaleOpacity : 1, target, TimeSpan.FromSeconds(stale ? 0.6 : 0.2))
            { EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } });
    }
    /// Looping motion by lifecycle mode, on the shared clock so a rebuilt row's
    /// motion continues where the old one was. The comet turns while the request
    /// works without an estimate (slower in a long step); light runs along a
    /// working arc; the stretch past the head breathes in a long step; a waiting
    /// request breathes. Without motion the comet is a still circle.
    private void UpdateSpin()
    {
        if (showing) return;
        bool live = motion && IsVisible && Visibility == Visibility.Visible;
        double now = Now;
        Memories.TryGetValue(taskID ?? "", out var memory);
        bool spin = live && pendingShown && mode is "working" or "longStep";
        double? period = spin ? mode == "longStep" ? LongStepPeriod : WorkingPeriod : null;
        if (period != spinningPeriod)
        {
            // Stopping or changing speed keeps the comet where it is.
            double angle = memory?.SpinAngle(now) ?? rotation.Angle;
            spinLease?.Dispose(); spinLease = null; rotation.BeginAnimation(RotateTransform.AngleProperty, null); rotation.Angle = angle;
            spinningPeriod = period;
            if (period is double seconds)
            {
                if (memory != null && memory.SpinPeriod != seconds) { memory.SpinOrigin = angle; memory.SpinEpoch = now; memory.SpinPeriod = seconds; }
                spinLease = new AnimationLease(new DoubleAnimation(angle, angle + 360, TimeSpan.FromSeconds(seconds)) { RepeatBehavior = RepeatBehavior.Forever },
                    clock => rotation.ApplyAnimationClock(RotateTransform.AngleProperty, clock));
            }
        }
        pending.Still = pendingShown && !spin;
        double? travel = live && !pendingShown && !dim && mode == "working" && targetFraction is > 0.04 and < 0.9995 ? targetFraction : null;
        if (travel != flowingTo)
        {
            flowLease?.Dispose(); flowLease = null; flow.BeginAnimation(EstimatePaint.FrontProperty, null);
            flowingTo = travel; flow.Flowing = travel != null;
            if (travel is double fraction)
            {
                // One run from the arc's start out through its head, then a rest; it never passes the head.
                double reach = fraction + EstimatePaint.FlowLengths[0];
                var run = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(EstimatePaint.FlowPeriod), RepeatBehavior = RepeatBehavior.Forever,
                    BeginTime = TimeSpan.FromSeconds(-(now % EstimatePaint.FlowPeriod)) };
                run.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                run.KeyFrames.Add(new LinearDoubleKeyFrame(reach, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.FlowTravel))));
                run.KeyFrames.Add(new DiscreteDoubleKeyFrame(reach, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.FlowPeriod))));
                flowLease = new AnimationLease(run, clock => flow.ApplyAnimationClock(EstimatePaint.FrontProperty, clock));
            }
        }
        flow.Limit = targetFraction;
        // A long step: the light stops and the stretch past the head breathes.
        bool stepShown = !pendingShown && mode == "longStep" && targetFraction < 0.9995;
        bool stepBreath = live && stepShown;
        if (stepBreath != (stepLease != null))
        {
            stepLease?.Dispose(); stepLease = null; step.BeginAnimation(OpacityProperty, null);
            if (stepBreath)
            {
                var breath = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(EstimatePaint.StepPeriod), RepeatBehavior = RepeatBehavior.Forever,
                    BeginTime = TimeSpan.FromSeconds(-(now % EstimatePaint.StepPeriod)) };
                var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
                breath.KeyFrames.Add(new LinearDoubleKeyFrame(0.2, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                breath.KeyFrames.Add(new EasingDoubleKeyFrame(0.85, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.StepPeriod / 2)), ease));
                breath.KeyFrames.Add(new EasingDoubleKeyFrame(0.2, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(EstimatePaint.StepPeriod)), ease));
                stepLease = new AnimationLease(breath, clock => step.ApplyAnimationClock(OpacityProperty, clock));
            }
        }
        if (!stepBreath) step.Opacity = stepShown ? 0.55 : 0;
        // The comet breathes until the first estimate, the arc after it.
        UIElement? breath2 = !live || mode != "waiting" ? null : pendingShown ? pending : (UIElement)arc;
        if (breath2 != breathingTarget)
        {
            StopBreathing();
            if (breath2 is UIElement element)
            {
                double high = element == pending ? PendingOpacity : 1;
                breathLease = new AnimationLease(new DoubleAnimation(high, high * BreathLow, TimeSpan.FromSeconds(BreathPeriod / 2))
                    { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
                      BeginTime = TimeSpan.FromSeconds(-(now % BreathPeriod)) }, clock => element.ApplyAnimationClock(OpacityProperty, clock));
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
        if (breathingTarget == pending) pending.Opacity = pendingShown ? PendingOpacity : 0; else arc.Opacity = dim ? StaleOpacity : 1;
        breathingTarget = null;
    }
    /// Whether a waiting request's ring is breathing; read by the presentation checks.
    internal bool Breathing => breathLease?.IsActive == true && breathingTarget?.HasAnimatedProperties == true;
    /// Whether any endless clock is still leased; read by the presentation checks.
    internal bool HasEndlessClocks => spinLease != null || flowLease != null || stepLease != null || breathLease != null;
    /// What the ring loops now, for the presentation checks: spin, flow, step and breath.
    internal string Loops => string.Join(",", new[] { spinLease != null ? "spin" : null, flowLease != null ? "flow" : null,
        stepLease != null ? "step" : null, breathLease != null ? "breath" : null }.Where(value => value != null));
    /// Whether the comet shows as a still circle; read by the presentation checks.
    internal bool CometStill => pending.Still;
    internal double CometTail => pending.Tail;
    /// Whether the comet's tail is still growing or shrinking to its length.
    internal bool CometGrowing => tailLease != null;
    /// When a task's arc finishes its sweep, as seconds from now; the icon fills its disc after it.
    internal static double SweepRemaining(string id) =>
        Memories.TryGetValue(id, out var memory) && memory.State == "reported" ? Math.Max(0, memory.Duration - memory.Elapsed(Now)) : 0;
    private void UpdateArc() { arc.Fraction = flow.Fraction = step.Fraction = DisplayFraction; }
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
