using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal enum NotificationChangeResult { Applied, Unavailable, SaveFailed, Superseded }

/// App-owned state: closing a settings window cannot abandon an outstanding
/// registration or let its completion override a newer switch position.
internal sealed class NotificationSession : IDisposable
{
    private readonly PreferencesSession preferences;
    private readonly ISystemNotifications system;
    private readonly Action<Action> post;
    private readonly Action<string> activate;
    private readonly bool demo;
    private readonly Func<bool> canOpenHarness;
    private readonly SemaphoreSlim operations = new(1, 1);
    private long revision, deliveryEpoch;
    private ulong deliveredSequence;
    private volatile bool deliverEnabled, disposed;
    private bool hideProjects;
    internal bool DesiredEnabled { get; private set; }
    internal bool IsChanging { get; private set; }
    internal NotificationAvailability? Availability { get; private set; }
    internal event Action? Changed;

    internal NotificationSession(PreferencesSession preferences, ISystemNotifications system, Action<Action> post,
        Action<string> activate, bool demo, Func<bool>? canOpenHarness = null)
    {
        this.preferences = preferences; this.system = system; this.post = post; this.activate = activate; this.demo = demo;
        DesiredEnabled = preferences.Current.SystemNotifications; hideProjects = preferences.Current.HideProjects;
        this.canOpenHarness = canOpenHarness ?? (() => false);
        preferences.Changed += PreferencesChanged; system.Activated += Activated;
    }

    internal async Task RefreshAsync()
    {
        long current = revision;
        await operations.WaitAsync();
        try
        {
            if (disposed || current != revision || !preferences.Current.SystemNotifications) return;
            var availability = await system.EnableAsync();
            if (disposed || current != revision) return;
            Availability = availability; deliverEnabled = CanAttempt(availability);
            Changed?.Invoke();
        }
        finally { operations.Release(); }
    }

    internal async Task<NotificationChangeResult> SetEnabledAsync(bool value)
    {
        long current = ++revision;
        Interlocked.Increment(ref deliveryEpoch); deliverEnabled = false;
        DesiredEnabled = value; IsChanging = true; Changed?.Invoke();
        await operations.WaitAsync();
        try
        {
            if (disposed || current != revision) return NotificationChangeResult.Superseded;
            NotificationAvailability? availability = null;
            if (value) availability = await system.EnableAsync();
            else await system.DisableAsync();
            if (disposed || current != revision) return NotificationChangeResult.Superseded;
            Availability = availability;
            if (value && availability != NotificationAvailability.Available)
            {
                if (!preferences.Current.SystemNotifications) await system.DisableAsync();
                return NotificationChangeResult.Unavailable;
            }
            var result = await preferences.ChangeAsync(p => p with { SystemNotifications = value });
            if (disposed || current != revision) return NotificationChangeResult.Superseded;
            if (result != PreferencesApplyResult.Applied)
            {
                if (preferences.Current.SystemNotifications) Availability = await system.EnableAsync();
                else await system.DisableAsync();
                return NotificationChangeResult.SaveFailed;
            }
            return NotificationChangeResult.Applied;
        }
        finally
        {
            if (!disposed && current == revision)
            {
                DesiredEnabled = preferences.Current.SystemNotifications; IsChanging = false;
                deliverEnabled = DesiredEnabled && CanAttempt(Availability);
                Changed?.Invoke();
            }
            operations.Release();
        }
    }

    internal void Receive(EngineSnapshot snapshot)
    {
        // A notice received while off is never replayed when the switch is on.
        if (demo || snapshot.Demo || !deliverEnabled || disposed || snapshot.Notices.Count == 0) return;
        long epoch = Interlocked.Read(ref deliveryEpoch);
        post(() =>
        {
            if (disposed || !deliverEnabled || epoch != Interlocked.Read(ref deliveryEpoch) || snapshot.Sequence <= deliveredSequence) return;
            deliveredSequence = snapshot.Sequence;
            foreach (var notice in snapshot.Notices.DistinctBy(value => value.Id))
            {
                string body = preferences.Current.HideProjects ? notice.PrivateBody ?? notice.Title : notice.Body ?? notice.Title + " · " + notice.Detail;
                var actions = (notice.Actions ?? []).Where(value => SupportedAction(value.Kind)).ToArray();
                var defaultAction = notice.DefaultAction is { } main && (main.Kind == "showIsland" || SupportedAction(main.Kind)) ? main : null;
                if (!system.Deliver(new(notice.Id, "Codex Pacer", body, actions, defaultAction)))
                {
                    // A transient SDK failure must not disable all later
                    // notices. The adapter checks the OS setting every time.
                    Availability = system.CurrentAvailability is NotificationAvailability.Denied or NotificationAvailability.Unsupported
                        ? system.CurrentAvailability : Availability == NotificationAvailability.Denied ? Availability : NotificationAvailability.Failed;
                    Changed?.Invoke(); break;
                }
                if (Availability != NotificationAvailability.Available) { Availability = NotificationAvailability.Available; Changed?.Invoke(); }
            }
        });
    }

    private static bool CanAttempt(NotificationAvailability? availability) => availability is NotificationAvailability.Available or NotificationAvailability.Denied;
    private bool SupportedAction(string action) => action is "openTask" or "snoozeSpike" or "topUp" || action == "openHarness" && canOpenHarness();

    private void PreferencesChanged(DesktopPreferences value)
    {
        if (!value.SystemNotifications) deliverEnabled = false;
        if (hideProjects == value.HideProjects) return;
        hideProjects = value.HideProjects; Interlocked.Increment(ref deliveryEpoch);
        _ = ClearHistoryAsync();
    }
    private async Task ClearHistoryAsync()
    {
        await operations.WaitAsync();
        try { if (!disposed) await system.ClearAsync(); }
        finally { operations.Release(); }
    }
    private void Activated(string action) => post(() =>
    {
        string? kind = NotificationPayload.ParseAction(action);
        if (!disposed && preferences.Current.SystemNotifications && kind != null && (kind == "showIsland" || SupportedAction(kind))) activate(action);
    });
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; deliverEnabled = false; revision++; Interlocked.Increment(ref deliveryEpoch);
        preferences.Changed -= PreferencesChanged; system.Activated -= Activated; system.Dispose();
    }
}
