using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Interop;

namespace CodexPacer.Windows;

internal enum InstanceAction { Show = 1, Settings = 2 }

/// A second launch can only request Show or Settings in this user's desktop.
/// No task, path, credential, notification payload or arbitrary command crosses.
internal sealed class WindowsInstanceActivation : IDisposable
{
    private const int Acknowledged = 0x50414331;
    private readonly Window window;
    private readonly Action<InstanceAction> activated;
    private readonly string marker;
    private readonly uint message;
    private HwndSource? source;
    private IntPtr handle;
    private bool disposed;

    internal WindowsInstanceActivation(Window window, Action<InstanceAction> activated, Guid? qa = null)
    {
        this.window = window; this.activated = activated;
        string name = Scope(qa); marker = name + ".Window"; message = RegisterWindowMessageW(name);
        if (message == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        window.SourceInitialized += Initialized; window.Closed += Closed;
        if (new WindowInteropHelper(window).Handle != IntPtr.Zero) Attach();
    }
    private static string Scope(Guid? qa)
    {
        using var identity = WindowsIdentity.GetCurrent();
        string sid = identity.User?.Value ?? throw new InvalidOperationException("The current user is unavailable.");
        string user = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid))).Substring(0, 24);
        return "CodexPacer.Activate.v1." + user + "." + Process.GetCurrentProcess().SessionId + (qa is Guid id ? ".QA." + id.ToString("N") : "");
    }
    private void Initialized(object? sender, EventArgs args) => Attach();
    private void Closed(object? sender, EventArgs args) => Dispose();
    private void Attach()
    {
        if (disposed || source != null) return;
        handle = new WindowInteropHelper(window).Handle;
        source = HwndSource.FromHwnd(handle) ?? throw new InvalidOperationException("The app window is unavailable.");
        source.AddHook(Receive);
        if (!SetPropW(handle, marker, new IntPtr(1))) { source.RemoveHook(Receive); source = null; throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
    }
    private IntPtr Receive(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (disposed || (uint)msg != message || lParam != IntPtr.Zero || wParam.ToInt64() is not (1 or 2)) return IntPtr.Zero;
        var action = (InstanceAction)wParam.ToInt32();
        window.Dispatcher.InvokeAsync(() => { if (!disposed) activated(action); });
        handled = true; return new IntPtr(Acknowledged);
    }
    internal static bool TryActivate(InstanceAction action, Guid? qa = null)
    {
        if (action is not (InstanceAction.Show or InstanceAction.Settings)) return false;
        string name = Scope(qa), marker = name + ".Window"; uint message = RegisterWindowMessageW(name);
        if (message == 0) return false;
        var deadline = Stopwatch.StartNew();
        do
        {
            bool sent = false;
            EnumWindows((hwnd, _) =>
            {
                if (GetPropW(hwnd, marker) != new IntPtr(1)) return true;
                GetWindowThreadProcessId(hwnd, out uint process); AllowSetForegroundWindow(process);
                sent = SendMessageTimeoutW(hwnd, message, new IntPtr((int)action), IntPtr.Zero, 2, 300, out var result) != IntPtr.Zero && result == new IntPtr(Acknowledged);
                return !sent;
            }, IntPtr.Zero);
            if (sent) return true;
            Thread.Sleep(40);
        // The first process owns its mutex before WPF creates the marked HWND.
        // Cold startup must have time to publish it; an existing ready window
        // still acknowledges on the first attempt.
        } while (deadline.Elapsed < TimeSpan.FromSeconds(8));
        return false;
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        window.SourceInitialized -= Initialized; window.Closed -= Closed;
        if (handle != IntPtr.Zero) RemovePropW(handle, marker);
        if (source is { IsDisposed: false }) source.RemoveHook(Receive);
        source = null; handle = IntPtr.Zero;
    }
    private delegate bool EnumerateWindow(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SetPropW(IntPtr hwnd, string name, IntPtr value);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetPropW(IntPtr hwnd, string name);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr RemovePropW(IntPtr hwnd, string name);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumerateWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool AllowSetForegroundWindow(uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint milliseconds, out IntPtr result);
}
