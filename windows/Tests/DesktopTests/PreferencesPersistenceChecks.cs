using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexPacer.Windows;

internal static class PreferencesPersistenceChecks
{
    internal static async Task Run(string enginePath)
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-persistence-中文-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            await using var engine = new EngineClient();
            await engine.StartAsync(enginePath, true, "en", referenceFixture: true);
            foreach (string method in new[] { "storageRecoveryStatus", "recoverFutureStorage" })
            {
                var status = await engine.QueryAsync<JsonElement>(method);
                Check(status.TryGetProperty("futureFiles", out var files) && files.GetArrayLength() == 0 && !engine.IsConnectionClosed,
                    "Recovery replies must pass the production protocol parser and keep demo isolated from real stores");
            }
            var alternate = new DesktopPreferences
            {
                Language = "zh-Hans", Position = "bottomRight", PositionChosen = true, DisplayMode = "floating", IslandAppearance = "classic",
                ExpandedQuotaStyle = "classic", CompactLayout = "{\"version\":9,\"leading\":[],\"trailing\":[],\"warnings\":[\"ssh\"]}",
                CompactSingleTask = "count", CompactMetric = "pace", CodexQuotaWindow = "7d", ClaudeQuotaWindow = "5h", QuotaRingOuter = "none", QuotaRingInner = "deepseek",
                DeepSeekPanelStyle = "simple", DeepSeekMode = "budget", DeepSeekBalanceSource = "apiKey", DeepSeekDailyBudget = 25, DeepSeekWeeklyBudget = 120,
                DeepSeekRingPeriod = "week", DeepSeekSpeedSource = "account", DeepSeekShowsTurnCost = false, SystemNotifications = true,
                WarningKinds = ["ssh"], DeepSeekLowBalanceLine = 15, DeepSeekSpikeLimit = 8, LastSettingsPane = "collapsed", HideProjects = true,
                ShowAppButtons = false, ShowEmbeddedCodexSessions = false, MonitorRemoteControl = false, MonitorWSL = false, ShowClaudeCloudProjects = false, RetentionMinutes = 240,
                CodexExecutable = @"C:\合成 path\codex.exe", CodexHome = @"C:\合成 path\.codex", ClaudeHome = @"C:\合成 path\.claude",
                ClaudeOrganization = "11111111-1111-4111-8111-111111111111", DeepseekHome = @"C:\合成 path\.dsh",
                ProviderModes = new() { ["codex"] = "enabled", ["claude"] = "disabled", ["deepseek"] = "automatic" }
            };
            var properties = typeof(DesktopPreferences).GetProperties(BindingFlags.Public | BindingFlags.Instance).Where(p => p.Name != "SchemaVersion").ToArray();
            int acknowledged = 0;
            foreach (var property in properties)
            {
                string file = Path.Combine(root, property.Name + ".json");
                var store = new PreferencesStore(file);
                var initial = store.Load().Value;
                await engine.SendAsync("configure", initial.EngineConfiguration());
                var session = new PreferencesSession(initial, value => engine.SendAsync("configure", value), store.Save, async value =>
                { acknowledged++; return await PreferencesAcknowledgement.ValidateAsync(engine, value); });
                Check(await session.ChangeAsync(value =>
                {
                    var next = value with { }; property.SetValue(next, property.GetValue(alternate));
                    if (property.Name == "CompactLayout") next = next with { WarningKinds = alternate.WarningKinds };
                    return next;
                }) == PreferencesApplyResult.Applied, property.Name + " must acknowledge and commit");
                var restart = new PreferencesStore(file).Load();
                Check(!restart.Unavailable, property.Name + " must survive a fresh store");
                Check(JsonSerializer.Serialize(property.GetValue(restart.Value)) == JsonSerializer.Serialize(property.GetValue(session.Current)), property.Name + " must survive restart without losing its value");
                Check(JsonDocument.Parse(File.ReadAllBytes(file)).RootElement.GetProperty("schemaVersion").GetInt32() == PreferencesCodec.Version, "Edits use the current storage schema");
            }
            Check(acknowledged == properties.Length, "Every persisted option must receive an engine acknowledgement, including host-only options");
            Check(properties.Length >= 37, "The persistence table must cover every public option");
            await CheckAcknowledgement();
            CheckTransactions(root);
            CheckCanonicalKeys(root);
            await PreferencesRecoveryChecks.Run(root);
        }
        finally { foreach (string file in Directory.EnumerateFiles(root)) File.Delete(file); Directory.Delete(root); }
    }
    private static async Task CheckAcknowledgement()
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int commands = 0, saves = 0;
        var session = new PreferencesSession(new(), _ => { commands++; return Task.CompletedTask; }, _ => { saves++; return true; },
            async value => { await gate.Task; return value; });
        var pending = session.ChangeAsync(value => value with { Language = "zh-Hans" });
        Check(!pending.IsCompleted && !session.Current.HideProjects && saves == 0 && commands == 0,
            "Host-only choices wait asynchronously for acknowledgement before touching disk or current state");
        gate.SetResult();
        Check(await pending == PreferencesApplyResult.Applied && saves == 1 && commands == 0,
            "Read-only preference acknowledgement never reconfigures collectors");
        var failed = new PreferencesSession(new(), _ => { commands++; return Task.CompletedTask; }, _ => { saves++; return true; },
            _ => Task.FromException<DesktopPreferences>(new IOException("Synthetic acknowledgement failure")));
        Check(await failed.ChangeAsync(value => value with { HideProjects = true }) == PreferencesApplyResult.EngineFailed
            && !failed.Current.HideProjects && saves == 1 && commands == 0, "A failed read-only acknowledgement cannot configure or save an edit");
    }
    private static void CheckTransactions(string root)
    {
        string file = Path.Combine(root, "concurrent.json"); var seed = new PreferencesStore(file);
        Check(seed.Save(new()), "Synthetic preferences initialize");
        var first = new PreferencesStore(file); var second = new PreferencesStore(file);
        var a = first.Load().Value; var b = second.Load().Value;
        Check(first.Save(a with { HideProjects = true }), "The first independent writer commits");
        byte[] before = File.ReadAllBytes(file);
        Check(!second.Save(b with { Language = "zh-Hans" }) && before.SequenceEqual(File.ReadAllBytes(file)), "A stale writer cannot erase another process's privacy edit");
        Check(second.Save(second.Load().Value with { Language = "zh-Hans" }) && new PreferencesStore(file).Load().Value.HideProjects,
            "A refreshed writer preserves the first edit");
        foreach (string damaged in new[] { "not JSON", "{\"schemaVersion\":3}", "{\"schemaVersion\":2,\"compactIslandLayout\":\"%%%\"}", new string('x', PreferencesStore.MaximumBytes + 1) })
        {
            File.WriteAllText(file, damaged); var store = new PreferencesStore(file, recoverDamagedFiles: false);
            Check(store.Load().Unavailable, "A damaged profile is reported");
            Check(!store.Save(new()) && File.ReadAllText(file) == damaged, "Saving after a failed read must preserve the original bytes");
        }
    }
    private static void CheckCanonicalKeys(string root)
    {
        string file = Path.Combine(root, "keys.json");
        File.WriteAllText(file, "{\"schemaVersion\":2,\"appLanguage\":\"future\",\"islandDisplayMode\":\"future\",\"floatingIsland\":true,\"compactSingleTask\":\"future\",\"compactMetric\":\"future\",\"quotaRingOuter\":\"\",\"quotaRingInner\":\"future\",\"futureOption\":42}");
        var store = new PreferencesStore(file); var value = store.Load();
        Check(!value.Unavailable && value.Value.Language == "system" && value.Value.CompactSingleTask == "stage" && value.Value.CompactMetric == "remaining", "Unknown preference strings use the Mac defaults");
        Check(value.Value.DisplayMode == "floating", "An unknown display mode retains the Mac legacy floatingIsland fallback");
        Check(value.Value.QuotaRingOuter == "none" && value.Value.QuotaRingInner == "none", "Present empty or unknown rings mean no ring");
        Check(!value.Value.HasChosenPosition && value.Value.QuotaRingInner != new DesktopPreferences().QuotaRingInner, "Missing choices remain distinct from explicit empty ring choices");
        Check(store.Save(value.Value with { LastSettingsPane = "collapsed", RetentionMinutes = 60, Language = "en" }), "Canonical choices save");
        var saved = JsonNode.Parse(File.ReadAllBytes(file))!.AsObject();
        Check(saved["appLanguage"]!.GetValue<string>() == "en" && saved["settingsPane"]!.GetValue<string>() == "collapsedBar"
            && saved["completedRetentionMinutes"]!.GetValue<int>() == 60 && saved["futureOption"]!.GetValue<int>() == 42,
            "Mac keys and unknown future keys survive an edit");
        Check(!saved.ContainsKey("language") && !saved.ContainsKey("retentionMinutes") && !saved.ContainsKey("providerModes") && !saved.ContainsKey("islandPosition"), "The new profile has no duplicate aliases or invented position choice");
        File.WriteAllText(file, "{\"schemaVersion\":1,\"language\":\"zh-Hans\",\"position\":\"topLeft\",\"quotaRingOuter\":\"\"}");
        var legacy = new PreferencesStore(file); var old = legacy.Load();
        Check(!old.Unavailable && old.Value.HasChosenPosition && old.Value.QuotaRingOuter == "", "Version 1 keeps its corner and automatic ring semantics");
        Check(legacy.Save(old.Value) && new PreferencesStore(file).Load().Value.Language == "zh-Hans", "Legacy preferences migrate on the next successful edit");
        Check(!JsonNode.Parse(File.ReadAllBytes(file))!.AsObject().ContainsKey("quotaRingOuter"), "A migrated automatic ring is absent, as in Mac UserDefaults");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
