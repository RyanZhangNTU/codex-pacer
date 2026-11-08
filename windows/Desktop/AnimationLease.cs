using System;
using System.Windows.Media.Animation;

namespace CodexPacer.Windows;

// Removing the property animation alone can leave an unreferenced root clock
// ticking until a GC. Own a controllable clock and remove it from the manager.
internal sealed class AnimationLease : IDisposable
{
    private AnimationClock? clock;
    private Action<AnimationClock?>? apply;
    private readonly Action? completed;
    private Action<AnimationClock>? timeInvalidated;
    internal bool IsActive => clock != null;
    internal TimeSpan? CurrentTime => clock?.CurrentTime;
    internal AnimationLease(AnimationTimeline animation, Action<AnimationClock?> apply, Action? completed = null,
        Action<AnimationClock>? timeInvalidated = null)
    {
        this.apply = apply; this.completed = completed; this.timeInvalidated = timeInvalidated;
        clock = (AnimationClock)animation.CreateClock(true); clock.Completed += Completed;
        if (timeInvalidated != null) clock.CurrentTimeInvalidated += TimeInvalidated;
        apply(clock);
    }
    private void TimeInvalidated(object? sender, EventArgs args) { if (clock != null) timeInvalidated?.Invoke(clock); }
    private void Completed(object? sender, EventArgs args) { Dispose(); completed?.Invoke(); }
    internal void Seek(TimeSpan position) => clock?.Controller?.SeekAlignedToLastTick(position, TimeSeekOrigin.BeginTime);
    public void Dispose()
    {
        if (clock == null) return;
        var value = clock; clock = null;
        value.Completed -= Completed; value.CurrentTimeInvalidated -= TimeInvalidated; timeInvalidated = null;
        value.Controller?.Stop(); value.Controller?.Remove();
        var remove = apply; apply = null; remove?.Invoke(null);
    }
}
