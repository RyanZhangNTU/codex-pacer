using CodexPacer.Windows;

internal static class EngineRecoveryChecks
{
    internal static void Run()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        Check(EngineRecovery.MinimumUptime == TimeSpan.FromMinutes(10), "The app restarts only for an engine that ran ten minutes");
        Check(!EngineRecovery.ShouldRestart(TimeSpan.Zero), "An engine that stops at once keeps the stopped status");
        Check(!EngineRecovery.ShouldRestart(EngineRecovery.MinimumUptime - TimeSpan.FromMilliseconds(1)), "An engine that stops within ten minutes keeps the stopped status");
        Check(EngineRecovery.ShouldRestart(EngineRecovery.MinimumUptime), "An engine that ran ten minutes restarts with the app");
        Check(EngineRecovery.ShouldRestart(TimeSpan.FromHours(15)), "An engine that ran for hours restarts with the app");
        Check(!EngineRecovery.ShouldRestart(TimeSpan.FromMinutes(-5)), "A negative uptime never restarts the app");
    }
}
