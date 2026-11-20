using System;
using System.Diagnostics;
using System.Threading.Tasks;
using CodexPacer.Windows;

/// The collapsed bar's status words after they slide in: a finished slide and
/// an interrupted one both leave the words at their resting place, opaque and
/// alone, so Chinese or Latin status text keeps the bar's center line.
internal static class CompactStatusMotionChecks
{
    internal static async Task Run()
    {
        var status = new CompactStatusText();
        string idle = "空闲", working = "工作中";
        status.Update(idle, null, 108, 12.5, animations: true);
        Check(!status.Sliding && status.Offset == 0 && status.ShownOpacity == 1 && status.Lines == 1, "The first status words appear in place");

        // A change after the settled moment slides in and comes to rest.
        await Task.Delay(CompactStatusText.Settle + TimeSpan.FromMilliseconds(150));
        status.Update(working, null, 108, 12.5, animations: true);
        Check(status.Sliding && status.Lines == 2, "A settled change slides the new words in over the old ones");
        var watch = Stopwatch.StartNew();
        while (status.Sliding && watch.Elapsed < PresentationWait.Limit) await Task.Delay(20);
        Check(!status.Sliding && status.Offset == 0 && status.ShownOpacity == 1 && status.Lines == 1 && status.Text == working,
            $"A finished slide rests at the bar's center line (offset {status.Offset}, opacity {status.ShownOpacity}, lines {status.Lines})");

        // Unloading mid-slide, as a re-parented bar does, ends the slide at rest.
        await Task.Delay(CompactStatusText.Settle + TimeSpan.FromMilliseconds(150));
        status.Update(idle, "attention", 108, 12.5, animations: true);
        Check(status.Sliding, "A second settled change slides too");
        status.Rest();
        Check(!status.Sliding && status.Offset == 0 && status.ShownOpacity == 1 && status.Lines == 1 && status.Text == idle,
            $"An interrupted slide rests in place (offset {status.Offset}, opacity {status.ShownOpacity}, lines {status.Lines})");
        Console.WriteLine("PASS collapsed status motion: settled slide, finished and interrupted slides rest at the center line");
    }

    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
