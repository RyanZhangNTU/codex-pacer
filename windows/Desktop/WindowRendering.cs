using System;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class WindowRendering
{
    // Some multi-adapter/virtual-display sessions show an empty opaque WPF
    // client with hardware rendering. Keep the layered island's path intact.
    internal static void Prepare(Window window)
    {
        window.SourceInitialized += (_, _) =>
        {
            if (!window.AllowsTransparency && PresentationSource.FromVisual(window) is HwndSource source)
                source.CompositionTarget.RenderMode = RenderMode.SoftwareOnly;
        };
    }

    // A non-layered popup opens its own opaque HWND with the same empty client.
    internal static void Prepare(Popup popup) => popup.Opened += (_, _) =>
    {
        if (!popup.AllowsTransparency && popup.Child is Visual child && PresentationSource.FromVisual(child) is HwndSource source)
            source.CompositionTarget.RenderMode = RenderMode.SoftwareOnly;
    };

    // Show Desktop and similar shell commands minimize hidden helper hosts and
    // island parts, which then appear as a stub above the taskbar or vanish.
    // Refuse the command and undo an external minimize without activation.
    internal static void KeepUnminimized(Window window)
    {
        window.SourceInitialized += (_, _) =>
        {
            if (PresentationSource.FromVisual(window) is not HwndSource source) return;
            source.AddHook((IntPtr hwnd, int message, IntPtr wparam, IntPtr lparam, ref bool handled) =>
            {
                if (message == 0x0112 && (wparam.ToInt64() & 0xFFF0) == 0xF020) handled = true;
                else if (message == 0x0005 && wparam.ToInt64() == 1) window.Dispatcher.BeginInvoke(() => ShowWindow(hwnd, 4));
                return IntPtr.Zero;
            });
        };
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);

    internal static string Mode(Window window)
        => (PresentationSource.FromVisual(window) as HwndSource)?.CompositionTarget?.RenderMode.ToString() ?? "uninitialized";
}
