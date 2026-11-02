using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace CodexPacer.Windows;

/// Uses the same native resolver as provider auto-detection. Metadata reads
/// never start Harness or inspect its profile, account or task files.
internal sealed class WindowsHarnessApplication
{
    private readonly Find find;
    private readonly Validate validate;
    internal WindowsHarnessApplication(string directory)
    {
        find = NativeMotion.SharedExport<Find>(directory, "pacer_harness_application_find");
        validate = NativeMotion.SharedExport<Validate>(directory, "pacer_harness_application_validate");
    }
    internal string? Locate()
    {
        var buffer = new ushort[32768]; int count = find(buffer, buffer.Length);
        return count > 0 && count < buffer.Length ? new string(buffer.Take(count).Select(value => (char)value).ToArray()) : null;
    }
    internal bool IsApplication(string path)
    {
        if (string.IsNullOrEmpty(path) || path.Length >= 32768 || path.Any(char.IsControl) || !Path.IsPathFullyQualified(path)) return false;
        var wide = path.Select(value => (ushort)value).ToArray();
        return validate(wide, wide.Length) == 1;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Find([Out] ushort[] path, int capacity);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Validate([In] ushort[] path, int count);
}
