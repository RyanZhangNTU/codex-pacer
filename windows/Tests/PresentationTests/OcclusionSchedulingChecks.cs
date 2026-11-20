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

internal static class OcclusionSchedulingChecks
{
    internal static async Task Run()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        async Task Until(Func<bool> ready, string message)
        {
            var clock = Stopwatch.StartNew();
            while (!ready() && clock.Elapsed.TotalSeconds < 3) await Task.Delay(20);
            Check(ready(), message);
        }
        await using var engine = new EngineClient();
        var window = new IslandWindow(engine, true, false, animationOverride: true) { IsHitTestVisible = false, ShowActivated = false };
        Window? cover = null; long renders = 0;
        DispatcherHookEventHandler posted = (_, args) => { if (args.Operation.Priority == DispatcherPriority.Render) Interlocked.Increment(ref renders); };
        try
        {
            window.ApplyPreferences(new() { IslandAppearance = "classic" }); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.Reveal(); await window.WaitForPresentationAsync(); await Task.Delay(400);
            var quota = (AlternatingQuotaText)window.FindName("QuotaLabel"); var badge = (ActivityBadge)window.FindName("Badge");
            bool composed = badge.RotationScheduling.Composed; ulong sequence = engine.LatestSnapshot!.Sequence;
            Check(!window.DecorationsOccluded && quota.Scheduling.Scheduled, "The uncovered island retains its alternating labels");
            // The reference panel shares a row with Codex's banked resets, whose capsule takes turns too.
            Check(PanelRotations(window) is { Length: > 0 } open && open.All(turns => turns.Scheduling.Scheduled || turns.Scheduling.Clocks > 0),
                "The uncovered panel's reset capsule takes turns");
            var monitor = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(window).Handle).Bounds;
            double scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
            cover = new Window { Owner = window, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowActivated = false, ShowInTaskbar = false,
                Topmost = true, Left = monitor.Left / scale, Top = monitor.Top / scale, Width = monitor.Width / scale, Height = monitor.Height / scale, Background = Brushes.Black };
            WindowRendering.Prepare(cover); cover.Show();
            await Until(() => window.DecorationsOccluded, "A nonactivating fullscreen cover is detected by window events");
            Check(window.IsVisible && window.IsExpandedForAutomation && engine.LatestSnapshot!.Sequence == sequence,
                "Cosmetic suspension keeps logical visibility, expansion and engine business state");
            Check(!quota.Scheduling.Scheduled && quota.Scheduling.Clocks == 0 && !badge.RotationScheduling.Composed && !badge.RotationScheduling.FallbackClock,
                "Full occlusion stops both deadline timers and native/WPF badge animation");
            Check(PanelRotations(window) is { Length: > 0 } covered && covered.All(turns => !turns.Scheduling.Scheduled && turns.Scheduling.Clocks == 0),
                "Full occlusion also stops the panel's reset capsule from taking turns");
            Application.Current.Dispatcher.Hooks.OperationPosted += posted;
            await Task.Delay(350); long before = Interlocked.Read(ref renders), wakes = quota.Scheduling.Wakes;
            await Task.Delay(700);
            Check(Interlocked.Read(ref renders) == before && quota.Scheduling.Wakes == wakes, "A covered island has no continuing WPF render or quota wakeups");
            cover.Close(); cover = null;
            await Until(() => !window.DecorationsOccluded && quota.Scheduling.Scheduled, "Removing the cover resumes the existing four-second alternation");
            await Until(() => PanelRotations(window).All(turns => turns.Scheduling.Scheduled || turns.Scheduling.Clocks > 0), "Removing the cover resumes the reset capsule's turns");
            Check(composed ? badge.RotationScheduling.Composed && !badge.RotationScheduling.FallbackClock : badge.RotationScheduling.FallbackClock,
                "Removing the cover restores the original native or fallback rotation");
            Console.WriteLine("PASS fullscreen occlusion: event-driven cosmetic pause, no idle render/timer work, unchanged engine state and automatic restoration");
        }
        finally { cover?.Close(); Application.Current.Dispatcher.Hooks.OperationPosted -= posted; window.AllowClose = true; window.Close(); }
    }
    /// The panel's own rotations, such as the reset capsule's, which share one clock.
    private static AlternatingQuotaText[] PanelRotations(DependencyObject root)
    {
        var found = new System.Collections.Generic.List<AlternatingQuotaText>(); var pending = new System.Collections.Generic.Stack<DependencyObject>(); pending.Push(root);
        while (pending.Count > 0)
        {
            var node = pending.Pop();
            if (node is AlternatingQuotaText { SharedPhase: true } turns) found.Add(turns);
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++) pending.Push(VisualTreeHelper.GetChild(node, index));
        }
        return found.ToArray();
    }
}
