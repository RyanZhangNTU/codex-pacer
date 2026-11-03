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
    internal static Context Read(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
        {
            var work = SystemParameters.WorkArea;
            return new(IntPtr.Zero, new(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight),
                new(work.X, work.Y, work.Width, work.Height), 1);
        }
        var monitor = MonitorFromWindow(hwnd, 2); var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info))
        {
            var work = SystemParameters.WorkArea;
            return new(IntPtr.Zero, new(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight),
                new(work.X, work.Y, work.Width, work.Height), VisualTreeHelper.GetDpi(window).DpiScaleX);
        }
        double scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
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
    private IslandScreen.Context? currentDisplay;
    private bool displayRefreshPending;
    private void RememberDisplay() { if (screenGeometry == null) currentDisplay = IslandScreen.Read(this); }
    private void QueueDisplayRefresh()
    {
        if (presentationStopped || displayRefreshPending || screenGeometry != null) return;
        displayRefreshPending = true;
        Dispatcher.BeginInvoke(() =>
        {
            displayRefreshPending = false;
            if (presentationStopped || !IsVisible || !Shell.IsLoaded) return;
            var current = IslandScreen.Read(this);
            if (currentDisplay != current)
            {
                currentDisplay = current;
                // A DPI change reflows once in the new coordinate system.
                // Do not animate a spring whose previous values used another DPI.
                var pixels = VisibleScreenBounds;
                var initial = new MotionBounds(pixels.X / current.Scale, pixels.Y / current.Scale, pixels.Width / current.Scale, pixels.Height / current.Scale);
                StopRendering(); motion.Dispose();
                motion = new NativeMotion(System.IO.Path.Combine(AppContext.BaseDirectory, "Engine"), initial, expanded,
                    layout.Attached && islandAppearance == "liquidGlass", layout.Position);
                surfaceBounds = initial; destinationExpanded = !expanded;
                NativeWindowBounds.Apply(this, initial); Relayout(); StopRendering(); ApplyMotion(motion.SettledAt(transitionStarted));
            }
            SyncBackdrop();
        }, DispatcherPriority.ContextIdle);
    }
}
