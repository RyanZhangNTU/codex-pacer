using System.Text;
using CodexPacer.Windows;

internal static class PreferencesRecoveryChecks
{
    internal static async Task Run(string root)
    {
        string file = Path.Combine(root, "recovery-中文.json");
        for (int index = 0; index < 6; index++)
        {
            byte[] broken = Encoding.UTF8.GetBytes(index % 2 == 0 ? "{synthetic-damage-" + index : new string('x', PreferencesStore.MaximumBytes + 1));
            File.WriteAllBytes(file, broken);
            var store = new PreferencesStore(file); var loaded = store.Load();
            Check(!loaded.Unavailable && System.Text.Json.JsonSerializer.Serialize(loaded.Value) == System.Text.Json.JsonSerializer.Serialize(new DesktopPreferences()), "Damaged preferences recover the normal defaults");
            string name = store.TakeRecoveryFileName() ?? throw new InvalidOperationException("Missing recovery notice");
            Check(name == Path.GetFileName(name) && name.StartsWith(Path.GetFileName(file) + ".damaged-") && name.Contains('Z'), "The notice exposes only a UTC backup filename");
            Check(store.TakeRecoveryFileName() == null, "The recovery notice is consumed once");
            Check(File.ReadAllBytes(Path.Combine(root, name)).SequenceEqual(broken), "Quarantine preserves every original byte, including an oversized file");
            Check(store.Save(loaded.Value with { Language = "zh-Hans" }) && new PreferencesStore(file).Load().Value.Language == "zh-Hans", "Recovery permits saving and restart without manual file repair");
            Check(Directory.GetFiles(root, Path.GetFileName(file) + ".damaged-*").Length == Math.Min(index + 1, 3), "Only the latest three backups of this original are retained");
        }
        string unrelated = file + ".damaged-user-note"; File.WriteAllText(unrelated, "synthetic-unrelated");
        File.WriteAllText(file, "broken"); _ = new PreferencesStore(file).Load();
        Check(File.ReadAllText(unrelated) == "synthetic-unrelated", "Retention never removes files outside the owned backup grammar");
        byte[] future = Encoding.UTF8.GetBytes("{\"schemaVersion\":999,\"syntheticFutureOption\":true}");
        File.WriteAllBytes(file, future);
        var protectedStore = new PreferencesStore(file); var fallback = protectedStore.Load();
        Check(fallback.Unavailable && protectedStore.HasFutureVersion && protectedStore.TakeRecoveryFileName() == null, "A future profile is protected and has no automatic backup");
        Check(!protectedStore.Save(new()) && File.ReadAllBytes(file).SequenceEqual(future), "Ordinary edits never overwrite a future profile");
        int acknowledgements = 0;
        var session = new PreferencesSession(fallback.Value, _ => Task.CompletedTask, protectedStore.Save, value => { acknowledgements++; return Task.FromResult(value); });
        Check(await session.RecoverDefaultsAsync(protectedStore.BackupAndUseDefaults) == PreferencesApplyResult.Applied && acknowledgements == 1,
            "Explicit recovery still waits for the normal engine acknowledgement");
        string backup = protectedStore.TakeRecoveryFileName()!;
        Check(File.ReadAllBytes(Path.Combine(root, backup)).SequenceEqual(future) && !protectedStore.HasFutureVersion, "Confirmed recovery quarantines, rather than erases, the future bytes");
        Check(!new PreferencesStore(file).Load().Unavailable && protectedStore.Save(session.Current with { Language = "en" }), "Confirmed defaults and subsequent edits survive restart");
        File.WriteAllBytes(file, future); var stale = new PreferencesStore(file); _ = stale.Load();
        byte[] changed = Encoding.UTF8.GetBytes("{\"schemaVersion\":1000}"); File.WriteAllBytes(file, changed);
        Check(!stale.BackupAndUseDefaults(new()) && File.ReadAllBytes(file).SequenceEqual(changed), "Confirmation cannot discard another writer's newer file");
        var declined = new PreferencesStore(file); _ = declined.Load();
        var rejected = new PreferencesSession(new(), _ => Task.CompletedTask, declined.Save, _ => Task.FromException<DesktopPreferences>(new IOException("synthetic acknowledgement failure")));
        Check(await rejected.RecoverDefaultsAsync(declined.BackupAndUseDefaults) == PreferencesApplyResult.EngineFailed && File.ReadAllBytes(file).SequenceEqual(changed),
            "A rejected acknowledgement cannot quarantine the future profile");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
