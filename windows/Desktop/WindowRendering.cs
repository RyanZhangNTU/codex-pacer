using System;
using System.Windows;
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

    internal static string Mode(Window window)
        => (PresentationSource.FromVisual(window) as HwndSource)?.CompositionTarget?.RenderMode.ToString() ?? "uninitialized";
}
