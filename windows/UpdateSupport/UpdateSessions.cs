using System;
using System.IO;
using System.Linq;

namespace CodexPacer.Windows;

// Each update uses DataRoot\Updates\<Guid N>: the verified installer, the
// copied helper, its plan, the result and the installer log. Only those are
// removed later; the state file and the last installer log stay.
internal static class UpdateSessions
{
    internal const string LastLog = "last-install.log", InstallLog = "install.log";
    private static readonly string[] Owned = [UpdateFeedClient.InstallerName, UpdateFeedClient.PartialName, "PacerUpdate.exe", "plan.json", "result.json", InstallLog];
    internal static string Root(string dataRoot) => Path.Combine(dataRoot, "Updates");
    internal static string Create(WindowsInstallationIdentity identity)
    {
        string directory = Path.Combine(Root(identity.DataRoot), Guid.NewGuid().ToString("N"));
        UpdateFiles.Check(directory); Directory.CreateDirectory(directory); UpdateFiles.Check(directory);
        return directory;
    }
    /// Deletes finished sessions except `keep`. A session holding a file it
    /// does not own, or one still in use, is left for a later attempt.
    /// Returns the number of sessions that remain.
    internal static int Clean(string dataRoot, string? keep = null)
    {
        string root = Root(dataRoot);
        if (!Directory.Exists(root)) return 0;
        int remaining = 0;
        foreach (string directory in Directory.EnumerateDirectories(root))
        {
            string name = Path.GetFileName(directory);
            if (!Guid.TryParseExact(name, "N", out _)) continue;
            if (string.Equals(name, keep, StringComparison.OrdinalIgnoreCase)) { remaining++; continue; }
            try
            {
                UpdateFiles.Check(directory);
                string[] files = Directory.GetFiles(directory);
                if (Directory.GetDirectories(directory).Length != 0 || files.Any(file => !Owned.Contains(Path.GetFileName(file), StringComparer.OrdinalIgnoreCase)
                    && !Path.GetFileName(file).EndsWith(".tmp", StringComparison.OrdinalIgnoreCase))) { remaining++; continue; }
                foreach (string file in files) { UpdateFiles.Check(file); File.Delete(file); }
                Directory.Delete(directory, false);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { remaining++; }
        }
        return remaining;
    }
    /// Keeps the newest installer log after its session is removed.
    internal static void PreserveLog(string session)
    {
        string log = Path.Combine(session, InstallLog);
        if (!File.Exists(log)) return;
        UpdateFiles.Write(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(session))!, LastLog), UpdateFiles.Read(log, 4 * 1024 * 1024));
    }
}
