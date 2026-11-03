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

internal sealed class WindowsInstallationOperations(WindowsInstallationIdentity identity,
    IUserRegistrationStore? registrations = null, IInstallationShortcut? shortcuts = null)
{
    private readonly IUserRegistrationStore store = registrations ?? new UserRegistrationStore();
    private readonly IInstallationShortcut links = shortcuts ?? new WindowsInstallShortcuts();
    private WindowsStartupRegistration Startup() => new(identity.Executable, name: identity.StartupName, store: store);
    private static readonly string[] OwnValues = ["SchemaVersion", "Path", "ShortcutPath", "ShortcutHash"];
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
    }
    internal void Register()
    {
        _ = WindowsInstallationIdentity.Load(identity.Root, identity.QaScope, requireContext: true);
        string? previous = OwnMarker ? Text("Path") : null;
        var before = OwnValues.ToDictionary(name => name, name => store.Read(identity.RegistryKey, name));
        string? oldShortcut = Text("ShortcutPath"), oldHash = Text("ShortcutHash");
        bool shortcutOwned = OwnMarker && SamePath(oldShortcut, identity.Shortcut) &&
            oldHash != null && WindowsInstallShortcuts.Digest(identity.Shortcut) == oldHash &&
            (SamePath(links.Target(identity.Shortcut), identity.Executable) ||
             previous != null && SamePath(links.Target(identity.Shortcut), Path.Combine(previous, "CodexPacer.exe")));
        byte[]? priorShortcut = shortcutOwned ? WindowsInstallationIdentity.ReadBounded(identity.Shortcut, 256 * 1024) : null;
        bool writeShortcut = !File.Exists(identity.Shortcut) || shortcutOwned;
        try
        {
            var startup = Startup();
            if (previous != null && !startup.MigrateFrom(Path.Combine(previous, "CodexPacer.exe")))
                throw new IOException("The startup entry could not be migrated.");
            if (writeShortcut) links.Create(identity.Shortcut, identity.Executable);
            store.Write(identity.RegistryKey, "SchemaVersion", new(1, RegistryValueKind.DWord));
            store.Write(identity.RegistryKey, "Path", new(identity.Root, RegistryValueKind.String));
            if (writeShortcut)
            {
                store.Write(identity.RegistryKey, "ShortcutPath", new(identity.Shortcut, RegistryValueKind.String));
                store.Write(identity.RegistryKey, "ShortcutHash", new(WindowsInstallShortcuts.Digest(identity.Shortcut)!, RegistryValueKind.String));
            }
            else { store.Delete(identity.RegistryKey, "ShortcutPath"); store.Delete(identity.RegistryKey, "ShortcutHash"); }
        }
        catch
        {
            foreach (var pair in before)
            { if (pair.Value == null) store.Delete(identity.RegistryKey, pair.Key); else store.Write(identity.RegistryKey, pair.Key, pair.Value); }
            if (writeShortcut)
            {
                if (priorShortcut == null) { if (File.Exists(identity.Shortcut)) File.Delete(identity.Shortcut); }
                else File.WriteAllBytes(identity.Shortcut, priorShortcut);
            }
            throw;
        }
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
        return failures;
    }
    internal void RemoveOwnedRegistrations()
    {
        if (OwnValues.All(name => store.Read(identity.RegistryKey, name) == null)) return;
        if (!OwnMarker || !SamePath(Text("Path"), identity.Root)) throw new InvalidDataException("This installation does not own its registration.");
        if (!Startup().RemoveOwned()) throw new IOException("The startup entry could not be removed.");
        string? shortcut = Text("ShortcutPath"), hash = Text("ShortcutHash");
        if (SamePath(shortcut, identity.Shortcut) && hash != null && WindowsInstallShortcuts.Digest(identity.Shortcut) == hash
            && SamePath(links.Target(identity.Shortcut), identity.Executable))
        {
            File.Delete(identity.Shortcut);
            string directory = Path.GetDirectoryName(identity.Shortcut)!;
            if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory, false);
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
        var (preferences, unavailable) = new PreferencesStore(Path.Combine(identity.DataRoot, "preferences-v1.json")).Load();
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
