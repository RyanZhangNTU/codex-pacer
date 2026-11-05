using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace CodexPacer.Windows;

internal static class IslandScreen
{
    internal readonly record struct Context(IntPtr Monitor, MotionBounds Screen, MotionBounds Work, double Scale);
    internal static Context Read(Window window, DisplayMonitor? preferred = null)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
        {
            var work = SystemParameters.WorkArea;
            return new(IntPtr.Zero, new(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight),
                new(work.X, work.Y, work.Width, work.Height), 1);
        }
        double scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
        if (preferred != null)
        {
            var frame = preferred.AtScale(scale);
            return new(preferred.Handle, frame.Screen, frame.WorkArea, scale);
        }
        var monitor = MonitorFromWindow(hwnd, 2); var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info))
        {
            var work = SystemParameters.WorkArea;
            return new(IntPtr.Zero, new(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight),
                new(work.X, work.Y, work.Width, work.Height), VisualTreeHelper.GetDpi(window).DpiScaleX);
        }
        MotionBounds Convert(Rectangle rect) => new(rect.Left / scale, rect.Top / scale, (rect.Right - rect.Left) / scale, (rect.Bottom - rect.Top) / scale);
        return new(monitor, Convert(info.Screen), Convert(info.Work), scale);
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { internal int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { internal int Size; internal Rectangle Screen, Work; internal int Flags; }
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
}

public partial class IslandWindow
{
    private readonly IDisplayTopologySource displays;
    internal IDisplayTopologySource DisplayTopology => displays;
    internal DisplayResolution SelectedDisplay => DisplaySelection.Resolve(displays.Current, displayedPlacement ?? compactPreferences);
    private IslandScreen.Context? currentDisplay;
    private bool displayRefreshPending, displayRefreshAgain, displayForce;
    private void DisplayTopologyChanged() { CancelMove(); QueueDisplayRefresh(force: true); }
    private void RememberDisplay() { if (screenGeometry == null) currentDisplay = IslandScreen.Read(this); }
    private void QueueDisplayRefresh(bool force = false)
    {
        if (presentationStopped || screenGeometry != null || move?.Active == true) return;
        displayForce |= force;
        if (displayRefreshPending) { displayRefreshAgain = true; return; }
        displayRefreshPending = true;
        Dispatcher.BeginInvoke(() =>
        {
            try
            {
                if (presentationStopped || !Shell.IsLoaded || move?.Active == true) return;
                bool requested = displayForce; displayForce = false;
                var selected = SelectedDisplay.Display;
                var actual = IslandScreen.Read(this);
                if (selected != null && selected.Handle != actual.Monitor) NativeWindowBounds.MoveToDisplay(this, selected.Bounds);
                var current = IslandScreen.Read(this, selected);
                if (currentDisplay != current || requested)
                {
                    currentDisplay = current;
                    // Do not allocate a spring canvas spanning two monitors.
                    // Snap in the new DPI system, including while policy-hidden.
                    Relayout(snap: true);
                }
                SyncBackdrop(); occlusion?.Request(); ApplyFullscreenVisibility();
            }
            finally
            {
                displayRefreshPending = false;
                if (displayRefreshAgain) { displayRefreshAgain = false; QueueDisplayRefresh(); }
            }
        }, DispatcherPriority.ContextIdle);
    }
    private ScreenRectangle TargetMonitorBounds()
    {
        if (SelectedDisplay.Display is { } selected) return selected.Bounds;
        var current = IslandScreen.Read(this);
        return new((int)Math.Round(current.Screen.X * current.Scale), (int)Math.Round(current.Screen.Y * current.Scale),
            (int)Math.Round((current.Screen.X + current.Screen.Width) * current.Scale), (int)Math.Round((current.Screen.Y + current.Screen.Height) * current.Scale));
    }
}
