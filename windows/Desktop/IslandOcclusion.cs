using System;
using System.Windows.Interop;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private FullscreenOcclusionObserver? occlusion;
    private HwndSource? occlusionSource;
    private bool decorationsOccluded;
    private bool DecorationsAnimate => IsVisible && AnimationsEnabled && !decorationsOccluded;
    internal bool DecorationsOccluded => decorationsOccluded;
    private void InitializeOcclusion()
    {
        SourceInitialized += (_, _) =>
        {
            if (presentationStopped) return;
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            occlusion = new(hwnd, () =>
            {
                var bounds = VisibleScreenBounds;
                return bounds.IsEmpty ? default : new((int)Math.Floor(bounds.Left), (int)Math.Floor(bounds.Top),
                    (int)Math.Ceiling(bounds.Right), (int)Math.Ceiling(bounds.Bottom));
            }, value => { decorationsOccluded = value; UpdateCompactBar(); }, Dispatcher);
            occlusionSource = HwndSource.FromHwnd(hwnd); occlusionSource?.AddHook(OcclusionMessage);
        };
        Loaded += (_, _) => occlusion?.Request();
        IsVisibleChanged += (_, _) => occlusion?.Request();
    }
    private IntPtr OcclusionMessage(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message is 0x0047 or 0x02E0 or 0x007E) occlusion?.Request();
        return IntPtr.Zero;
    }
    private void DisposeOcclusion()
    {
        occlusion?.Dispose(); occlusion = null;
        if (occlusionSource is { IsDisposed: false }) occlusionSource.RemoveHook(OcclusionMessage);
        occlusionSource = null;
    }
}
