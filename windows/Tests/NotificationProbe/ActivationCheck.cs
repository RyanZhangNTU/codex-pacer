using CodexPacer.Windows;
using Microsoft.Windows.AppNotifications;
using System.Text.Json;

/// The QA identity uses an offline engine and an isolated reference store.
/// Native clicks exercise production parsing, readiness and source validation.
/// External handlers record synthetic destinations without launching an app.
internal static class ActivationCheck
{
    private sealed record Pending(Guid Scope, DateTimeOffset CreatedAt, string Expected, Dictionary<string, EngineNoticeAction> Actions);
    private static readonly string PendingPath = Path.Combine(AppContext.BaseDirectory, "notification-activation.pending.json");
    private static readonly string ResultPath = Path.Combine(AppContext.BaseDirectory, "notification-activation.result.jsonl");
    private static Pending ReadPending(bool cleanup = false)
    {
        if (!File.Exists(PendingPath) || new FileInfo(PendingPath).Length > 4096) throw new InvalidOperationException("Missing bounded QA references.");
        var value = JsonSerializer.Deserialize<Pending>(File.ReadAllText(PendingPath));
        if (value == null || !cleanup && (value.CreatedAt > DateTimeOffset.UtcNow || DateTimeOffset.UtcNow - value.CreatedAt > TimeSpan.FromMinutes(10)) ||
            value.Actions.Count > 5 || value.Actions.Any(pair => !NotificationPayload.IsAction(pair.Key) || pair.Value.Kind != pair.Key || !NotificationPayload.IsReference(pair.Value.Reference)))
            throw new InvalidOperationException("Expired or invalid QA references.");
        return value;
    }
    internal static string ArgumentsFor(string kind)
    {
        var action = ReadPending().Actions[kind];
        return NotificationPayload.Argument(action.Kind, action.Reference!);
    }
    internal static async Task<int> RunAsync(string mode, string expected = "snoozeSpike")
    {
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) != "Pacer.NotificationProbe") throw new InvalidOperationException("Unexpected probe process identity.");
        using var instance = new Mutex(true, "Local\\Pacer.NotificationProbe.ActivationQA", out bool first);
        if (!first) throw new InvalidOperationException("A QA notification probe is already running.");
        if (mode != "cleanup" && !AppNotificationManager.IsSupported()) throw new InvalidOperationException("Native notifications are unsupported in this session.");
        if (expected != "all" && !NotificationPayload.IsAction(expected) || mode == "prepare-cold" && expected == "all") throw new ArgumentException("Unknown synthetic action.");
        Pending? pending = mode == "cold-activation" ? ReadPending() : null;
        bool keepForColdActivation = false;
        using var system = new WindowsSystemNotifications(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"), "Codex Pacer notification QA", suppressDisplay: mode == "warm", longDuration: true);
        system.Registered += () => { Console.WriteLine(JsonSerializer.Serialize(new { phase = "registered", mode, processId = Environment.ProcessId })); Console.Out.Flush(); };
        var received = new Queue<string>(); var signal = new SemaphoreSlim(0);
        system.Activated += arguments => { lock (received) received.Enqueue(arguments); signal.Release(); };
        var manager = AppNotificationManager.Default;
        await using var engine = new EngineClient();
        try
        {
            var availability = await system.EnableAsync();
            if (mode == "cleanup") { if (File.Exists(PendingPath)) pending = ReadPending(cleanup: true); return 0; }
            if (availability != NotificationAvailability.Available) throw new InvalidOperationException("Native notification availability: " + availability);
            var scope = pending?.Scope ?? Guid.NewGuid();
            var generated = new Dictionary<string, EngineNoticeAction>();
            engine.Snapshot += frame =>
            {
                foreach (var notice in frame.Notices)
                {
                    foreach (var action in (notice.Actions ?? []).Concat(notice.DefaultAction == null ? [] : new[] { notice.DefaultAction }))
                        if (NotificationPayload.IsReference(action.Reference)) generated[action.Kind] = action;
                }
            };
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            bool resolvedAfterReady = false, sourceChecked = false; string? dispatched = null;
            var router = new NotificationActions(ready.Task, () => false, () => dispatched = "showIsland", () => throw new InvalidOperationException("Snooze must be applied in the engine"),
                uri => { if (uri != NotificationActions.TopUpUri) return false; dispatched = "topUp"; return true; },
                openHarness: () => { dispatched = "openHarness"; return true; },
                resolve: async (kind, reference) =>
                {
                    resolvedAfterReady = ready.Task.IsCompletedSuccessfully;
                    var action = await engine.QueryAsync<EngineNotificationActivation>("activateNotification", new { context = reference, notificationAction = kind });
                    sourceChecked = action.Kind == kind;
                    if (kind == "snoozeSpike") dispatched = kind;
                    return action;
                }, openTask: async link =>
                {
                    var plan = await engine.QueryAsync<EngineNavigationPlan>("prepareActivityOpen", new { context = link.Context });
                    if (plan.Kind != "demo" || plan.Provider != link.Provider || plan.Context != link.Context) return false;
                    await engine.SendAsync("completeActivityOpen", new { context = link.Context }); dispatched = "openTask"; return true;
                });
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true, notificationQa: scope);
            await engine.SendAsync("demoStage", new { demoStage = 1 });
            await engine.SendAsync("configure", new { reminderSettings = new { warnings = new[] { "lowBalance", "spendSpike", "budget" }, lowLine = 100, spikeLine = 1000 } });
            await engine.SendAsync("configure", new { reminderSettings = new { warnings = new[] { "lowBalance", "spendSpike", "budget" }, lowLine = 100, spikeLine = 0.00001 } });
            if (generated.Count != 5) throw new InvalidOperationException("The offline engine did not produce all five bounded routes.");
            pending ??= new(scope, DateTimeOffset.UtcNow, expected, generated);
            if (mode != "cold-activation") { File.WriteAllText(PendingPath, JsonSerializer.Serialize(pending)); File.WriteAllText(ResultPath, ""); }
            ready.SetResult();
            foreach (string kind in pending.Expected == "all" ? new[] { "showIsland", "openTask", "topUp", "openHarness", "snoozeSpike" } : new[] { pending.Expected })
            {
                if (mode != "cold-activation")
                {
                    var action = pending.Actions[kind];
                    var content = new NotificationContent("pacer-isolated-activation-qa", "Codex Pacer QA", "Synthetic " + kind + " check. No private task or account data.",
                        kind == "showIsland" ? [] : [action with { Title = "Verify " + kind }], action);
                    if (!system.Deliver(content)) throw new InvalidOperationException("The native SDK did not accept the QA notification.");
                    var history = await manager.GetAllAsync();
                    if (!history.Any(value => value.Tag == NotificationPayload.Tag(content.Id) && value.Group == "pacer" && value.Id != 0)) throw new InvalidOperationException("The synthetic notification is missing from its own OS history.");
                    Console.WriteLine(JsonSerializer.Serialize(new { phase = "ready", mode, action = kind, ownHistoryVerified = true, processId = Environment.ProcessId })); Console.Out.Flush();
                    if (mode == "prepare-cold") { keepForColdActivation = true; return 0; }
                }
                if (!await signal.WaitAsync(TimeSpan.FromSeconds(mode == "cold-activation" ? 20 : 120))) throw new TimeoutException("The synthetic native click did not arrive.");
                string arguments; lock (received) arguments = received.Dequeue();
                bool handled = await router.HandleReferenceAsync(arguments);
                if (!handled || !resolvedAfterReady || !sourceChecked || dispatched != kind) throw new InvalidOperationException("The clicked route did not complete after source validation.");
                var result = new { mode, action = kind, nativeCallback = true, engineReady = resolvedAfterReady, sourceChecked, handled, externalLaunch = false };
                File.AppendAllText(ResultPath, JsonSerializer.Serialize(result) + "\n"); Console.WriteLine(JsonSerializer.Serialize(result)); Console.Out.Flush();
            }
            return 0;
        }
        finally
        {
            if (!keepForColdActivation)
            {
                try { await manager.RemoveAllAsync(); }
                finally
                {
                    system.Dispose(); QaNotificationRegistration.Remove(manager); File.Delete(PendingPath);
                    await engine.DisposeAsync();
                    if (pending != null)
                    {
                        string temporary = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "Engine")).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                        string root = Path.GetFullPath(Path.Combine(temporary, "notification-qa-" + pending.Scope.ToString("D").ToLowerInvariant()));
                        if (!root.StartsWith(temporary, StringComparison.OrdinalIgnoreCase) || new DirectoryInfo(root).LinkTarget != null) throw new InvalidOperationException("Unexpected QA reference root.");
                        if (Directory.Exists(root)) Directory.Delete(root, true);
                    }
                }
                Console.WriteLine("The separate QA history, registration and reference store were removed.");
            }
        }
    }
}
