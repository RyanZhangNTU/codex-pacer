using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// <summary>
/// The folder of engine crash reports and the host's part of each one.
/// </summary>
/// <remarks>
/// Every start of the engine gets an identifier of its own, which names its
/// report. The engine writes the report when it stops on a fault it can observe.
/// The host then adds what only it knows: the exit code, the running time and
/// the source line a Swift fatal error named. When the engine was ended without
/// a chance to write, the host writes the whole report. A report is meant to be
/// attached to a public issue, so it holds only these fields and none of the
/// engine's own text, which can carry paths.
/// </remarks>
internal sealed class EngineCrashLog
{
    internal const string Folder = "CrashLogs", Prefix = "engine-crash-", Title = "Codex Pacer engine crash report 1";
    internal const int Kept = 10;
    internal string Directory { get; }
    internal string Version { get; }
    // What Swift prints before it stops: `Module/File.swift:12: Fatal error: message`.
    private static readonly Regex SwiftStopLine = new(
        @"^(?:([A-Za-z0-9_]{1,64})/)?([A-Za-z0-9_+.\-]{1,64}\.swift):([0-9]{1,7}): (Fatal error|Precondition failed|Assertion failed)(?=:|\r?$)",
        RegexOptions.CultureInvariant);

    internal EngineCrashLog(string directory, string version)
    {
        Directory = Path.GetFullPath(directory); Version = version;
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

    /// <summary>Removes empty leftovers and all but the newest reports. Names sort by the time their engine started.</summary>
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
    /// The identifier of one start of the engine: its time and a random part.
    /// The host and the engine both name the report by it, so a process number
    /// that Windows hands out again cannot point at an older report.
    /// </summary>
    internal static string NewIdentifier(DateTimeOffset now)
        => now.UtcDateTime.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N")[..8];

    internal string ReportPath(string identifier) => Path.Combine(Directory, Prefix + identifier + ".txt");

    /// <summary>
    /// The source line Swift named when it stopped, or null for any other line.
    /// Only the module, the file name, the line number and the kind are kept:
    /// the message after them can quote a path, and so can everything else the
    /// runtime prints.
    /// </summary>
    internal static string? SwiftStop(string line)
    {
        Match match = SwiftStopLine.Match(line);
        if (!match.Success) return null;
        return match.Groups[4].Value + " at " + (match.Groups[1].Success ? match.Groups[1].Value + " " : "") + match.Groups[2].Value + ":" + match.Groups[3].Value;
    }

    /// <summary>
    /// Adds the host's part after the engine stopped unexpectedly. Returns the
    /// report, or null when the engine left none and exited without an error.
    /// </summary>
    internal string? Complete(string identifier, int processId, int exitCode, TimeSpan uptime, string? swiftStop, DateTimeOffset now)
    {
        try
        {
            string report = ReportPath(identifier);
            bool written = File.Exists(report) && new FileInfo(report).Length != 0;
            if (!written && exitCode == 0) return null;
            var text = new StringBuilder();
            if (!written)
            {
                System.IO.Directory.CreateDirectory(Directory);
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
            if (swiftStop != null) text.Append("  swift: ").Append(swiftStop).Append('\n');
            File.AppendAllText(report, text.ToString(), new UTF8Encoding(false));
            return report;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
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
