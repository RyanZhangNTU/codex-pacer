using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace CodexPacer.Windows;

// WinEvents coalesce onto the UI dispatcher. No timer or foreground polling
// runs while the desktop and island geometry are unchanged.
internal sealed class FullscreenOcclusionObserver : IDisposable
{
    private readonly IntPtr content;
    private readonly Func<ScreenRectangle> islandBounds;
    private readonly Action<bool> changed;
    private readonly DispatcherTimer wake;
    private readonly TrailingRefreshThrottle throttle;
    private readonly WinEvent callback;
    private readonly GCHandle callbackRoot;
    private readonly IntPtr[] hooks = new IntPtr[4];
    private bool disposed;
    private bool? previous;
    internal FullscreenOcclusionObserver(IntPtr content, Func<ScreenRectangle> islandBounds, Action<bool> changed, Dispatcher dispatcher)
    {
        this.content = content; this.islandBounds = islandBounds; this.changed = changed;
        long epoch = Stopwatch.GetTimestamp();
        wake = new(DispatcherPriority.ContextIdle, dispatcher);
        throttle = new(() => Stopwatch.GetElapsedTime(epoch), delay => { wake.Interval = delay; wake.Start(); }, () => wake.Stop(), Refresh);
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
        Request();
    }
    internal void Request() => throttle.Request();
    private void Wake(object? sender, EventArgs args) { wake.Stop(); throttle.Fire(); }
    private void Refresh()
    {
        bool covered = false;
        var island = islandBounds();
        if (island.Valid && IsWindowVisible(content))
        {
            var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(MonitorFromWindow(content, 2), ref monitor))
            {
                EnumWindows((hwnd, _) =>
                {
                    if (hwnd == content) return false;
                    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, out var bounds)) return true;
                    long style = GetWindowLongPtr(hwnd, -20).ToInt64();
                    if (DwmGetWindowAttribute(hwnd, 14, out int cloak, sizeof(int)) != 0) return true;
                    bool cloaked = cloak != 0;
                    if (!FullscreenOcclusionPolicy.Covers(bounds, monitor.Bounds, island, true, true, cloaked,
                        (style & 0x80000) != 0, (style & 0x200000) != 0, true)) return true;
                    if (!RegionContains(hwnd, bounds, island)) return true;
                    covered = true; return false;
                }, IntPtr.Zero);
            }
        }
        if (previous == covered) return;
        previous = covered; changed(covered);
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
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { internal int Size; internal ScreenRectangle Bounds, Work; internal uint Flags; }
    private delegate bool EnumCallback(IntPtr hwnd, IntPtr value);
    private delegate void WinEvent(IntPtr hook, uint kind, IntPtr hwnd, int objectId, int child, uint thread, uint time);
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint first, uint last, IntPtr module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumCallback callback, IntPtr value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hwnd, out ScreenRectangle value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr hwnd, ref MonitorInfo value);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out int value, int size);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("user32.dll")] private static extern int GetWindowRgn(IntPtr hwnd, IntPtr region);
    [DllImport("gdi32.dll")] private static extern int CombineRgn(IntPtr output, IntPtr first, IntPtr second, int mode);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(IntPtr value);
}
