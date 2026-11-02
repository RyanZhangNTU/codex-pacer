using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace CodexPacer.Windows;

internal static class NativeWindowBounds
{
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
        static int Pixel(double value) => checked((int)Math.Round(value, MidpointRounding.AwayFromZero));
        int x = Pixel(origin.X), y = Pixel(origin.Y), width = Math.Max(1, Pixel(size.X)), height = Math.Max(1, Pixel(size.Y));
        if (!GetWindowRect(source.Handle, out var current)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (current.Left == x && current.Top == y && current.Right - current.Left == width && current.Bottom - current.Top == height) return;
        // WPF observes WM_MOVE/WM_SIZE and updates its DPs without issuing a
        // second resize. Do not activate the island or alter its Z order.
        if (!SetWindowPos(source.Handle, IntPtr.Zero, x, y, width, height, 0x0004 | 0x0010))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    [StructLayout(LayoutKind.Sequential)] private struct WindowRect { internal int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr window, out WindowRect rectangle);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
