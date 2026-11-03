using System;
using System.Windows;
using System.Windows.Interop;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private FullscreenOcclusionObserver? occlusion;
    private HwndSource? occlusionSource;
    private bool decorationsOccluded;
    private FullscreenObservation fullscreen;
    private bool visibleRequested, applyingPolicyVisibility;
    internal bool FullscreenSuppressed => visibleRequested && !IsVisible && fullscreen.HasApplication && fullscreen.Monitor == TargetMonitorBounds();
    internal bool FullscreenRaiseFailed { get; private set; }
    private bool DecorationsAnimate => AnimationsEnabled && !decorationsOccluded;
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
            }, TargetMonitorBounds, value =>
            {
                fullscreen = value; decorationsOccluded = value.Occluded;
                ApplyFullscreenVisibility(); UpdateCompactBar();
            }, Dispatcher);
            occlusionSource = HwndSource.FromHwnd(hwnd); occlusionSource?.AddHook(OcclusionMessage);
        };
        Loaded += (_, _) => occlusion?.Request();
        IsVisibleChanged += (_, _) =>
        {
            if (!applyingPolicyVisibility) { visibleRequested = IsVisible; ApplyFullscreenVisibility(); }
            occlusion?.Request();
        };
    }
    private void RequestIslandVisibility() { visibleRequested = true; ApplyFullscreenVisibility(); }
    private void ApplyFullscreenVisibility()
    {
        if (presentationStopped || applyingPolicyVisibility) return;
        bool present = fullscreen.Monitor == TargetMonitorBounds() && fullscreen.HasApplication;
        bool visible = FullscreenDisplayPolicy.Visible(visibleRequested, compactPreferences.ShowInFullscreen, present);
        if (visible != IsVisible)
        {
            applyingPolicyVisibility = true;
            try { if (visible) Show(); else Hide(); }
            finally { applyingPolicyVisibility = false; }
        }
        if (visible && present && compactPreferences.ShowInFullscreen && fullscreen.AboveContent)
        { FullscreenRaiseFailed = !NativeWindowBounds.RaiseWithoutActivation(this); SyncBackdrop(force: true); occlusion?.Request(); }
        else if (!present || !compactPreferences.ShowInFullscreen) FullscreenRaiseFailed = false;
    }
    private IntPtr OcclusionMessage(IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled)
    {
        if (message is 0x0047 or 0x02E0 or 0x007E) occlusion?.Request();
        if (message is 0x007E or 0x001A) displays.Refresh();
        return IntPtr.Zero;
    }
    private void DisposeOcclusion()
    {
        occlusion?.Dispose(); occlusion = null;
        if (occlusionSource is { IsDisposed: false }) occlusionSource.RemoveHook(OcclusionMessage);
        occlusionSource = null;
    }
}
