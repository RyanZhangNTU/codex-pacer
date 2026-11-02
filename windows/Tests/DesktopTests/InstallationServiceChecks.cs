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
        var operations = new WindowsInstallationOperations(identity, store, links);
        try
        {
            Directory.CreateDirectory(identity.DataRoot);
            byte[] preference = "synthetic preference-private"u8.ToArray(), read = "synthetic read-private"u8.ToArray();
            File.WriteAllBytes(Path.Combine(identity.DataRoot, "preferences-v1.json"), preference);
            File.WriteAllBytes(Path.Combine(identity.DataRoot, "completion-dismissals-v1.json"), read);
            operations.Register();
            Check(WindowsInstallationIdentity.Load(identity.Root, identity.QaScope, true) == identity, "The package identity must round-trip independently of user preferences");
            Check((string?)store.Read(identity.RegistryKey, "Path")?.Value == identity.Root && links.Target(identity.Shortcut) == identity.Executable,
                "Install must register this location and its Start menu shortcut");
            string beforeHash = WindowsInstallShortcuts.Digest(identity.Shortcut)!;
            operations.Register();
            Check(links.Target(identity.Shortcut) == identity.Executable && WindowsInstallShortcuts.Digest(identity.Shortcut) == beforeHash,
                "A same-version repair must keep a valid owned shortcut");
            Check(File.ReadAllBytes(Path.Combine(identity.DataRoot, "preferences-v1.json")).SequenceEqual(preference) &&
                File.ReadAllBytes(Path.Combine(identity.DataRoot, "completion-dismissals-v1.json")).SequenceEqual(read),
                "Install and repair cannot modify preferences or read state outside the application directory");
            store.Put(identity.RegistryKey, "OtherFixture", new("preserve", RegistryValueKind.String));
            operations.RemoveOwnedRegistrations();
            Check(!File.Exists(identity.Shortcut) && store.Read(identity.RegistryKey, "Path") == null &&
                (string?)store.Read(identity.RegistryKey, "OtherFixture")?.Value == "preserve",
                "Uninstall must remove its shortcut and known values while preserving an unrelated value");
            Check(Directory.Exists(identity.DataRoot), "Uninstall cannot delete retained data");

            Directory.CreateDirectory(Path.GetDirectoryName(identity.Shortcut)!);
            File.WriteAllText(identity.Shortcut, @"C:\synthetic other application.exe");
            operations.Register();
            Check(File.ReadAllText(identity.Shortcut) == @"C:\synthetic other application.exe" &&
                store.Read(identity.RegistryKey, "ShortcutHash") == null, "Install cannot replace or claim a pre-existing foreign shortcut");
            operations.RemoveOwnedRegistrations();
            Check(File.Exists(identity.Shortcut), "Uninstall must preserve that foreign shortcut");
            File.Delete(identity.Shortcut);

            operations.Register();
            File.AppendAllText(identity.Shortcut, " user modification");
            operations.RemoveOwnedRegistrations();
            Check(File.Exists(identity.Shortcut), "A user-modified shortcut must no longer be deleted as owned");
            File.Delete(identity.Shortcut);

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
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Links : IInstallationShortcut
    {
        public void Create(string path, string executable)
        { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, executable); }
        public string? Target(string path) => File.Exists(path) ? File.ReadAllText(path) : null;
    }
}
