using System;

namespace CodexPacer.Windows;

internal readonly record struct QuotaAlternationFrame(int Current, int Next, double NextOpacity, double FadeRemaining, double NextFade);
internal static class QuotaAlternationSchedule
{
    internal const double Slot = 4, Fade = .35;
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
