using System.Diagnostics;
using System.Text;
using System.Text.Json;
using CodexPacer.Windows;

internal static class Program
{
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(10);

    private static async Task<int> Main(string[] args)
    {
        if (args is ["--remote-source-unit-only"])
        { WslTerminalChecks.Run(); Console.WriteLine("PASS WSL terminal source routing and launch rejection"); return 0; }
        if (args is ["--preferences-only", var preferencesEngine])
        { PreferencesChecks.Run(); await PreferencesPersistenceChecks.Run(preferencesEngine); Console.WriteLine("PASS preferences persistence, acknowledgement, recovery and forward-version protection"); return 0; }
        if (args is ["--deepseek-only", var budgetEngine]) { await DeepSeekOptionPersistenceChecks.Run(budgetEngine); return 0; }
        if (args is ["--startup-only"])
        { SettingsServiceChecks.Run(); StartupRegistrationChecks.Run(); Console.WriteLine("PASS startup ownership, OS disablement, policy, rollback and cleanup"); return 0; }
        if (args is ["--ssh-only"])
        { SshTerminalChecks.Run(); Console.WriteLine("PASS SSH terminal argv, fallback and preference persistence"); return 0; }
        if (args is ["--installation-only"])
        { InstallationServiceChecks.Run(); Console.WriteLine("PASS installation identity, repair, ownership, data retention, failure rollback and notification cleanup"); return 0; }
        if (args.Contains("--hold")) { await Task.Delay(Timeout.Infinite); return 0; }
        int fixture = Array.IndexOf(args, "--language");
        if (fixture >= 0) { await Fixture(args[fixture + 1]); return 0; }
        if (args.Length is 2 or 3 && args[0] == "--quota-check")
            return await CheckQuota(Path.GetFullPath(args[1]), args.Length == 3 ? args[2] : "");
        if (args.Length is 2 or 3 && args[0] == "--harness-identity")
            return HarnessApplicationChecks.CheckIdentity(Path.GetDirectoryName(Path.GetFullPath(args[1]))!, args.Length == 3 ? args[2] : null);
        if (args.Length != 1 || !File.Exists(args[0])) throw new ArgumentException("Supply the built PacerEngine.exe.");
        string engine = Path.GetFullPath(args[0]);
        int failed = 0, passed = 0;
        async Task Test(string name, Func<Task> run)
        {
            try { await run(); passed++; Console.WriteLine("PASS " + name); }
            catch (Exception error) { failed++; Console.WriteLine("FAIL " + name + ": " + error); }
        }

        await Test("quota alternation deadlines preserve four-second slots and 350 ms fades", () => { QuotaScheduleChecks.Run(); return Task.CompletedTask; });
        await Test("opaque fullscreen occlusion respects z-order, transparency, regions and monitor bounds", () => { OcclusionPolicyChecks.Run(); return Task.CompletedTask; });
        await Test("occlusion refresh trails location-event bursts with a bounded rate", () => { OcclusionRefreshChecks.Run(); return Task.CompletedTask; });

        await Test("real engine: demo, configuration rejection and acknowledged privacy", async () =>
        {
            await using var client = new EngineClient();
            EngineSnapshot? latest = null;
            client.Snapshot += value => latest = value;
            await client.StartAsync(engine, true, "zh-Hans", referenceFixture: true);
            Check(latest?.Demo == true && latest.Tasks.Select(t => t.Provider).Distinct().Count() == 3, "Three demo providers");
            var initial = latest!;
            Check(initial.QuotaDashboard is { SchemaVersion: 1, Providers.Count: 3 }
                && initial.QuotaDashboard.Providers.Single(value => value.Provider == "codex").Weekly.RemainingPercent == 43,
                "The optional dashboard extension must carry the shared period projection");
            Check(initial.CapturedAt == 1_800_000_000 && initial.Presentation?.Rows.Count == 7 && initial.Wallet?.Balance == 86.4,
                $"The original Mac synthetic clock, task families and wallet reach the renderer (clock={initial.CapturedAt}, rows={initial.Presentation?.Rows.Count}, balance={initial.Wallet?.Balance})");
            try
            {
                await client.SendAsync("configure", new { hideProjects = true, enabledProviders = new[] { "invalid" } });
                throw new InvalidOperationException("Invalid configuration was acknowledged.");
            }
            catch (EngineCommandException error) { Check(error.Code == "invalidConfiguration", "Typed rejection"); }
            await client.SendAsync("refresh");
            Check(latest!.Tasks.Select(t => t.Title).SequenceEqual(initial.Tasks.Select(t => t.Title)), "Atomic rejected configuration");
            await client.SendAsync("configure", new { hideProjects = true });
            Check(latest!.Sequence > initial.Sequence && latest.Tasks.All(t => t.Title == "本地任务"), "Names hidden before IPC");
            try
            {
                await client.SendAsync("demoStage", new { demoStage = "wrong type" });
                throw new InvalidOperationException("Malformed parameters were accepted.");
            }
            catch (EngineCommandException error) { Check(error.Code == "invalidCommand", "Malformed command keeps its correlation ID"); }
            await client.SendAsync("demoStage", new { demoStage = 3 });
            Check(latest!.Tasks.Any(t => t.Unread && t.Phase == "completed"), "Shared completion projection");
        });

        await Test("provider-pinned conversation links, matched cloud fallback and existing host plans", ConversationApplicationChecks.Run);
        await Test("SSH terminal argv, console fallback and shared preference key", () => { SshTerminalChecks.Run(); return Task.CompletedTask; });
        await Test("real engine: Claude/Codex/DeepSeek discovery, reads and write notifications beyond MAX_PATH", () => LongPathChecks.Run(engine));

        await Test("real Claude file notification: first reply after large Desktop metadata", async () =>
        {
            string root = Path.Combine(Path.GetTempPath(), "pacer-claude-first-中文-" + Guid.NewGuid().ToString("N"));
            string project = Path.Combine(root, "projects", "synthetic-desktop"); Directory.CreateDirectory(project);
            try
            {
                await using var client = new EngineClient();
                EngineSnapshot? latest = null; client.Snapshot += value => latest = value;
                await client.StartAsync(engine, false, "en", configuration: new { enabledProviders = new[] { "claude" }, claudeHome = root, hideProjects = true });
                await client.SendAsync("setExpanded", new { expanded = true });
                string session = Guid.NewGuid().ToString("D"), prompt = Guid.NewGuid().ToString("D"), assistant = Guid.NewGuid().ToString("D"), stamp = DateTimeOffset.UtcNow.ToString("O");
                string Row(object value) => JsonSerializer.Serialize(value) + "\n";
                var text = new StringBuilder(Row(new { type = "user", sessionId = session, uuid = prompt, timestamp = stamp, origin = new { kind = "human" },
                    message = new { role = "user", content = "synthetic-private-prompt" } }));
                string metadata = Row(new { type = "api-request-shape", sessionId = session, timestamp = stamp, payload = new string('x', 70000) });
                for (int i = 0; i < 8; i++) text.Append(metadata);
                text.Append(Row(new { type = "assistant", sessionId = session, uuid = assistant, parentUuid = prompt, timestamp = stamp,
                    message = new { role = "assistant", content = new[] { new { type = "text", text = "synthetic-private-reply" } }, stop_reason = "end_turn" } }));
                text.Append(Row(new { type = "system", sessionId = session, uuid = Guid.NewGuid().ToString("D"), parentUuid = assistant, timestamp = stamp,
                    subtype = "stop_hook_summary", preventedContinuation = false, hookErrors = Array.Empty<string>(), hookAdditionalContext = Array.Empty<string>() }));
                await File.WriteAllTextAsync(Path.Combine(project, session + ".jsonl"), text.ToString(), new UTF8Encoding(false));
                // No refresh command follows this write. The actual process
                // must discover, drain and publish through directory notifications.
                var until = Stopwatch.StartNew();
                while (latest?.Tasks.Any(task => task.SessionId == session && task.Phase == "completed") != true && until.Elapsed < Deadline) await Task.Delay(25);
                Check(latest?.Tasks.Any(task => task.SessionId == session && task.Phase == "completed" && task.Unread) == true, "A genuinely new first transcript must retain its ending and unread indication");
                string snapshot = JsonSerializer.Serialize(latest);
                Check(!snapshot.Contains("synthetic-private-prompt", StringComparison.Ordinal) && !snapshot.Contains("synthetic-private-reply", StringComparison.Ordinal), "Actual process output must exclude transcript text");
            }
            finally
            {
                string cleanup = Path.GetFullPath(root), temporary = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (!cleanup.StartsWith(temporary, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(cleanup).StartsWith("pacer-claude-first-", StringComparison.Ordinal) || new DirectoryInfo(cleanup).LinkTarget != null)
                    throw new InvalidOperationException("Unexpected Claude fixture directory");
                Directory.Delete(cleanup, true);
            }
        });

        DesktopPreferences? saved = null;
        await Test("backdrop policy, restoration, device ownership and idle scheduling", () => { BackdropChecks.Run(); return Task.CompletedTask; });
        await Test("preferences round trip, bounded corrupt files and rejected updates", () =>
        {
            saved = PreferencesChecks.Run(); return Task.CompletedTask;
        });
        await Test("isolated login registration and allowlisted desktop activation", () =>
        {
            SettingsServiceChecks.Run(); return Task.CompletedTask;
        });
        await Test("DeepSeek replies keep bounded session identity and exclude tokens", () =>
        { DeepSeekIdentityReplyChecks.Run(); return Task.CompletedTask; });
        await Test("startup OS disablement, policy, upgrade ownership and transactional failure recovery", () =>
        { StartupRegistrationChecks.Run(); return Task.CompletedTask; });
        await Test("installation, repair and uninstall retain user data and protect foreign registrations", () =>
        { InstallationServiceChecks.Run(); return Task.CompletedTask; });
        await Test("shared Harness desktop identity, cached availability and fresh activation", () =>
        {
            HarnessApplicationChecks.Run(Path.GetDirectoryName(engine)!); return Task.CompletedTask;
        });
        await Test("immediate settings edits serialize, recover and preserve acknowledged state", PreferencesSessionChecks.Run);
        await Test("all settings acknowledge, persist, restart and migrate without overwriting another writer", () => PreferencesPersistenceChecks.Run(engine));
        await Test("DeepSeek options persist and restore through independent engine restarts", () => DeepSeekOptionPersistenceChecks.Run(engine));
        await Test("native notification lifecycle, privacy, action payloads and permission races", NotificationChecks.Run);
        await Test("notification actions wait for initialization and cancel on quit", NotificationActionChecks.Run);
        await Test("real engine: snoozing an old notice while DeepSeek is disabled", () => NotificationActionChecks.RunWithEngine(engine));
        await Test("saved settings apply shared module modes, privacy and language to the engine", async () =>
        {
            Check(saved != null, "The round-trip fixture must produce saved settings");
            await using var client = new EngineClient();
            EngineSnapshot? latest = null;
            client.Snapshot += value => latest = value;
            await client.StartAsync(engine, true, saved!.Language, saved.EngineConfiguration(), referenceFixture: true);
            Check(latest?.Modules?.Count == 3 && latest.Modules.Single(value => value.Provider == "codex") is { Mode: "disabled", Enabled: false }
                && latest.Modules.Single(value => value.Provider == "claude") is { Mode: "automatic", Enabled: true }, "Saved modes must control the real projection");
            Check(latest!.Tasks.Count > 0 && latest.Tasks.All(value => value.Provider == "claude" && value.Title == "本地任务")
                && latest.Wallet == null, "Saved privacy and module choices must apply before the first snapshot");
            Check(latest.QuotaDashboard?.Classic.Slots.Select(value => value.Id).SequenceEqual(new[] { "claude:5h", "claude:7d" }) == true,
                "A single-provider dashboard must keep both native Classic periods in the managed DTO");
            await client.SendAsync("configure", new { providerModes = new { codex = "enabled", claude = "disabled", deepseek = "disabled" } });
            Check(latest!.QuotaDashboard is { Classic.Kind: "legacyCodex", Split.Kind: "splitSingle", LegacyCodex.Fresh: true }
                && latest.QuotaDashboard.LegacyCodex.Buckets.First().Windows.First().RemainingPercent == 43,
                "Codex's original Classic bars and Split Ring must share the same provider value in the managed projection");
        });

        await Test("real engine: correlated source queries and explicit default restoration", async () =>
        {
            await using var client = new EngineClient();
            var settled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            client.Snapshot += snapshot =>
            {
                if (snapshot.DeepseekConnection is { Refreshing: false } && snapshot.Wallet?.Balance != null)
                    settled.TrySetResult();
            };
            await client.StartAsync(engine, true, "en", referenceFixture: true);
            // Initialization can finish before the demo wallet's async read.
            // Establish the query baseline after that independent projection.
            await settled.Task.WaitAsync(Deadline);
            ulong sequence = client.LatestSnapshot!.Sequence;
            var queries = await Task.WhenAll(Enumerable.Range(1, 3).Select(index => client.QueryAsync<CodexSourceReport>("inspectCodexSource",
                new { codexExecutable = @"C:\Demo\" + index + @"\codex.exe", codexHome = @"C:\Demo\" + index })));
            for (int index = 1; index <= queries.Length; index++)
                Check(queries[index - 1].SelectedExecutable == @"C:\Demo\" + index + @"\codex.exe"
                    && queries[index - 1].EffectiveHome == @"C:\Demo\" + index, "Query values must survive frame disposal and remain correlated");
            Check(client.LatestSnapshot!.Sequence == sequence, "Source inspection cannot publish or change collectors");
            string path = @"C:\Demo\custom-source";
            await client.SendAsync("configure", new { codexHome = path });
            Check((await client.QueryAsync<CodexSourceReport>("inspectCodexSource")).EffectiveHome == path, "The settings query must report the actual configured home");
            using var configuration = JsonDocument.Parse(JsonSerializer.Serialize(new DesktopPreferences().EngineConfiguration()));
            foreach (string key in new[] { "codexHome", "claudeHome", "deepseekHome" })
                Check(configuration.RootElement.GetProperty(key).GetString() == "", "A cleared preference must send an explicit empty source override");
            await client.SendAsync("configure", new DesktopPreferences().EngineConfiguration());
            var restored = await client.QueryAsync<CodexSourceReport>("inspectCodexSource");
            Check(restored.EffectiveHome != path && restored.EffectiveHome.Contains("Demo"), "Clearing the source must restore the synthetic inherited home");
            try { await client.QueryAsync<CodexSourceReport>("refresh"); throw new InvalidOperationException("A valueless command was accepted as a query."); }
            catch (InvalidDataException) { }
            try { await client.QueryAsync<int>("inspectCodexSource"); throw new InvalidOperationException("An incompatible query value was accepted."); }
            catch (InvalidDataException) { }
            ulong beforeOversized = client.LatestSnapshot!.Sequence;
            try { await client.SendAsync("configure", new { codexExecutable = new string('x', 64 * 1024) }); throw new InvalidOperationException("An oversized command was sent."); }
            catch (EngineCommandException error) { Check(error.Code == "commandLimit", "Oversized settings must use the normal rejected-command path"); }
            Check(client.LatestSnapshot!.Sequence == beforeOversized, "A locally rejected command cannot mutate engine state");
            await client.SendAsync("refresh");
        });

        await Test("fragmented Unicode frames and correlated results", async () =>
        {
            await using var client = new EngineClient();
            EngineSnapshot? latest = null;
            client.Snapshot += value => latest = value;
            await client.StartAsync(Environment.ProcessPath!, true, "fragmented");
            Check(latest?.Tasks.Single().StageLabel == "思考中", "Split UTF8 frame");
            await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => client.SendAsync("refresh")));
            Check(latest!.Sequence == 9, "Every result is paired with its command");
        });

        await Test("incompatible engine is rejected before initialize", async () =>
        {
            await using var client = new EngineClient(TimeSpan.FromSeconds(1));
            try { await client.StartAsync(Environment.ProcessPath!, true, "incompatible"); }
            catch (IOException) { return; }
            throw new InvalidOperationException("An incompatible engine was accepted.");
        });

        await Test("out of order snapshots close the owned connection", async () =>
        {
            await using var client = new EngineClient(TimeSpan.FromSeconds(1));
            var failedProtocol = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            client.Status += code => { if (code == "engineProtocolFailed") failedProtocol.TrySetResult(); };
            await client.StartAsync(Environment.ProcessPath!, true, "outOfOrder");
            try { await client.SendAsync("refresh"); } catch (IOException) { }
            await failedProtocol.Task.WaitAsync(Deadline);
        });

        await Test("quit removes an unresponsive owned engine and its descendant", async () =>
        {
            var client = new EngineClient(TimeSpan.FromMilliseconds(250));
            EngineSnapshot? latest = null;
            client.Snapshot += value => latest = value;
            await client.StartAsync(Environment.ProcessPath!, true, "hang");
            int childId = int.Parse(latest!.Tasks.Single().Id, System.Globalization.CultureInfo.InvariantCulture);
            using Process child = Process.GetProcessById(childId);
            await client.DisposeAsync();
            await child.WaitForExitAsync().WaitAsync(Deadline);
            Check(child.HasExited, "Owned descendant exited");
            await client.DisposeAsync();
        });
        await Test("managed renderer uses the shared Swift motion and preserves reversal velocity", () =>
        {
            using var motion = new NativeMotion(Path.GetDirectoryName(engine)!, new(550, 20, 300, 32));
            motion.RetargetTo(new(480, 20, 440, 560), true, 0);
            var first = motion.At(1.0 / 60);
            Check(first.Bounds.Width > 300 && first.Bounds.Height > 32 && first.Content == 0, "Native first-frame reveal");
            Check(Math.Abs(first.Bounds.Y - 20) < 1e-9, "Fixed top anchor");
            var shown = motion.At(0.1);
            motion.RetargetTo(new(550, 20, 300, 32), false, 0.11);
            var reversal = motion.At(0.11);
            Check(reversal.Bounds == shown.Bounds && reversal.WidthVelocity == shown.WidthVelocity && reversal.HeightVelocity == shown.HeightVelocity,
                "Retarget from the last displayed position and velocity");
            var finished = motion.At(2);
            Check(finished.Finished && finished.Window == new MotionBounds(550, 20, 300, 32) && finished.Content == 0, "Exact folded geometry");
            motion.Dispose();
            for (int index = 0; index < 50; index++)
            {
                using var another = new NativeMotion(Path.GetDirectoryName(engine)!, new(550, 20, 300, 32));
                Check(another.At(0).Finished, "Repeated motion ownership");
            }
            var layout = new NativeLayout(Path.GetDirectoryName(engine)!);
            var corner = layout.Measure(new(-1920, -400, 1920, 1080), new(-1872, -400, 1872, 1040),
                2, 0, 0, 4, false, 404, 402, 162, 135);
            Check(corner.Target == new MotionBounds(-32, 495, 32, 135) && corner.Position == 4,
                "Original bottom-right strip geometry through the CLR");
            return Task.CompletedTask;
        });
        Console.WriteLine($"Desktop integration: {passed} passed, {failed} failed.");
        return failed == 0 ? 0 : 1;
    }

    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }

    private static async Task<int> CheckQuota(string engine, string executable)
    {
        // Opt-in real-account check. Never print task metadata, identity or
        // diagnostic strings; the normal integration suite uses demo data.
        await using var client = new EngineClient();
        var ready = new TaskCompletionSource<EngineSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Snapshot += snapshot =>
        {
            var source = snapshot.Sources.FirstOrDefault(value => value.Id == "codex:quota");
            if (source?.Available == true || source?.Reason != null) ready.TrySetResult(snapshot);
        };
        await client.StartAsync(engine, false, "en", new { enabledProviders = new[] { "codex" }, hideProjects = true, codexExecutable = executable });
        try
        {
            var snapshot = await ready.Task.WaitAsync(TimeSpan.FromSeconds(20));
            var quota = snapshot.Quota.FirstOrDefault(value => value.Provider == "codex");
            bool connected = snapshot.Sources.Any(value => value.Id == "codex:quota" && value.Available);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                connected, stale = quota?.Stale,
                failure = snapshot.Sources.FirstOrDefault(value => value.Id == "codex:quota")?.Failure,
                windows = quota?.Windows.Select(value => new { value.DurationMinutes, value.RemainingPercent }),
                diagnosticAvailable = snapshot.Sources.Any(value => value.Id == "codex:quota" && value.Reason != null)
            }));
            return connected ? 0 : 1;
        }
        catch (TimeoutException)
        {
            Console.WriteLine("{\"connected\":false,\"timeout\":true}"); return 1;
        }
    }

    private static async Task Fixture(string mode)
    {
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);
        async Task Write(object value)
        {
            byte[] data = JsonSerializer.SerializeToUtf8Bytes(value).Concat(new byte[] { 10 }).ToArray();
            Stream output = Console.OpenStandardOutput();
            if (mode == "fragmented") { foreach (byte part in data) await output.WriteAsync(new[] { part }); }
            else await output.WriteAsync(data);
            await output.FlushAsync();
        }
        await Write(new { protocolVersion = mode == "incompatible" ? 99 : 1, type = "hello", engine = "PacerEngine" });
        if (mode == "incompatible") { await Task.Delay(Timeout.Infinite); return; }
        ulong sequence = 0;
        Process? child = null;
        while (await Console.In.ReadLineAsync() is string line)
        {
            using var document = JsonDocument.Parse(line);
            string method = document.RootElement.GetProperty("method").GetString()!;
            string id = document.RootElement.GetProperty("id").GetString()!;
            if (method == "shutdown")
            {
                if (mode == "hang") { await Task.Delay(Timeout.Infinite); return; }
                await Write(new { protocolVersion = 1, type = "result", id, ok = true }); return;
            }
            if (mode == "hang" && child == null)
            {
                var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
                start.ArgumentList.Add("--hold"); child = Process.Start(start)!;
            }
            sequence++;
            await Write(new
            {
                protocolVersion = 1, type = "snapshot", sequence = mode == "outOfOrder" ? 1UL : sequence,
                demo = true, capturedAt = 1000,
                tasks = new[] { new { id = child?.Id.ToString() ?? "fixture", provider = "codex", title = "Fixture",
                    source = "local", phase = "running", stage = "thinking", stageLabel = "思考中" } },
                requests = Array.Empty<object>(), sources = Array.Empty<object>(), quota = Array.Empty<object>(), notices = Array.Empty<object>(),
                runningCount = 1, waitingCount = 0, rateIsFresh = false
            });
            await Write(new { protocolVersion = 1, type = "result", id, ok = true });
        }
    }
}
