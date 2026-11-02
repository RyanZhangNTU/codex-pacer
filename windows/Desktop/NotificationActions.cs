using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

/// Native callbacks may arrive before initialization or while quitting. Keep
/// the fixed action routes and readiness/lifetime checks in one place.
internal sealed class NotificationActions(Task ready, Func<bool> stopping, Action showIsland,
    Func<Task> snoozeSpike, Func<Uri, bool> openLink, CancellationToken lifetime = default, Func<bool>? openHarness = null)
{
    internal static readonly Uri TopUpUri = new("https://platform.deepseek.com/top_up");

    internal async Task<bool> HandleAsync(string action)
    {
        if (stopping() || lifetime.IsCancellationRequested) return false;
        try
        {
            if (action == "topUp") return openLink(TopUpUri);
            if (action == "openHarness") return openHarness?.Invoke() == true;
            if (action is not ("showIsland" or "snoozeSpike")) return false;
            await ready.WaitAsync(lifetime);
            if (stopping() || lifetime.IsCancellationRequested) return false;
            if (action == "showIsland") showIsland();
            else await snoozeSpike();
            return true;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException or InvalidOperationException or System.ComponentModel.Win32Exception) { return false; }
    }
}
