using System.Text.Json;
using CodexPacer.Windows;

internal static class GuideControlChecks
{
    internal static async Task Run()
    {
        foreach (bool codex in new[] { false, true }) foreach (bool claude in new[] { false, true })
        {
            var value = new DesktopPreferences { ShowEmbeddedCodexSessions = codex, ShowEmbeddedClaudeSessions = claude, HideProjects = true };
            Check(GuideControls.ShowsEmbedded(value) == (codex && claude), "The legacy combined switch is on only when both provider switches are on");
            foreach (bool enabled in new[] { false, true })
            {
                var changed = GuideControls.SetEmbedded(value, enabled);
                Check(changed.ShowEmbeddedCodexSessions == enabled && changed.ShowEmbeddedClaudeSessions == enabled
                    && changed with { ShowEmbeddedCodexSessions = codex, ShowEmbeddedClaudeSessions = claude } == value,
                    "One combined edit changes both providers and preserves unrelated preferences");
                using var configuration = JsonDocument.Parse(JsonSerializer.Serialize(changed.EngineConfiguration()));
                Check(configuration.RootElement.GetProperty("showEmbeddedCodexSessions").GetBoolean() == enabled
                    && configuration.RootElement.GetProperty("showEmbeddedClaudeSessions").GetBoolean() == enabled,
                    "Both provider choices cross the existing engine configuration boundary");
            }
        }
        string file = Path.Combine(AppContext.BaseDirectory, "guide-controls-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new PreferencesStore(file); _ = store.Load(); int configurations = 0; bool reject = false;
            var initial = new DesktopPreferences { HideProjects = true, ShowEmbeddedCodexSessions = true, ShowEmbeddedClaudeSessions = false };
            var session = new PreferencesSession(initial, _ => { configurations++; return Task.CompletedTask; }, value => !reject && store.Save(value));
            Check(await session.ChangeAsync(value => GuideControls.SetEmbedded(value, true)) == PreferencesApplyResult.Applied
                && configurations == 1 && GuideControls.ShowsEmbedded(session.Current), "A combined edit is applied and saved as one acknowledged change");
            var restarted = new PreferencesStore(file).Load();
            Check(!restarted.Unavailable && GuideControls.ShowsEmbedded(restarted.Value) && restarted.Value.HideProjects,
                "Schema 2 reads both independent provider keys after reopening");
            using var saved = JsonDocument.Parse(File.ReadAllBytes(file));
            Check(saved.RootElement.GetProperty("showEmbeddedCodexSessions").GetBoolean() && saved.RootElement.GetProperty("showEmbeddedClaudeSessions").GetBoolean(),
                "The combined control keeps the Mac-compatible independent storage keys");
            reject = true;
            Check(await session.ChangeAsync(value => GuideControls.SetEmbedded(value, false)) == PreferencesApplyResult.SaveFailed
                && configurations == 3 && GuideControls.ShowsEmbedded(session.Current) && GuideControls.ShowsEmbedded(new PreferencesStore(file).Load().Value),
                "A rejected save restores both acknowledged engine flags and leaves the saved pair intact");
        }
        finally { File.Delete(file); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
