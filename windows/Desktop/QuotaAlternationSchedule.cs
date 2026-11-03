using System;

namespace CodexPacer.Windows;

internal readonly record struct QuotaAlternationFrame(int Current, int Next, double NextOpacity, double FadeRemaining, double NextFade);
internal readonly record struct QuotaAlternationStep(QuotaAlternationFrame Frame, double WaitBeforeFade, double NextWakeAfter, long Slot, double EndsAt);
internal static class QuotaAlternationSchedule
{
    internal const double Slot = 4, Fade = .35;
    // Dispatcher and animation clocks can reach a scheduled boundary before
    // Stopwatch does. Honor that boundary without another timer wake or fade.
    internal static QuotaAlternationStep AtDeadline(double elapsed, int count, double reached = 0)
    {
        if (!double.IsFinite(reached) || reached < 0) throw new ArgumentOutOfRangeException(nameof(reached));
        var actual = At(elapsed, count);
        double effective = Math.Max(elapsed, reached);
        var frame = reached > elapsed ? At(effective, count) : actual;
        long slot = (long)Math.Floor(effective / Slot);
        return new(frame, frame.FadeRemaining > 0 ? Math.Max(0, reached - elapsed) : 0,
            Math.Max(.001, frame.NextFade - elapsed), slot, (slot + 1) * Slot);
    }
    internal static QuotaAlternationFrame At(double elapsed, int count)
    {
        if (!double.IsFinite(elapsed) || elapsed < 0 || count < 1) throw new ArgumentOutOfRangeException(nameof(elapsed));
        if (count == 1) return new(0, 0, 0, 0, double.PositiveInfinity);
        double slot = Math.Floor(elapsed / Slot), position = elapsed - slot * Slot;
        int current = (int)(slot % count), next = (current + 1) % count;
        double remaining = Slot - position;
        bool fading = remaining <= Fade + 1e-10;
        double progress = fading ? Math.Clamp(1 - remaining / Fade, 0, 1) : 0;
        return new(current, next, progress, fading ? Math.Min(Fade, remaining) : 0, (slot + 1) * Slot - Fade);
    }
}
