using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using CodexPacer.Windows;

/// The ring's looping motion starts from its finished state. Task rows are
/// rebuilt for every snapshot, so a waiting request's new ring must breathe
/// even though making it visible runs its motion update mid-show.
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
            async Task<TaskProgressRing> Shown(string? state, string mode, double fraction, bool animate = true)
            {
                await Discard();
                current = await Loaded();
                current.Show(id, state, mode, fraction, false, Colors.Orange, animate);
                return current;
            }
            var working = await Shown("reported", "working", 0.4);
            Check(!working.Breathing && working.HasEndlessClocks, "A working request runs its dot instead of breathing");
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
            Check((await Shown("pending", "waiting", 0)).Breathing, "A waiting request without an estimate breathes its dashes");
            Check(!(await Shown("reported", "done", 1)).Breathing, "An ended request keeps still");
            // A request that never reported (a cloud run) ends from its turning dashes.
            await Shown(null, "working", 0);
            Check((await Shown("pending", "working", 0)).HasEndlessClocks, "Dashes turn while a request without an estimate works");
            var filled = await Shown("reported", "done", 1);
            Check(!filled.HasEndlessClocks, "The ending stops the dashes");
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
            Check(IconGlyph.Has("zzz"), "A turn waiting for its background work has its own drawn glyph");
            Console.WriteLine("PASS progress ring: breathing, reduced motion, completion sweeps, Codex completion-only pulses, continuous downward rebuilds and real Unloaded cleanup");
        }
        finally { window.Close(); }
    }
}
