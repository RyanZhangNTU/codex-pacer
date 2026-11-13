using Microsoft.Win32;
using CodexPacer.Windows;

internal static class SettingsServiceChecks
{
    internal static void Run()
    {
        // This isolated key is never an OS startup location.
        string parent = @"Software\CodexPacer\Tests";
        string name = Guid.NewGuid().ToString("N"), key = parent + "\\" + name;
        try
        {
            using (var fixture = Registry.CurrentUser.CreateSubKey(key)) fixture.SetValue("OtherFixture", "preserve");
            var startup = new WindowsStartupRegistration(@"C:\fixture 中文 space\CodexPacer.exe", key);
            Check(startup.Read() == new StartupRegistrationState(false, true), "The fixture must start without a Pacer entry");
            Check(startup.Set(true) && startup.Read().Registered, "Enabling must register only Pacer");
            using (var fixture = Registry.CurrentUser.OpenSubKey(key))
            {
                Check((string?)fixture?.GetValue("CodexPacer") == "\"C:\\fixture 中文 space\\CodexPacer.exe\" --launch-at-login", "The executable path must stay quoted");
                Check((string?)fixture?.GetValue("OtherFixture") == "preserve", "Other entries must be preserved");
            }
            Check(startup.Set(false) && !startup.Read().Registered, "Disabling must remove Pacer's own value");
            Check(!new WindowsStartupRegistration("C:\\" + new string('x', 260) + "\\CodexPacer.exe", key).Set(true), "An oversized Run command cannot be registered");
        }
        finally { Registry.CurrentUser.DeleteSubKey(key, throwOnMissingSubKey: false); }

        var opened = new List<string>();
        var apps = new WindowsDesktopApplications(family => family.StartsWith("OpenAI.Codex_", StringComparison.Ordinal),
            value => { opened.Add(value); return true; });
        Check(apps.Available().Select(value => value.Provider).SequenceEqual(["codex"]), "Only registered desktop apps belong in the catalog");
        Check(!apps.Open("claude") && !apps.Open("unknown;command"), "Missing and unknown providers cannot launch anything");
        Check(apps.Open("codex") && opened.SequenceEqual(["OpenAI.Codex_2p2nqsd0c76g0!App"]), "Activation must use the verified package identity");
        Check(!new WindowsDesktopApplications(_ => true, _ => false).Open("claude"), "Activation failures must remain failures");

        string root = Path.Combine(Path.GetTempPath(), "pacer-wsl-migration-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string profile = Path.Combine(root, "preferences.json");
        try
        {
            int evidenceReads = 0;
            Func<string, bool> usedDot = _ => { evidenceReads++; return true; }, neverUsedDot = _ => { evidenceReads++; return false; };
            var defaults = new PreferencesStore(profile).Load(migrateOptIns: true, durableEvidence: usedDot).Value;
            Check(!defaults.MonitorWSL && !defaults.MonitorRemoteControl && !defaults.MonitorDurable && evidenceReads == 0,
                "New profiles opt in to every kind of remote monitoring, including Dot");
            File.WriteAllText(profile, """{"schemaVersion":1,"monitorWSL":true,"monitorRemoteControl":true,"hideProjects":true,"otherPreference":true}""");
            var store = new PreferencesStore(profile);
            var migrated = store.Load(migrateOptIns: true, durableEvidence: neverUsedDot).Value;
            Check(!migrated.MonitorWSL && migrated.WslOptInMigrated && migrated.MonitorRemoteControl && migrated.HideProjects,
                "The upgrade closes WSL and preserves the user's other choices");
            Check(!migrated.MonitorDurable && migrated.DurableOptInMigrated && evidenceReads == 1, "A profile that never used Dot upgrades with Dot off");
            Check(File.ReadAllText(profile).Contains("otherPreference", StringComparison.Ordinal), "Unknown settings survive the migration");
            Check(store.Save(migrated with { MonitorWSL = true }), "The user can opt back in");
            Check(new PreferencesStore(profile).Load(migrateOptIns: true, durableEvidence: usedDot).Value is { MonitorWSL: true, MonitorDurable: false }
                && evidenceReads == 1, "Relaunch preserves the new opt-in and never re-decides Dot");

            File.WriteAllText(profile, """{"schemaVersion":1,"monitorWSL":false,"wslOptInMigrated":true}""");
            var dotUser = new PreferencesStore(profile).Load(migrateOptIns: true, durableEvidence: usedDot).Value;
            Check(dotUser.MonitorDurable && dotUser.DurableOptInMigrated && evidenceReads == 2, "A profile with Dot receipts keeps Dot after the upgrade");
            Check(new PreferencesStore(profile).Load(migrateOptIns: true, durableEvidence: neverUsedDot).Value.MonitorDurable && evidenceReads == 2,
                "The upgrade decision is saved once");
            File.WriteAllText(profile, """{"schemaVersion":1}""");
            Check(!new PreferencesStore(profile).Load(migrateOptIns: false, durableEvidence: usedDot).Value.MonitorDurable && evidenceReads == 2,
                "Demo and read-only loads never migrate");

            string codexHome = Path.Combine(root, "codex"), receipts = Path.Combine(codexHome, DurableUsageEvidence.ReceiptsPath);
            Check(!DurableUsageEvidence.HasReceipts(codexHome), "A Codex home without receipts is not Dot evidence");
            Directory.CreateDirectory(Path.GetDirectoryName(receipts)!);
            File.WriteAllText(receipts, "{}");
            Check(!DurableUsageEvidence.HasReceipts(codexHome), "An empty mailbox is not Dot evidence");
            File.WriteAllText(receipts, """{"a:b":{"threadID":"a","turnID":"b","callID":"c","percent":40,"at":0}}""");
            Check(DurableUsageEvidence.HasReceipts(codexHome), "A recorded receipt is Dot evidence, however old");
            File.WriteAllText(receipts, "not json");
            Check(!DurableUsageEvidence.HasReceipts(codexHome), "A damaged mailbox is not Dot evidence");
            Directory.Delete(codexHome, recursive: true);
        }
        finally { File.Delete(profile); Directory.Delete(root); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
