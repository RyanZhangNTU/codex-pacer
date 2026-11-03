using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using System.Runtime.InteropServices;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private static readonly Brush SurfaceBlack = PacerPalette.Ink(11, 12, 14);
    // Alpha zero makes a layered HWND pass otherwise-empty areas to the next
    // window. One alpha step keeps the existing WPF controls' input surface.
    private static readonly Brush SurfaceInput = PacerPalette.Ink(0, 0, 0, 1);
    private BackdropController? backdrop;
    private BackdropSystemSource? backdropSystem;
    private HwndSource? backdropSource;
    private string islandAppearance = "classic";
    private bool destinationBlackHeader;
    private readonly Func<IBackdropSystemSource>? backdropSystemFactory;
    private readonly Func<Window, ICompositionBackdrop>? backdropFactory;
    private BackdropDecision? announcedSurface;
    private bool announcedGlass;
    internal event Action? SurfaceChanged;
    internal BackdropDecision SurfaceDecision => backdrop?.Decision ?? BackdropPolicy.Resolve(islandAppearance,
        new(Environment.OSVersion.Version.Build, true, SystemParameters.HighContrast));
    internal bool GlassVisible => backdrop?.Glass == true;
    internal IntPtr BackdropWindowHandle => backdrop?.WindowHandle ?? IntPtr.Zero;
    internal bool GlassSystemSupported => Environment.OSVersion.Version.Build >= 22621;
    private void InitializeBackdrop()
    {
        SourceInitialized += (_, _) =>
        {
            if (presentationStopped) return;
            void Post(Action value) => Dispatcher.BeginInvoke(value, DispatcherPriority.ContextIdle);
            var system = backdropSystemFactory?.Invoke() ?? (backdropSystem = new BackdropSystemSource(Post));
            backdrop = new(system, () => backdropFactory?.Invoke(this) ?? new NativeCompositionBackdrop(this), Post);
            backdrop.Changed += RefreshSurface;
            backdropSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
            var hwnd = new WindowInteropHelper(this).Handle;
            SetWindowLongPtr(hwnd, -20, new IntPtr(GetWindowLongPtr(hwnd, -20).ToInt64() | 0x08000000L | 0x80));
            backdropSource?.AddHook(BackdropMessage);
            backdrop.Prefer(islandAppearance);
            RememberDisplay();
        };
        Loaded += (_, _) => SyncBackdrop();
    }
    private void PreferSurface(string value)
    {
        islandAppearance = value; backdrop?.Prefer(value); RefreshSurface();
    }
    private void RefreshSurface()
    {
        Shell.Background = GlassVisible ? SurfaceInput : SurfaceBlack;
        double black = GlassVisible && layout.Attached ? Math.Clamp(lastFrame.BlackOpacity, 0, 1) : 0;
        Header.Background = black > 0 ? PacerPalette.Ink(11, 12, 14, (byte)Math.Round(255 * black)) : Brushes.Transparent;
        var decision = SurfaceDecision;
        if (announcedSurface != decision || announcedGlass != GlassVisible)
        { announcedSurface = decision; announcedGlass = GlassVisible; SurfaceChanged?.Invoke(); }
    }
    private void SyncBackdrop(bool force = false)
    {
        if (backdrop == null || presentationStopped) return;
        if (!IsVisible) { backdrop.Hide(); return; }
        if (!Shell.IsLoaded || Shell.ActualWidth <= 0 || Shell.ActualHeight <= 0) return;
        var clip = Shell.Clip ?? ClipShape(Shell.ActualWidth, Shell.ActualHeight, Shell.CornerRadius);
        backdrop.Apply(NativeCompositionBackdrop.Frame(this, Shell, clip), force); RefreshSurface();
    }
    private IntPtr BackdropMessage(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message == 0x0021) { handled = true; return new IntPtr(3); }
        if (message is 0x02E0 or 0x007E or 0x0047) QueueDisplayRefresh();
        if (message is 0x007E or 0x031E) backdrop?.GraphicsChanged();
        if (message is 0x001A or 0x031A) backdropSystem?.Refresh();
        return IntPtr.Zero;
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    private void DisposeBackdrop()
    {
        if (backdropSource is { IsDisposed: false }) backdropSource.RemoveHook(BackdropMessage);
        backdropSource = null;
        if (backdrop != null) { backdrop.Changed -= RefreshSurface; backdrop.Dispose(); backdrop = null; }
        backdropSystem = null;
    }
}
