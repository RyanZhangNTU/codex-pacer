using System;
using System.Runtime.InteropServices;

namespace CodexPacer.Windows;

internal static class WindowsPlatformPolicy
{
    internal const int MinimumBuild = 19041;
    internal static bool Supports(int major, int build) => major >= 10 && build >= MinimumBuild;
    internal static bool NotificationsSupported(int build, Func<bool> probe)
    {
        if (build < MinimumBuild) return false;
        try { return probe(); }
        catch (Exception error) when (error is COMException or TypeLoadException or DllNotFoundException
            or EntryPointNotFoundException or MissingMethodException or NotSupportedException or InvalidOperationException) { return false; }
    }
}
