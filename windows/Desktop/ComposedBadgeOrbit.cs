using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace CodexPacer.Windows;

// Only the rotating ring is a native decoration. WPF retains the badge core,
// transient effects, input, and accessibility; no WPF frame clock is retained.
internal sealed class ComposedBadgeOrbit : IDisposable
{
    private const int RemovedMessage = 0x85A2;
    private readonly ActivityBadge badge;
    private readonly OrbitPaint paint;
    private readonly Window owner;
    private readonly HwndSource source;
    private readonly Action unavailable;
    private readonly Texture texture;
    private readonly Update update;
    private readonly HandleAction hide, destroy, testLoss;
    private readonly List<DependencyObject> ancestors = [];
    private static readonly DependencyPropertyDescriptor OpacityDescriptor = DependencyPropertyDescriptor.FromProperty(UIElement.OpacityProperty, typeof(UIElement));
    private IntPtr handle;
    private bool enabled, dirty = true;
    private double textureScale;
    private Frame? last;
    private readonly record struct Frame(int X, int Y, int Width, int Height, double Scale, double Opacity, bool Ending);
    internal IntPtr WindowHandle { get; }
    internal long Uploads { get; private set; }
    internal ComposedBadgeOrbit(ActivityBadge badge, OrbitPaint paint, Action unavailable)
    {
        this.badge = badge; this.paint = paint; this.unavailable = unavailable;
        owner = Window.GetWindow(badge) ?? throw new InvalidOperationException("The badge is not attached.");
        var hwnd = new WindowInteropHelper(owner).Handle;
        source = HwndSource.FromHwnd(hwnd) ?? throw new InvalidOperationException("The badge HWND is not initialized.");
        IntPtr library = NativeCompositionBackdrop.Library();
        T Export<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, name));
        texture = Export<Texture>("pacer_orbit_texture"); update = Export<Update>("pacer_orbit_update");
        hide = Export<HandleAction>("pacer_orbit_hide"); destroy = Export<HandleAction>("pacer_surface_destroy"); testLoss = Export<HandleAction>("pacer_surface_test_loss");
        Check(Export<Create>("pacer_orbit_create")(hwnd, RemovedMessage, out handle));
        WindowHandle = Export<GetWindow>("pacer_surface_window")(handle);
        // LayoutUpdated is raised for every layout pass on the thread, so it is
        // followed only while the orbit shows; moves and fades have their own events.
        source.AddHook(Message); paint.Changed += PaintChanged; owner.LocationChanged += Layout;
        badge.RenderTransform.Changed += Layout;
        for (DependencyObject? node = badge; node != null; node = VisualTreeHelper.GetParent(node))
            if (node is UIElement) { ancestors.Add(node); OpacityDescriptor.AddValueChanged(node, Layout); }
    }
    internal void Set(bool value)
    {
        if (value != enabled) { if (value) badge.LayoutUpdated += Layout; else badge.LayoutUpdated -= Layout; }
        enabled = value;
        if (!value) { hide(handle); last = null; return; }
        Sync();
    }
    // A change of services eases its colours for a third of a second; the
    // compositor keeps turning the previous texture meanwhile and receives
    // only the final one, instead of a readback and upload for every frame.
    private void PaintChanged() { dirty = true; if (!paint.Transitioning) Sync(); }
    private void Layout(object? sender, EventArgs args) => Sync();
    private void Sync()
    {
        if (handle == IntPtr.Zero || !enabled || !badge.IsVisible || badge.ActualWidth <= 0 || badge.ActualHeight <= 0) return;
        if (PresentationSource.FromVisual(badge) == null) { hide(handle); last = null; return; }
        try
        {
            Point start = badge.PointToScreen(new()), end = badge.PointToScreen(new(badge.ActualWidth, badge.ActualHeight));
            double scale = (end.Y - start.Y) / 20, opacity = 1;
            foreach (var node in ancestors) opacity *= ((UIElement)node).Opacity;
            var frame = new Frame((int)Math.Round(start.X), (int)Math.Round(start.Y), Math.Max(1, (int)Math.Round(end.X - start.X)),
                Math.Max(1, (int)Math.Round(end.Y - start.Y)), scale, opacity, badge.HasEndingMarker);
            double dpi = VisualTreeHelper.GetDpi(badge).DpiScaleX;
            if (dirty && (!paint.Transitioning || Uploads == 0) || textureScale != dpi)
            {
                var bitmap = paint.Bitmap(dpi); int stride = bitmap.PixelWidth * 4;
                byte[] pixels = new byte[stride * bitmap.PixelHeight]; bitmap.CopyPixels(pixels, stride, 0);
                Check(texture(handle, bitmap.PixelWidth, bitmap.PixelHeight, pixels, stride)); Uploads++; dirty = false; textureScale = dpi;
            }
            if (last == frame) return;
            Check(update(handle, frame.X, frame.Y, frame.Width, frame.Height, frame.Scale, frame.Opacity, frame.Ending ? 1 : 0, 1)); last = frame;
        }
        catch (Exception error) when (Recoverable(error)) { unavailable(); }
    }
    private IntPtr Message(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message == RemovedMessage && wparam == WindowHandle) { unavailable(); handled = true; }
        else if (message is 0x007E or 0x031E) { dirty = true; last = null; Sync(); }
        return IntPtr.Zero;
    }
    internal void InjectDeviceLoss() => testLoss(handle);
    internal static bool Recoverable(Exception error) => error is COMException or DllNotFoundException or EntryPointNotFoundException
        or BadImageFormatException or IOException or NotSupportedException;
    private static void Check(int result) { if (result < 0) throw new COMException("The badge compositor is unavailable.", result); }
    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        badge.LayoutUpdated -= Layout; enabled = false; paint.Changed -= PaintChanged; owner.LocationChanged -= Layout; badge.RenderTransform.Changed -= Layout;
        foreach (var node in ancestors) OpacityDescriptor.RemoveValueChanged(node, Layout); ancestors.Clear();
        if (!source.IsDisposed) source.RemoveHook(Message);
        var value = handle; handle = IntPtr.Zero; destroy(value);
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Create(IntPtr owner, uint message, out IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr GetWindow(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Texture(IntPtr handle, int width, int height, [In] byte[] pixels, int stride);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Update(IntPtr handle, int x, int y, int width, int height, double scale, double opacity, int ending, int show);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void HandleAction(IntPtr handle);
}
