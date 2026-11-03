using System;

namespace CodexPacer.Windows;

// Keep one trailing refresh at the next allowed deadline. New events do not
// postpone that deadline, so a continuous event stream cannot starve refresh.
internal sealed class TrailingRefreshThrottle : IDisposable
{
    internal static readonly TimeSpan MinimumInterval = TimeSpan.FromMilliseconds(250);
    private readonly Func<TimeSpan> now;
    private readonly Action<TimeSpan> arm;
    private readonly Action cancel, refresh;
    private TimeSpan? last;
    private bool pending, disposed;
    internal TrailingRefreshThrottle(Func<TimeSpan> now, Action<TimeSpan> arm, Action cancel, Action refresh)
    { this.now = now; this.arm = arm; this.cancel = cancel; this.refresh = refresh; }

    internal void Request()
    {
        if (disposed || pending) return;
        TimeSpan delay = last is { } previous ? previous + MinimumInterval - now() : TimeSpan.Zero;
        pending = true;
        arm(delay > TimeSpan.Zero ? delay : TimeSpan.Zero);
    }
    internal void Fire()
    {
        if (disposed || !pending) return;
        TimeSpan current = now();
        if (last is { } previous && current < previous + MinimumInterval)
        { arm(previous + MinimumInterval - current); return; }
        pending = false; last = current;
        refresh();
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; pending = false; cancel();
    }
}
