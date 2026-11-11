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
        PatchFiles();
        FullInstallationUpdateState();
    }
    private static void FullInstallationUpdateState()
    {
        string fixture = Path.Combine(Path.GetTempPath(), "pacer-full-update-" + Guid.NewGuid().ToString("N"));
        var identity = new WindowsInstallationIdentity(Path.Combine(fixture, "app space"), Guid.NewGuid());
        string updates = UpdateSessions.Root(identity.DataRoot), path = Path.Combine(updates, "state-v1.json");
        var state = WindowsUpdateState.ForInstallation(identity);
        var store = new StartupRegistrationChecks.Store();
        var operations = new WindowsInstallationOperations(identity, store, new Links());
        const string marker = UpdateHandoff.PatchFailedKey;
        Directory.CreateDirectory(identity.Root); Directory.CreateDirectory(updates);
        try
        {
            File.WriteAllText(Path.Combine(identity.Root, WindowsInstallationIdentity.ContextFile),
                JsonSerializer.Serialize(new { schemaVersion = 1, qaScope = identity.Scope }));
            byte[] payload = "synthetic executable"u8.ToArray();
            File.WriteAllBytes(identity.Executable, payload);
            File.WriteAllText(Path.Combine(identity.Root, UpdateCatalog.ManifestName), JsonSerializer.Serialize(new
            {
                schemaVersion = 1, version = "1.2.3", build = 4, files = new[]
                { new { path = "CodexPacer.exe", sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(payload)) } }
            }));
            void Complete() => operations.CompleteFullInstallation(CancellationToken.None);
            string[] Backups() => Directory.GetFiles(updates, "state-v1.json.damaged-*");

            byte[] truncated = "{\"SchemaVersion\":1,\"Values\":"u8.ToArray();
            File.WriteAllBytes(path, truncated);
            store.FailWriteAfter = (identity.RegistryKey, "Path");
            try { Complete(); throw new InvalidOperationException("Registration failure was hidden by state recovery."); }
            catch (IOException) { }
            Check(File.ReadAllBytes(path).SequenceEqual(truncated) && Backups().Length == 0, "Registration must succeed before touching damaged update state");

            byte[] Oversize(byte[] prefix) => prefix.Concat(Enumerable.Repeat((byte)' ', 32768)).ToArray();
            foreach (byte[] damaged in new[] { truncated, "{\"SchemaVersion\":1,\"Values\":{\"PacerPatchFailedBuild\":null}}"u8.ToArray(), Oversize(truncated) })
            {
                File.WriteAllBytes(path, damaged);
                Complete();
                Check(!File.Exists(path) && Backups().Any(backup => File.ReadAllBytes(backup).SequenceEqual(damaged)),
                    "Full installation preserves the exact damaged bytes and removes them from the updater's active path");
                state.Write("SkipThisVersion", "1.2.3.1");
                Check(state.Read("SkipThisVersion") == "1.2.3.1", "Update checks can save state again after a full repair");
            }

            byte[] future = "{\"SchemaVersion\":2,\"Values\":{}}"u8.ToArray();
            foreach (byte[] versioned in new[] { future, Oversize(future) })
            {
                File.WriteAllBytes(path, versioned);
                Complete();
                Check(File.ReadAllBytes(path).SequenceEqual(versioned) && Backups().Length == 3,
                    "Full installation preserves an explicit future schema, even when the current reader cannot load the full file");
            }

            File.WriteAllBytes(path, truncated);
            using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None)) Complete();
            Check(File.ReadAllBytes(path).SequenceEqual(truncated) && Backups().Length == 3,
                "A file-sharing denial is not treated as corruption or replaced by the installer");

            File.Delete(path);
            state.Write("SkipThisVersion", "1.2.3.1");
            state.Write(marker, "1.2.3.5"); Complete();
            Check(state.Read(marker) == "1.2.3.5", "An older full installer cannot clear a newer repair marker");

            state.Write(marker, "1.2.3.4");
            File.WriteAllText(identity.Executable, "synthetic damage");
            try { Complete(); throw new InvalidOperationException("A failed manifest verification was hidden."); }
            catch (InvalidDataException) { }
            Check(state.Read(marker) == "1.2.3.4", "Failed verification leaves the repair marker");

            File.WriteAllBytes(identity.Executable, payload);
            File.SetAttributes(path, FileAttributes.ReadOnly);
            try
            {
                try { state.Write(marker, null); throw new InvalidOperationException("The state fixture was not write-protected."); }
                catch (UnauthorizedAccessException) { }
                Complete();
                Check(state.Read(marker) == "1.2.3.4", "Read-only state keeps its marker after a successful full install");
            }
            finally { File.SetAttributes(path, FileAttributes.Normal); }

            Complete();
            Check(state.Read(marker) == null && state.Read("SkipThisVersion") == "1.2.3.1",
                "A verified full installation removes only the eligible marker when state is writable");
            Console.WriteLine("PASS full installation: damaged updater state backed up, inaccessible and future state preserved, verified repair marker cleared");
        }
        finally { if (Directory.Exists(fixture)) Directory.Delete(fixture, true); }
    }
    // A patch replaces files only in exactly its base installation, and only
    // when every file it does not carry already holds the new content.
    private static void PatchFiles()
    {
        string fixture = Path.Combine(Path.GetTempPath(), "pacer-patch-中文-" + Guid.NewGuid().ToString("N"));
        var identity = new WindowsInstallationIdentity(Path.Combine(fixture, "app space"), Guid.NewGuid());
        try
        {
            static string Hash(string text) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));
            static object Entry(string path, string text) => new { path, sha256 = Hash(text) };
            void Write(string relative, string text)
            {
                string path = Path.Combine(identity.Root, relative.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, text);
            }
            Write("CodexPacer.exe", "synthetic executable"); Write("Same.dll", "same"); Write("Changed.dll", "old");
            string installed = Path.Combine(identity.Root, "build-info.json");
            File.WriteAllText(installed, JsonSerializer.Serialize(new { schemaVersion = 1, files = new[] { Entry("CodexPacer.exe", "synthetic executable"), Entry("Same.dll", "same"), Entry("Changed.dll", "old") } }));
            string temporary = Path.Combine(fixture, "setup temp"); Directory.CreateDirectory(temporary);
            File.WriteAllText(Path.Combine(temporary, "build-info.json"), JsonSerializer.Serialize(new { schemaVersion = 1, files = new[]
                { Entry("CodexPacer.exe", "synthetic executable"), Entry("Same.dll", "same"), Entry("Changed.dll", "new"), Entry("Added/new.txt", "added") } }));
            string patch = Path.Combine(temporary, WindowsInstallationOperations.PatchFile);
            // The same camelCase shape package-installer.ps1 writes.
            File.WriteAllText(patch, JsonSerializer.Serialize(new { schemaVersion = 1, baseBuild = "1.2.3.4",
                baseManifestSHA256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(installed))),
                files = new[] { "Changed.dll", "Added/new.txt", "Maintenance/PacerMaintenance.exe" } }));
            var operations = new WindowsInstallationOperations(identity, new StartupRegistrationChecks.Store(), new Links());
            void Prepare() => operations.PreparePatchAsync(patch, CancellationToken.None).GetAwaiter().GetResult();
            void Refused(string message)
            {
                try { Prepare(); } catch (InvalidDataException) { return; }
                throw new InvalidOperationException(message);
            }
            Prepare();
            Check(File.Exists(Path.Combine(temporary, WindowsInstallationOperations.StaleList)), "A matching base prepares like a full installation");
            Write("Same.dll", "locally modified");
            Refused("A file the patch does not carry must already hold its new content");
            Write("Same.dll", "same");
            File.AppendAllText(installed, " ");
            Refused("A patch refuses an installation whose manifest is not its base");
            File.WriteAllText(installed, File.ReadAllText(installed).TrimEnd());
            operations.Verify(CancellationToken.None);
            Write("Changed.dll", "damaged");
            try { operations.Verify(CancellationToken.None); throw new InvalidOperationException("Verification accepted a file that differs from the manifest."); }
            catch (InvalidDataException) { }
        }
        finally { if (Directory.Exists(fixture)) Directory.Delete(fixture, true); }
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
