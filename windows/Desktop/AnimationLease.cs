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
    internal bool IsActive => clock != null;
    internal AnimationLease(AnimationTimeline animation, Action<AnimationClock?> apply, Action? completed = null)
    {
        this.apply = apply; this.completed = completed;
        clock = (AnimationClock)animation.CreateClock(true); clock.Completed += Completed; apply(clock);
    }
    private void Completed(object? sender, EventArgs args) { Dispose(); completed?.Invoke(); }
    public void Dispose()
    {
        if (clock == null) return;
        var value = clock; clock = null;
        value.Completed -= Completed; value.Controller?.Stop(); value.Controller?.Remove();
        var remove = apply; apply = null; remove?.Invoke(null);
    }
}
