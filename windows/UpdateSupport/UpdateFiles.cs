using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace CodexPacer.Windows;

internal static class UpdateFiles
{
    internal static void Check(string path)
    {
        path = Path.GetFullPath(path);
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw new IOException("No update owner is available.");
        var admin = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        bool elevated = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        bool target = true;
        for (string? current = path; current != null; current = Path.GetDirectoryName(current))
        {
            FileAttributes attrs;
            try { attrs = File.GetAttributes(current); }
            catch (FileNotFoundException) { continue; }
            catch (DirectoryNotFoundException) { continue; }
            if ((attrs & FileAttributes.ReparsePoint) != 0) throw new IOException("Update paths cannot contain reparse points.");
            if (target && (attrs & FileAttributes.Directory) == 0)
            {
                using var handle = File.OpenHandle(current, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (!GetFileInformationByHandle(handle, out var facts) || facts.Links != 1) throw new IOException("Update files cannot use hard links.");
            }
            // Volume/system ancestors can have SYSTEM/TrustedInstaller owners.
            // Check the requested file and every existing Pacer-owned directory.
            if (target || Path.GetFileName(current).StartsWith("CodexPacer", StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(current) == "Updates")
            {
                var owner = (attrs & FileAttributes.Directory) != 0
                    ? new DirectoryInfo(current).GetAccessControl(AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier))
                    : new FileInfo(current).GetAccessControl(AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier));
                if (!user.Equals(owner) && !(elevated && admin.Equals(owner))) throw new IOException("Update files have another owner.");
            }
            target = false;
        }
    }
    [StructLayout(LayoutKind.Sequential)] private struct FileFacts
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileFacts info);
    internal static byte[] Read(string path, int limit) => ReadFile(path, limit, false, out _);
    internal static byte[] ReadPrefix(string path, int limit, out long length) => ReadFile(path, limit, true, out length);
    private static byte[] ReadFile(string path, int limit, bool allowPrefix, out long length)
    {
        Check(path);
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        length = file.Length;
        if (!allowPrefix && length > limit) throw new InvalidDataException("Update data exceeds its limit.");
        var data = new byte[checked((int)Math.Min(length, limit))]; file.ReadExactly(data); Check(path); return data;
    }
    internal static void Write(string path, byte[] bytes)
    {
        Check(path); Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!); Check(path);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
            Check(path); File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

// The update service keeps its schedule, skipped build and presented notes
// here, never in HKCU. Keys keep the names WinSparkle used before 4.2.3.
internal sealed class WindowsUpdateState(string path)
{
    private const int MaximumBytes = 32768;
    internal static WindowsUpdateState ForInstallation(WindowsInstallationIdentity identity) =>
        new(Path.Combine(UpdateSessions.Root(identity.DataRoot), "state-v1.json"));

    private sealed record State(int SchemaVersion, Dictionary<string, string> Values);
    private readonly object sync = new();
    private Dictionary<string, string> Load()
    {
        if (!File.Exists(path)) return [];
        return Decode(UpdateFiles.Read(path, MaximumBytes));
    }
    private static Dictionary<string, string> Decode(byte[] bytes)
    {
        var state = JsonSerializer.Deserialize<State>(bytes);
        if (state is not { SchemaVersion: 1, Values.Count: <= 32 } || state.Values.Any(pair => !Valid(pair.Key, pair.Value)))
            throw new InvalidDataException("The update state is incompatible.");
        return state.Values;
    }
    private static bool Valid(string key, string? value) => key.Length is > 0 and <= 128 && !key.Any(char.IsControl) && value is { Length: <= 4096 } && !value.Contains('\0');

    // A full install can repair the app even when its optional update state
    // is unreadable. Move only checked, demonstrably damaged state aside so
    // the new app can start checks again. Leave future schemas and IO failures alone.
    internal Version? RecoverForFullInstallation()
    {
        lock (sync)
        {
            byte[] bytes; long length;
            try { bytes = UpdateFiles.ReadPrefix(path, MaximumBytes, out length); }
            catch (Exception error) when (StateUnavailable(error)) { return null; }

            if (length <= MaximumBytes)
            {
                try { return Version.TryParse(Decode(bytes).GetValueOrDefault(UpdateHandoff.PatchFailedKey), out var build) ? build : null; }
                catch (Exception error) when (error is JsonException or InvalidDataException) { }
            }
            if (!HasUnsupportedSchema(bytes, complete: length == bytes.Length))
                try
                {
                    // Keep a file another process has already replaced. An
                    // oversized file needs only a bounded probe and a rename.
                    byte[] current = UpdateFiles.ReadPrefix(path, MaximumBytes, out long currentLength);
                    if (currentLength == length && current.AsSpan().SequenceEqual(bytes)) FileQuarantine.Move(path, UpdateFiles.Check);
                }
                catch (Exception recovery) when (StateUnavailable(recovery)) { }
            return null;
        }
    }
    private static bool HasUnsupportedSchema(byte[] bytes, bool complete)
    {
        try
        {
            var reader = new Utf8JsonReader(bytes, isFinalBlock: complete, state: default);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return false;
            while (reader.Read())
                if (reader.CurrentDepth == 1 && reader.TokenType == JsonTokenType.PropertyName &&
                    string.Equals(reader.GetString(), "SchemaVersion", StringComparison.OrdinalIgnoreCase) && reader.Read() &&
                    (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt32(out int schema) || schema != 1)) return true;
        }
        catch (JsonException) { }
        return false;
    }
    internal static bool StateUnavailable(Exception error) => error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException;
    internal void ClearVerifiedRepair(Version expected)
    {
        lock (sync)
        {
            try
            {
                var values = Load();
                if (!Version.TryParse(values.GetValueOrDefault(UpdateHandoff.PatchFailedKey), out var build) || build != expected) return;
                values.Remove(UpdateHandoff.PatchFailedKey);
                Save(values);
            }
            catch (Exception error) when (StateUnavailable(error)) { }
        }
    }
    internal string? Read(string key) { lock (sync) { return Load().GetValueOrDefault(key); } }
    internal void Write(string key, string? value)
    {
        lock (sync)
        {
            if (!Valid(key, value ?? "")) throw new InvalidDataException("Invalid update state.");
            var values = Load();
            if (value == null) values.Remove(key); else values[key] = value;
            if (values.Count > 32) throw new InvalidDataException("Too much update state.");
            Save(values);
        }
    }
    private void Save(Dictionary<string, string> values)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new State(1, values));
        if (bytes.Length > MaximumBytes) throw new InvalidDataException("Update state exceeds its limit.");
        UpdateFiles.Write(path, bytes);
    }
    internal bool ClaimNotes(string build)
    {
        lock (sync) { if (Read("LastPresentedBuild") == build) return false; Write("LastPresentedBuild", build); return true; }
    }
}
