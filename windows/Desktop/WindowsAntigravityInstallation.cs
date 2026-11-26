using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal static class WindowsAntigravityInstallation
{
    private const string Filename = "Antigravity.exe";
    private static readonly object Gate = new();
    private readonly record struct Stamp(uint Volume, ulong FileId, ulong Length, ulong Modified);
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll")]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);

    private static Stamp? ReadStamp(FileInfo file)
    {
        if (!file.Exists || (file.Attributes & (FileAttributes.Device | FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) return null;
        using var handle = File.OpenHandle(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (!GetFileInformationByHandle(handle, out var info)) return null;
        static ulong Combine(uint high, uint low) => (ulong)high << 32 | low;
        return new Stamp(info.Volume, Combine(info.IndexHigh, info.IndexLow), Combine(info.SizeHigh, info.SizeLow),
            Combine((uint)info.Written.dwHighDateTime, (uint)info.Written.dwLowDateTime));
    }
    private static (string Path, Stamp App, Stamp Server)? cached;

    internal static string? Resolve()
    {
        lock (Gate)
        {
            if (cached is { } known && Stamps(known.Path) == (known.App, known.Server)) return known.Path;
            cached = null;
            foreach (string candidate in Candidates())
            {
                try
                {
                    if (WindowsConversationApplication.LocalHandlerPath(candidate, [Filename]) is not string path ||
                        Stamps(path) is not { } before) continue;
                    var version = FileVersionInfo.GetVersionInfo(path);
                    if (version.ProductName != "Antigravity" || version.CompanyName != "Google" || Stamps(path) != before) continue;
                    cached = (path, before.App, before.Server);
                    return path;
                }
                catch (Exception error) when (PathError(error)) { }
            }
            return null;
        }
    }

    private static (Stamp App, Stamp Server)? Stamps(string path)
    {
        try
        {
            if (new DriveInfo(path).DriveType != DriveType.Fixed) return null;
            var server = new FileInfo(Path.Combine(Path.GetDirectoryName(path)!, "resources", "bin", "language_server.exe"));
            for (var folder = server.Directory; folder != null; folder = folder.Parent)
                if ((folder.Attributes & FileAttributes.ReparsePoint) != 0) return null;
            return ReadStamp(new FileInfo(path)) is { } app && ReadStamp(server) is { } peer ? (app, peer) : null;
        }
        catch (Exception error) when (PathError(error)) { return null; }
    }

    private static bool PathError(Exception error) => error is IOException or UnauthorizedAccessException or SecurityException
        or ArgumentException or NotSupportedException or System.ComponentModel.Win32Exception;

    private static IEnumerable<string> Candidates()
    {
        var paths = new List<string>();
        try { AddUninstallEntries(paths); }
        catch (Exception error) when (PathError(error)) { }
        try
        {
            using var handler = Registry.CurrentUser.OpenSubKey(@"Software\Classes\antigravity\shell\open\command");
            if (handler?.GetValue(null) is string command && command.StartsWith('"') && Executable(command) is { } registered)
                paths.Add(registered);
        }
        catch (Exception error) when (PathError(error)) { }
        string? local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (!string.IsNullOrEmpty(local) && Path.IsPathFullyQualified(local)) paths.Add(Path.Combine(local, "Programs", "antigravity", Filename));
        return paths;
    }

    private static void AddUninstallEntries(List<string> paths)
    {
        using var root = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall");
        foreach (string name in root?.GetSubKeyNames() ?? [])
        {
            try
            {
                using var entry = root!.OpenSubKey(name);
                if (entry?.GetValue("DisplayName") is not string display || !display.StartsWith("Antigravity", StringComparison.Ordinal) ||
                    entry.GetValue("Publisher") as string != "Google") continue;
                if (Executable(entry.GetValue("DisplayIcon")) is { } icon) paths.Add(icon);
                if (Executable(entry.GetValue("UninstallString")) is { } uninstall && Path.GetDirectoryName(uninstall) is { } directory)
                    paths.Add(Path.Combine(directory, Filename));
            }
            catch (Exception error) when (PathError(error)) { }
        }
    }

    private static string? Executable(object? field)
    {
        if (field is not string text) return null;
        var match = Regex.Match(text.Trim(), """^(?:"([^"]+\.exe)"|(.+?\.exe)(?=$|,|\s))""", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[match.Groups[1].Success ? 1 : 2].Value : null;
    }
}
