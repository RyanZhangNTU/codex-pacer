using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class PresentationWait
{
    // A wait for something to happen costs time only when it never happens, and
    // hosted runners are slower than a desktop, so these waits share one generous
    // limit. A check that bounds how long something may take keeps its own.
    internal static readonly TimeSpan Limit = TimeSpan.FromSeconds(30);

    // A WebView2 browser keeps its profile open until its processes exit. Wait for
    // the fixture profile to go, so the next browser check never starts while the
    // last one's browser is still shutting down. This runs in finally blocks, so it
    // reports a profile it could not remove instead of hiding the check's own error.
    internal static async Task RemoveBrowserFixtureAsync(string target)
    {
        var clock = Stopwatch.StartNew();
        while (Directory.Exists(target))
        {
            try { Directory.Delete(target, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (clock.Elapsed >= Limit)
                {
                    Console.Error.WriteLine($"A fixture browser kept its profile open for {Limit.TotalSeconds:0} s; {WebViewProcesses()} WebView2 processes are running.");
                    return;
                }
                await Task.Delay(100);
            }
        }
    }

    internal static int WebViewProcesses()
    {
        var processes = Process.GetProcessesByName("msedgewebview2");
        foreach (var process in processes) process.Dispose();
        return processes.Length;
    }

    internal static async Task UntilAsync(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew();
        while (!condition() && clock.Elapsed < Limit) await Task.Delay(20);
        if (!condition()) throw new TimeoutException(message);
        // EngineClient publishes snapshots before IslandWindow queues its render.
        // Drain both callbacks before inspecting the resulting visual tree.
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }

    internal static async Task CommandSnapshotAsync(EngineClient engine, string method, object parameters, bool waitForSnapshot = true)
    {
        ulong before = engine.LatestSnapshot?.Sequence ?? 0;
        await engine.SendAsync(method, parameters);
        if (!waitForSnapshot)
        {
            // Known unchanged demo/configuration inputs acknowledge normally
            // while the engine suppresses their duplicate wire projection.
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            return;
        }
        await UntilAsync(() => engine.LatestSnapshot?.Sequence > before,
            "The engine command must publish its snapshot: " + method);
    }
}
