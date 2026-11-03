using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

/// One maintenance request, scoped to the current user/session and exact exe.
/// A running app only receives a window message; it has no polling timer.
internal static class WindowsMaintenanceSignal
{
    internal const int Request = 0x504d31, Acknowledged = 0x504d32;
    internal static string Marker(string executable)
    {
        using var user = WindowsIdentity.GetCurrent();
        string sid = user.User?.Value ?? throw new IOException("The current user is unavailable.");
        string input = sid + "|" + Process.GetCurrentProcess().SessionId + "|" + Path.GetFullPath(executable).ToUpperInvariant();
        return "CodexPacer.Maintenance.v1." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(input)));
    }
    internal static async Task StopAsync(string executable, CancellationToken cancellation)
    {
        executable = Path.GetFullPath(executable);
        int session = Process.GetCurrentProcess().SessionId;
        var candidates = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(executable));
        try
        {
            var owned = candidates.Where(process =>
            {
                try { return process.Id != Environment.ProcessId && process.SessionId == session &&
                    string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase); }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
            }).ToArray();
            if (owned.Length > 16) throw new IOException("Too many instances use this installation.");
            foreach (var process in owned)
            {
                string marker = Marker(executable); uint message = RegisterWindowMessageW(marker);
                bool sent = false; var elapsed = Stopwatch.StartNew();
                while (!process.HasExited && !sent && elapsed.Elapsed < TimeSpan.FromSeconds(3))
                {
                    cancellation.ThrowIfCancellationRequested();
                    EnumWindows((window, _) =>
                    {
                        GetWindowThreadProcessId(window, out uint pid);
                        if (pid != process.Id || GetPropW(window, marker) != new IntPtr(1)) return true;
                        sent = SendMessageTimeoutW(window, message, new IntPtr(Request), IntPtr.Zero, 2, 300, out var result) != IntPtr.Zero
                            && result == new IntPtr(Acknowledged);
                        return !sent;
                    }, IntPtr.Zero);
                    if (!sent && !process.HasExited) await Task.Delay(100, cancellation);
                }
                if (!sent && !process.HasExited) throw new IOException("Close this installation before maintenance.");
                await process.WaitForExitAsync(cancellation);
            }
        }
        finally { foreach (var process in candidates) process.Dispose(); }
    }
    private delegate bool EnumerateWindow(IntPtr window, IntPtr context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessageW(string value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetPropW(IntPtr window, string name);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumerateWindow callback, IntPtr context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
