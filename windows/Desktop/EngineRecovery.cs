using System;

namespace CodexPacer.Windows;

/// <summary>
/// Whether an engine that stopped unexpectedly restarts with the app.
/// </summary>
internal static class EngineRecovery
{
    /// <summary>
    /// An engine that stops sooner than this most likely fails while starting,
    /// so another restart would only repeat the failure. It keeps the stopped
    /// status, which asks the user to restart.
    /// </summary>
    internal static readonly TimeSpan MinimumUptime = TimeSpan.FromMinutes(10);

    internal static bool ShouldRestart(TimeSpan uptime) => uptime >= MinimumUptime;
}
