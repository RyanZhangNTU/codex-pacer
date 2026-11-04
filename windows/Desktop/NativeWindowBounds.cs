using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace CodexPacer.Windows;

internal static class NativeWindowBounds
{
    internal static void MoveToDisplay(Window window, ScreenRectangle display)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero || !display.Valid || !GetWindowRect(hwnd, out var current)) return;
        int width = Math.Max(1, Math.Min(current.Right - current.Left, display.Right - display.Left));
        int height = Math.Max(1, Math.Min(current.Bottom - current.Top, display.Bottom - display.Top));
        if (!SetWindowPos(hwnd, IntPtr.Zero, display.Left + (display.Right - display.Left - width) / 2, display.Top, width, height, 0x0004 | 0x0010))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    internal static bool RaiseWithoutActivation(Window window)
        => SetWindowPos(new WindowInteropHelper(window).Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    internal static void Apply(Window window, MotionBounds bounds)
    {
        if (PresentationSource.FromVisual(window) is not HwndSource source || source.CompositionTarget == null)
        {
            window.Left = bounds.X; window.Top = bounds.Y; window.Width = bounds.Width; window.Height = bounds.Height;
            return;
        }
        // Move and resize the layered HWND together. Four WPF property
        // setters otherwise send separate native updates for the same frame.
        var transform = source.CompositionTarget.TransformToDevice;
        Point origin = transform.Transform(new Point(bounds.X, bounds.Y));
        Vector size = transform.Transform(new Vector(bounds.Width, bounds.Height));
        ApplyPixels(source.Handle, new(origin.X, origin.Y, size.X, size.Y));
    }
    internal static void MakeInputTransparent(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        const int exStyle = -20;
        SetWindowLongPtr(handle, exStyle, new IntPtr(GetWindowLongPtr(handle, exStyle).ToInt64() | 0x080000A0L));
    }
    internal static void ApplyPixels(Window window, MotionBounds bounds)
        => ApplyPixels(new WindowInteropHelper(window).Handle, bounds);
    private static void ApplyPixels(IntPtr handle, MotionBounds bounds)
    {
        static int Pixel(double value) => checked((int)Math.Round(value, MidpointRounding.AwayFromZero));
        int x = Pixel(bounds.X), y = Pixel(bounds.Y), width = Math.Max(1, Pixel(bounds.Width)), height = Math.Max(1, Pixel(bounds.Height));
        if (!GetWindowRect(handle, out var current)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (current.Left == x && current.Top == y && current.Right - current.Left == width && current.Bottom - current.Top == height) return;
        // WPF observes WM_MOVE/WM_SIZE and updates its DPs without issuing a
        // second resize. Do not activate the island or alter its Z order.
        if (!SetWindowPos(handle, IntPtr.Zero, x, y, width, height, 0x0004 | 0x0010))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [StructLayout(LayoutKind.Sequential)] private struct WindowRect { internal int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr window, out WindowRect rectangle);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
