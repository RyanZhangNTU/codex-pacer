using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Text.Json;

namespace CodexPacer.Windows;

/// Bounded, atomic display/source preferences; credentials live elsewhere.
internal sealed class PreferencesStore
{
    internal const int MaximumBytes = 60 * 1024;
    private readonly string file, mutexName;
    private readonly object gate = new();
    private byte[]? basis;
    private bool loaded;
    private readonly bool recoverDamagedFiles;
    private string? recoveryFileName;
    internal bool HasFutureVersion { get; private set; }
    internal string? TakeRecoveryFileName() { lock (gate) { string? name = recoveryFileName; recoveryFileName = null; return name; } }
    private static (DesktopPreferences Value, bool Unavailable) Unavailable() => (new() { HideProjects = true }, true);
    internal static string DefaultFile => Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer", "preferences-v1.json"));
    internal PreferencesStore(string? file = null, bool recoverDamagedFiles = true)
    {
        this.recoverDamagedFiles = recoverDamagedFiles;
        this.file = Path.GetFullPath(file ?? DefaultFile);
        mutexName = "Local\\CodexPacer.Preferences." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(this.file.ToUpperInvariant())));
    }
    private void CheckPath()
    {
        FileQuarantine.CheckPath(file);
    }
    private byte[]? Read()
    {
        CheckPath();
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            byte[] bytes = new byte[MaximumBytes + 1];
            int count = 0;
            while (count < bytes.Length)
            {
                int read = stream.Read(bytes, count, bytes.Length - count);
                if (read == 0) break;
                count += read;
            }
            return bytes[..count];
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    internal (DesktopPreferences Value, bool Unavailable) Load(bool migrateOptIns = false, Func<string, bool>? durableEvidence = null)
    {
        lock (gate)
        {
            try
            {
                using var mutex = new Mutex(false, mutexName);
                bool acquired;
                try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(1)); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return Unavailable();
                try
                {
                    basis = Read(); loaded = true; HasFutureVersion = Future(basis);
                    if (basis == null) return (new(), false);
                    if (HasFutureVersion) return Unavailable();
                    try
                    {
                        var settings = Decode(basis);
                        if (migrateOptIns && (!settings.WslOptInMigrated || !settings.DurableOptInMigrated))
                        {
                            if (!settings.WslOptInMigrated) settings = settings with { MonitorWSL = false, WslOptInMigrated = true };
                            // Profiles that already used Dot keep it; others start off.
                            if (!settings.DurableOptInMigrated)
                                settings = settings with { MonitorDurable = (durableEvidence ?? DurableUsageEvidence.HasReceipts)(settings.CodexHome), DurableOptInMigrated = true };
                            string temporary = file + ".tmp-" + Guid.NewGuid().ToString("N");
                            try { Commit(PreferencesCodec.Encode(settings, basis), temporary); }
                            catch (Exception error) when (Recoverable(error)) { }
                            finally { DeleteTemporary(temporary); }
                        }
                        return (settings, false);
                    }
                    catch (Exception error) when (Recoverable(error) && recoverDamagedFiles)
                    {
                        recoveryFileName = FileQuarantine.Move(file); basis = null;
                        return (new(), false);
                    }
                }
                finally { mutex.ReleaseMutex(); }
            }
            catch (Exception error) when (Recoverable(error)) { loaded = true; return Unavailable(); }
        }
    }
    internal bool Save(DesktopPreferences settings) => Save(settings, confirmFuture: false);
    internal bool BackupAndUseDefaults(DesktopPreferences settings) => Save(settings, confirmFuture: true);
    private bool Save(DesktopPreferences settings, bool confirmFuture)
    {
        if (!settings.IsValid) return false;
        lock (gate)
        {
            Mutex? mutex = null;
            bool acquired = false;
            string temporary = file + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                mutex = new Mutex(false, mutexName);
                try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(1)); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return false;
                byte[]? current = Read();
                HasFutureVersion = Future(current);
                if (HasFutureVersion && !confirmFuture) return false;
                if (!loaded && current != null) return false;
                bool damaged = false;
                if (current != null)
                {
                    try { _ = Decode(current); }
                    catch (Exception error) when (Recoverable(error)) { damaged = true; }
                }
                // Another process changed the profile after this session read it.
                if (!(damaged && recoverDamagedFiles && !HasFutureVersion) && loaded &&
                    !(basis == null ? current == null : current != null && basis.AsSpan().SequenceEqual(current))) return false;
                if (current != null)
                {
                    if (HasFutureVersion && confirmFuture || damaged && recoverDamagedFiles && !HasFutureVersion)
                    {
                        recoveryFileName = FileQuarantine.Move(file); basis = current = null; HasFutureVersion = false;
                    }
                    else if (damaged) return false;
                }
                byte[] bytes = PreferencesCodec.Encode(settings, current ?? []);
                Commit(bytes, temporary); return true;
            }
            catch (Exception error) when (Recoverable(error)) { return false; }
            finally
            {
                if (acquired) mutex!.ReleaseMutex();
                mutex?.Dispose();
                DeleteTemporary(temporary);
            }
        }
    }
    private void Commit(byte[] bytes, string temporary)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!); CheckPath();
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { stream.Write(bytes); stream.Flush(flushToDisk: true); }
        CheckPath();
        File.Move(temporary, file, overwrite: true);
        basis = bytes; loaded = true;
    }
    private static void DeleteTemporary(string path)
    {
        try { File.Delete(path); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    private static DesktopPreferences Decode(byte[] bytes) => bytes.Length <= MaximumBytes ? PreferencesCodec.Decode(bytes) : throw new JsonException();
    private static bool Future(byte[]? bytes)
    {
        if (bytes == null) return false;
        // A valid future envelope remains protected even if it exceeds today's size limit.
        try
        {
            var reader = new Utf8JsonReader(bytes, isFinalBlock: false, state: default);
            while (reader.Read())
                if (reader.TokenType == JsonTokenType.PropertyName && reader.CurrentDepth == 1 && reader.ValueTextEquals("schemaVersion"))
                    return reader.Read() && reader.TokenType == JsonTokenType.Number && reader.TryGetInt32(out int version) && version > PreferencesCodec.Version;
            return false;
        }
        catch (JsonException) { return false; }
    }
    private static bool Recoverable(Exception error) => error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException
        or ArgumentException or InvalidOperationException or FormatException or System.Security.SecurityException;
}
