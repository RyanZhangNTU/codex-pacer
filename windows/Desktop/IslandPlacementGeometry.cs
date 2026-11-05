using System;
using System.Collections.Generic;
using System.Linq;

namespace CodexPacer.Windows;

internal static class IslandPlacementGeometry
{
    internal static IslandPlacement FromFrame(IslandEdge edge, MotionBounds work, MotionBounds bar) =>
        new(edge, Fraction(bar.X + bar.Width / 2 - work.X, work.Width), Fraction(bar.Y + bar.Height / 2 - work.Y, work.Height));

    internal static IslandEdge SnapEdge(MotionBounds work, MotionBounds bar, IslandEdge previous)
    {
        // Keep the highlighted edge through small reversals and corner jitter.
        var edges = new (IslandEdge Edge, double Distance)[]
        {
            (IslandEdge.Left, Math.Max(0, bar.X - work.X)),
            (IslandEdge.Right, Math.Max(0, Right(work) - Right(bar))),
            (IslandEdge.Top, Math.Max(0, bar.Y - work.Y)),
            (IslandEdge.Bottom, Math.Max(0, Bottom(work) - Bottom(bar)))
        };
        var nearest = edges.MinBy(value => value.Distance);
        if (previous != IslandEdge.Free)
        {
            double distance = edges.First(value => value.Edge == previous).Distance;
            if (distance <= 24 && (nearest.Distance > 16 || distance <= nearest.Distance + 4)) return previous;
        }
        return nearest.Distance <= 16 ? nearest.Edge : IslandEdge.Free;
    }

    internal static DisplayMonitor? MonitorAt(IReadOnlyList<DisplayMonitor> monitors, double x, double y, DisplayMonitor? current)
        => monitors.FirstOrDefault(value => value.Bounds.Valid && value.Work.Valid &&
            x >= value.Bounds.Left && x < value.Bounds.Right && y >= value.Bounds.Top && y < value.Bounds.Bottom) ?? current;

    internal static MotionBounds CollapsedFrame(this IslandPlacement placement, MotionBounds work, double width, double height)
    {
        width = Math.Min(width, work.Width); height = Math.Min(height, work.Height);
        var bar = Clamp(work, new(work.X + placement.X * work.Width - width / 2, work.Y + placement.Y * work.Height - height / 2, width, height));
        return placement.Edge switch
        {
            IslandEdge.Left => bar with { X = work.X },
            IslandEdge.Right => bar with { X = Right(work) - width },
            IslandEdge.Top => bar with { Y = work.Y },
            IslandEdge.Bottom => bar with { Y = Bottom(work) - height },
            _ => bar
        };
    }

    internal static IslandLayout Arrange(this IslandPlacement placement, MotionBounds work, IslandLayout measured, double barWidth, double barHeight, double contentHeight, bool expanded)
    {
        var edge = placement.Edge;
        var bar = placement.CollapsedFrame(work, barWidth, barHeight);
        double below = Bottom(work) - bar.Y, above = Bottom(bar) - work.Y;
        double full = placement.Vertical ? Math.Max(bar.Height, contentHeight) : bar.Height + contentHeight;
        bool up = edge == IslandEdge.Bottom || (edge != IslandEdge.Top && below < full && above > below);
        // A bar placed mid-screen can have too little room on both sides; the open
        // panel then slides inward to fit the work area instead of being clipped.
        double height = Math.Min(full, work.Height);
        double top = Math.Clamp(up ? Bottom(bar) - height : bar.Y, work.Y, Bottom(work) - height);
        double width = Math.Min(measured.CanvasWidth, work.Width);
        double center = bar.X + bar.Width / 2;
        bool left = edge == IslandEdge.Left || (!placement.Vertical && center - width / 2 < work.X);
        bool right = edge == IslandEdge.Right || (!placement.Vertical && center + width / 2 > Right(work));
        if (left) width = Math.Min(width, Right(work) - bar.X);
        if (right) width = Math.Min(width, Right(bar) - work.X);
        int anchor = left ? up ? 2 : 1 : right ? up ? 4 : 3 : up ? 5 : 0;
        var panel = Points(new MotionBounds(left ? bar.X : right ? Right(bar) - width : center - width / 2, top, width, height));
        return measured with { Target = expanded ? panel : Points(bar), CanvasWidth = panel.Width, CanvasHeight = panel.Height,
            Position = placement.Vertical ? anchor : 0, Dock = edge, OpensUp = up, Anchor = anchor };
    }

    // Fractions of a work area give fractional frames. The shared motion settles on
    // whole points, as IslandGeometry.windowFrame does on the Mac, so a fractional
    // target would never match the displayed size. Rounding each edge keeps shared
    // edges shared and integral sizes unchanged.
    private static MotionBounds Points(MotionBounds frame)
    {
        double left = Math.Round(frame.X, MidpointRounding.AwayFromZero), top = Math.Round(frame.Y, MidpointRounding.AwayFromZero);
        return new(left, top, Math.Max(1, Math.Round(Right(frame), MidpointRounding.AwayFromZero) - left),
            Math.Max(1, Math.Round(Bottom(frame), MidpointRounding.AwayFromZero) - top));
    }

    internal static MotionBounds Clamp(MotionBounds work, MotionBounds bounds)
    {
        double width = Math.Min(work.Width, bounds.Width), height = Math.Min(work.Height, bounds.Height);
        return new(Math.Clamp(bounds.X, work.X, Right(work) - width), Math.Clamp(bounds.Y, work.Y, Bottom(work) - height), width, height);
    }

    private static double Right(MotionBounds bounds) => bounds.X + bounds.Width;
    private static double Bottom(MotionBounds bounds) => bounds.Y + bounds.Height;
    private static double Fraction(double offset, double length) => Math.Clamp(offset / length, 0, 1);
}
