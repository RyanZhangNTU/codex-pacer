using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using CodexPacer.Windows;

internal static class DisplayWindowChecks
{
    internal static async Task Run(string output)
    {
        using var native = new WindowsDisplayTopology(action => Application.Current.Dispatcher.BeginInvoke(action));
        var main = native.Current.First(value => value.Primary);
        var measured = new List<object>();
        foreach (string appearance in new[] { "classic", "liquidGlass" })
        {
            await using var engine = new EngineClient();
            var window = new IslandWindow(engine, true, false, animationOverride: true) { ShowActivated = false };
            try
            {
                var preference = new DesktopPreferences { IslandAppearance = appearance, DisplayMode = "floating" };
                window.ApplyPreferences(preference); window.Show();
                await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
                window.Reveal(); await window.WaitForPresentationAsync();
                ulong sequence = engine.LatestSnapshot!.Sequence;
                await using var fixture = await Fixture.Start();
                await Until(() => window.FullscreenSuppressed && !window.IsVisible, "Fullscreen-off must hide the island");
                Check(Surfaces(window).All(value => !IsWindowVisible(value)), "Fullscreen-off hides every native decoration");
                await Task.Delay(600);
                Check(!window.IsVisible && window.IsExpandedForAutomation && engine.LatestSnapshot!.Sequence == sequence,
                    "Detection continues while hidden without flashing, collapsing or reconfiguring the engine");
                window.ApplyPreferences(preference with { ShowInFullscreen = true });
                await Until(() => window.IsVisible && Above(window, fixture.Handle), "Fullscreen-on must lift all island surfaces above the application");
                Check(!window.FullscreenRaiseFailed && !window.IsActive && GetForegroundWindow() != new WindowInteropHelper(window).Handle,
                    "Raising never activates the island");
                var visible = window.VisibleScreenBounds;
                Check(WindowFromPoint(new((int)(visible.X + visible.Width / 2), (int)(visible.Y + visible.Height / 2))) == new WindowInteropHelper(window).Handle,
                    "The visible island retains its input surface");
                Check(WindowFromPoint(new((int)visible.Right + 8, (int)visible.Top + 6)) == fixture.Handle, "Outside the island still hits the synthetic fullscreen app");
                await fixture.Send("show");
                await Until(() => Above(window, fixture.Handle), "A later fullscreen raise restores the configured island order");
                window.ApplyPreferences(preference);
                await Until(() => !window.IsVisible, "Turning the option off hides an already visible island");
                await fixture.Send("minimize");
                await Until(() => window.IsVisible, "Minimizing fullscreen restores the island");
                await fixture.Send("show"); await Until(() => !window.IsVisible, "Restoring fullscreen reapplies the saved off policy");
                window.Close(); // A user close while policy-hidden must stay hidden.
                await fixture.Send("hide"); await Task.Delay(600);
                Check(!window.IsVisible, "Fullscreen exit cannot resurrect a manually closed island");
                window.Reveal(); await Until(() => window.IsVisible, "An explicit reveal restores requested visibility");
                Check(!window.IsActive, "Fullscreen exit and explicit restoration keep nonactivation");
                measured.Add(new { appearance, scale = VisualTreeHelper.GetDpi(window).DpiScaleX, hideRestore = true, aboveAllSurfaces = true, outsideHit = true, activated = false });
            }
            finally { window.AllowClose = true; window.Close(); }
        }
        await CheckTopology(main);
        await CheckExpansionAnchor();
        File.WriteAllText(Path.Combine(output, "display-acceptance.json"), JsonSerializer.Serialize(new
        { syntheticOnly = true, physicalMonitorCount = native.Current.Count, fullscreen = "borderless", styles = measured, injectedTopology = true, windowsClosed = true }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine("PASS display windows: target topology, disconnect/reconnect, fullscreen off/on, all-surface order, nonactivation, outside hit and restoration");
    }

    internal static async Task CheckExpansionAnchor()
    {
        var work = new MotionBounds(0, 0, 960, 700);
        foreach (var edge in new[] { IslandEdge.Free, IslandEdge.Left, IslandEdge.Right })
        {
            await using var engine = new EngineClient();
            var window = new IslandWindow(engine, true, false, animationOverride: true, screenGeometry: () => (work, work))
                { ShowActivated = false, IsHitTestVisible = false };
            try
            {
                window.ApplyPreferences(new DesktopPreferences
                {
                    IslandAppearance = "classic", DisplayMode = "floating", IslandPlacement = new(edge, .5, .7)
                });
                window.ReceiveSnapshot(Snapshot(1, 3));
                window.Show();
                window.Reveal();
                await window.WaitForPresentationAsync();
                var tall = window.LogicalTarget;
                var frames = new List<MotionBounds>();
                window.FrameApplied += frame => frames.Add(frame.Window);

                window.ReceiveSnapshot(Snapshot(2, 0));
                await window.WaitForPresentationAsync();
                var shortPanel = window.LogicalTarget;
                double bottom = tall.Y + tall.Height;
                Check(shortPanel.Height < tall.Height && Math.Abs(shortPanel.Y + shortPanel.Height - bottom) <= 1
                    && frames.All(frame => Math.Abs(frame.Y + frame.Height - bottom) <= 1),
                    $"The {edge} island must keep its bottom anchor when an upward panel loses rows ({bottom} to {shortPanel.Y + shortPanel.Height})");

                window.CollapseForAutomation();
                await window.WaitForPresentationAsync();
                window.Reveal();
                double top = window.LogicalTarget.Y;
                frames.Clear();
                window.ReceiveSnapshot(Snapshot(3, 3));
                await window.WaitForPresentationAsync();
                var grown = window.LogicalTarget;
                Check(Math.Abs(grown.Height - tall.Height) <= 1 && grown.Y + grown.Height <= work.Height
                    && grown.Y <= top + 1 && frames.All(frame => frame.Y <= top + 1)
                    && ((ScrollViewer)window.FindName("ExpandedScroll")).ScrollableHeight <= 1,
                    $"The {edge} island must fit every row when more tasks arrive during a downward expansion");

                frames.Clear();
                window.ReceiveSnapshot(Snapshot(4, 0));
                await window.WaitForPresentationAsync();
                Check(Math.Abs(window.LogicalTarget.Y - grown.Y) <= 1 && frames.All(frame => Math.Abs(frame.Y - grown.Y) <= 1),
                    $"The {edge} island must stay where it moved to fit when the rows disappear again");
            }
            finally { window.AllowClose = true; window.Close(); }
        }
        Console.WriteLine("PASS expansion anchors: free, left and right placements fit the full panel without dropping as task rows change");

        static EngineSnapshot Snapshot(ulong sequence, int count)
        {
            var rows = Enumerable.Range(1, count).Select(index => new EngineTaskRow(
                $"qa-{index}", "codex", $"Demo task {index}", "Thinking", null, null, null, "running",
                "sparkle", null, "Demo", null, null, false, null, null, 0, false, false, false, null, false)).ToArray();
            var header = new EngineHeader(count, null, new Dictionary<string, int>(), null, null, null, false);
            return new(1, "snapshot", sequence, true, 0, [], [], [], [], [], count, 0, null, false,
                Presentation: new(rows, 3, 3, 1, header));
        }
    }
    private static async Task CheckTopology(DisplayMonitor physical)
    {
        int middle = physical.Bounds.Left + (physical.Bounds.Right - physical.Bounds.Left) / 2;
        ScreenRectangle Work(ScreenRectangle bounds) => new(Math.Max(bounds.Left, physical.Work.Left), Math.Max(bounds.Top, physical.Work.Top), Math.Min(bounds.Right, physical.Work.Right), Math.Min(bounds.Bottom, physical.Work.Bottom));
        var lb = physical.Bounds with { Right = middle }; var rb = physical.Bounds with { Left = middle };
        var left = new DisplayMonitor(physical.Handle, "qa-left", "QA Left", "QA1", lb, Work(lb), true);
        var right = new DisplayMonitor(physical.Handle, "qa-right", "QA Right", "QA2", rb, Work(rb), false);
        var topology = new MutableDisplayTopology(left, right);
        await using var engine = new EngineClient();
        var window = new IslandWindow(engine, true, false, animationOverride: false, displayTopologyFactory: () => topology) { IsHitTestVisible = false, ShowActivated = false };
        try
        {
            var preference = right.Choose(new() { IslandAppearance = "classic", DisplayMode = "floating" });
            window.ApplyPreferences(preference); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.Reveal(); await window.WaitForPresentationAsync(); CheckLocation(right);
            preference = preference with { IslandPlacement = new(IslandEdge.Bottom, .65, 1) };
            window.ApplyPreferences(preference);
            await window.WaitForPresentationAsync(); CheckLocation(right);
            topology.Set(left); await window.WaitForPresentationAsync();
            Check(window.SelectedDisplay.FellBack, "Disconnect reports a temporary fallback"); CheckLocation(left);
            topology.Set(left, right); await window.WaitForPresentationAsync();
            Check(!window.SelectedDisplay.FellBack && window.SelectedDisplay.Display?.DevicePath == preference.DisplayID, "Reconnect restores the retained identity"); CheckLocation(right);
            var smallerBounds = rb with { Right = rb.Right - (rb.Right - rb.Left) / 4 };
            var resized = right with { Bounds = smallerBounds, Work = Work(smallerBounds) };
            topology.Set(left, resized); await window.WaitForPresentationAsync(); CheckLocation(resized);
            topology.Set(left, right);
            await using var fixture = await Fixture.Start(); await fixture.Bounds(lb);
            await Task.Delay(600);
            Check(window.IsVisible, "Fullscreen on a different injected monitor cannot hide the island");
            window.ApplyPreferences(left.Choose(preference));
            await Until(() => !window.IsVisible, "Switching to the fullscreen target applies the off policy");
            window.ApplyPreferences(right.Choose(preference));
            await Until(() => window.IsVisible, "Switching away restores the island on its new target");
            await window.WaitForPresentationAsync(); CheckLocation(right);
            Check(!window.IsActive, "Topology changes never activate the island");
            void CheckLocation(DisplayMonitor expected)
            {
                var visible = window.VisibleScreenBounds;
                Check(visible.X >= expected.Bounds.Left - 2 && visible.Right <= expected.Bounds.Right + 2 && visible.Y >= expected.Bounds.Top - 2 && visible.Bottom <= expected.Bounds.Bottom + 2,
                    "The actual visible window follows the injected monitor and work area");
                if (preference.IslandPlacement != null)
                    Check(Math.Abs(visible.Bottom - expected.Work.Bottom) <= 2, "The saved bottom edge follows the fallback and reconnected work areas");
                Check(GetWindowRect(new WindowInteropHelper(window).Handle, out var canvas) && canvas.Right - canvas.Left <= expected.Bounds.Right - expected.Bounds.Left + 2,
                    "A display switch does not retain a canvas spanning two monitors");
            }
        }
        finally { window.AllowClose = true; window.Close(); }
        Check(topology.Disposed, "Closing releases the display source");
    }
    private static IntPtr[] Surfaces(IslandWindow window) => [new WindowInteropHelper(window).Handle, window.BackdropWindowHandle,
        ((ActivityBadge)window.FindName("Badge")).RotationScheduling.Window, ((ActivityBadge)window.FindName("StripBadge")).RotationScheduling.Window];
    private static bool Above(IslandWindow window, IntPtr fixture)
    {
        bool seen = false, valid = true; var surfaces = Surfaces(window);
        EnumWindows((hwnd, _) => { if (hwnd == fixture) seen = true; if (seen && surfaces.Contains(hwnd) && IsWindowVisible(hwnd)) valid = false; return true; }, IntPtr.Zero);
        return seen && valid;
    }
    private static async Task Until(Func<bool> ready, string message)
    { var clock = Stopwatch.StartNew(); while (!ready() && clock.Elapsed.TotalSeconds < PresentationWait.Limit.TotalSeconds) await Task.Delay(20); Check(ready(), message); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Fixture : IAsyncDisposable
    {
        private readonly OwnedJob job = new();
        private readonly Process process = new();
        private Task? drain;
        internal IntPtr Handle;
        internal static async Task<Fixture> Start()
        {
            var value = new Fixture();
            try
            {
                value.process.StartInfo = new(Path.Combine(AppContext.BaseDirectory, "Pacer.PresentationTests.exe"))
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
                value.process.StartInfo.ArgumentList.Add("--fullscreen-fixture");
                value.process.Start(); value.job.Attach(value.process);
                value.drain = value.process.StandardError.BaseStream.CopyToAsync(Stream.Null);
                using var data = await value.Read();
                Check(data.RootElement.GetProperty("type").GetString() == "ready", "Fullscreen fixture must initialize");
                value.Handle = new(data.RootElement.GetProperty("handle").GetInt64()); return value;
            }
            catch { await value.DisposeAsync(); throw; }
        }
        private async Task<JsonDocument> Read()
        {
            string? line = await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10));
            if (line == null || line.Length > 2048) throw new InvalidOperationException("Fullscreen fixture ended without a bounded reply");
            return JsonDocument.Parse(line);
        }
        internal async Task Send(string command) => await Command(new { command });
        internal async Task Bounds(ScreenRectangle value) => await Command(new { command = "bounds", left = value.Left, top = value.Top, right = value.Right, bottom = value.Bottom });
        private async Task Command(object command)
        { await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(command)); using var reply = await Read(); Check(reply.RootElement.GetProperty("type").GetString() == "ack", "Fullscreen fixture must acknowledge commands"); }
        public async ValueTask DisposeAsync()
        {
            try
            {
                if (!process.HasExited) { await process.StandardInput.WriteLineAsync("{\"command\":\"quit\"}"); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3)); }
            }
            catch (Exception error) when (error is InvalidOperationException or IOException or TimeoutException) { }
            finally { job.Dispose(); process.Dispose(); }
            if (drain != null)
                try { await drain; } catch (Exception error) when (error is IOException or ObjectDisposedException) { }
        }
    }
    [StructLayout(LayoutKind.Sequential)] private readonly record struct Point(int X, int Y);
    private delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hwnd, out ScreenRectangle rectangle);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
}
