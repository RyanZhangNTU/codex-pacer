using System.Text.Json;
using CodexPacer.Windows;

internal static class PreferencesChecks
{
    internal static DesktopPreferences Run()
    {
        string root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "pacer-prefs-" + Guid.NewGuid().ToString("N")));
        string file = Path.Combine(root, "preferences.json");
        // Maintenance's inspection mode must remain read-only, including on damage.
        var store = new PreferencesStore(file, recoverDamagedFiles: false);
        try
        {
            var missing = store.Load();
            Check(!missing.Unavailable && missing.Value.IsValid && !Directory.Exists(root), "Missing settings must use defaults without creating files");
            Check(missing.Value.IslandAppearance == "liquidGlass", "The appearance default matches the Mac preference");
            Check(missing.Value.ShowEmbeddedCodexSessions && missing.Value.ShowEmbeddedClaudeSessions, "Both independent embedding preferences default to visible");
            var original = new DesktopPreferences
            {
                Language = "zh-Hans", Position = "topRight", DisplayMode = "notch", IslandAppearance = "classic", ExpandedQuotaStyle = "classic", PositionChosen = true, LastSettingsPane = "appearance", HideProjects = true, ShowAppButtons = false, ShowEmbeddedCodexSessions = false, RetentionMinutes = 60,
                CodexHome = @"C:\中文 space\.codex", CodexExecutable = @"C:\tools 中文\codex.exe",
                DeepSeekPanelStyle = "simple", DeepSeekMode = "budget", DeepSeekDailyBudget = 12.5, DeepSeekWeeklyBudget = 70,
                DeepSeekRingPeriod = "week", DeepSeekSpeedSource = "account", DeepSeekShowsTurnCost = false, DeepSeekBalanceSource = "apiKey",
                CompactLayout = "{\"version\":9,\"leading\":[\"firstOutput\",\"activity\"],\"trailing\":[\"quota\"]}",
                CompactSingleTask = "count", CompactMetric = "pace", CodexQuotaWindow = "5h", ClaudeQuotaWindow = "7d", QuotaRingOuter = "claude", QuotaRingInner = "none",
                ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "automatic", ["deepseek"] = "disabled" }
            };
            Check(store.Save(original), "Valid preferences must save");
            var restored = store.Load();
            Check(!restored.Unavailable && restored.Value.Language == "zh-Hans" && restored.Value.Position == "topRight"
                && restored.Value.DisplayMode == "notch" && restored.Value.ExpandedQuotaStyle == "classic" && restored.Value.PositionChosen == true && restored.Value.LastSettingsPane == "appearance"
                && restored.Value.CodexHome == original.CodexHome && restored.Value.CodexExecutable == original.CodexExecutable
                && restored.Value.DeepSeekPanelStyle == "simple" && restored.Value.DeepSeekMode == "budget" && restored.Value.DeepSeekDailyBudget == 12.5
                && restored.Value.DeepSeekWeeklyBudget == 70 && restored.Value.DeepSeekRingPeriod == "week" && restored.Value.DeepSeekSpeedSource == "account" && !restored.Value.DeepSeekShowsTurnCost
                && restored.Value.DeepSeekBalanceSource == "apiKey"
                && restored.Value.CompactLayout == original.CompactLayout && restored.Value.CompactSingleTask == "count" && restored.Value.CompactMetric == "pace"
                && restored.Value.CodexQuotaWindow == "5h" && restored.Value.ClaudeQuotaWindow == "7d" && restored.Value.QuotaRingOuter == "claude" && restored.Value.QuotaRingInner == "none"
                && restored.Value.ProviderModes["codex"] == "disabled" && restored.Value.ProviderModes["claude"] == "automatic"
                && restored.Value.HideProjects && !restored.Value.ShowAppButtons && !restored.Value.ShowEmbeddedCodexSessions && restored.Value.RetentionMinutes == 60, "Unicode source choices, module modes and display preferences must survive relaunch");
            byte[] before = File.ReadAllBytes(file);
            var independentlyHidden = original with { ShowEmbeddedCodexSessions = true, ShowEmbeddedClaudeSessions = false };
            Check(store.Save(independentlyHidden) && store.Load().Value.ShowEmbeddedCodexSessions && !store.Load().Value.ShowEmbeddedClaudeSessions,
                "Hiding Claude embedding cannot borrow or overwrite Codex's separate preference");
            using (var config = JsonDocument.Parse(JsonSerializer.Serialize(independentlyHidden.EngineConfiguration())))
                Check(config.RootElement.GetProperty("showEmbeddedCodexSessions").GetBoolean() && !config.RootElement.GetProperty("showEmbeddedClaudeSessions").GetBoolean(),
                    "The acknowledged engine configuration carries both Mac preference keys independently");
            Check(store.Save(original), "Restore the original saved fixture before rejected-write assertions");
            Check(restored.Value.IslandAppearance == "classic" && JsonDocument.Parse(before).RootElement.GetProperty("islandAppearance").GetString() == "classic",
                "The original appearance key and value survive relaunch");
            Check(!store.Save(original with { IslandAppearance = "unknown" }), "An invalid appearance cannot replace saved settings");
            Check(!store.Save(original with { CodexHome = "relative\\folder" }), "Relative data homes cannot replace saved settings");
            Check(!store.Save(original with { RetentionMinutes = -1 }), "Invalid retention cannot replace saved settings");
            Check(!store.Save(original with { DisplayMode = "unknown" }), "An invalid display mode cannot replace saved settings");
            Check(!store.Save(original with { ExpandedQuotaStyle = "unknown" }), "An invalid quota style cannot replace saved settings");
            Check(!store.Save(original with { CompactLayout = new string('x', 8193) }) && !store.Save(original with { QuotaRingOuter = "foreign" })
                && !store.Save(original with { CompactSingleTask = "foreign" }) && !store.Save(original with { CompactMetric = "foreign" })
                && !store.Save(original with { CodexQuotaWindow = "bad\nvalue" }), "Invalid compact choices cannot replace saved settings");
            Check(!store.Save(original with { DeepSeekPanelStyle = "unknown" }) && !store.Save(original with { DeepSeekMode = "unknown" })
                && !store.Save(original with { DeepSeekDailyBudget = -1 }) && !store.Save(original with { DeepSeekWeeklyBudget = double.PositiveInfinity })
                && !store.Save(original with { DeepSeekBalanceSource = "foreign" }),
                "Invalid or nonfinite spending preferences cannot replace saved settings");
            Check(before.SequenceEqual(File.ReadAllBytes(file)), "Rejected settings must leave the last valid file intact");
            File.WriteAllText(file, "{\"schemaVersion\":1,\"position\":\"bottomRight\"}");
            var legacy = store.Load();
            Check(legacy.Value.ShowEmbeddedClaudeSessions, "An older profile without the Claude embedding key keeps sessions visible");
            Check(legacy.Value.IslandAppearance == "liquidGlass", "A missing appearance uses Liquid Glass without rewriting the profile");
            Check(!legacy.Unavailable && legacy.Value.HasChosenPosition && legacy.Value.DisplayMode == "automatic"
                && legacy.Value.LastSettingsPane == "general" && legacy.Value.ShowEmbeddedCodexSessions && legacy.Value.ExpandedQuotaStyle == "split"
                && legacy.Value.DeepSeekMode == "balance" && legacy.Value.DeepSeekPanelStyle == "detailed" && legacy.Value.DeepSeekDailyBudget == null && legacy.Value.DeepSeekShowsTurnCost
                && legacy.Value.DeepSeekBalanceSource == "automatic", "Older corner choices must remain explicit while new optional settings use defaults");
            File.WriteAllText(file, "{\"schemaVersion\":1,\"position\":\"bottomRight\",\"expandedQuotaStyle\":\"future-style\"}");
            var unknownStyle = store.Load();
            Check(!unknownStyle.Unavailable && unknownStyle.Value.Position == "bottomRight" && unknownStyle.Value.ExpandedQuotaStyle == "split",
                "An unknown quota style must fall back to Split Ring without discarding unrelated choices or rewriting the profile");
            const string futureAppearance = "{\"schemaVersion\":1,\"position\":\"topRight\",\"islandAppearance\":\"future\"}";
            File.WriteAllText(file, futureAppearance);
            var unknownSurface = store.Load();
            Check(!unknownSurface.Unavailable && unknownSurface.Value.IslandAppearance == "liquidGlass" && unknownSurface.Value.Position == "topRight"
                && File.ReadAllText(file) == futureAppearance, "A future appearance falls back without losing other choices or rewriting the file");
            foreach (string damaged in new[]
            {
                "not JSON", "null", "{}", "{\"schemaVersion\":3}", "{\"schemaVersion\":\"one\"}",
                "{\"schemaVersion\":1,\"providerModes\":null}", "{\"schemaVersion\":1,\"retentionMinutes\":-1}",
                new string('x', PreferencesStore.MaximumBytes + 1)
            })
            {
                File.WriteAllText(file, damaged);
                var fallback = store.Load();
                Check(fallback.Unavailable && fallback.Value.IsValid && fallback.Value.Language == "system" && fallback.Value.HideProjects,
                    "Malformed or future settings must fall back without crashing or revealing project names");
                Check(File.ReadAllText(file) == damaged, "Loading must never rewrite a settings file");
            }
            return restored.Value;
        }
        finally
        {
            // This fixture creates files only in its own unique temporary directory.
            if (Directory.Exists(root))
            {
                foreach (string entry in Directory.EnumerateFiles(root, "*", SearchOption.TopDirectoryOnly)) File.Delete(entry);
                Directory.Delete(root);
            }
        }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
