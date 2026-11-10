using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// <summary>
/// The folder of engine crash reports and the host's part of each one.
/// </summary>
/// <remarks>
/// The engine writes a report when it stops on a fault it can observe. The host
/// then adds what only it knows: the exit code and the last text the engine
/// wrote to standard error, such as a Swift fatal error. When the engine was
/// ended without a chance to write, the host writes the whole report. A report
/// is meant to be attached to a public issue, so the user's folder never
/// appears in it.
/// </remarks>
internal sealed class EngineCrashLog
{
    internal const string Folder = "CrashLogs", Prefix = "engine-crash-", Title = "Codex Pacer engine crash report 1";
    internal const int Kept = 10, MaximumOutput = 2000;
    internal string Directory { get; }
    internal string Version { get; }
    private readonly string profile;
    private static readonly System.Text.RegularExpressions.Regex UserFolder = new(@"([\\/]users[\\/]+)[^\\/\s""']+",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    internal EngineCrashLog(string directory, string version, string? profile = null)
    {
        Directory = Path.GetFullPath(directory); Version = version;
        this.profile = profile ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    /// <summary>Creates the folder and keeps only the newest reports. Null when the folder cannot be used.</summary>
    internal static EngineCrashLog? Prepare(string directory, string version)
    {
        try
        {
            var log = new EngineCrashLog(directory, version);
            System.IO.Directory.CreateDirectory(log.Directory);
            log.Prune();
            return log;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary>Removes empty leftovers and all but the newest reports. Names sort by time.</summary>
    internal void Prune()
    {
        var reports = new DirectoryInfo(Directory).GetFiles(Prefix + "*.txt").OrderByDescending(file => file.Name, StringComparer.Ordinal).ToList();
        int kept = 0;
        foreach (var report in reports)
        {
            if (report.Length != 0 && kept++ < Kept) continue;
            try { report.Delete(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// Adds the host's part after the engine stopped unexpectedly. Returns the
    /// report, or null when the engine left none and exited without an error.
    /// </summary>
    internal string? Complete(int processId, int exitCode, TimeSpan uptime, string output, DateTimeOffset now)
    {
        try
        {
            string suffix = "-" + processId.ToString(CultureInfo.InvariantCulture) + ".txt";
            string? report = System.IO.Directory.Exists(Directory)
                ? new DirectoryInfo(Directory).GetFiles(Prefix + "*" + suffix).Where(file => file.Length != 0)
                    .OrderByDescending(file => file.Name, StringComparer.Ordinal).Select(file => file.FullName).FirstOrDefault()
                : null;
            if (report == null && exitCode == 0) return null;
            var text = new StringBuilder();
            if (report == null)
            {
                System.IO.Directory.CreateDirectory(Directory);
                report = Path.Combine(Directory, Prefix + now.UtcDateTime.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + suffix);
                text.Append(Title).Append('\n')
                    .Append("time: ").Append(now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)).Append('\n')
                    .Append("app: ").Append(Version).Append('\n')
                    .Append("windows: ").Append(WindowsVersion()).Append('\n')
                    .Append("process: ").Append(processId.ToString(CultureInfo.InvariantCulture)).Append('\n')
                    .Append("reason: the engine stopped without writing a report\n");
            }
            text.Append("host:\n")
                .Append("  exit: 0x").Append(unchecked((uint)exitCode).ToString("X8", CultureInfo.InvariantCulture)).Append('\n')
                .Append("  running: ").Append(((long)Math.Max(0, uptime.TotalSeconds)).ToString(CultureInfo.InvariantCulture)).Append(" s\n");
            string[] lines = Redact(output).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length != 0) text.Append("  last output:\n");
            foreach (string line in lines) text.Append("    ").Append(line).Append('\n');
            File.AppendAllText(report, text.ToString(), new UTF8Encoding(false));
            return report;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
    }

    /// <summary>
    /// The end of the engine's error text as printable lines, with the user's
    /// folder replaced, so a path in a message does not name the account.
    /// </summary>
    internal string Redact(string output)
    {
        string text = output.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        // After its message the Swift runtime prints a stack of its own: bare addresses, or, where it finds
        // its backtrace helper, a line of asterisks and then folders and memory. The report has the stack.
        foreach (string heading in new[] { "***", "Current stack trace:" })
        {
            int stack = text.StartsWith(heading, StringComparison.Ordinal) ? 0 : text.IndexOf("\n" + heading, StringComparison.Ordinal);
            if (stack >= 0) text = text[..stack];
        }
        foreach (string form in new[] { profile, profile.Replace('\\', '/') })
            if (form.Length > 3) text = text.Replace(form, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        // Other spellings of a user folder, such as escaped or POSIX-style paths.
        text = UserFolder.Replace(text, "$1%USERNAME%");
        var clean = new StringBuilder(text.Length);
        foreach (char character in text) clean.Append(character == '\n' || character == '\t' || !char.IsControl(character) ? character : '?');
        text = clean.ToString();
        if (text.Length > MaximumOutput)
        {
            // Cut at a line when one starts inside the kept part.
            text = text[^MaximumOutput..];
            int line = text.IndexOf('\n');
            if (line >= 0 && line < text.Length - 1) text = text[(line + 1)..];
        }
        return text.Trim('\n');
    }

    /// <summary>The Windows version with its update revision, which selects the system binaries.</summary>
    internal static string WindowsVersion()
    {
        Version version = Environment.OSVersion.Version;
        int revision = 0;
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            if (key?.GetValue("UBR") is int value) revision = value;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        return string.Create(CultureInfo.InvariantCulture, $"{version.Major}.{version.Minor}.{version.Build}.{revision}");
    }
}
