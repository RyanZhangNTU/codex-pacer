using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed class NativeCompositionBackdrop : ICompositionBackdrop
{
    internal const int DeviceRemovedMessage = 0x85A1;
    private static readonly Dictionary<string, IntPtr> Libraries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Update update;
    private readonly NativeHide hide;
    private readonly Black black;
    private readonly Destroy destroy;
    private readonly TestLoss testLoss;
    private readonly Window content;
    private readonly HwndSource source;
    private IntPtr handle;
    public IntPtr WindowHandle { get; }
    public event Action? DeviceRemoved;
    internal NativeCompositionBackdrop(Window content, string? path = null, bool light = false)
    {
        content.Dispatcher.VerifyAccess(); this.content = content;
        IntPtr library = Library(path);
        T Export<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, name));
        if (Export<Version>("pacer_surface_abi_version")() != 1) throw new InvalidDataException("Composition surface ABI mismatch.");
        update = Export<Update>("pacer_surface_update"); hide = Export<NativeHide>("pacer_surface_hide");
        destroy = Export<Destroy>("pacer_surface_destroy"); testLoss = Export<TestLoss>("pacer_surface_test_loss");
        black = Export<Black>("pacer_surface_black");
        var hwnd = new WindowInteropHelper(content).Handle;
        source = HwndSource.FromHwnd(hwnd) ?? throw new InvalidOperationException("The content HWND is not initialized.");
        var getWindow = Export<GetWindow>("pacer_surface_window");
        CheckResult(Export<Create>("pacer_surface_create")(hwnd, DeviceRemovedMessage, out handle));
        try
        {
            // Light Liquid Glass washes the same material light instead of dark.
            if (light) CheckResult(Export<Tone>("pacer_surface_tone")(handle, 1));
            WindowHandle = getWindow(handle);
            if (WindowHandle == IntPtr.Zero) throw new InvalidDataException("The composition HWND is missing.");
            source.AddHook(Message);
        }
        catch { destroy(handle); handle = IntPtr.Zero; throw; }
    }
    internal static IntPtr Library(string? path = null)
    {
        string binary = Path.GetFullPath(path ?? Path.Combine(AppContext.BaseDirectory, "PacerCompositionBackdrop.dll"));
        IntPtr library;
        lock (Libraries)
        {
            if (!Libraries.TryGetValue(binary, out library))
            {
                library = NativeLibrary.Load(binary); Libraries.Add(binary, library);
            }
        }
        return library;
    }
    internal static BackdropFrame Frame(Window content, FrameworkElement shell, Geometry clip)
    {
        if (!GetWindowRect(new WindowInteropHelper(content).Handle, out var bounds)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        var origin = shell.PointToScreen(new Point()); var dpi = VisualTreeHelper.GetDpi(content);
        var geometry = clip.GetFlattenedPathGeometry(.1, ToleranceType.Absolute);
        if (geometry.Figures.Count != 1) throw new InvalidOperationException("A surface needs one closed contour.");
        var polygon = new List<double>();
        void PointValue(Point point) { polygon.Add(origin.X - bounds.Left + point.X * dpi.DpiScaleX); polygon.Add(origin.Y - bounds.Top + point.Y * dpi.DpiScaleY); }
        var figure = geometry.Figures[0]; PointValue(figure.StartPoint);
        foreach (var segment in figure.Segments)
        {
            if (segment is PolyLineSegment lines) foreach (Point point in lines.Points) PointValue(point);
            else if (segment is LineSegment line) PointValue(line.Point);
            else throw new InvalidOperationException("The flattened surface has a curved segment.");
        }
        return new(bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, dpi.DpiScaleX, polygon.ToArray(), content.IsVisible);
    }
    internal void Apply(FrameworkElement shell, Geometry clip) => Apply(Frame(content, shell, clip));
    public void Apply(BackdropFrame frame)
    {
        content.Dispatcher.VerifyAccess(); ObjectDisposedException.ThrowIf(handle == IntPtr.Zero, this);
        CheckResult(update(handle, frame.X, frame.Y, frame.Width, frame.Height,
            frame.Polygon, frame.Polygon.Length / 2, frame.Scale, frame.Visible ? 1 : 0));
    }
    private static void CheckResult(int result) { if (result < 0) throw new COMException("The composition surface is unavailable.", result); }
    public void MakeBlack() { content.Dispatcher.VerifyAccess(); if (handle != IntPtr.Zero) CheckResult(black(handle)); }
    public void Hide() { content.Dispatcher.VerifyAccess(); if (handle != IntPtr.Zero) hide(handle); }
    internal void InjectDeviceLoss() { content.Dispatcher.VerifyAccess(); if (handle != IntPtr.Zero) testLoss(handle); }
    private IntPtr Message(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (handle != IntPtr.Zero && message == DeviceRemovedMessage && wparam == WindowHandle) { DeviceRemoved?.Invoke(); handled = true; }
        return IntPtr.Zero;
    }
    public void Dispose()
    {
        content.Dispatcher.VerifyAccess(); if (handle == IntPtr.Zero) return;
        if (!source.IsDisposed) source.RemoveHook(Message);
        var value = handle; handle = IntPtr.Zero; destroy(value);
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { internal int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hwnd, out Rect value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Tone(IntPtr handle, int light);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Version();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Create(IntPtr content, uint message, out IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr GetWindow(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Update(IntPtr handle, int x, int y, int width, int height, [In] double[] points, int count, double scale, int show);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void NativeHide(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Destroy(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void TestLoss(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Black(IntPtr handle);
}
