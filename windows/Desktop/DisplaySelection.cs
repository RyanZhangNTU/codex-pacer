using System;
using System.Collections.Generic;
using System.Linq;

namespace CodexPacer.Windows;

internal sealed record DisplayMonitor(IntPtr Handle, string DevicePath, string Name, string DeviceName,
    ScreenRectangle Bounds, ScreenRectangle Work, bool Primary)
{
    internal (MotionBounds Screen, MotionBounds WorkArea) AtScale(double scale)
    {
        if (!double.IsFinite(scale) || scale <= 0) throw new ArgumentOutOfRangeException(nameof(scale));
        MotionBounds Convert(ScreenRectangle value) => new(value.Left / scale, value.Top / scale,
            ((double)value.Right - value.Left) / scale, ((double)value.Bottom - value.Top) / scale);
        return (Convert(Bounds), Convert(Work));
    }
    internal DesktopPreferences Choose(DesktopPreferences previous) => previous with
    { DisplaySelection = "specified", DisplayID = DevicePath, DisplayName = Name, DisplayX = Bounds.Left, DisplayY = Bounds.Top };
}

internal readonly record struct DisplayResolution(DisplayMonitor? Display, bool FellBack);

internal static class DisplaySelection
{
    internal static DisplayResolution Resolve(IReadOnlyList<DisplayMonitor> displays, DesktopPreferences preference)
    {
        var usable = displays.Where(value => value.Bounds.Valid && value.Work.Valid).ToArray();
        var primary = usable.FirstOrDefault(value => value.Primary) ?? usable.OrderBy(value => value.Bounds.Left)
            .ThenBy(value => value.Bounds.Top).ThenBy(value => value.DeviceName, StringComparer.OrdinalIgnoreCase).FirstOrDefault();
        if (preference.DisplaySelection != "specified") return new(primary, false);
        if (preference.DisplayID.Length > 0)
        {
            var exact = usable.Where(value => string.Equals(value.DevicePath, preference.DisplayID, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (exact.Length == 1) return new(exact[0], false);
        }
        var fallback = usable.Where(value => string.Equals(value.Name, preference.DisplayName, StringComparison.OrdinalIgnoreCase)
            && value.Bounds.Left == preference.DisplayX && value.Bounds.Top == preference.DisplayY).ToArray();
        return fallback.Length == 1 ? new(fallback[0], false) : new(primary, true);
    }
}

internal interface IDisplayTopologySource : IDisposable
{
    IReadOnlyList<DisplayMonitor> Current { get; }
    event Action? Changed;
    void Refresh();
}
