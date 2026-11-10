using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class IdleSchedulingChecks
{
    internal static async Task Run()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        await using var engine = new EngineClient();
        var window = new IslandWindow(engine, true, false, animationOverride: true) { IsHitTestVisible = false };
        long frames = 0, renders = 0, snapshots = 0;
        window.FrameApplied += _ => frames++;
        engine.Snapshot += _ => Interlocked.Increment(ref snapshots);
        DispatcherHookEventHandler posted = (_, args) => { if (args.Operation.Priority == DispatcherPriority.Render) Interlocked.Increment(ref renders); };
        try
        {
            window.ApplyPreferences(new() { IslandAppearance = "classic" }); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.CollapseForAutomation(); await window.WaitForPresentationAsync(); await Task.Delay(500);
            var badge = (ActivityBadge)window.FindName("Badge");
            var quota = (AlternatingQuotaText)window.FindName("QuotaLabel");
            var header = engine.LatestSnapshot!.Presentation!.Header;
            bool composed = badge.RotationScheduling.Composed;
            if (composed)
            {
                Check(!badge.RotationScheduling.FallbackClock && badge.RotationScheduling.Window != IntPtr.Zero,
                    "The continuous ring uses a composition HWND without a WPF spin clock");
                long uploads = badge.RotationScheduling.Uploads;
                for (int i = 0; i < 10; i++) badge.Update(header, true);
                await Task.Delay(250);
                Check(badge.RotationScheduling.Uploads == uploads, "Identical snapshots never repaint the ring texture");
                Check(GetForegroundWindow() != badge.RotationScheduling.Window, "The decoration never takes focus");
            }
            else Check(badge.RotationScheduling.FallbackClock, "A machine without composition retains the animated WPF fallback");
            badge.Update(header, false);
            Check(!badge.RotationScheduling.Composed && !badge.RotationScheduling.FallbackClock, "Reduced motion removes the continuous clock");
            Application.Current.Dispatcher.Hooks.OperationPosted += posted;
            for (int count = 1; count <= 3; count++)
            {
                var entries = new[] { ("codex", "43"), ("claude", "81"), ("deepseek", "86") }[..count];
                quota.Update(entries, true); quota.Visibility = Visibility.Hidden; quota.Visibility = Visibility.Visible;
                await Task.Delay(300);
                Check(quota.Scheduling.Clocks == 0 && quota.Scheduling.Scheduled == (count > 1), "Only multiple providers arm a single hold deadline");
                long beforeRenders = Interlocked.Read(ref renders), beforeWakes = quota.Scheduling.Wakes;
                for (int i = 0; i < 10; i++) quota.Update(entries, true);
                await Task.Delay(450);
                Check(Interlocked.Read(ref renders) == beforeRenders && quota.Scheduling.Wakes == beforeWakes,
                    "An unchanged hold has no WPF render callbacks or timer wakeups, without forcing GC");
            }
            long beforeSnapshots = Interlocked.Read(ref snapshots), beforeFrames = frames;
            // Keep the real hold deadline and both actual WPF clocks. Advance
            // the finite fade explicitly, so a delayed WPF timing tick cannot
            // turn the unchanged 3400 ms bound into a wall-clock race.
            int controlledFades = 0;
            void FinishFade(TimeSpan duration)
            {
                Check(quota.Scheduling.Clocks == 4 && duration > TimeSpan.Zero, "The controlled switch must own its finite WPF clocks: two fades and two slides");
                controlledFades++; quota.SeekFadeForAutomation(duration);
            }
            quota.FadeStartedForAutomation += FinishFade;
            try { await quota.WaitForNextCycleAsync(TimeSpan.FromMilliseconds(3400)); }
            catch (TimeoutException error) { throw new InvalidOperationException("The quota cycle exceeded its original deadline; " + quota.CycleDiagnostics + ", quota=" + quota.Scheduling, error); }
            finally { quota.FadeStartedForAutomation -= FinishFade; }
            Check(controlledFades == 1, "Exactly one real fade must finish before its next hold is observed");
            Check(quota.Scheduling.Wakes == 1 && quota.Scheduling.Clocks == 0 && quota.Scheduling.Scheduled,
                "The four-second switch releases both fade clocks and schedules only its next deadline; actual=" + quota.Scheduling);
            Check(Interlocked.Read(ref snapshots) == beforeSnapshots && frames == beforeFrames, "The frozen unchanged engine emits no snapshots or native window frames");
            await Task.Delay(250); long settled = Interlocked.Read(ref renders); await Task.Delay(350);
            Check(Interlocked.Read(ref renders) == settled, "Fade completion leaves no orphan root clock in the render manager; render delta="
                + (Interlocked.Read(ref renders) - settled) + ", quota=" + quota.Scheduling + ", badge=" + badge.RotationScheduling
                + ", window=" + window.AccessibilityMotionState);
            window.Hide(); await Task.Delay(250); var hidden = quota.Scheduling; settled = Interlocked.Read(ref renders);
            await Task.Delay(550);
            Check(!hidden.Scheduled && hidden.Clocks == 0 && quota.Scheduling.Wakes == hidden.Wakes && Interlocked.Read(ref renders) == settled,
                "Hidden quotas have no clocks, timers, or continuing render work");
            window.Show(); await Task.Delay(250); Check(quota.Scheduling.Scheduled, "Showing the island restores the original alternating values; quota="
                + quota.Scheduling + ", visible=" + window.IsVisible + ", occluded=" + window.DecorationsOccluded);
            // A new reading while the values take turns keeps one value in place.
            quota.Update([new AlternatingQuotaText.Item("codex", "41%", false), new AlternatingQuotaText.Item("claude", "62%", false)], true);
            quota.Update([new AlternatingQuotaText.Item("codex", "40%", false), new AlternatingQuotaText.Item("claude", "61%", false)], true);
            var shownValues = quota.Children.OfType<FrameworkElement>().Where(layer => layer.Opacity > 0.01).ToArray();
            Check(shownValues.Length == 1 && shownValues[0].Opacity > 0.99 && quota.ShownTexts.SequenceEqual(["40%", "61%"]),
                "A new reading during the rotation shows one value, never two in one place");
            if (composed)
            {
                badge.Update(header, true); await Task.Delay(150);
                Check(badge.RotationScheduling.Composed, "Showing restores the compositor ring");
                badge.InjectOrbitDeviceLoss(); await Task.Delay(250);
                Check(badge.RotationScheduling.FallbackClock && !badge.RotationScheduling.Composed, "Device loss retains the animated WPF fallback");
                SendMessage(new WindowInteropHelper(window).Handle, 0x031E, IntPtr.Zero, IntPtr.Zero); await Task.Delay(300);
                Check(badge.RotationScheduling.Composed && !badge.RotationScheduling.FallbackClock, "A compositor notification restores the ring without polling");
            }
            Console.WriteLine("PASS idle clocks, deadline-only quota switching, no-op snapshots, hidden scheduling, and composition fallback/recovery");
        }
        finally
        {
            Application.Current.Dispatcher.Hooks.OperationPosted -= posted;
            window.AllowClose = true; window.Close();
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam);
}
