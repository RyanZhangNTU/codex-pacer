using CodexPacer.Windows;

internal static class NotificationActionChecks
{
    internal static async Task Run()
    {
        int shown = 0, snoozed = 0, harnessOpened = 0; var links = new List<Uri>(); bool stopping = false, harnessAvailable = true;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var lifetime = new CancellationTokenSource();
        var actions = new NotificationActions(ready.Task, () => stopping, () => shown++, () => { snoozed++; return Task.CompletedTask; }, uri => { links.Add(uri); return true; }, lifetime.Token,
            () => { if (!harnessAvailable) return false; harnessOpened++; return true; });
        var show = actions.HandleAsync("showIsland"); var snooze = actions.HandleAsync("snoozeSpike");
        Check(!show.IsCompleted && !snooze.IsCompleted && shown == 0 && snoozed == 0, "Native startup actions cannot send commands before initialization");
        var topUp = actions.HandleAsync("topUp"); var harness = actions.HandleAsync("openHarness");
        Check(!topUp.IsCompleted && links.Count == 0, "The fixed top-up route waits for initialization");
        Check(!harness.IsCompleted && harnessOpened == 0 && shown == 0, "Harness activation also waits for the engine");
        ready.SetResult();
        Check(await topUp && links.Single().AbsoluteUri == "https://platform.deepseek.com/top_up", "Ready top-up activation uses only the fixed URI");
        Check(await harness && harnessOpened == 1, "Ready Harness activation uses the validated launcher");
        harnessAvailable = false;
        Check(!await actions.HandleAsync("openHarness") && harnessOpened == 1, "An uninstalled Harness cannot turn an old notification into a successful action");
        Check(!await actions.HandleAsync("topUp&url=https://untrusted.invalid") && links.Count == 1, "Unknown actions cannot supply a URL");
        Check(await show && await snooze && shown == 1 && snoozed == 1, "Ready actions are dispatched once");
        stopping = true;
        Check(!await actions.HandleAsync("showIsland") && !await actions.HandleAsync("topUp") && !await actions.HandleAsync("openHarness") && links.Count == 1, "Quitting prevents new UI, app or link actions");
        var neverReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var closing = new NotificationActions(neverReady.Task, () => false, () => throw new Exception("Late show"), () => throw new Exception("Late snooze"), _ => true, lifetime.Token);
        var pending = closing.HandleAsync("showIsland"); lifetime.Cancel();
        Check(!await pending.WaitAsync(TimeSpan.FromSeconds(1)), "Quit cancels a queued action even if initialization never finishes");
        var failed = new NotificationActions(Task.FromException(new IOException("Initialization failed")), () => false, () => throw new Exception(), () => throw new Exception(), _ => false);
        Check(!await failed.HandleAsync("showIsland") && !await failed.HandleAsync("snoozeSpike"), "Initialization failure cannot produce an unobserved action error");
        var rejected = new NotificationActions(Task.CompletedTask, () => false, () => { }, () => Task.FromException(new EngineCommandException("unavailable")), _ => false);
        Check(!await rejected.HandleAsync("snoozeSpike") && !await rejected.HandleAsync("topUp"), "Rejected commands and link failures remain failures");
        var unavailableShell = new NotificationActions(Task.CompletedTask, () => false, () => throw new InvalidOperationException("Window closed"), () => Task.CompletedTask,
            _ => throw new System.ComponentModel.Win32Exception(5));
        Check(!await unavailableShell.HandleAsync("showIsland") && !await unavailableShell.HandleAsync("topUp"), "Unavailable UI and shell handlers cannot leave unobserved action exceptions");
        var unavailableHarness = new NotificationActions(Task.CompletedTask, () => false, () => { }, () => Task.CompletedTask, _ => false,
            openHarness: () => throw new System.ComponentModel.Win32Exception(2));
        Check(!await unavailableHarness.HandleAsync("openHarness") && !await failed.HandleAsync("openHarness"), "A missing handler or failed native launch is a handled failure");
        await References();
    }
    private static async Task References()
    {
        int resolves = 0, opens = 0, links = 0, shows = 0; bool sourceValid = true;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var link = new EngineActivityLink("synthetic-task", "codex", Guid.NewGuid().ToString("D"));
        var gate = new TaskCompletionSource<EngineNotificationActivation>(TaskCreationOptions.RunContinuationsAsynchronously);
        var actions = new NotificationActions(ready.Task, () => false, () => shows++, () => throw new Exception("Snooze belongs to the engine"), _ => { links++; return true; },
            resolve: async (kind, reference) =>
            {
                resolves++;
                if (!sourceValid) throw new EngineCommandException("staleNotification");
                if (reference == new string('b', 32)) return await gate.Task;
                return new(kind, kind == "openTask" ? link : null);
            }, openTask: value => { Check(value == link, "Only the fresh validated link reaches navigation"); opens++; return Task.FromResult(true); });
        string task = NotificationPayload.Argument("openTask", new string('a', 32));
        var queued = actions.HandleReferenceAsync(task);
        Check(!queued.IsCompleted && resolves == 0 && opens == 0, "Cold activation waits for engine initialization before source validation or navigation");
        ready.SetResult(); Check(await queued && resolves == 1 && opens == 1, "Ready task activation resolves its opaque reference before dispatch");
        string delayed = NotificationPayload.Argument("showIsland", new string('b', 32));
        var pending = actions.HandleReferenceAsync(delayed);
        Check(!await actions.HandleReferenceAsync(delayed) && !pending.IsCompleted, "Duplicate native callbacks share one in-flight reference");
        gate.SetResult(new("showIsland", null)); Check(await pending && shows == 1, "A single validated callback reveals the island");
        sourceValid = false;
        Check(!await actions.HandleReferenceAsync(NotificationPayload.Argument("topUp", new string('c', 32))) && links == 0,
            "An old account or changed source cannot open even a fixed link");
        sourceValid = true;
        Check(await actions.HandleReferenceAsync(NotificationPayload.Argument("topUp", new string('d', 32))) && links == 1, "A validated top-up action uses the fixed route");
        Check(await actions.HandleReferenceAsync(NotificationPayload.Argument("snoozeSpike", new string('e', 32))), "Validated snooze is applied once by the engine");
        int before = resolves;
        Check(!await actions.HandleReferenceAsync("pacer=1&action=topUp") && !await actions.HandleReferenceAsync(task + "&url=https://untrusted.invalid") &&
            !await actions.HandleReferenceAsync(new string('a', 129)) && resolves == before, "Legacy, extra-field and oversized payloads never reach the engine");
        using var lifetime = new CancellationTokenSource();
        var never = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var closing = new NotificationActions(never.Task, () => false, () => throw new Exception(), () => throw new Exception(), _ => throw new Exception(), lifetime.Token,
            resolve: (_, _) => throw new Exception("A cancelled cold activation reached the engine"));
        var cancelled = closing.HandleReferenceAsync(task); lifetime.Cancel();
        Check(!await cancelled.WaitAsync(TimeSpan.FromSeconds(1)), "Quit cancels cold task activation before initialization");
    }
    internal static async Task RunWithEngine(string executable)
    {
        await using var engine = new EngineClient();
        await engine.StartAsync(executable, true, "en", new { enabledProviders = new[] { "deepseek" } }, referenceFixture: true);
        await engine.SendAsync("configure", new { enabledProviders = Array.Empty<string>() });
        int shown = 0;
        var actions = new NotificationActions(Task.CompletedTask, () => false, () => shown++, () => engine.SendAsync("snoozeDeepSeekSpike"), _ => false);
        Check(await actions.HandleAsync("snoozeSpike") && shown == 0, "An old notification can mute future spikes while the module is off, without showing the island");
        object Group(double spike) => new { warnings = new[] { "spendSpike" }, lowLine = (double?)null, spikeLine = spike };
        await engine.SendAsync("configure", new { enabledProviders = new[] { "deepseek" }, reminderSettings = Group(1000) });
        await engine.SendAsync("configure", new { reminderSettings = Group(0.00001) });
        Check(engine.LatestSnapshot?.Wallet?.Alert?.Kind == "spike" && engine.LatestSnapshot.Notices.All(value => value.Category != "deepseek.spike"),
            "The hour snooze survives module re-enable and suppresses a new crossing while leaving its compact warning visible");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
