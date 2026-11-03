using CodexPacer.Windows;

internal static class QuotaScheduleChecks
{
    internal static void Run()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        bool Near(double left, double right) => Math.Abs(left - right) < 1e-9;
        foreach (int count in new[] { 2, 3 })
        {
            for (int slot = 0; slot < count * 3; slot++)
            {
                double start = slot * 4;
                var hold = QuotaAlternationSchedule.At(start, count);
                Check(hold.Current == slot % count && hold.Next == (slot + 1) % count, "Provider order and full-cycle wrap");
                Check(hold.NextOpacity == 0 && hold.FadeRemaining == 0 && Near(hold.NextFade, start + 3.65), "Hold has one future deadline and no animation");
                Check(QuotaAlternationSchedule.At(start + 3.649, count).FadeRemaining == 0, "No fade before the original boundary");
                var fade = QuotaAlternationSchedule.At(start + 3.65, count);
                Check(Near(fade.NextOpacity, 0) && Near(fade.FadeRemaining, .35), "350 ms fade begins at 3.65 seconds");
                var late = QuotaAlternationSchedule.At(start + 3.825, count);
                Check(Near(late.NextOpacity, .5) && Near(late.FadeRemaining, .175), "Late wakes resume the phase instead of extending the cadence");
                var end = QuotaAlternationSchedule.At(start + 4, count);
                Check(end.Current == (slot + 1) % count && end.NextOpacity == 0 && end.FadeRemaining == 0, "Exact slot end settles on the new provider");
            }
            var skipped = QuotaAlternationSchedule.At(4 * (count * 100 + 1) + 1, count);
            Check(skipped.Current == 1 && skipped.FadeRemaining == 0, "A suspended dispatcher skips elapsed slots without catch-up callbacks");
        }
        var single = QuotaAlternationSchedule.At(1_000_000, 1);
        Check(single.Current == 0 && single.Next == 0 && single.FadeRemaining == 0 && double.IsPositiveInfinity(single.NextFade), "One provider never schedules a wake");
        foreach (double invalid in new[] { -1, double.NaN, double.PositiveInfinity })
        {
            try { QuotaAlternationSchedule.At(invalid, 3); throw new InvalidOperationException("Invalid clock accepted"); }
            catch (ArgumentOutOfRangeException) { }
        }
        try { QuotaAlternationSchedule.At(0, 0); throw new InvalidOperationException("Empty provider set accepted"); }
        catch (ArgumentOutOfRangeException) { }
    }
}
