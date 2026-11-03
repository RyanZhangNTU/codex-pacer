using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace CodexPacer.Windows;

/// Bounded, atomic display/source preferences; credentials live elsewhere.
internal sealed class PreferencesStore
{
    internal const int MaximumBytes = 60 * 1024;
    private readonly string file, mutexName;
    private readonly object gate = new();
    private byte[]? basis;
    private bool loaded;
    private static (DesktopPreferences Value, bool Unavailable) Unavailable() => (new() { HideProjects = true }, true);
    internal static string DefaultFile => Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer", "preferences-v1.json"));
    internal PreferencesStore(string? file = null)
    {
        this.file = Path.GetFullPath(file ?? DefaultFile);
        mutexName = "Local\\CodexPacer.Preferences." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(this.file.ToUpperInvariant())));
    }
    private void CheckPath()
    {
        for (string? path = file; path != null; path = Path.GetDirectoryName(path))
        {
            try { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("A settings path is redirected."); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
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
            if (count > MaximumBytes) throw new IOException("Settings exceed the storage limit.");
            return bytes[..count];
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    internal (DesktopPreferences Value, bool Unavailable) Load()
    {
        lock (gate)
        {
            try
            {
                basis = Read(); loaded = true;
                return basis == null ? (new(), false) : (PreferencesCodec.Decode(basis), false);
            }
            catch (Exception error) when (Recoverable(error)) { loaded = true; return Unavailable(); }
        }
    }
    internal bool Save(DesktopPreferences settings)
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
                if (!loaded && current != null) return false;
                // Another process changed the profile after this session read it.
                if (loaded && !(basis == null ? current == null : current != null && basis.AsSpan().SequenceEqual(current))) return false;
                if (current != null) _ = PreferencesCodec.Decode(current);
                byte[] bytes = PreferencesCodec.Encode(settings, current ?? []);
                Directory.CreateDirectory(Path.GetDirectoryName(file)!); CheckPath();
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                { stream.Write(bytes); stream.Flush(flushToDisk: true); }
                CheckPath();
                File.Move(temporary, file, overwrite: true);
                basis = bytes; loaded = true; return true;
            }
            catch (Exception error) when (Recoverable(error)) { return false; }
            finally
            {
                if (acquired) mutex!.ReleaseMutex();
                mutex?.Dispose();
                try { File.Delete(temporary); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
        }
    }
    private static bool Recoverable(Exception error) => error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException
        or ArgumentException or InvalidOperationException or FormatException or System.Security.SecurityException;
}
