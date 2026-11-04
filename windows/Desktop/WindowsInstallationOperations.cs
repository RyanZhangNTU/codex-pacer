using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace CodexPacer.Windows;

[Flags]
internal enum UninstallFailure { None = 0, ClaudeConfiguration = 1, Registrations = 2 }
internal enum InstallShortcut { StartMenu, Desktop }

internal sealed class WindowsInstallationOperations(WindowsInstallationIdentity identity,
    IUserRegistrationStore? registrations = null, IInstallationShortcut? shortcuts = null)
{
    private readonly IUserRegistrationStore store = registrations ?? new UserRegistrationStore();
    private readonly IInstallationShortcut links = shortcuts ?? new WindowsInstallShortcuts();
    private WindowsStartupRegistration Startup() => new(identity.Executable, name: identity.StartupName, store: store);
    private static readonly string[] OwnValues = ["SchemaVersion", "Path", "ShortcutPath", "ShortcutHash", "DesktopShortcutPath", "DesktopShortcutHash"];
    private string? Text(string name) => store.Read(identity.RegistryKey, name) is { Kind: RegistryValueKind.String, Value: string text } ? text : null;
    private bool OwnMarker => store.Read(identity.RegistryKey, "SchemaVersion") is { Kind: RegistryValueKind.DWord, Value: 1 };
    private static bool SamePath(string? a, string? b) => a != null && b != null && string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    internal async Task PrepareAsync(string payloadIndex, CancellationToken cancellation)
    {
        string root = identity.Root;
        if (Directory.Exists(root) && Directory.EnumerateFileSystemEntries(root).Any() && !(OwnMarker && SamePath(Text("Path"), root)))
        {
            // A portable Pacer directory can become an installed copy; an
            // unrelated application's nonempty directory cannot.
            using var info = JsonDocument.Parse(WindowsInstallationIdentity.ReadBounded(Path.Combine(root, "build-info.json"), 2 * 1024 * 1024));
            if (!info.RootElement.TryGetProperty("schemaVersion", out var version) || !version.TryGetInt32(out int schema) || schema != 1 ||
                !File.Exists(identity.Executable)) throw new InvalidDataException("Choose an empty folder or an existing Pacer installation.");
        }
        await WindowsMaintenanceSignal.StopAsync(identity.Executable, cancellation);
        Directory.CreateDirectory(root);
        string probe = Path.Combine(root, ".pacer-install-" + Guid.NewGuid().ToString("N"));
        using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        File.Delete(probe);
        using var manifest = JsonDocument.Parse(WindowsInstallationIdentity.ReadBounded(payloadIndex, 2 * 1024 * 1024));
        foreach (var item in manifest.RootElement.GetProperty("files").EnumerateArray())
        {
            cancellation.ThrowIfCancellationRequested();
            string relative = item.GetProperty("path").GetString() ?? throw new InvalidDataException("Invalid package path.");
            string path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid package path.");
            WindowsInstallationIdentity.RequireNoReparse(path);
            if (File.Exists(path))
            {
                // Refuse an occupied/read-only payload before Setup overwrites
                // any files. No force-close and no reboot replacement.
                using var available = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            }
        }
        WriteStale(manifest.RootElement, Path.Combine(Path.GetDirectoryName(Path.GetFullPath(payloadIndex))!, StaleList));
    }
    internal const string StaleList = "pacer-stale.json", PatchFile = "pacer-patch.json";
    internal sealed record PatchDescription(int SchemaVersion, string BaseBuild, string BaseManifestSHA256, string[] Files);
    // A patch carries only the files that changed since one build, so it may
    // replace files only in exactly that installation. Every file it does not
    // carry must already hold the new content, or nothing is touched.
    internal async Task PreparePatchAsync(string patchPath, CancellationToken cancellation)
    {
        // Written by package-installer.ps1 in camelCase.
        var patch = JsonSerializer.Deserialize<PatchDescription>(WindowsInstallationIdentity.ReadBounded(patchPath, 2 * 1024 * 1024),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Invalid update patch.");
        if (patch.SchemaVersion != 1 || patch.BaseManifestSHA256.Length != 64) throw new InvalidDataException("Invalid update patch.");
        string payloadIndex = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(patchPath))!, "build-info.json");
        string installed = Path.Combine(identity.Root, "build-info.json");
        if (!File.Exists(installed) || !string.Equals(Digest(installed), patch.BaseManifestSHA256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("This update applies only to the installation it was built from.");
        var carried = new HashSet<string>(patch.Files.Select(path => path.Replace('\\', '/')), StringComparer.OrdinalIgnoreCase);
        using (var manifest = JsonDocument.Parse(WindowsInstallationIdentity.ReadBounded(payloadIndex, 2 * 1024 * 1024)))
            CheckFiles(ManifestFiles(manifest.RootElement).Where(pair => !carried.Contains(pair.Key)), cancellation);
        await PrepareAsync(payloadIndex, cancellation);
    }
    /// Confirms the installed files match this installation's manifest.
    internal void Verify(CancellationToken cancellation)
    {
        using var manifest = JsonDocument.Parse(WindowsInstallationIdentity.ReadBounded(Path.Combine(identity.Root, "build-info.json"), 2 * 1024 * 1024));
        CheckFiles(ManifestFiles(manifest.RootElement), cancellation);
    }
    private void CheckFiles(IEnumerable<KeyValuePair<string, string>> files, CancellationToken cancellation)
    {
        string root = Path.GetFullPath(identity.Root);
        foreach (var (relative, digest) in files)
        {
            cancellation.ThrowIfCancellationRequested();
            string path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid package path.");
            if (!File.Exists(path) || Digest(path) != digest) throw new InvalidDataException("An installed file differs from its manifest.");
        }
    }
    private static string Digest(string path)
    {
        WindowsInstallationIdentity.RequireNoReparse(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(stream));
    }
    private static Dictionary<string, string> ManifestFiles(JsonElement manifest)
    {
        var files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in manifest.GetProperty("files").EnumerateArray())
            if (item.GetProperty("path").GetString() is { Length: > 0 } relative && item.GetProperty("sha256").GetString() is { Length: 64 } digest)
                files[relative.Replace('\\', '/')] = digest.ToLowerInvariant();
        return files;
    }
    // Files the installed version listed and the new payload no longer has.
    // Setup only adds and replaces files, so they would otherwise remain.
    private void WriteStale(JsonElement payload, string list)
    {
        File.Delete(list);
        string installed = Path.Combine(identity.Root, "build-info.json");
        if (!File.Exists(installed)) return;
        Dictionary<string, string> before;
        try
        {
            using var current = JsonDocument.Parse(WindowsInstallationIdentity.ReadBounded(installed, 2 * 1024 * 1024));
            before = ManifestFiles(current.RootElement);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or IOException) { return; }
        var after = ManifestFiles(payload);
        var stale = before.Where(pair => !after.ContainsKey(pair.Key)).Select(pair => new StaleFile(pair.Key, pair.Value)).ToArray();
        File.WriteAllBytes(list, JsonSerializer.SerializeToUtf8Bytes(stale));
    }
    private sealed record StaleFile(string Path, string SHA256);
    // Removes only listed regular files that still hold the old content, then
    // the folders that leaves empty. Anything changed or unknown is kept.
    internal int RemoveStale(string list)
    {
        if (!File.Exists(list)) return 0;
        var files = JsonSerializer.Deserialize<StaleFile[]>(WindowsInstallationIdentity.ReadBounded(list, 2 * 1024 * 1024)) ?? [];
        string root = Path.GetFullPath(identity.Root);
        int removed = 0;
        foreach (var file in files)
        {
            string path = Path.GetFullPath(Path.Combine(root, file.Path.Replace('/', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) continue;
            try
            {
                if (Digest(path) != file.SHA256) continue;
                File.Delete(path); removed++;
                for (string? folder = Path.GetDirectoryName(path); folder != null && folder.Length > root.Length
                    && !Directory.EnumerateFileSystemEntries(folder).Any(); folder = Path.GetDirectoryName(folder))
                    Directory.Delete(folder, false);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { }
        }
        return removed;
    }
    private (string File, string PathValue, string HashValue) Link(InstallShortcut kind) => kind == InstallShortcut.Desktop
        ? (identity.DesktopShortcut, "DesktopShortcutPath", "DesktopShortcutHash") : (identity.Shortcut, "ShortcutPath", "ShortcutHash");
    private bool Owns(InstallShortcut kind, string? previous)
    {
        var (file, pathValue, hashValue) = Link(kind);
        string? hash = Text(hashValue);
        return OwnMarker && SamePath(Text(pathValue), file) && hash != null && WindowsInstallShortcuts.Digest(file) == hash &&
            (SamePath(links.Target(file), identity.Executable) || previous != null && SamePath(links.Target(file), Path.Combine(previous, "CodexPacer.exe")));
    }
    // Registration refreshes only the shortcuts this installation already
    // owns. New ones come from the person's choice on the setup finish page
    // (AddShortcut), so a silent update never adds one they did not ask for.
    internal void Register()
    {
        _ = WindowsInstallationIdentity.Load(identity.Root, identity.QaScope, requireContext: true);
        string? previous = OwnMarker ? Text("Path") : null;
        var before = OwnValues.ToDictionary(name => name, name => store.Read(identity.RegistryKey, name));
        var owned = Enum.GetValues<InstallShortcut>().Where(kind => Owns(kind, previous))
            .ToDictionary(kind => kind, kind => WindowsInstallationIdentity.ReadBounded(Link(kind).File, 256 * 1024));
        try
        {
            var startup = Startup();
            if (previous != null && !startup.MigrateFrom(Path.Combine(previous, "CodexPacer.exe")))
                throw new IOException("The startup entry could not be migrated.");
            foreach (var kind in owned.Keys) links.Create(Link(kind).File, identity.Executable);
            store.Write(identity.RegistryKey, "SchemaVersion", new(1, RegistryValueKind.DWord));
            store.Write(identity.RegistryKey, "Path", new(identity.Root, RegistryValueKind.String));
            foreach (var kind in Enum.GetValues<InstallShortcut>())
            {
                var (file, pathValue, hashValue) = Link(kind);
                if (owned.ContainsKey(kind)) Claim(file, pathValue, hashValue);
                else { store.Delete(identity.RegistryKey, pathValue); store.Delete(identity.RegistryKey, hashValue); }
            }
        }
        catch
        {
            Restore(before);
            foreach (var pair in owned) File.WriteAllBytes(Link(pair.Key).File, pair.Value);
            throw;
        }
    }
    // Creates a requested shortcut for this registered installation. A file
    // already there that this installation does not own is left alone.
    internal void AddShortcut(InstallShortcut kind)
    {
        _ = WindowsInstallationIdentity.Load(identity.Root, identity.QaScope, requireContext: true);
        if (!OwnMarker || !SamePath(Text("Path"), identity.Root)) throw new InvalidDataException("Register this installation first.");
        var (file, pathValue, hashValue) = Link(kind);
        bool owned = Owns(kind, null);
        if (File.Exists(file) && !owned) return;
        byte[]? prior = owned ? WindowsInstallationIdentity.ReadBounded(file, 256 * 1024) : null;
        var before = OwnValues.ToDictionary(name => name, name => store.Read(identity.RegistryKey, name));
        try
        {
            links.Create(file, identity.Executable);
            Claim(file, pathValue, hashValue);
        }
        catch
        {
            Restore(before);
            if (prior != null) File.WriteAllBytes(file, prior);
            else if (File.Exists(file)) File.Delete(file);
            throw;
        }
    }
    private void Claim(string file, string pathValue, string hashValue)
    {
        store.Write(identity.RegistryKey, pathValue, new(file, RegistryValueKind.String));
        store.Write(identity.RegistryKey, hashValue, new(WindowsInstallShortcuts.Digest(file)!, RegistryValueKind.String));
    }
    private void Restore(Dictionary<string, RegistrationValue?> before)
    {
        foreach (var pair in before)
        { if (pair.Value == null) store.Delete(identity.RegistryKey, pair.Key); else store.Write(identity.RegistryKey, pair.Key, pair.Value); }
    }
    internal async Task<UninstallFailure> UninstallAsync(CancellationToken cancellation, bool continueAfterFailure = false)
    {
        _ = WindowsInstallationIdentity.Load(identity.Root, identity.QaScope, requireContext: true);
        // A previous attempt may already have removed the known marker values.
        // A foreign/partially modified marker is never adopted on retry.
        if (!(OwnMarker && SamePath(Text("Path"), identity.Root)) && OwnValues.Any(name => store.Read(identity.RegistryKey, name) != null))
            return UninstallFailure.Registrations;
        var failures = UninstallFailure.None;
        string hooks = Path.Combine(identity.Root, "Engine", "PacerInstallerHooks.exe");
        IReadOnlyList<string>? homes = null;
        string runtime = Path.Combine(identity.DataRoot, "ClaudeRuntime");
        static string[] HookArguments(string operation, string runtime, IReadOnlyList<string> homes) =>
            new[] { operation, runtime }.Concat(homes).ToArray();
        try
        {
            homes = ClaudeHomes();
            await RunAsync(hooks, HookArguments("--check-uninstall-all", runtime, homes), TimeSpan.FromSeconds(10), cancellation);
        }
        catch { failures |= UninstallFailure.ClaudeConfiguration; }
        if (failures != UninstallFailure.None && !continueAfterFailure) return failures;
        try { await WindowsMaintenanceSignal.StopAsync(identity.Executable, cancellation); }
        catch { return failures | UninstallFailure.Registrations; }
        if (homes != null)
        {
            try { await RunAsync(hooks, HookArguments(continueAfterFailure ? "--uninstall-all-continue" : "--uninstall-all", runtime, homes), TimeSpan.FromSeconds(10), cancellation); }
            catch { failures |= UninstallFailure.ClaudeConfiguration; }
        }
        if (failures != UninstallFailure.None && !continueAfterFailure) return failures;
        try { await RunAsync(identity.Executable, ["--uninstall-notifications"], TimeSpan.FromSeconds(10), cancellation); }
        catch { failures |= UninstallFailure.Registrations; }
        if (failures != UninstallFailure.None && !continueAfterFailure) return failures;
        try { RemoveOwnedRegistrations(); }
        catch { failures |= UninstallFailure.Registrations; }
        // Downloaded installers are not preferences: remove them with the app.
        // A locked or unknown session is left; it never changes the result.
        try { UpdateSessions.Clean(identity.DataRoot); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return failures;
    }
    internal void RemoveOwnedRegistrations()
    {
        if (OwnValues.All(name => store.Read(identity.RegistryKey, name) == null)) return;
        if (!OwnMarker || !SamePath(Text("Path"), identity.Root)) throw new InvalidDataException("This installation does not own its registration.");
        if (!Startup().RemoveOwned()) throw new IOException("The startup entry could not be removed.");
        foreach (var kind in Enum.GetValues<InstallShortcut>())
        {
            if (!Owns(kind, null)) continue;
            File.Delete(Link(kind).File);
            string directory = Path.GetDirectoryName(identity.Shortcut)!;
            if (kind == InstallShortcut.StartMenu && !Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory, false);
        }
        var before = OwnValues.ToDictionary(name => name, name => store.Read(identity.RegistryKey, name));
        try { foreach (string name in OwnValues) store.Delete(identity.RegistryKey, name); }
        catch
        {
            // Retain the ownership proof when a partial registry removal
            // fails, so Retry can finish. Never overwrite a concurrent edit.
            foreach (var pair in before)
                if (pair.Value != null && store.Read(identity.RegistryKey, pair.Key) == null)
                    try { store.Write(identity.RegistryKey, pair.Key, pair.Value); } catch { }
            throw;
        }
        store.DeleteEmptyKey(identity.RegistryKey);
        store.DeleteEmptyKey(@"Software\CodexPacer\Installations");
        store.DeleteEmptyKey(@"Software\CodexPacer\StartupOwners");
        store.DeleteEmptyKey(@"Software\CodexPacer");
    }
    internal IReadOnlyList<string> ClaudeHomes()
    {
        // QA packages cannot reach the user's provider homes or preferences.
        if (identity.QaScope != null) return [Path.Combine(identity.DataRoot, "claude")];
        var homes = new List<string>();
        string? environment = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        homes.Add(string.IsNullOrWhiteSpace(environment)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude") : WindowsInstallationIdentity.SafeRoot(environment));
        var (preferences, unavailable) = new PreferencesStore(Path.Combine(identity.DataRoot, "preferences-v1.json"), recoverDamagedFiles: false).Load();
        if (unavailable) throw new InvalidDataException("Repair the unreadable preferences before uninstalling.");
        if (!string.IsNullOrWhiteSpace(preferences.ClaudeHome)) homes.Add(WindowsInstallationIdentity.SafeRoot(preferences.ClaudeHome));
        return homes.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }
    internal static async Task RunAsync(string executable, IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken cancellation)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        lifetime.CancelAfter(timeout);
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(executable)!,
            RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string value in arguments) start.ArgumentList.Add(value);
        using var process = Process.Start(start) ?? throw new IOException("The maintenance helper did not start.");
        // Helper diagnostics are fixed messages. Drain both bounded protocols;
        // never forward settings, paths or account details to an installer log.
        async Task Drain(StreamReader reader)
        {
            char[] buffer = new char[1024]; int total = 0, count;
            while ((count = await reader.ReadAsync(buffer, lifetime.Token)) != 0)
                if ((total += count) > 4096) throw new IOException("Maintenance output exceeds its limit.");
        }
        try
        {
            await Task.WhenAll(process.WaitForExitAsync(lifetime.Token), Drain(process.StandardOutput), Drain(process.StandardError));
            if (process.ExitCode != 0) throw new IOException("The maintenance helper reported failure.");
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }
    }
}
