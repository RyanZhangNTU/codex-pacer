using System.Text.Json;
using CodexPacer.Windows;
using Microsoft.Win32;

internal static class InstallationServiceChecks
{
    internal static void Run()
    {
        string fixture = Path.Combine(Path.GetTempPath(), "pacer-install-unit-中文-" + Guid.NewGuid().ToString("N"));
        var identity = new WindowsInstallationIdentity(Path.Combine(fixture, "app space"), Guid.NewGuid());
        Directory.CreateDirectory(identity.Root);
        File.WriteAllText(Path.Combine(identity.Root, WindowsInstallationIdentity.ContextFile),
            JsonSerializer.Serialize(new { schemaVersion = 1, qaScope = identity.Scope }));
        var store = new StartupRegistrationChecks.Store();
        var links = new Links();
        // Never the real desktop: the fixture holds the desktop shortcut.
        var placed = identity with { DesktopFolder = Path.Combine(fixture, "desktop") };
        var operations = new WindowsInstallationOperations(placed, store, links);
        try
        {
            Directory.CreateDirectory(identity.DataRoot);
            byte[] preference = "synthetic preference-private"u8.ToArray(), read = "synthetic read-private"u8.ToArray();
            File.WriteAllBytes(Path.Combine(identity.DataRoot, "preferences-v1.json"), preference);
            File.WriteAllBytes(Path.Combine(identity.DataRoot, "completion-dismissals-v1.json"), read);
            try { operations.AddShortcut(InstallShortcut.Desktop); throw new InvalidOperationException("A shortcut was added before registration."); }
            catch (InvalidDataException) { }
            operations.Register();
            Check(WindowsInstallationIdentity.Load(identity.Root, identity.QaScope, true) == identity, "The package identity must round-trip independently of user preferences");
            Check((string?)store.Read(identity.RegistryKey, "Path")?.Value == identity.Root && !File.Exists(identity.Shortcut) && !File.Exists(placed.DesktopShortcut),
                "Registration alone records this location and adds no shortcut the person has not chosen");
            operations.AddShortcut(InstallShortcut.StartMenu);
            operations.AddShortcut(InstallShortcut.Desktop);
            Check(links.Target(identity.Shortcut) == identity.Executable && links.Target(placed.DesktopShortcut) == identity.Executable &&
                (string?)store.Read(identity.RegistryKey, "DesktopShortcutPath")?.Value == placed.DesktopShortcut,
                "The finish-page choices add owned Start menu and desktop shortcuts");
            string beforeHash = WindowsInstallShortcuts.Digest(identity.Shortcut)!, desktopHash = WindowsInstallShortcuts.Digest(placed.DesktopShortcut)!;
            operations.Register();
            Check(links.Target(identity.Shortcut) == identity.Executable && WindowsInstallShortcuts.Digest(identity.Shortcut) == beforeHash &&
                WindowsInstallShortcuts.Digest(placed.DesktopShortcut) == desktopHash,
                "A same-version repair or silent update must keep valid owned shortcuts");
            File.Delete(placed.DesktopShortcut);
            operations.Register();
            Check(!File.Exists(placed.DesktopShortcut) && store.Read(identity.RegistryKey, "DesktopShortcutHash") == null && File.Exists(identity.Shortcut),
                "An update must not bring back a shortcut the person deleted");
            operations.AddShortcut(InstallShortcut.Desktop);
            Check(File.ReadAllBytes(Path.Combine(identity.DataRoot, "preferences-v1.json")).SequenceEqual(preference) &&
                File.ReadAllBytes(Path.Combine(identity.DataRoot, "completion-dismissals-v1.json")).SequenceEqual(read),
                "Install and repair cannot modify preferences or read state outside the application directory");
            store.Put(identity.RegistryKey, "OtherFixture", new("preserve", RegistryValueKind.String));
            operations.RemoveOwnedRegistrations();
            Check(!File.Exists(identity.Shortcut) && !File.Exists(placed.DesktopShortcut) && store.Read(identity.RegistryKey, "Path") == null &&
                (string?)store.Read(identity.RegistryKey, "OtherFixture")?.Value == "preserve",
                "Uninstall must remove its shortcuts and known values while preserving an unrelated value");
            Check(Directory.Exists(identity.DataRoot), "Uninstall cannot delete retained data");
            var removed = store.Snapshot();
            operations.RemoveOwnedRegistrations();
            Check(store.Same(removed), "Retrying completed registration cleanup must be idempotent and preserve unrelated values");
            operations.Register();
            store.FailDeleteAfter = (identity.RegistryKey, "Path");
            try { operations.RemoveOwnedRegistrations(); throw new InvalidOperationException("An uninstall failure was swallowed."); }
            catch (UnauthorizedAccessException) { }
            Check((string?)store.Read(identity.RegistryKey, "Path")?.Value == identity.Root &&
                store.Read(identity.RegistryKey, "SchemaVersion") is { Value: 1 }, "Partial removal must retain ownership proof for Retry");
            operations.RemoveOwnedRegistrations();
            Check(store.Read(identity.RegistryKey, "Path") == null && (string?)store.Read(identity.RegistryKey, "OtherFixture")?.Value == "preserve",
                "Retry after partial removal must finish without deleting a foreign value");

            Directory.CreateDirectory(Path.GetDirectoryName(identity.Shortcut)!);
            File.WriteAllText(identity.Shortcut, @"C:\synthetic other application.exe");
            operations.Register();
            operations.AddShortcut(InstallShortcut.StartMenu);
            Check(File.ReadAllText(identity.Shortcut) == @"C:\synthetic other application.exe" &&
                store.Read(identity.RegistryKey, "ShortcutHash") == null, "Install cannot replace or claim a pre-existing foreign shortcut");
            operations.RemoveOwnedRegistrations();
            Check(File.Exists(identity.Shortcut), "Uninstall must preserve that foreign shortcut");
            File.Delete(identity.Shortcut);

            operations.Register();
            operations.AddShortcut(InstallShortcut.StartMenu);
            operations.AddShortcut(InstallShortcut.Desktop);
            File.AppendAllText(identity.Shortcut, " user modification");
            File.AppendAllText(placed.DesktopShortcut, " user modification");
            operations.RemoveOwnedRegistrations();
            Check(File.Exists(identity.Shortcut) && File.Exists(placed.DesktopShortcut), "A user-modified shortcut must no longer be deleted as owned");
            File.Delete(identity.Shortcut);
            File.Delete(placed.DesktopShortcut);

            var before = store.Snapshot();
            store.FailWriteAfter = (identity.RegistryKey, "Path");
            try { operations.Register(); throw new InvalidOperationException("The registration failure was swallowed."); }
            catch (IOException) { }
            Check(store.Same(before) && !File.Exists(identity.Shortcut), "Registration failure must restore the original registry values and shortcut");
            try { WindowsInstallationIdentity.Load(identity.Root, Guid.NewGuid(), true); throw new InvalidOperationException("A foreign installation scope was accepted."); }
            catch (InvalidDataException) { }
            File.WriteAllText(Path.Combine(identity.Root, WindowsInstallationIdentity.ContextFile), "{\"schemaVersion\":99}");
            try { WindowsInstallationIdentity.ForApp(identity.Root); throw new InvalidOperationException("An unsupported identity was accepted."); }
            catch (InvalidDataException) { }
            Check(!new UnavailableStartupRegistration().Read().Available, "Unreadable installation metadata must leave a usable Settings error state");
        }
        finally
        {
            if (File.Exists(identity.Shortcut)) File.Delete(identity.Shortcut);
            string menu = Path.GetDirectoryName(identity.Shortcut)!;
            if (Directory.Exists(menu) && !Directory.EnumerateFileSystemEntries(menu).Any()) Directory.Delete(menu, false);
            if (!Path.GetFullPath(fixture).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase) ||
                !Path.GetFileName(fixture).StartsWith("pacer-install-unit-", StringComparison.Ordinal)) throw new InvalidOperationException("Unsafe fixture cleanup.");
            Directory.Delete(fixture, true);
        }
        NotificationOwnership();
        StaleFiles();
    }
    private static void NotificationOwnership()
    {
        const string executable = @"C:\synthetic test\Pacer\CodexPacer.exe";
        var store = new StartupRegistrationChecks.Store();
        Check(NotificationRegistration.Find(executable, store) == null && store.Snapshot().Count == 0,
            "Uninstall of an app without notifications must not create a new SDK registration");
        string mapping = NotificationRegistration.Root + executable.Replace('\\', '.');
        string app = Guid.NewGuid().ToString("B"), activator = Guid.NewGuid().ToString("B");
        store.Put(mapping, "NotificationGUID", new(app, RegistryValueKind.String));
        store.Put(NotificationRegistration.Root + app, "CustomActivator", new(activator, RegistryValueKind.String));
        string server = @"Software\Classes\CLSID\" + activator + @"\LocalServer32";
        store.Put(server, "", new("\"" + executable + "\" ----AppNotificationActivated:", RegistryValueKind.String));
        var own = NotificationRegistration.Find(executable, store)!;
        store.Put(mapping, "UserFixture", new("preserve", RegistryValueKind.String));
        own.RemoveMapping(store);
        Check(store.Read(mapping, "NotificationGUID") == null && (string?)store.Read(mapping, "UserFixture")?.Value == "preserve",
            "SDK cleanup must remove only its own path mapping value");
        store.Put(mapping, "NotificationGUID", new(app, RegistryValueKind.String));
        store.Put(server, "", new("\"C:\\synthetic other.exe\" ----AppNotificationActivated:", RegistryValueKind.String));
        var before = store.Snapshot();
        try { NotificationRegistration.Find(executable, store); throw new InvalidOperationException("A foreign COM server was accepted."); }
        catch (InvalidDataException) { }
        Check(store.Same(before), "A modified activation record must be preserved without touching its foreign server");
    }
    // An upgrade removes files the old manifest listed and the new one does
    // not, only while they still hold the old content and stay in the folder.
    private static void StaleFiles()
    {
        string fixture = Path.Combine(Path.GetTempPath(), "pacer-stale-中文-" + Guid.NewGuid().ToString("N"));
        var identity = new WindowsInstallationIdentity(Path.Combine(fixture, "app space"), Guid.NewGuid());
        try
        {
            string Write(string relative, string text)
            {
                string path = Path.Combine(identity.Root, relative.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, text); return path;
            }
            static object Entry(string path, string text) => new { path, sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text))) };
            string kept = Write("CodexPacer.dll", "same"), old = Write("WinSparkle.dll", "old"), changed = Write("de/Edited.resources.dll", "original"), notice = Write("Licenses/Old/notice.txt", "notice");
            File.WriteAllText(changed, "edited after install"); Write("CodexPacer.exe", "synthetic executable");
            string outside = Path.Combine(fixture, "outside.txt"); File.WriteAllText(outside, "outside");
            File.WriteAllText(Path.Combine(identity.Root, "build-info.json"), JsonSerializer.Serialize(new { schemaVersion = 1, files = new[]
                { Entry("CodexPacer.dll", "same"), Entry("WinSparkle.dll", "old"), Entry("de/Edited.resources.dll", "original"), Entry("Licenses/Old/notice.txt", "notice"), Entry("../outside.txt", "outside") } }));
            string temporary = Path.Combine(fixture, "setup temp"); Directory.CreateDirectory(temporary);
            string payload = Path.Combine(temporary, "build-info.json");
            File.WriteAllText(payload, JsonSerializer.Serialize(new { schemaVersion = 1, files = new[] { Entry("CodexPacer.dll", "same") } }));
            var operations = new WindowsInstallationOperations(identity, new StartupRegistrationChecks.Store(), new Links());
            operations.PrepareAsync(payload, CancellationToken.None).GetAwaiter().GetResult();
            string list = Path.Combine(temporary, WindowsInstallationOperations.StaleList);
            using (var stale = JsonDocument.Parse(File.ReadAllBytes(list)))
                Check(stale.RootElement.GetArrayLength() == 4, "Prepare lists only the installed files the new payload drops");
            Check(operations.RemoveStale(list) == 2, "Two stale files still hold their old content");
            Check(File.Exists(kept) && !File.Exists(old) && File.Exists(changed) && !File.Exists(notice) && !Directory.Exists(Path.Combine(identity.Root, "Licenses"))
                && Directory.Exists(Path.Combine(identity.Root, "de")) && File.Exists(outside),
                "Stale removal deletes only unchanged listed files and the folders it empties; edited files and paths outside the installation stay");
            Check(operations.RemoveStale(Path.Combine(temporary, "missing.json")) == 0, "Without a list nothing is removed");
        }
        finally { if (Directory.Exists(fixture)) Directory.Delete(fixture, true); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Links : IInstallationShortcut
    {
        public void Create(string path, string executable)
        { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, executable); }
        public string? Target(string path) => File.Exists(path) ? File.ReadAllText(path) : null;
    }
}
