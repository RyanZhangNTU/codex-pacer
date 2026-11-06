using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CodexPacer.Windows;

/// The ring's looping motion starts from its finished state. Task rows are
/// rebuilt for every snapshot, so a waiting request's new ring must breathe
/// even though making it visible runs its motion update mid-show.
internal static class ProgressRingMotionChecks
{
    internal static void Run()
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
            // These rings are never loaded, so no Unloaded event halts their
            // endless clocks; later idle checks require that nothing ticks.
            void Discard()
            {
                current?.Halt();
                Check(current?.HasEndlessClocks != true, "Halting a ring removes its endless clocks from WPF's clock manager");
                current = null; host.Children.Clear();
            }
            TaskProgressRing Shown(string? state, string mode, double fraction, bool animate = true)
            {
                Discard();
                current = new TaskProgressRing(); host.Children.Add(current);
                current.Show(id, state, mode, fraction, false, Colors.Orange, animate);
                return current;
            }
            var working = Shown("reported", "working", 0.4);
            Check(!working.Breathing && working.HasEndlessClocks, "A working request runs its dot instead of breathing");
            Check(Shown("reported", "waiting", 0.4).Breathing, "A rebuilt row for the same estimate breathes once its request waits");
            Check(Shown("reported", "waiting", 0.4).Breathing, "Every rebuild of a waiting row keeps breathing");
            var still = Shown("reported", "waiting", 0.4, animate: false);
            Check(!still.Breathing, "Reduced motion never breathes");
            var paused = Shown("reported", "waiting", 0.4);
            paused.SetMotion(false);
            Check(!paused.Breathing, "Motion switched off stops the breath");
            paused.SetMotion(true);
            Check(paused.Breathing, "Motion switched back on resumes it");
            Shown(null, "working", 0);
            Check(Shown("pending", "waiting", 0).Breathing, "A waiting request without an estimate breathes its dashes");
            Check(!Shown("reported", "done", 1).Breathing, "An ended request keeps still");
            // A request that never reported (a cloud run) ends from its turning dashes.
            Shown(null, "working", 0);
            Check(Shown("pending", "working", 0).HasEndlessClocks, "Dashes turn while a request without an estimate works");
            var filled = Shown("reported", "done", 1);
            Check(!filled.HasEndlessClocks, "The ending stops the dashes");
            Check(filled.DisplayFraction < 0.01 && filled.HasAnimatedProperties, "The ending sweeps the arc to full instead of jumping there");
            Discard();
            Check(IconGlyph.Has("zzz"), "A turn waiting for its background work has its own drawn glyph");
            Console.WriteLine("PASS progress ring: waiting rows breathe after every rebuild, reduced motion and endings keep still, unreported endings sweep from the dashes");
        }
        finally { window.Close(); }
    }
}
