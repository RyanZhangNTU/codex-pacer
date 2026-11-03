using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

/// Native callbacks may arrive before initialization or while quitting. Keep
/// the fixed action routes and readiness/lifetime checks in one place.
internal sealed class NotificationActions(Task ready, Func<bool> stopping, Action showIsland,
    Func<Task> snoozeSpike, Func<Uri, bool> openLink, CancellationToken lifetime = default, Func<bool>? openHarness = null,
    Func<string, string, Task<EngineNotificationActivation>>? resolve = null, Func<EngineActivityLink, Task<bool>>? openTask = null)
{
    internal static readonly Uri TopUpUri = new("https://platform.deepseek.com/top_up");
    private readonly System.Collections.Generic.HashSet<string> received = [];
    internal async Task<bool> HandleReferenceAsync(string arguments)
    {
        string? kind = NotificationPayload.ParseAction(arguments), reference = NotificationPayload.ParseReference(arguments);
        if (kind == null || reference == null || resolve == null || stopping() || lifetime.IsCancellationRequested) return false;
        lock (received) { if (received.Count >= 128 || !received.Add(reference)) return false; }
        try
        {
            await ready.WaitAsync(lifetime);
            if (stopping() || lifetime.IsCancellationRequested) return false;
            var action = await resolve(kind, reference).WaitAsync(lifetime);
            if (action.Kind != kind || stopping() || lifetime.IsCancellationRequested) return false;
            if (kind == "openTask") return action.Link != null && openTask != null && await openTask(action.Link);
            // The engine applies snooze while consuming its source-bound ref.
            return kind == "snoozeSpike" || await HandleAsync(kind);
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
        finally { lock (received) received.Remove(reference); }
    }

    internal async Task<bool> HandleAsync(string action)
    {
        if (stopping() || lifetime.IsCancellationRequested) return false;
        try
        {
            if (action is not ("showIsland" or "snoozeSpike" or "topUp" or "openHarness")) return false;
            await ready.WaitAsync(lifetime);
            if (stopping() || lifetime.IsCancellationRequested) return false;
            if (action == "topUp") return openLink(TopUpUri);
            if (action == "openHarness") return openHarness?.Invoke() == true;
            if (action == "showIsland") showIsland();
            else await snoozeSpike();
            return true;
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }
    private static bool Recoverable(Exception error) => error is IOException or OperationCanceledException or EngineCommandException or InvalidOperationException or System.ComponentModel.Win32Exception;
}
