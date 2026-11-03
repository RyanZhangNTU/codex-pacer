using CodexPacer.Windows;

internal static class OcclusionRefreshChecks
{
    internal static void Run()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        TimeSpan now = TimeSpan.Zero;
        TimeSpan? due = null;
        var refreshes = new List<TimeSpan>();
        var monitor = new ScreenRectangle(0, 0, 1920, 1080);
        var island = new ScreenRectangle(600, 0, 1320, 660);
        ScreenRectangle latestWindow = default;
        bool observedCovered = false;
        int arms = 0, cancels = 0;
        using var throttle = new TrailingRefreshThrottle(() => now, delay =>
        {
            Check(due == null, "Only one refresh callback may be pending");
            arms++; due = now + delay;
        }, () => { cancels++; due = null; }, () =>
        {
            refreshes.Add(now);
            observedCovered = FullscreenOcclusionPolicy.Covers(latestWindow, monitor, island, true, true, false, false, false, true);
        });
        void Advance(TimeSpan until)
        {
            while (due is { } next && next <= until)
            {
                now = next; due = null; throttle.Fire();
            }
            now = until;
        }
        for (int index = 0; index < 100; index++)
        {
            Advance(TimeSpan.FromMilliseconds(index * 10));
            latestWindow = index == 99 ? monitor : default;
            throttle.Request(); // Same entry used by native location events.
        }
        Check(!observedCovered && due == TimeSpan.FromSeconds(1), "The last location event retains a trailing refresh");
        Advance(TimeSpan.FromSeconds(1));
        Check(refreshes.Count <= 5, "One hundred location events in one second produce at most five refreshes");
        Check(refreshes.Count == 5 && arms == 5, "Continuous events make progress without duplicate queued work");
        Check(refreshes.Zip(refreshes.Skip(1)).All(pair => pair.Second - pair.First >= TrailingRefreshThrottle.MinimumInterval),
            "Consecutive refreshes stay at least 250 ms apart");
        Check(observedCovered && due == null, "The final occlusion result includes the last event and leaves no idle timer");
        Advance(TimeSpan.FromSeconds(10));
        Check(refreshes.Count == 5, "Silence never starts a polling refresh");
        latestWindow = default; throttle.Request();
        Check(due == now, "A new event after a quiet interval does not wait another full interval");
        Advance(now);
        Check(!observedCovered && refreshes.Count == 6, "The first event after silence restores the latest state");
        throttle.Request();
        Check(due == now + TrailingRefreshThrottle.MinimumInterval, "A second immediate event retains one trailing deadline");
        throttle.Dispose(); throttle.Fire(); throttle.Request();
        Check(cancels == 1 && due == null && refreshes.Count == 6, "Disposal cancels pending work and rejects late callbacks and events");

        TimeSpan earlyNow = TimeSpan.Zero, armedDelay = TimeSpan.Zero;
        int earlyRefreshes = 0;
        using var early = new TrailingRefreshThrottle(() => earlyNow, delay => armedDelay = delay, () => { }, () => earlyRefreshes++);
        early.Request(); early.Fire();
        earlyNow = TimeSpan.FromMilliseconds(100); early.Request();
        Check(armedDelay == TimeSpan.FromMilliseconds(150), "The deadline uses elapsed time rather than another full interval");
        earlyNow = TimeSpan.FromMilliseconds(249); early.Fire();
        Check(earlyRefreshes == 1 && armedDelay == TimeSpan.FromMilliseconds(1), "An early timer cannot bypass the minimum interval");
        earlyNow = TimeSpan.FromMilliseconds(250); early.Fire();
        Check(earlyRefreshes == 2, "The remaining deadline still runs the trailing refresh");
    }
}
