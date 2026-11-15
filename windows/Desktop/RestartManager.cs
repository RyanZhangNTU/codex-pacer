using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexPacer.Windows;

/// Asks an app to quit the way Windows Installer and Windows Update do: the
/// Restart Manager sends it the end-of-session messages and waits for it to
/// close. Nothing is forced; an app that declines keeps running.
internal static class RestartManager
{
    internal static bool AskToQuit(Process process)
    {
        var key = new StringBuilder(64);
        if (RmStartSession(out uint session, 0, key) != 0) return false;
        try
        {
            var start = process.StartTime.ToFileTime();
            var target = new UniqueProcess { ProcessId = process.Id, StartLow = (uint)(start & 0xFFFFFFFF), StartHigh = (uint)(start >> 32) };
            if (RmRegisterResources(session, 0, null, 1, [target], 0, null) != 0) return false;
            return RmShutdown(session, 0, IntPtr.Zero) == 0;
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { return false; }
        finally { RmEndSession(session); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct UniqueProcess { internal int ProcessId; internal uint StartLow; internal uint StartHigh; }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] private static extern int RmStartSession(out uint session, int flags, StringBuilder key);
    [DllImport("rstrtmgr.dll")] private static extern int RmEndSession(uint session);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint session, uint files, string[]? fileNames, uint applications, [In] UniqueProcess[] processes, uint services, string[]? serviceNames);
    [DllImport("rstrtmgr.dll")] private static extern int RmShutdown(uint session, uint flags, IntPtr status);
}
