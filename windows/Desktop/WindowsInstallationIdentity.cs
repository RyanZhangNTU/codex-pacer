using System;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace CodexPacer.Windows;

internal sealed record WindowsInstallationIdentity(string Root, Guid? QaScope)
{
    internal const string ContextFile = "installation-identity.json";
    internal string Scope => QaScope?.ToString("N") ?? "default";
    internal string RegistryKey => @"Software\CodexPacer\Installations\" + Scope;
    internal string StartupName => QaScope == null ? "CodexPacer" : "CodexPacer.QA." + Scope;
    internal string DisplayName => QaScope == null ? "Codex Pacer" : "Codex Pacer QA " + Scope;
    internal string AppId => QaScope == null ? "CodexPacer.Windows" : "CodexPacer.Windows.QA." + Scope;
    internal string Executable => Path.Combine(Root, "CodexPacer.exe");
    internal string DataRoot => QaScope == null
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer")
        : Path.Combine(Path.GetDirectoryName(Root)!, "CodexPacer-QA-" + Scope);
    internal string Shortcut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), DisplayName, "Codex Pacer.lnk");
    // Tests point this at a fixture so they never touch the real desktop.
    internal string? DesktopFolder { get; init; }
    internal string DesktopShortcut => Path.Combine(DesktopFolder ?? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), DisplayName + ".lnk");
    internal WindowsStartupRegistration Startup() => new(Executable, name: StartupName);
    internal static WindowsInstallationIdentity Load(string root, Guid? expectedScope = null, bool requireContext = false)
    {
        root = SafeRoot(root);
        string file = Path.Combine(root, ContextFile);
        if (!File.Exists(file))
        {
            if (requireContext) throw new InvalidDataException("The installation identity is missing.");
            return new(root, expectedScope);
        }
        RequireNoReparse(file);
        byte[] bytes = ReadBounded(file, 4096);
        using var json = JsonDocument.Parse(bytes);
        var value = json.RootElement;
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("schemaVersion", out var schema) || !schema.TryGetInt32(out int version) || version != 1)
            throw new InvalidDataException("The installation identity is invalid.");
        Guid? scope = null;
        if (value.TryGetProperty("qaScope", out var qa) && qa.ValueKind != JsonValueKind.Null)
        {
            if (qa.ValueKind != JsonValueKind.String || !Guid.TryParseExact(qa.GetString(), "N", out var id))
                throw new InvalidDataException("The test installation identity is invalid.");
            scope = id;
        }
        if (expectedScope != scope) throw new InvalidDataException("The installation identity differs from this package.");
        return new(root, scope);
    }
    internal static WindowsInstallationIdentity ForApp(string root)
    {
        string file = Path.Combine(root, ContextFile);
        if (!File.Exists(file)) return new(SafeRoot(root), null);
        RequireNoReparse(file);
        using var json = JsonDocument.Parse(ReadBounded(file, 4096));
        Guid? expected = json.RootElement.TryGetProperty("qaScope", out var qa) && qa.ValueKind == JsonValueKind.String
            && Guid.TryParseExact(qa.GetString(), "N", out var id) ? id : null;
        return Load(root, expected, requireContext: true);
    }
    internal static string SafeRoot(string root)
    {
        if (!Path.IsPathFullyQualified(root) || root.StartsWith(@"\\", StringComparison.Ordinal) || root.Any(char.IsControl) || root.Contains('"'))
            throw new InvalidDataException("A local installation path is required.");
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        if (string.Equals(root, Path.TrimEndingDirectorySeparator(Path.GetPathRoot(root)!), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("A drive root is not an installation directory.");
        RequireNoReparse(root); return root;
    }
    internal static void RequireNoReparse(string path)
    {
        path = Path.GetFullPath(path);
        for (string? current = path; current != null; current = Path.GetDirectoryName(current))
        {
            try { if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("Installation paths cannot contain reparse points."); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
    internal static byte[] ReadBounded(string path, int maximum)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        byte[] bytes = new byte[maximum + 1]; int count = 0;
        while (count < bytes.Length)
        {
            int read = stream.Read(bytes, count, bytes.Length - count);
            if (read == 0) break; count += read;
        }
        if (count > maximum) throw new InvalidDataException("An installation record exceeds its limit.");
        return bytes.AsSpan(0, count).ToArray();
    }
}
