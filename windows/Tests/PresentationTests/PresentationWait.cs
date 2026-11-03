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

    internal static async Task CommandSnapshotAsync(EngineClient engine, string method, object parameters)
    {
        ulong before = engine.LatestSnapshot?.Sequence ?? 0;
        await engine.SendAsync(method, parameters);
        await UntilAsync(() => engine.LatestSnapshot?.Sequence > before,
            "The engine command must publish its snapshot: " + method);
    }
}
