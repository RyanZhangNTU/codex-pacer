using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace CodexPacer.Windows;

internal static class FileQuarantine
{
    internal static void CheckPath(string file)
    {
        for (string? path = file; path != null; path = Path.GetDirectoryName(path))
        {
            try { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("A storage path is redirected."); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    // Rename, never copy or overwrite: the original bytes survive even if the next write fails.
    internal static string Move(string file)
    {
        CheckPath(file);
        string backup = file + ".damaged-" + DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmssfffffff'Z'", CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N");
        File.Move(file, backup);
        string pattern = "^" + Regex.Escape(Path.GetFileName(file)) + @"\.damaged-\d{8}T\d{13}Z-[0-9a-f]{32}$";
        foreach (string older in Directory.EnumerateFiles(Path.GetDirectoryName(file)!).Where(value => value != backup && Regex.IsMatch(Path.GetFileName(value), pattern))
            .OrderByDescending(Path.GetFileName, StringComparer.Ordinal).Skip(2))
        {
            CheckPath(older);
            File.Delete(older);
        }
        return Path.GetFileName(backup);
    }
}
