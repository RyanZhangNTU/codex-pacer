using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Threading;

namespace CodexPacer.Windows;

// WinEvents coalesce onto the UI dispatcher. No timer or foreground polling
// runs while the desktop and island geometry are unchanged.
internal sealed class FullscreenOcclusionObserver : IDisposable
{
    private readonly IntPtr content;
    private readonly Func<ScreenRectangle> islandBounds;
    private readonly Func<ScreenRectangle> monitorBounds;
    private readonly Action<FullscreenObservation> changed;
    private readonly DispatcherTimer wake;
    private readonly TrailingRefreshThrottle throttle;
    private readonly WinEvent callback;
    private readonly GCHandle callbackRoot;
    private readonly IntPtr[] hooks = new IntPtr[4];
    private bool disposed;
    private FullscreenObservation? previous;
    internal FullscreenOcclusionObserver(IntPtr content, Func<ScreenRectangle> islandBounds, Func<ScreenRectangle> monitorBounds,
        Action<FullscreenObservation> changed, Dispatcher dispatcher)
    {
        this.content = content; this.islandBounds = islandBounds; this.monitorBounds = monitorBounds; this.changed = changed;
        long epoch = Stopwatch.GetTimestamp();
        wake = new(DispatcherPriority.ContextIdle, dispatcher);
        throttle = new(() => Stopwatch.GetElapsedTime(epoch), delay =>
        { wake.Interval = TimeSpan.FromMilliseconds(Math.Ceiling(delay.TotalMilliseconds)); wake.Start(); }, () => wake.Stop(), Refresh);
        wake.Tick += Wake;
        callback = Event;
        callbackRoot = GCHandle.Alloc(callback);
        hooks[0] = SetWinEventHook(3, 3, IntPtr.Zero, callback, 0, 0, 0); // foreground
        hooks[1] = SetWinEventHook(0x8000, 0x8004, IntPtr.Zero, callback, 0, 0, 0); // create/destroy/show/hide/reorder
        hooks[2] = SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, callback, 0, 0, 0); // top-level location
        hooks[3] = SetWinEventHook(0x8017, 0x8018, IntPtr.Zero, callback, 0, 0, 0); // cloak/uncloak
        Request();
    }
    private void Event(IntPtr hook, uint kind, IntPtr hwnd, int objectId, int child, uint thread, uint time)
    {
        if (hwnd == IntPtr.Zero || objectId != 0 || child != 0) return;
        // Only top-level windows are enumerated; a child moving inside its window changes nothing.
        if (kind != 0x8001 && GetAncestor(hwnd, 2) is var root && root != IntPtr.Zero && root != hwnd) return;
        // The island's own see-through surfaces (content, backdrop, decoration and
        // orbit) never cover anything and follow every frame of its motion; the
        // content's own moves arrive through its window messages.
        if (hwnd == content || GetWindowThreadProcessId(hwnd, out uint process) != 0 && process == Environment.ProcessId
            && (GetWindowLongPtr(hwnd, -20).ToInt64() & (0x80000 | 0x200000)) != 0) return;
        Request();
    }
    internal void Request() => throttle.Request();
    private void Wake(object? sender, EventArgs args) { wake.Stop(); throttle.Fire(); }
    private void Refresh()
    {
        bool covered = false, above = true, applicationAbove = false;
        IntPtr application = IntPtr.Zero;
        var island = islandBounds();
        var monitor = monitorBounds();
        bool contentVisible = IsWindowVisible(content);
        if (monitor.Valid)
        {
            EnumWindows((hwnd, _) =>
            {
                if (hwnd == content) { above = false; return true; }
                if (!IsWindowVisible(hwnd)) return true;
                var info = new WindowInfo { Size = Marshal.SizeOf<WindowInfo>() };
                if (!GetWindowInfo(hwnd, ref info) || !info.Bounds.Contains(monitor)
                    || DwmGetWindowAttribute(hwnd, 14, out int cloak, sizeof(int)) != 0 || cloak != 0) return true;
                bool layered = (info.ExStyle & 0x80000) != 0;
                if (contentVisible && !covered && FullscreenOcclusionPolicy.Covers(info.Bounds, monitor, island, above, true, false,
                    layered, (info.ExStyle & 0x200000) != 0, true) && RegionContains(hwnd, info.Bounds, island)) covered = true;
                if (application != IntPtr.Zero || !info.Client.Contains(monitor)) return true;
                if (GetWindowThreadProcessId(hwnd, out uint process) == 0 || process == 0) return true;
                var kind = new StringBuilder(256); _ = GetClassName(hwnd, kind, kind.Capacity);
                bool shell = kind.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd";
                var candidate = new FullscreenCandidate(info.Bounds, info.Client, true, (info.Style & 0x20000000) != 0, false,
                    layered, (info.ExStyle & 0x80) != 0, process == Environment.ProcessId, shell, RegionContains(hwnd, info.Bounds, monitor));
                if (FullscreenDisplayPolicy.IsApplication(candidate, monitor)) { application = hwnd; applicationAbove = above; }
                return true;
            }, IntPtr.Zero);
        }
        var result = new FullscreenObservation(application, applicationAbove, covered, monitor);
        if (previous == result) return;
        previous = result; changed(result);
    }
    private static bool RegionContains(IntPtr window, ScreenRectangle bounds, ScreenRectangle island)
    {
        IntPtr region = CreateRectRgn(0, 0, 0, 0), rectangle = IntPtr.Zero;
        if (region == IntPtr.Zero) return false;
        try
        {
            int kind = GetWindowRgn(window, region);
            if (kind == 0) return true; // default rectangular window
            rectangle = CreateRectRgn(island.Left - bounds.Left, island.Top - bounds.Top, island.Right - bounds.Left, island.Bottom - bounds.Top);
            return rectangle != IntPtr.Zero && CombineRgn(rectangle, rectangle, region, 4) == 1;
        }
        finally { if (rectangle != IntPtr.Zero) DeleteObject(rectangle); DeleteObject(region); }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        throttle.Dispose(); wake.Tick -= Wake;
        foreach (var hook in hooks) if (hook != IntPtr.Zero) UnhookWinEvent(hook);
        if (callbackRoot.IsAllocated) callbackRoot.Free();
    }
    [StructLayout(LayoutKind.Sequential)] private struct WindowInfo
    {
        internal int Size; internal ScreenRectangle Bounds, Client; internal uint Style, ExStyle, Status, BorderX, BorderY;
        internal ushort Atom, Version;
    }
    private delegate bool EnumCallback(IntPtr hwnd, IntPtr value);
    private delegate void WinEvent(IntPtr hook, uint kind, IntPtr hwnd, int objectId, int child, uint thread, uint time);
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint first, uint last, IntPtr module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumCallback callback, IntPtr value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowInfo(IntPtr hwnd, ref WindowInfo value);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out int value, int size);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("user32.dll")] private static extern int GetWindowRgn(IntPtr hwnd, IntPtr region);
    [DllImport("gdi32.dll")] private static extern int CombineRgn(IntPtr output, IntPtr first, IntPtr second, int mode);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(IntPtr value);
}
