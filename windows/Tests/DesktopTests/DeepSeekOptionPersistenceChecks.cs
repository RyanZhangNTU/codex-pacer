using System.Reflection;
using System.Text.Json;
using CodexPacer.Windows;

internal static class DeepSeekOptionPersistenceChecks
{
    internal static async Task Run(string enginePath)
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-deepseek-options-中文 space-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        string file = Path.Combine(root, "preferences.json");
        try
        {
            var store = new PreferencesStore(file);
            var initial = store.Load().Value with { ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "enabled" } };
            Check(store.Save(initial), "The isolated budget profile initializes");
            await using var engine = new EngineClient(); await engine.StartAsync(enginePath, true, "en", initial.EngineConfiguration(), true);
            var session = new PreferencesSession(initial, value => engine.SendAsync("configure", value), store.Save,
                value => PreferencesAcknowledgement.ValidateAsync(engine, value));
            (string Field, object? Value)[] options = [
                ("DeepSeekMode", "budget"), ("DeepSeekDailyBudget", 12.5), ("DeepSeekWeeklyBudget", 75.0),
                ("DeepSeekRingPeriod", "week"), ("DeepSeekRingPeriod", "day"),
                ("DeepSeekMode", "balance"), ("DeepSeekMode", "budget"),
                ("DeepSeekPanelStyle", "simple"), ("DeepSeekPanelStyle", "detailed"),
                ("DeepSeekSpeedSource", "account"), ("DeepSeekSpeedSource", "local"),
                ("DeepSeekShowsTurnCost", false), ("DeepSeekShowsTurnCost", true),
                ("DeepSeekLowBalanceLine", 18.5), ("DeepSeekLowBalanceLine", null),
                ("DeepSeekSpikeLimit", 6.5), ("DeepSeekSpikeLimit", null),
                ("DeepSeekBalanceSource", "web"), ("DeepSeekBalanceSource", "apiKey"), ("DeepSeekBalanceSource", "automatic"),
                ("QuotaRingOuter", "deepseek"), ("QuotaRingInner", "deepseek"), ("QuotaRingOuter", "none"), ("QuotaRingInner", "none"),
                ("DeepSeekDailyBudget", null), ("DeepSeekWeeklyBudget", null)
            ];
            foreach (var option in options)
            {
                PropertyInfo field = typeof(DesktopPreferences).GetProperty(option.Field)!;
                Check(await session.ChangeAsync(value => { var next = value with { }; field.SetValue(next, option.Value); return next; }) == PreferencesApplyResult.Applied,
                    option.Field + " must acknowledge before saving");
                var restored = new PreferencesStore(file).Load();
                Check(!restored.Unavailable && JsonSerializer.Serialize(field.GetValue(restored.Value)) == JsonSerializer.Serialize(option.Value),
                    option.Field + " must survive a new preference store");
                using var document = JsonDocument.Parse(File.ReadAllBytes(file));
                int version = document.RootElement.GetProperty("schemaVersion").GetInt32();
                string key = char.ToLowerInvariant(option.Field[0]) + option.Field[1..];
                if (key.StartsWith("deepSeek", StringComparison.Ordinal)) key = "deepseek" + key[8..];
                bool present = document.RootElement.TryGetProperty(key, out var saved);
                Check(version == PreferencesCodec.Version && version == 2 && (option.Value == null ? !present || saved.ValueKind == JsonValueKind.Null : present), "Schema 2 must retain the Mac option key and missing/null amount semantics");
                await using var restarted = new EngineClient();
                await restarted.StartAsync(enginePath, true, "en", restored.Value.EngineConfiguration(), true);
                Check(restarted.LatestSnapshot?.Modules?.Single(value => value.Provider == "deepseek").Enabled == true,
                    "A fresh engine must restore the saved single-service configuration");
                if (restored.Value.DeepSeekBalanceSource != "apiKey")
                {
                    var wallet = restarted.LatestSnapshot?.Wallet;
                    Check(wallet?.Solo != null, "Saved options must reach the shared single-service projection after engine restart");
                    int expected = restored.Value.DeepSeekMode == "budget" ? (restored.Value.DeepSeekDailyBudget != null ? 1 : 0) + (restored.Value.DeepSeekWeeklyBudget != null ? 1 : 0) : 0;
                    Check(wallet!.Solo!.Budgets.Count == expected, "Balance mode retains amounts without applying them; cleared amounts remain off after restart");
                }
            }
            Check(!File.ReadAllText(file).Contains("sk-", StringComparison.Ordinal), "Options never persist an API credential");
            Console.WriteLine("PASS 26 DeepSeek option writes, storage reloads and independent engine restarts; budget, source, speed, panel, rings, costs and reminder defaults");
        }
        finally { foreach (string entry in Directory.EnumerateFiles(root)) File.Delete(entry); Directory.Delete(root); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
