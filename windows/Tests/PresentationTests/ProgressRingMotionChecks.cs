using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using CodexPacer.Windows;

/// The task icon's motion, as the Mac draws it. The ring's loops start from its
/// finished state: task rows are rebuilt for every snapshot, so a waiting
/// request's new ring must breathe even though making it visible runs its
/// motion update mid-show. The face plays a new state's arrival once, never on
/// first sight or a rebuilt row; and the collapsed badge shows a single task's
/// estimate in place of its orbit.
internal static class ProgressRingMotionChecks
{
    internal static async Task Run()
    {
        void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var host = new StackPanel();
        var window = new Window { Content = host, Width = 80, Height = 80, Left = -20000, Top = -20000, WindowStyle = WindowStyle.None,
            ShowInTaskbar = false, ShowActivated = false };
        window.Show();
        try
        {
            string id = "progress-ring-check-" + Guid.NewGuid().ToString("N");
            TaskProgressRing? current = null;
            async Task Removed(TaskProgressRing removed)
            {
                await PresentationWait.UntilAsync(() => !removed.IsLoaded, "Removing a loaded ring must deliver Unloaded");
                Check(!removed.HasEndlessClocks, "Unloaded releases the ring's endless clocks without an explicit Halt call");
                Check(!removed.HasAnimatedProperties, "Unloaded also detaches the ring's finite property animations");
                foreach (UIElement child in removed.Children)
                    Check(!child.HasAnimatedProperties, "Unloaded detaches child opacity animations");
            }
            async Task Discard()
            {
                var removed = current; current = null; host.Children.Clear();
                if (removed != null) await Removed(removed);
            }
            async Task<TaskProgressRing> Loaded()
            {
                var ring = new TaskProgressRing(); host.Children.Add(ring);
                await PresentationWait.UntilAsync(() => ring.IsLoaded, "The progress ring must enter the real visual tree");
                return ring;
            }
            async Task<TaskProgressRing> Shown(string? state, string mode, double fraction, bool animate = true, bool stale = false)
            {
                await Discard();
                current = await Loaded();
                current.Show(id, state, mode, fraction, stale, Colors.Orange, animate);
                return current;
            }
            var working = await Shown("reported", "working", 0.4);
            Check(!working.Breathing && working.Loops == "flow", "A working request runs its light along the arc instead of breathing");
            Check((await Shown("reported", "longStep", 0.4)).Loops == "step", "A long step stops the light and breathes past the head");
            Check((await Shown("reported", "working", 0.4, stale: true)).Loops == "", "A stale estimate dims and keeps still");
            Check((await Shown("reported", "waiting", 0.4)).Breathing, "A rebuilt row for the same estimate breathes once its request waits");
            Check((await Shown("reported", "waiting", 0.4)).Breathing, "Every rebuild of a waiting row keeps breathing");
            var still = await Shown("reported", "waiting", 0.4, animate: false);
            Check(!still.Breathing, "Reduced motion never breathes");
            var paused = await Shown("reported", "waiting", 0.4);
            paused.SetMotion(false);
            Check(!paused.Breathing, "Motion switched off stops the breath");
            paused.SetMotion(true);
            Check(paused.Breathing, "Motion switched back on resumes it");
            await Shown(null, "working", 0);
            var waiting = await Shown("pending", "waiting", 0);
            Check(waiting.Breathing && waiting.CometStill, "A waiting request without an estimate shows a still circle that breathes");
            Check(!(await Shown("reported", "done", 1)).Breathing, "An ended request keeps still");
            // A request that never reported (a cloud run) ends from its turning comet.
            await Shown(null, "working", 0);
            var comet = await Shown("pending", "working", 0);
            Check(comet.Loops == "spin" && !comet.CometStill && comet.CometGrowing, "A new request's comet turns and grows its tail from a point");
            Check((await Shown("pending", "longStep", 0)).Loops == "spin", "A long step keeps the comet turning, slower");
            Check((await Shown("pending", "working", 0, animate: false)).CometStill, "Without motion the comet is a still circle");
            var filled = await Shown("reported", "done", 1);
            Check(!filled.HasEndlessClocks, "The ending stops the comet");
            Check(filled.DisplayFraction < 0.01 && filled.HasAnimatedProperties, "The ending sweeps the arc to full instead of jumping there");
            // Downward estimates use a sine curve. Reapplying that curve from
            // zero on each rebuild changes its trajectory; resume its clock.
            var tickTarget = new TranslateTransform();
            using var tick = new AnimationLease(new DoubleAnimation(0, 1, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever },
                clock => tickTarget.ApplyAnimationClock(TranslateTransform.XProperty, clock));
            foreach (int stalledMilliseconds in new[] { 0, 90, 170 })
            {
                await Shown("reported", "working", 0.9, animate: false);
                await Task.Delay(35);
                // Make the WPF time manager's last tick old before creating
                // the sweep, as on a slow renderer. No dispatcher yield may
                // refresh that tick between the stall and Show.
                Thread.Sleep(stalledMilliseconds);
                current!.Show(id, "reported", "working", 0.1, false, Colors.Orange, true);
                for (int rebuild = 0; rebuild < 3; rebuild++)
                {
                    await Task.Delay(rebuild == 0 ? 130 : 80);
                    var replacement = await Loaded();
                    if (stalledMilliseconds == 90 && rebuild == 0)
                    {
                        // Reproduce the CI clock lead even on a fast renderer:
                        // move the real WPF clock, not the remembered timeline.
                        var sweep = (AnimationLease?)typeof(TaskProgressRing).GetField("sweepLease", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(current);
                        if (sweep?.CurrentTime is TimeSpan elapsed) sweep.Seek(elapsed + TimeSpan.FromMilliseconds(45));
                    }
                    var removed = current!; double before = removed.DisplayFraction;
                    replacement.Show(id, "reported", "working", 0.1, false, Colors.Orange, true);
                    Check(Math.Abs(replacement.DisplayFraction - before) < 0.06,
                        $"A downward estimate must stay continuous through rebuild {rebuild} after a {stalledMilliseconds} ms render stall: {before:F4} -> {replacement.DisplayFraction:F4}");
                    current = replacement; host.Children.Remove(removed); await Removed(removed);
                }
            }
            current!.SetMotion(false);
            Check(Math.Abs(current.DisplayFraction - 0.1) < 0.0001 && !current.HasEndlessClocks,
                "Switching motion off settles the finite sweep and stops its loops");
            Check(Math.Abs((await Shown("reported", "working", 0.1)).DisplayFraction - 0.1) < 0.0001,
                "A rebuild after reduced motion cannot resume the old unfinished curve");
            await Discard();
            id = "codex-ring-check-" + Guid.NewGuid().ToString("N");
            current = await Loaded();
            current.Show(id, "reported", "working", 0.41, false, Colors.Turquoise, true, completionPulseOnly: true);
            current.Show(id, "reported", "working", 1, false, Colors.Turquoise, true, completionPulseOnly: true);
            Check(!((ScaleTransform)current.RenderTransform).HasAnimatedProperties, "A Codex estimate of 100% must not pulse during work");
            current.Show(id, "reported", "done", 1, false, Colors.Turquoise, true, completionPulseOnly: true);
            Check(((ScaleTransform)current.RenderTransform).HasAnimatedProperties, "Codex must pulse on completion even at an unchanged 100%");
            await Discard();
            current = await Loaded();
            current.Show(id, "reported", "done", 1, false, Colors.Turquoise, true, completionPulseOnly: true);
            Check(!((ScaleTransform)current.RenderTransform).HasAnimatedProperties, "Rebuilding a completed Codex row must not replay its pulse");
            current.Show(id, "pending", "paused", 0, false, Colors.Turquoise, true, completionPulseOnly: true);
            Check(!current.HasEndlessClocks, "A paused Codex ring is static");
            await Discard();
            Check(IconGlyph.Has("moon.zzz") && TaskGlyphArt.Parts("moon.zzz").Count == 3, "A turn waiting for its background work has its own drawn glyph");

            // The face: arrivals play once, never on first sight or a rebuilt row.
            TaskStatusIcon? icon = null;
            EngineTaskRow Row(string task, string symbol, string? state, string mode, double fraction, bool read = false) =>
                new(task, "claude", "Task", "Status", null, null, null, "running", symbol, null, "Model", null, null, false, null, null, 0, false, false, read, null, false,
                    ProgressState: state, ProgressFraction: fraction, ProgressStale: false, ProgressMode: mode);
            async Task<TaskStatusIcon> Face(string task, string symbol, string? state = "reported", string mode = "working", double fraction = 0.4, bool animate = true, bool read = false)
            {
                if (icon != null)
                {
                    var removed = icon; host.Children.Remove(removed);
                    await PresentationWait.UntilAsync(() => !removed.IsLoaded, "Removing a loaded icon must deliver Unloaded");
                    Check(!removed.RhythmsRunning && !removed.Arriving && !removed.Ring.HasEndlessClocks, "Unloaded stops the face's rhythms, arrivals and ring loops");
                }
                icon = new TaskStatusIcon(); host.Children.Add(icon);
                await PresentationWait.UntilAsync(() => icon.IsLoaded, "The status icon must enter the real visual tree");
                icon.Show(Row(task, symbol, state, mode, fraction, read), Colors.Orange, animate);
                return icon;
            }
            string task = "status-icon-check-" + Guid.NewGuid().ToString("N");
            var first = await Face(task, "checkmark.circle", "reported", "done", 1);
            Check(first.Face == "solid:checkmark.circle" && !first.Arriving, "A task seen for the first time draws its state without its arrival");
            task = "status-icon-check-" + Guid.NewGuid().ToString("N");
            var thinking = await Face(task, "sparkle");
            Check(thinking.Face == "working:sparkle" && thinking.RhythmsRunning, "A working stage lights its glyph's parts in turn");
            thinking.Show(Row(task, "terminal", "reported", "working", 0.4), Colors.Orange, true);
            Check(thinking.GlyphLayers == 2 && thinking.Face == "working:terminal", "A stage change hands the old glyph over to the new one");
            await PresentationWait.UntilAsync(() => thinking.GlyphLayers == 1, "The old glyph leaves once the new one has grown in");
            thinking.Show(Row(task, "checkmark.circle", "reported", "done", 1), Colors.Orange, true);
            Check(thinking.Arriving && !thinking.RhythmsRunning, "An ending fills its disc and draws its check once");
            var rebuilt = await Face(task, "checkmark.circle", "reported", "done", 1);
            Check(!rebuilt.Arriving && rebuilt.Face == "solid:checkmark.circle", "A rebuilt row draws the ending without replaying it");
            task = "status-icon-check-" + Guid.NewGuid().ToString("N");
            var asking = await Face(task, "terminal");
            asking.Show(Row(task, "hand.raised", "reported", "attention", 0.4), Colors.Orange, true);
            Check(asking.Arriving && asking.Face == "solid:hand.raised", "A request for the user fills, bounces and rings");
            Check(!(await Face(task + "-still", "sparkle", animate: false)).RhythmsRunning, "Reduced motion leaves the glyph still");
            await Face(task + "-last", "moon", null);
            Check(icon!.Face == "plain:moon", "An unknown state shows the moon alone");

            // The collapsed badge: one working estimate replaces the orbit with its arc.
            if (icon != null) { host.Children.Remove(icon); icon = null; }
            var badge = new ActivityBadge(); host.Children.Add(badge);
            await PresentationWait.UntilAsync(() => badge.IsLoaded, "The badge must enter the real visual tree");
            var header = new EngineHeader(1, "sparkle", new Dictionary<string, int> { ["claude"] = 1 }, null, null, null, false, "1", 0.4, false, false);
            badge.Update(header, true);
            Check(badge.ShowsEstimate && badge.EstimateLoops == "flow" && !badge.RotationScheduling.FallbackClock && !badge.RotationScheduling.Composed,
                "A single working estimate replaces the orbit with its arc and running light");
            badge.Update(header with { ProgressLongStep = true }, true);
            Check(badge.EstimateLoops == "step", "A long step breathes past the badge arc's head");
            badge.Update(header with { ProgressFraction = null, ProgressLongStep = null, ProgressStale = null }, true);
            Check(!badge.ShowsEstimate && badge.EstimateLoops == "", "Without an estimate the orbit returns");
            // Several tasks: a task without an estimate breathes in its segment and stays out of the average.
            EngineTaskShare reportedShare = new("codex", 0.5, false), waitingShare = new("claude", null, false);
            var several = new EngineHeader(2, null, new Dictionary<string, int> { ["codex"] = 1, ["claude"] = 1 }, null, null, null, false, "2",
                ProgressTasks: [reportedShare, waitingShare], ProgressAverage: 0.5, ProgressAverageStale: false, ProgressAverageProvider: "codex", ProgressReported: 1, ProgressSegments: true);
            badge.Update(several, true, new BadgeOptions(MultiRing: "segments"));
            Check(badge.RingMode == "segments" && badge.SegmentCount == 2 && badge.SegmentBreathing, "A task without an estimate breathes in its segment");
            badge.Update(several, false, new BadgeOptions(MultiRing: "segments"));
            Check(badge.RingMode == "segments" && !badge.SegmentBreathing, "Reduced motion keeps only the segment's track");
            badge.Update(several with { ProgressTasks = [reportedShare, waitingShare with { Fraction = 0.2 }], ProgressAverage = 0.35, ProgressReported = 2 }, true, new BadgeOptions(MultiRing: "segments"));
            Check(badge.RingMode == "segments" && !badge.SegmentBreathing, "An estimate stops the segment's breath");
            badge.Update(several with { ProgressTasks = [reportedShare with { Fraction = null }, waitingShare], ProgressAverage = null, ProgressReported = 0, ProgressSegments = false },
                true, new BadgeOptions(MultiRing: "average", MultiCore: "percent"));
            Check(badge.RingMode == "orbit" && badge.CoreText == "2", "With no estimate at all the ring shows the services");
            badge.Update(several with { ActiveCount = 5, ActiveCountText = "5", ProgressSegments = false }, true, new BadgeOptions(MultiRing: "segments", MultiCore: "percent"));
            Check(badge.RingMode == "average" && badge.CoreText == "5", "More tasks than segments give way to the average and keep the count");
            badge.Update(several, true, new BadgeOptions(MultiRing: "average", MultiCore: "percent"));
            Check(badge.RingMode == "average" && badge.CoreText == "50", "The chosen average counts only reported tasks and shows its percent");
            await CheckHelpers(badge, header, several);
            badge.Update(new EngineHeader(0, "checkmark.circle", new Dictionary<string, int>(), null, "checkmark.circle", "claude", true, "0"), true);
            Check(!badge.SegmentBreathing, "Leaving the segments stops their breath");
            Check(badge.CoreIsSolid, "When everything has ended the core is a solid disc under a dark mark");
            host.Children.Remove(badge);
            Console.WriteLine("PASS progress ring: comet, running light, long-step breath, breathing, reduced motion, completion sweeps, Codex completion-only pulses, continuous downward rebuilds, one-time arrivals, stage changes, badge estimate, Codex for Claude light and real Unloaded cleanup");
        }
        finally { window.Close(); }
    }

    /// Codex for Claude runs have no number on the badge: without an estimate they
    /// circle as Codex comets; over an estimate Codex's light travels the stretch
    /// it has not reached, and in segments the stretch of the task they work for.
    private static async Task CheckHelpers(ActivityBadge badge, EngineHeader single, EngineHeader several)
    {
        const double gap = HelperLight.Gap;
        static bool Near(double a, double b) => Math.Abs(a - b) < 0.0001;
        static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var estimate = single with { ProgressFraction = 0.62, ProgressLongStep = false, ProgressStale = false };
        badge.Update(estimate, true);
        Check(badge.HelperStretch == null && !badge.HelperTravels, "No run, no Codex light");
        badge.Update(estimate with { DelegatedRunning = 1, DelegatedText = "Codex 1" }, true);
        Check(badge.HelperStretch is { } free && Near(free.Start, 0.62 + gap) && Near(free.End, 1 - gap) && badge.HelperTravels,
            "Codex's light keeps clear of the arc's head and of the top, where the arc starts");
        Check(badge.EstimateLoops == "flow", "Claude's light keeps running along its arc beside Codex's");
        Check(badge.OrbitCodexWeight == 0, "Over an estimate the runs are no comets");
        // The island updates both badges and then shows one: a hidden badge stops its lights, a shown one starts them.
        badge.Visibility = Visibility.Collapsed;
        await PresentationWait.UntilAsync(() => !badge.HelperTravels && badge.EstimateLoops == "", "A hidden badge must stop its lights");
        badge.Visibility = Visibility.Visible;
        await PresentationWait.UntilAsync(() => badge.HelperTravels && badge.EstimateLoops == "flow", "A badge shown again must start its lights without a new snapshot");
        badge.Update(estimate with { DelegatedRunning = 1, ProgressLongStep = true }, true);
        Check(badge.HelperStretch is { } breath && Near(breath.Start, 0.62 + EstimatePaint.StepLengths[0] + gap) && badge.HelperTravels,
            "Codex's light keeps clear of a long step's breath and keeps travelling");
        badge.Update(estimate with { DelegatedRunning = 1, ProgressFraction = 0.95 }, true);
        Check(badge.HelperStretch == null && !badge.HelperTravels, "Too little ring left to show Codex's light");
        badge.Update(estimate with { DelegatedRunning = 2, ProgressFraction = 0.3 }, false);
        Check(badge.HelperTinted && !badge.HelperTravels, "Without motion the stretch keeps a still Codex tint");
        badge.Update(single with { ProgressFraction = null, ProgressLongStep = null, ProgressStale = null, DelegatedRunning = 2 }, true);
        Check(badge.HelperStretch == null && badge.RingMode == "orbit" && badge.OrbitCodexWeight == 2, "Without an estimate the runs join the comets in Codex's colour");
        // Segments: the light travels the free stretch of the Claude task the runs work for.
        var segmented = several with { ProgressTasks = [new("claude", 0.4, false, 1), new("codex", 0.5, false)], ProgressAverage = 0.45, ProgressReported = 2, DelegatedRunning = 1 };
        badge.Update(segmented, true, new BadgeOptions(MultiRing: "segments"));
        double span = (1 - SegmentPaint.Gap * 2) / 2, first = SegmentPaint.Gap / 2;
        var lanes = badge.LaneHelperStretches;
        Check(badge.RingMode == "segments" && lanes.Length == 2 && lanes[1] == null && lanes[0] is { } lane
            && Near(lane.Start, first + 0.4 * span + gap) && Near(lane.End, first + span - gap) && badge.HelperLoops,
            "In segments Codex's light travels the free stretch of the task its runs work for");
        badge.Update(segmented with { ProgressTasks = [new("claude", 0.4, false), new("codex", 0.5, false)], DelegatedRunning = null }, true, new BadgeOptions(MultiRing: "segments"));
        Check(badge.LaneHelperStretches.All(stretch => stretch == null) && !badge.HelperLoops, "Codex's light leaves when the runs end");
        // The light is one smooth gradient: a soft front ahead of the head and a tail that fades away behind it.
        Check(Near(EstimatePaint.LightShare(0), 1) && Near(EstimatePaint.LightShare(EstimatePaint.FlowFront), 0) && EstimatePaint.LightShare(0.01) is > 0 and < 1
            && Near(EstimatePaint.LightShare(-0.2 * EstimatePaint.FlowTail), 0.62) && Near(EstimatePaint.LightShare(-EstimatePaint.FlowTail), 0)
            && Enumerable.Range(1, 40).Select(step => EstimatePaint.LightShare(-EstimatePaint.FlowTail * step / 40)).Zip(
                Enumerable.Range(0, 40).Select(step => EstimatePaint.LightShare(-EstimatePaint.FlowTail * step / 40))).All(pair => pair.First <= pair.Second),
            "The light fades smoothly from its head");
        // Drawn, the light covers only its reach inside its stretch, from the stretch's start to
        // just past its head, through its gradient; the retained drawing is read, never pixels.
        var lit = new EstimatePaint(EstimatePaint.Layer.Flow, 9, 2, 0) { Fraction = 1, Start = 0.5, Limit = 0.9, Peak = 1, Ink = Colors.White, Flowing = true, FlowHead = 0.7 };
        var drawn = DrawingInspection.Render(lit, 20, 20);
        var reach = EstimatePaint.Arc(new Point(10, 10), 9, 0.5, 0.7 + EstimatePaint.FlowFront).GetRenderBounds(new Pen(Brushes.White, 2));
        var bounds = VisualTreeHelper.GetDrawing(lit)?.Bounds ?? Rect.Empty;
        Check(drawn.Count == 1 && drawn[0].Brush is ImageBrush && Math.Abs(bounds.Left - reach.Left) < 0.05 && Math.Abs(bounds.Top - reach.Top) < 0.05
            && Math.Abs(bounds.Right - reach.Right) < 0.05 && Math.Abs(bounds.Bottom - reach.Bottom) < 0.05,
            $"The drawn light covers just its reach at its head, through its gradient: {bounds} against {reach}");
        var travel = EstimatePaint.Travel(0.5, 0.9, 0, 30);
        Check(travel.KeyFrames[0].Value == 0.5 - EstimatePaint.FlowFront && travel.KeyFrames[2].Value == 0.9 + EstimatePaint.FlowTail,
            "The light enters at its stretch's start and leaves past its end before resting");
    }
}
