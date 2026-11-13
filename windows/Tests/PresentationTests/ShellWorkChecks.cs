using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;
using Microsoft.Win32;

/// The shell's work while nothing changes on screen: the surface a settled
/// island keeps, a hidden panel that waits for its opening, snapshot bursts
/// that render once, and decorations that stop while nobody can see them.
internal static class ShellWorkChecks
{
    internal static async Task Run(bool motion)
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        CheckFittedSurface();
        await using var engine = new EngineClient();
        using var presence = new DisplayPresence(observe: false);
        var window = new IslandWindow(engine, true, false, animationOverride: motion,
            screenGeometry: () => (new(0, 0, 2560, 1440), new(0, 0, 2560, 1400)), presence: presence) { IsHitTestVisible = false, ShowActivated = false };
        var deliveries = new List<ulong>();
        engine.Snapshot += value => deliveries.Add(value.Sequence);
        string scenario = motion ? "motion" : "reduced";
        try
        {
            window.ApplyPreferences(new() { IslandAppearance = "classic" }); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot != null && window.RenderedSequence == engine.LatestSnapshot.Sequence,
                "The island must render the first reference snapshot");
            await window.WaitForPresentationAsync();

            // A settled island gives back the spring's canvas at the right and
            // bottom edges and keeps its origin: a moved layered window shows
            // its previous bitmap at the new place, and the shell, glass and
            // shoulders jump apart for a frame.
            NativeRect Native() => GetWindowRect(new WindowInteropHelper(window).Handle, out var native) ? native : default;
            bool Fits()
            {
                double scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
                var native = Native(); var surface = window.SurfaceBounds; var target = window.LogicalTarget;
                return surface.X <= target.X + 0.5 && surface.Y <= target.Y + 0.5
                    && Math.Abs(surface.X + surface.Width - target.X - target.Width) < 1 && Math.Abs(surface.Y + surface.Height - target.Y - target.Height) < 1
                    && Math.Abs((native.Right - native.Left) / scale - surface.Width) < 2 && Math.Abs((native.Bottom - native.Top) / scale - surface.Height) < 2;
            }
            window.Reveal(); await window.WaitForPresentationAsync(); await Pump();
            Check(window.IsExpandedForAutomation && window.LogicalTarget.Height > 100 && Fits(),
                $"An open island must settle on the panel's far edges ({scenario}): surface={window.SurfaceBounds}, target={window.LogicalTarget}, actual={window.ActualWidth}x{window.ActualHeight}");
            var badge = (ActivityBadge)window.FindName("Badge");
            Check(badge.LoopFrameRate == ActivityBadge.OpenFrameRate, "The badge's loops run at full rate while the panel is open");
            var opened = Native();
            window.CollapseForAutomation(); await window.WaitForPresentationAsync(); await Pump();
            var closed = Native();
            Check(!window.IsExpandedForAutomation && window.LogicalTarget.Height < 100 && window.SurfaceBounds.Height < 100 && Fits()
                && closed.Left == opened.Left && closed.Top == opened.Top,
                $"A collapsed island must give back the panel's height without moving its origin ({scenario}): surface={window.SurfaceBounds}, target={window.LogicalTarget}, origin {opened.Left},{opened.Top} -> {closed.Left},{closed.Top}");
            window.Reveal(); await window.WaitForPresentationAsync(); await Pump();
            Check(Native() is var reopened && reopened.Left == opened.Left && reopened.Top == opened.Top && Fits(),
                $"Reopening must grow the far edges in place ({scenario}): surface={window.SurfaceBounds}, target={window.LogicalTarget}");
            window.CollapseForAutomation(); await window.WaitForPresentationAsync(); await Pump();
            Check(badge.LoopFrameRate == ActivityBadge.CollapsedFrameRate, "The badge's loops slow down while only the bar shows");

            // A collapsed island builds and measures nothing of its panel; the
            // next opening builds it once from the newest snapshot.
            int builds = window.PanelBuilds, measures = window.PanelMeasures;
            foreach (int stage in new[] { 1, 2 })
            {
                await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = stage });
                await PresentationWait.UntilAsync(() => window.RenderedSequence == engine.LatestSnapshot!.Sequence, "The collapsed bar must still render each snapshot");
            }
            await window.WaitForPresentationAsync();
            Check(window.PanelBuilds == builds && window.PanelMeasures == measures && window.PanelDirty,
                $"Snapshots must not rebuild or measure a collapsed panel (builds {builds}->{window.PanelBuilds}, measures {measures}->{window.PanelMeasures})");
            window.Reveal(); await window.WaitForPresentationAsync(); await Pump();
            var latest = engine.LatestSnapshot!.Presentation!;
            string[] expected = latest.Rows.Take(latest.PageSize).Select(row => row.Id).ToArray();
            string[] shown = Descendants<TaskRow>(window).Select(row => ((TaskRowState)row.DataContext).Value.Id).ToArray();
            Check(!window.PanelDirty && window.PanelBuilds > builds && window.PanelMeasures > measures && shown.SequenceEqual(expected) && Fits(),
                $"Opening must build the skipped panel once from the newest snapshot: rows={string.Join(",", shown)}, expected={string.Join(",", expected)}");

            // While open, unchanged readings keep their views and the same tasks
            // take new values in place; nothing is measured for an unchanged snapshot.
            var current = engine.LatestSnapshot!;
            var rowsBefore = Descendants<TaskRow>(window).ToArray();
            var dialsBefore = Descendants<QuotaDial>(window).ToArray();
            int measured = window.PanelMeasures;
            window.ReceiveSnapshot(current); await Pump();
            Check(Descendants<TaskRow>(window).SequenceEqual(rowsBefore) && Descendants<QuotaDial>(window).SequenceEqual(dialsBefore) && window.PanelMeasures == measured,
                "A repeated snapshot must keep every row and dial and measure nothing");
            var ticked = current.Presentation!.Rows.Select(row => row with { TurnTime = "59:59", RateText = "987" }).ToArray();
            window.ReceiveSnapshot(current with { Presentation = current.Presentation with { Rows = ticked } }); await Pump();
            var rowsAfter = Descendants<TaskRow>(window).ToArray();
            Check(rowsBefore.Length > 0 && rowsAfter.SequenceEqual(rowsBefore) && rowsAfter.All(row => ((TaskRowState)row.DataContext).Value.TurnTime == "59:59")
                && Descendants<QuotaDial>(window).SequenceEqual(dialsBefore), "A new rate or turn time must update the same rows in place");
            window.ReceiveSnapshot(current); await window.WaitForPresentationAsync();

            // A burst renders once, with the newest snapshot, while every
            // snapshot still reaches the engine's other subscribers.
            window.CollapseForAutomation(); await window.WaitForPresentationAsync();
            int seen = deliveries.Count, renders = window.SnapshotRenders;
            using (var released = new ManualResetEventSlim())
            {
                var burst = Task.Run(async () =>
                {
                    try
                    {
                        foreach (int stage in new[] { 0, 1, 2 })
                        {
                            ulong before = engine.LatestSnapshot!.Sequence;
                            await engine.SendAsync("demoStage", new { demoStage = stage });
                            var deadline = DateTime.UtcNow + PresentationWait.Limit;
                            while (engine.LatestSnapshot!.Sequence <= before && DateTime.UtcNow < deadline) await Task.Delay(20);
                        }
                    }
                    finally { released.Set(); }
                });
                // The dispatcher is held while the engine publishes, as a busy UI thread would be.
                Check(released.Wait(PresentationWait.Limit + PresentationWait.Limit), "The burst must finish while the dispatcher is held");
                await burst;
            }
            ulong last = engine.LatestSnapshot!.Sequence;
            await PresentationWait.UntilAsync(() => deliveries.LastOrDefault() == last && window.RenderedSequence == last, "The burst must reach every subscriber and the window");
            var burstSequences = deliveries.Skip(seen).ToArray();
            int burstRenders = window.SnapshotRenders - renders;
            Check(burstSequences.Length >= 3 && burstSequences.Zip(burstSequences.Skip(1)).All(pair => pair.Second > pair.First),
                $"Every snapshot of a burst must reach the engine's subscribers in order: {string.Join(",", burstSequences)}");
            Check(burstRenders >= 1 && burstRenders < burstSequences.Length,
                $"A burst must render fewer times than it publishes: renders={burstRenders}, snapshots={burstSequences.Length}");

            // A locked session or a dark display stops every decoration, and
            // they come back when someone can see the desktop again.
            var quota = (AlternatingQuotaText)window.FindName("QuotaLabel");
            bool Moving() => quota.Scheduling.Scheduled || badge.RotationScheduling.Composed || badge.RotationScheduling.FallbackClock
                || badge.EstimateLoops.Length > 0 || badge.SegmentBreathing;
            if (motion)
            {
                await PresentationWait.UntilAsync(Moving, "The visible reference island must run its decorations");
                foreach (var (leave, back, name) in new (Action, Action, string)[]
                {
                    (() => presence.Apply(SessionSwitchReason.SessionLock), () => presence.Apply(SessionSwitchReason.SessionUnlock), "lock"),
                    (() => presence.ApplyDisplayState(0), () => presence.ApplyDisplayState(1), "display off"),
                    (() => presence.Apply(SessionSwitchReason.RemoteDisconnect), () => presence.Apply(SessionSwitchReason.RemoteConnect), "disconnect"),
                })
                {
                    leave();
                    Check(!presence.Present, "The presence must end on " + name);
                    await PresentationWait.UntilAsync(() => !Moving(), "Decorations must stop on " + name);
                    back();
                    await PresentationWait.UntilAsync(() => presence.Present && Moving(), "Decorations must resume after " + name);
                }
                presence.ApplyDisplayState(2); await Pump();
                Check(presence.Present && Moving(), "A dimmed display is still seen");
            }
            Console.WriteLine("PASS shell work " + scenario + ": settled surface, deferred hidden panel, coalesced bursts and presence");
        }
        finally { window.StopPresentation(); window.AllowClose = true; window.Close(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { internal int Left, Top, Right, Bottom; }
    /// The rule behind the settled surface, apart from any window.
    internal static void CheckFittedSurface()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        var canvas = new MotionBounds(1078, 0, 404, 460);
        Check(IslandWindow.FittedSurface(canvas, new(1195, 0, 170, 36)) == new MotionBounds(1078, 0, 287, 36),
            "Closing keeps the canvas origin and trims the right and bottom edges");
        Check(IslandWindow.FittedSurface(canvas, new(1078, 0, 404, 438)) == new MotionBounds(1078, 0, 404, 438),
            "Opening trims only the spring's extra bottom");
        Check(IslandWindow.FittedSurface(new(1195, 0, 170, 36), new(1078, 0, 404, 438)) == new MotionBounds(1078, 0, 404, 438),
            "An outline left of the surface moves the origin to include it");
        Check(IslandWindow.FittedSurface(new(1078, 400, 404, 460), new(1195, 824, 170, 36)) == new MotionBounds(1078, 400, 287, 460),
            "A panel that opened upward keeps its top and gives back only the right edge");
    }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out NativeRect rectangle);
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T typed) yield return typed;
            foreach (T nested in Descendants<T>(child)) yield return nested;
        }
    }
}
