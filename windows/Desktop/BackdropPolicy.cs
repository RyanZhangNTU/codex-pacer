using System;

namespace CodexPacer.Windows;

internal enum BackdropReason { Classic, Available, OldSystem, TransparencyOff, HighContrast, SystemUnavailable, GraphicsUnavailable, DeviceLost }
internal readonly record struct BackdropSystemState(int Build, bool Transparency, bool HighContrast, bool Available = true);
internal readonly record struct BackdropDecision(string Preferred, bool Glass, BackdropReason Reason);
internal static class BackdropPolicy
{
    internal static BackdropDecision Resolve(string preferred, BackdropSystemState state, bool failed = false, bool lost = false)
    {
        if (preferred == "classic") return new(preferred, false, BackdropReason.Classic);
        if (preferred != "liquidGlass") throw new ArgumentException("Unknown island appearance.");
        if (state.Build < 22621) return new(preferred, false, BackdropReason.OldSystem);
        if (!state.Available) return new(preferred, false, BackdropReason.SystemUnavailable);
        if (state.HighContrast) return new(preferred, false, BackdropReason.HighContrast);
        if (!state.Transparency) return new(preferred, false, BackdropReason.TransparencyOff);
        if (lost) return new(preferred, false, BackdropReason.DeviceLost);
        if (failed) return new(preferred, false, BackdropReason.GraphicsUnavailable);
        return new(preferred, true, BackdropReason.Available);
    }
}
internal sealed record BackdropFrame(int X, int Y, int Width, int Height, double Scale, double[] Polygon, bool Visible)
{
    internal bool SameGeometry(BackdropFrame other) => X == other.X && Y == other.Y && Width == other.Width && Height == other.Height
        && Scale == other.Scale && Visible == other.Visible && Polygon.AsSpan().SequenceEqual(other.Polygon);
}
internal interface IBackdropSystemSource : IDisposable
{
    BackdropSystemState Current { get; }
    event Action? Changed;
}
internal interface ICompositionBackdrop : IDisposable
{
    IntPtr WindowHandle { get; }
    event Action? DeviceRemoved;
    void Apply(BackdropFrame frame);
    void MakeBlack();
    void Hide();
}
