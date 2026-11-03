using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal enum StartupBlockReason { None, Disabled, Policy, Unknown, OtherInstallation }
internal readonly record struct StartupRegistrationState(bool Registered, bool Available, StartupBlockReason BlockReason = StartupBlockReason.None)
{
    internal bool Effective => Registered && BlockReason == StartupBlockReason.None;
}
internal interface IStartupRegistration
{
    StartupRegistrationState Read();
    bool Set(bool enabled);
    bool OpenSettings() => false;
}

internal sealed record RegistrationValue(object Value, RegistryValueKind Kind)
{
    internal bool Same(RegistrationValue? other) => other != null && Kind == other.Kind &&
        (Value is byte[] a && other.Value is byte[] b ? a.SequenceEqual(b) : Value.Equals(other.Value));
}
internal interface IUserRegistrationStore
{
    RegistrationValue? Read(string path, string name);
    void Write(string path, string name, RegistrationValue value);
    void Delete(string path, string name);
    void DeleteEmptyKey(string path);
}
internal sealed class UserRegistrationStore : IUserRegistrationStore
{
    public RegistrationValue? Read(string path, string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(path, false);
        object? value = key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
        return value == null ? null : new(value, key!.GetValueKind(name));
    }
    public void Write(string path, string name, RegistrationValue value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(path, true);
        key.SetValue(name, value.Value, value.Kind);
    }
    public void Delete(string path, string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(path, true);
        key?.DeleteValue(name, false);
    }
    public void DeleteEmptyKey(string path)
    {
        using (var key = Registry.CurrentUser.OpenSubKey(path, false))
            if (key == null || key.ValueCount != 0 || key.SubKeyCount != 0) return;
        Registry.CurrentUser.DeleteSubKey(path, false);
    }
}

/// The OS owns the choice. No second copy is stored in preferences.
internal sealed class WindowsStartupRegistration : IStartupRegistration
{
    internal const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    internal const string PolicyKey = @"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer";
    internal const string SettingsUri = "ms-settings:startupapps";
    private readonly string executable, key, approvedKey, ownerKey, name;
    private readonly IUserRegistrationStore store;
    private readonly Func<bool> openSettings;
    private readonly Func<string, bool> exists;
    internal WindowsStartupRegistration(string executable, string key = RunKey, string name = "CodexPacer",
        string? approvedKey = null, string? ownerKey = null, IUserRegistrationStore? store = null, Func<bool>? openSettings = null,
        Func<string, bool>? exists = null)
    {
        this.executable = Path.GetFullPath(executable); this.key = key; this.name = name;
        this.approvedKey = approvedKey ?? (key == RunKey ? ApprovedKey : key + @"\Approved");
        this.ownerKey = ownerKey ?? (key == RunKey ? @"Software\CodexPacer\StartupOwners\" + name : key);
        this.store = store ?? new UserRegistrationStore(); this.openSettings = openSettings ?? LaunchSettings; this.exists = exists ?? File.Exists;
    }
    internal string Command => CommandFor(executable);
    private static string CommandFor(string path) => "\"" + Path.GetFullPath(path) + "\" --launch-at-login";
    private bool Valid => Command.Length <= 260 && !executable.Any(char.IsControl) && !executable.Contains('"');
    private bool Owns(RegistrationValue? value, string? path = null) => value is { Kind: RegistryValueKind.String, Value: string text }
        && string.Equals(text, path == null ? Command : CommandFor(path), StringComparison.OrdinalIgnoreCase);
    private bool OwnsMarker(RegistrationValue? value) => value is { Kind: RegistryValueKind.String, Value: string text }
        && string.Equals(text, executable, StringComparison.OrdinalIgnoreCase);
    // A copy deleted with startup still on leaves an entry Windows can no
    // longer launch. It belongs to no installation, so this copy may take it.
    // Only a missing local file is conclusive; a network copy may be offline.
    private bool Abandoned(RegistrationValue? value)
    {
        if (value is not { Kind: RegistryValueKind.String, Value: string text } || !text.StartsWith('"')) return false;
        int end = text.IndexOf('"', 1);
        if (end < 2 || text[(end + 1)..] != " --launch-at-login") return false;
        string path = text[1..end];
        return Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal)
            && string.Equals(Path.GetFileName(path), "CodexPacer.exe", StringComparison.OrdinalIgnoreCase) && !exists(path);
    }
    private static bool Equal(RegistrationValue? a, RegistrationValue? b) => a == null ? b == null : a.Same(b);
    internal static bool Recoverable(Exception error) => error is IOException or UnauthorizedAccessException or SecurityException or InvalidOperationException;

    public StartupRegistrationState Read()
    {
        if (!Valid) return new(false, false, StartupBlockReason.Unknown);
        try
        {
            var run = store.Read(key, name);
            if (run != null && !Owns(run)) return Abandoned(run) ? new(false, true) : new(false, false, StartupBlockReason.OtherInstallation);
            if (run == null) return new(false, true);
            var policy = store.Read(PolicyKey, "DisableCurrentUserRun");
            if (policy != null)
            {
                if (policy is not { Kind: RegistryValueKind.DWord, Value: int value }) return new(true, true, StartupBlockReason.Unknown);
                if (value != 0) return new(true, true, StartupBlockReason.Policy);
            }
            var approval = store.Read(approvedKey, name);
            if (approval == null) return new(true, true);
            // StartupApproved is not a public binary contract. Recognize the
            // observed forms, surface future/malformed values, and never edit
            // it to bypass a Windows disable decision.
            if (approval is not { Kind: RegistryValueKind.Binary, Value: byte[] bytes } || bytes.Length != 12)
                return new(true, true, StartupBlockReason.Unknown);
            return new(true, true, BitConverter.ToUInt32(bytes, 0) switch
            {
                2 or 6 => StartupBlockReason.None,
                3 or 7 => StartupBlockReason.Disabled,
                _ => StartupBlockReason.Unknown
            });
        }
        catch (Exception error) when (Recoverable(error)) { return new(false, false, StartupBlockReason.Unknown); }
    }
    public bool Set(bool enabled) => SetCore(enabled, null);
    private bool SetCore(bool enabled, string? previousExecutable)
    {
        if (!Valid) return false;
        RegistrationValue? beforeRun = null, beforeOwner = null;
        bool captured = false;
        try
        {
            beforeRun = store.Read(key, name); beforeOwner = store.Read(ownerKey, "Executable");
            captured = true;
            if (beforeRun != null && !Owns(beforeRun) && (previousExecutable == null || !Owns(beforeRun, previousExecutable)) && !Abandoned(beforeRun)) return false;
            if (!enabled && beforeRun == null) return true;
            store.Write(ownerKey, "Executable", new(executable, RegistryValueKind.String));
            if (enabled) store.Write(key, name, new(Command, RegistryValueKind.String)); else store.Delete(key, name);
            if (!Equal(store.Read(key, name), enabled ? new(Command, RegistryValueKind.String) : null)
                || !OwnsMarker(store.Read(ownerKey, "Executable"))) throw new IOException("Startup registration readback failed.");
            return true;
        }
        catch (Exception error) when (Recoverable(error))
        {
            if (captured)
            {
                try
                {
                    var currentRun = store.Read(key, name);
                    var writtenRun = enabled ? new RegistrationValue(Command, RegistryValueKind.String) : null;
                    if (Equal(currentRun, beforeRun) || Equal(currentRun, writtenRun)) Restore(key, name, beforeRun);
                    var currentOwner = store.Read(ownerKey, "Executable");
                    if (Equal(currentOwner, beforeOwner) || OwnsMarker(currentOwner)) Restore(ownerKey, "Executable", beforeOwner);
                    if (beforeOwner == null) store.DeleteEmptyKey(ownerKey);
                }
                catch (Exception rollback) when (Recoverable(rollback)) { /* Read() exposes the actual result; UI reports failure. */ }
            }
            return false;
        }
    }
    private void Restore(string path, string valueName, RegistrationValue? value)
    { if (value == null) store.Delete(path, valueName); else store.Write(path, valueName, value); }

    internal bool MigrateFrom(string previousExecutable)
    {
        try
        {
            // A different app/copy is not an upgrade of this installation.
            return !Owns(store.Read(key, name), previousExecutable) || SetCore(true, previousExecutable);
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }
    internal bool RemoveOwned()
    {
        try
        {
            var run = store.Read(key, name); var owner = store.Read(ownerKey, "Executable");
            if (Owns(run) || run == null && OwnsMarker(owner))
            {
                if (Owns(run)) store.Delete(key, name);
                store.Delete(approvedKey, name);
            }
            if (OwnsMarker(owner)) { store.Delete(ownerKey, "Executable"); store.DeleteEmptyKey(ownerKey); }
            return true;
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }
    public bool OpenSettings() => openSettings();
    private static bool LaunchSettings()
    {
        try { using var process = Process.Start(new ProcessStartInfo(SettingsUri) { UseShellExecute = true }); return true; }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException) { return false; }
    }
}

internal sealed class DemoStartupRegistration : IStartupRegistration
{
    private bool enabled;
    public StartupRegistrationState Read() => new(enabled, true);
    public bool Set(bool value) { enabled = value; return true; }
    public bool OpenSettings() => true;
}

internal sealed class UnavailableStartupRegistration : IStartupRegistration
{
    public StartupRegistrationState Read() => new(false, false, StartupBlockReason.Unknown);
    public bool Set(bool value) => false;
    public bool OpenSettings() => new WindowsStartupRegistration(Environment.ProcessPath!).OpenSettings();
}
