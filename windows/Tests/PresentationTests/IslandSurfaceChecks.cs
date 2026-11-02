using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using CodexPacer.Windows;
internal static class IslandSurfaceChecks
{
    internal static Task Run(IslandWindow window)
    {
        if (!window.AllowsTransparency || window.WindowStyle != WindowStyle.None || window.ShowInTaskbar)
            throw new InvalidOperationException("The Black island must retain its borderless, per-pixel-opacity host and tray lifetime.");
        if (window.Background is not SolidColorBrush brush || brush.Color.A != 0)
            throw new InvalidOperationException("The shaped window must retain a transparent canvas around its Black surface.");
        return Task.CompletedTask;
    }
}
