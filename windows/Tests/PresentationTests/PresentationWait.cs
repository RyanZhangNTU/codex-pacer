using System;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class PresentationWait
{
    internal static async Task UntilAsync(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew();
        while (!condition() && clock.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(20);
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
