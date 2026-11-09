using System;
using System.Runtime.InteropServices;

namespace CodexPacer.Windows;

internal readonly record struct IslandLayout(MotionBounds Target, double CanvasWidth, double CanvasHeight,
    double HeaderHeight, bool Attached, int Position, double NotchWidth)
{
    internal IslandEdge Dock { get; init; }
    internal bool OpensUp { get; init; }
    internal int? Anchor { get; init; }
    internal int MotionAnchor => Anchor ?? Position;
    private readonly double stripWidth;
    /// Width of the docked strip for the measured bar size.
    internal double StripWidth { get => stripWidth > 0 ? stripWidth : 32; init => stripWidth = value; }
}

internal sealed class NativeLayout
{
    private readonly Layout layout;
    private readonly double[] output = new double[11];
    internal NativeLayout(string directory)
    {
        layout = NativeMotion.SharedExport<Layout>(directory, "pacer_layout_frame");
    }
    /// `size` indexes Core's CompactBarSize cases: small, standard, large, extra large.
    internal IslandLayout Measure(MotionBounds screen, MotionBounds workArea, int displayMode, double safeTop,
        double notchWidth, int position, bool expanded, double contentWidth, double contentHeight, double headerWidth, double stripHeight, int size = 1)
    {
        double[] input = [screen.X, screen.Y, screen.Width, screen.Height, workArea.X, workArea.Y, workArea.Width, workArea.Height,
            displayMode, safeTop, notchWidth, position, expanded ? 1 : 0, contentWidth, contentHeight, headerWidth, stripHeight, Math.Clamp(size, 0, 3)];
        if (layout(input, input.Length, output, output.Length) != 1) throw new ArgumentOutOfRangeException(nameof(contentWidth));
        return new(new(output[0], output[1], output[2], output[3]), output[4], output[5], output[6], output[7] != 0, (int)output[8], output[9])
            { StripWidth = output[10] };
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int Layout([In] double[] input, int count, [Out] double[] output, int capacity);
}
