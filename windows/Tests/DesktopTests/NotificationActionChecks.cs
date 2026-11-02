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
        Check(await actions.HandleAsync("topUp") && links.Single().AbsoluteUri == "https://platform.deepseek.com/top_up", "The fixed top-up route remains available while the engine initializes");
        Check(await actions.HandleAsync("openHarness") && harnessOpened == 1 && shown == 0, "Harness opens through its validated launcher without waiting for the engine or revealing the island");
        harnessAvailable = false;
        Check(!await actions.HandleAsync("openHarness") && harnessOpened == 1, "An uninstalled Harness cannot turn an old notification into a successful action");
        Check(!await actions.HandleAsync("topUp&url=https://untrusted.invalid") && links.Count == 1, "Unknown actions cannot supply a URL");
        ready.SetResult();
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
