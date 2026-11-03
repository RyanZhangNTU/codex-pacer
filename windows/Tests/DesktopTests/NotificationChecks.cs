using CodexPacer.Windows;
using System.Xml.Linq;

internal static class NotificationChecks
{
    internal static async Task Run()
    {
        var notice = new EngineNotice("same-transition-id", "completion", "Finished", "Secret project", Body: "Finished · Secret project", PrivateBody: "Finished · Local task",
            Actions: [new("snoozeSpike", "Not for an Hour"), new("openHarness", "Open Harness"), new("unsafe", "Unsafe")]);
        var queue = new Queue<Action>(); void Pump() { while (queue.TryDequeue(out var action)) action(); }
        var deliveredActions = new List<string>(); var system = new Fake(); int configurations = 0; bool save = true;
        var preferences = new PreferencesSession(new(), _ => { configurations++; return Task.CompletedTask; }, _ => save);
        using var session = new NotificationSession(preferences, system, queue.Enqueue, value => deliveredActions.Add(NotificationPayload.ParseAction(value)!), false);
        session.Receive(Frame(1, notice)); Pump(); Check(system.Delivered.Count == 0, "The default is off");
        Check(await session.SetEnabledAsync(true) == NotificationChangeResult.Applied && preferences.Current.SystemNotifications && configurations == 0,
            "The system switch is host-only and is saved after native enable succeeds");
        session.Receive(Frame(2, notice)); Pump(); session.Receive(Frame(2, notice)); Pump();
        Check(system.Delivered.Count == 1 && system.Delivered[0].Body.Contains("Secret project"), "A frame is delivered once");
        Check(system.Delivered[0].Actions.Select(value => value.Kind).SequenceEqual(new[] { "snoozeSpike" }), "Only supported live actions are shown");
        session.Receive(Frame(3, notice)); Pump();
        Check(system.Delivered.Count == 2, "A later threshold crossing may reuse a stable notice identifier");
        session.Receive(Frame(4, notice));
        await preferences.ChangeAsync(p => p with { HideProjects = true }); Pump();
        Check(system.Delivered.Count == 2 && system.ClearCount == 1, "Privacy invalidates queued old content and clears the app's notification history");
        session.Receive(Frame(5, notice)); Pump();
        Check(system.Delivered.Last().Body == "Finished · Local task", "Privacy is checked at delivery");
        session.Receive(Frame(6, notice with { PrivateBody = null })); Pump();
        Check(system.Delivered.Last().Body == "Finished", "An older engine cannot leak its detail without a private projection");
        session.Receive(Frame(7, notice));
        Check(await session.SetEnabledAsync(false) == NotificationChangeResult.Applied && !preferences.Current.SystemNotifications, "Disable is acknowledged"); Pump();
        Check(system.Delivered.Count == 4 && !system.Registered, "Disable cancels queued delivery and unregisters");
        system.Fire("topUp"); Pump(); Check(deliveredActions.Count == 0, "Old history cannot activate actions after disable");
        system.Result = NotificationAvailability.Denied;
        Check(await session.SetEnabledAsync(true) == NotificationChangeResult.Unavailable && !preferences.Current.SystemNotifications
            && !session.DesiredEnabled && session.Availability == NotificationAvailability.Denied, "Denial keeps a new opt-in off");
        system.Result = NotificationAvailability.Available; save = false;
        Check(await session.SetEnabledAsync(true) == NotificationChangeResult.SaveFailed && !preferences.Current.SystemNotifications && !system.Registered,
            "An unsaved enable cannot leave live delivery on");
        save = true; await session.SetEnabledAsync(true); save = false;
        Check(await session.SetEnabledAsync(false) == NotificationChangeResult.SaveFailed && preferences.Current.SystemNotifications && system.Registered,
            "An unsaved disable restores the previously acknowledged switch");
        system.Fire("topUp"); system.Fire("openHarness"); system.Fire("arbitrary"); Pump();
        Check(deliveredActions.SequenceEqual(new[] { "topUp" }), "Activation uses a fixed implemented vocabulary");
        save = true; session.Receive(Frame(8, notice, demo: true)); Pump();
        Check(system.Delivered.Count == 4, "A demo snapshot cannot reach the OS");
        system.RejectNextDelivery = true; session.Receive(Frame(12, notice)); Pump();
        Check(session.Availability == NotificationAvailability.Failed && system.Delivered.Count == 4, "A transient delivery failure is visible");
        session.Receive(Frame(13, notice)); Pump();
        Check(session.Availability == NotificationAvailability.Available && system.Delivered.Count == 5, "The next new notice can recover without replaying the failed one");
        system.Result = NotificationAvailability.Denied; session.Receive(Frame(14, notice)); Pump();
        Check(session.Availability == NotificationAvailability.Denied && preferences.Current.SystemNotifications && system.Delivered.Count == 5,
            "Revocation after registration reports OS denial without erasing the saved preference");
        system.Result = NotificationAvailability.Available; session.Receive(Frame(15, notice)); Pump();
        Check(session.Availability == NotificationAvailability.Available && system.Delivered.Count == 6, "Delivery recovers when the OS enables notifications again");
        using (var demo = new NotificationSession(preferences, new Fake(), queue.Enqueue, _ => throw new Exception(), true))
        { await demo.RefreshAsync(); demo.Receive(Frame(9, notice)); Pump(); }

        bool harnessAvailable = true; var harnessActions = new List<string>(); var harnessSystem = new Fake();
        using (var harness = new NotificationSession(preferences, harnessSystem, queue.Enqueue, value => harnessActions.Add(NotificationPayload.ParseAction(value)!), false, () => harnessAvailable))
        {
            await harness.RefreshAsync(); harness.Receive(Frame(1, notice)); Pump();
            Check(harnessSystem.Delivered.Single().Actions.Select(value => value.Kind).SequenceEqual(new[] { "snoozeSpike", "openHarness" }),
                "An available desktop adds the shared Harness action while keeping unknown actions out");
            harnessSystem.Fire("openHarness"); Pump();
            Check(harnessActions.SequenceEqual(new[] { "openHarness" }), "The supported native activation reaches the application router once");
            harnessSystem.Fire("openHarness"); harnessAvailable = false; Pump();
            Check(harnessActions.Count == 1, "Availability is checked again when a queued activation is dispatched");
            harness.Receive(Frame(2, notice)); Pump();
            Check(harnessSystem.Delivered.Last().Actions.Select(value => value.Kind).SequenceEqual(new[] { "snoozeSpike" }),
                "Later notifications omit Harness after it becomes unavailable");
        }

        var pending = new TaskCompletionSource<NotificationAvailability>(TaskCreationOptions.RunContinuationsAsynchronously);
        var delayedSystem = new Fake { Pending = pending.Task }; var saved = new List<bool>();
        var delayedPreferences = new PreferencesSession(new(), _ => Task.CompletedTask, p => { saved.Add(p.SystemNotifications); return true; });
        using (var delayed = new NotificationSession(delayedPreferences, delayedSystem, queue.Enqueue, _ => { }, false))
        {
            Task<NotificationChangeResult> first = delayed.SetEnabledAsync(true), latest = delayed.SetEnabledAsync(false);
            pending.SetResult(NotificationAvailability.Available);
            Check(await first == NotificationChangeResult.Superseded && await latest == NotificationChangeResult.Applied
                && saved.SequenceEqual(new[] { false }) && !delayedSystem.Registered && !delayed.DesiredEnabled,
                "A late native response cannot overwrite a newer off choice");
        }
        var oldPreference = new PreferencesSession(new() { SystemNotifications = true }, _ => Task.CompletedTask, _ => throw new Exception("Unexpected save"));
        var deniedSystem = new Fake { Result = NotificationAvailability.Denied };
        using (var denied = new NotificationSession(oldPreference, deniedSystem, queue.Enqueue, _ => { }, false))
        {
            await denied.RefreshAsync(); denied.Receive(Frame(10, notice)); Pump();
            Check(oldPreference.Current.SystemNotifications && denied.Availability == NotificationAvailability.Denied && deniedSystem.Delivered.Count == 0,
                "OS revocation pauses delivery without silently rewriting a saved choice");
            deniedSystem.Result = NotificationAvailability.Available; denied.Receive(Frame(11, notice)); Pump();
            Check(deniedSystem.Delivered.Count == 1 && denied.Availability == NotificationAvailability.Available, "An OS permission change is recognized on the next new notice without reopening settings");
        }

        var payload = new NotificationContent("secret/task/path", "A < B", "Reply & approve <tag>", [new("topUp", "Top <Up>", new string('a', 32)), new("malicious&action=topUp", "Bad", new string('b', 32))]);
        XElement xml = XElement.Parse(NotificationPayload.Xml(payload));
        Check(xml.Descendants("text").Select(value => value.Value).SequenceEqual(new[] { "A < B", "Reply & approve <tag>" })
            && xml.Descendants("action").Count() == 1 && xml.Element("audio")?.Attribute("silent")?.Value == "true", "Text is XML-escaped and notifications stay silent");
        Check(NotificationPayload.ParseAction(NotificationPayload.Argument("snoozeSpike", new string('a', 32))) == "snoozeSpike"
            && NotificationPayload.ParseAction("pacer=1&action=topUp&url=https://untrusted.invalid") == null
            && NotificationPayload.ParseAction("pacer=1&action=TOPUP") == null, "Launch arguments are exact, not open-ended commands");
        Check(NotificationPayload.Tag(payload.Id).Length == 16 && !NotificationPayload.Xml(payload).Contains(payload.Id), "Raw task identities never enter OS launch arguments");
        Check(new DesktopPreferences().IsValid && !(new DesktopPreferences { WarningKinds = ["budget", "budget"] }).IsValid
            && !(new DesktopPreferences { WarningKinds = ["unknown"] }).IsValid && !(new DesktopPreferences { DeepSeekSpikeLimit = double.NaN }).IsValid,
            "Reminder preferences reject unknown/duplicate kinds and nonfinite thresholds");
    }
    private static EngineSnapshot Frame(ulong sequence, EngineNotice notice, bool demo = false) => new(1, "snapshot", sequence, demo, 0, [], [], [], [], [notice], 0, 0, null, false);
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Fake : ISystemNotifications
    {
        public event Action<string>? Activated;
        internal NotificationAvailability Result = NotificationAvailability.Available;
        internal Task<NotificationAvailability>? Pending;
        internal bool Registered;
        public NotificationAvailability? CurrentAvailability => Result;
        internal int ClearCount;
        internal bool RejectNextDelivery;
        internal readonly List<NotificationContent> Delivered = [];
        public async Task<NotificationAvailability> EnableAsync() { var result = Pending == null ? Result : await Pending; Registered = true; return result; }
        public Task ClearAsync() { ClearCount++; return Task.CompletedTask; }
        public Task DisableAsync() { Registered = false; return Task.CompletedTask; }
        public bool Deliver(NotificationContent content)
        {
            if (Result != NotificationAvailability.Available) return false;
            if (RejectNextDelivery) { RejectNextDelivery = false; return false; }
            Delivered.Add(content); return true;
        }
        internal void Fire(string action) => Activated?.Invoke(NotificationPayload.Argument(action, new string('a', 32)));
        public void Dispose() { Registered = false; }
    }
}
