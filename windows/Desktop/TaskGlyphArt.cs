using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The task icon's centre glyphs, drawn as paths so each can light one part
/// at a time: the three stars while thinking, the dots while replying, the
/// cursor while a tool runs. A glyph never turns, scales or moves; only its
/// parts brighten and dim. Paths use the Mac's 24-unit box with y running down.
internal static class TaskGlyphArt
{
    /// How a part's opacity loops. Every part of one glyph shares a period, and
    /// parts of a wave start one after another.
    internal sealed record Rhythm(double Period, double[] Values, double[] Times, double Offset, bool Stepped = false)
    {
        internal static Rhythm Wave(int index, double period, double step, double low) => new(period, [low, 1, low, low], [0, 0.25, 0.6, 1], index * step);
        /// Two frames, like a text cursor.
        internal static readonly Rhythm Blink = new(1.1, [1, 0.12], [0, 0.5], 0, Stepped: true);
        internal static readonly Rhythm SandTop = new(2.4, [1, 0.2, 1], [0, 0.65, 1], 0);
        internal static readonly Rhythm SandBottom = new(2.4, [0.2, 1, 0.2], [0, 0.65, 1], 0);
    }
    internal sealed record Part(Geometry Path, bool Filled, Rhythm? Rhythm = null);

    /// Wire symbols for the working stages; anything else has no working glyph.
    internal static bool IsWorking(string symbol) => symbol is "sparkle" or "terminal" or "ellipsis.bubble" or "text.bubble" or "hourglass"
        or "cloud" or "arrow.triangle.branch" or "moon.zzz" or "zzz";
    /// Wire symbols that fill a solid disc: a request for the user or an ending.
    internal static bool IsSolid(string symbol) => symbol is "hand.raised" or "questionmark.bubble" or "checkmark.circle" or "pause.circle" or "xmark.circle";
    internal static bool AsksUser(string symbol) => symbol is "hand.raised" or "questionmark.bubble";

    /// The working glyph for a stage. Stages without one draw no parts.
    internal static IReadOnlyList<Part> Parts(string symbol) => symbol switch
    {
        // Three stars, the large one dimming least so the glyph always reads.
        "sparkle" => [new(Star(9.6, 14, 7.2), false, new(2.1, [0.55, 1, 0.55, 0.55], [0, 0.25, 0.6, 1], 0)),
                      new(Star(17.6, 5.6, 3.6), true, Rhythm.Wave(1, 2.1, 0.35, 0.3)),
                      new(Star(20, 17.6, 2.3), true, Rhythm.Wave(2, 2.1, 0.35, 0.3))],
        "terminal" => [new(new RectangleGeometry(new Rect(3.5, 5, 17, 14), 3.2, 3.2), false),
                       new(Svg("M7.6 10.1l2.6 1.9-2.6 1.9"), false),
                       new(Svg("M12.6 14.2h3.8"), false, Rhythm.Blink)],
        "ellipsis.bubble" or "text.bubble" => [new(Bubble, false),
            new(Dot(8.6, 11.2, 1.25), true, Rhythm.Wave(0, 1.2, 0.18, 0.28)),
            new(Dot(12, 11.2, 1.25), true, Rhythm.Wave(1, 1.2, 0.18, 0.28)),
            new(Dot(15.4, 11.2, 1.25), true, Rhythm.Wave(2, 1.2, 0.18, 0.28))],
        "hourglass" => [new(Svg("M7 3.5h10M7 20.5h10"), false),
                        new(Svg("M8.2 3.5v2.3c0 2.3 1.5 3.8 3.8 6.2 2.3-2.4 3.8-3.9 3.8-6.2V3.5"), false),
                        new(Svg("M8.2 20.5v-2.3c0-2.3 1.5-3.8 3.8-6.2 2.3 2.4 3.8 3.9 3.8 6.2v2.3"), false),
                        new(Svg("M10 6.6h4l-2 2.3z"), true, Rhythm.SandTop),
                        new(Svg("M9.6 19.2h4.8c-.35-1.5-1.2-2.4-2.4-3.2-1.2.8-2.05 1.7-2.4 3.2z"), true, Rhythm.SandBottom)],
        // A cloud Project only says it is working, so its glyph keeps still.
        "cloud" => [new(Svg("M7.6 18.2h9a4 4 0 0 0 .5-7.97 5.4 5.4 0 0 0-10.3 1.2A3.4 3.4 0 0 0 7.6 18.2z"), false)],
        "arrow.triangle.branch" => [new(Svg("M12 17.2v-4.6M12 12.6L8 8.4M12 12.6l4-4.2"), false),
            new(Dot(12, 19.2, 1.9), true, Rhythm.Wave(0, 2.1, 0.35, 0.3)),
            new(Dot(6.6, 6.8, 1.9), true, Rhythm.Wave(1, 2.1, 0.35, 0.3)),
            new(Dot(17.4, 6.8, 1.9), true, Rhythm.Wave(2, 2.1, 0.35, 0.3))],
        "moon.zzz" or "zzz" => [new(Svg("M11.8 6.2a6.6 6.6 0 1 0 6.9 8.9 5.2 5.2 0 0 1-6.9-8.9z"), false),
            new(Svg("M14.6 3.6h2.9l-2.9 2.9h2.9"), false, new(3, [0.2, 1, 0.2], [0, 0.5, 1], 0)),
            new(Svg("M18.4 8.4h2.2l-2.2 2.2h2.2"), false, new(3, [0.2, 1, 0.2], [0, 0.5, 1], 1.5))],
        _ => []
    };

    /// The check a finished task draws inside its disc.
    internal static readonly Geometry Check = Svg("M7.4 12.4l3.1 3.1 6.1-6.6");
    /// The moon an unknown state shows on its own.
    internal static readonly Geometry Moon = Svg("M11.8 4.2a8 8 0 1 0 8.2 11 6.4 6.4 0 0 1-8.2-11z");

    /// The dark marks on a solid disc: filled shapes and strokes, as the Mac's filled symbols read.
    internal static IReadOnlyList<Part> Solid(string symbol) => symbol switch
    {
        "hand.raised" => [new(Svg("M7.6 13V7.2c0-1.1 1.6-1.1 1.6 0V11.4V5.4c0-1.1 1.6-1.1 1.6 0v6V4.6c0-1.1 1.6-1.1 1.6 0v6.8V6c0-1.1 1.6-1.1 1.6 0v6.6l.9-1.7c.6-1 2-.5 1.7.6l-1.6 4.7c-.8 2.4-2.6 4-5.2 4-2.9 0-4.6-2.2-4.6-5.2z"), true)],
        "questionmark.bubble" => [new(Bubble, true), new(Svg("M9.9 9.3c0-1.5 1-2.4 2.2-2.4s2.2.8 2.2 2c0 1.6-2.1 1.7-2.1 3.3M12.2 14.6v.1"), false)],
        "pause.circle" => [new(new RectangleGeometry(new Rect(7.6, 6.4, 3, 11.2), 1, 1), true), new(new RectangleGeometry(new Rect(13.4, 6.4, 3, 11.2), 1, 1), true)],
        "xmark.circle" => [new(Svg("M8.2 8.2l7.6 7.6M15.8 8.2l-7.6 7.6"), false)],
        "checkmark.circle" => [new(Check, false)],
        _ => []
    };

    private static readonly Geometry Bubble = BubblePath();
    private static Geometry BubblePath()
    {
        const double r = 2.7;
        var figure = new PathFigure { StartPoint = new Point(6.2, 5.2), IsClosed = true };
        void Line(double x, double y) => figure.Segments.Add(new LineSegment(new Point(x, y), true));
        void Corner(double x, double y) => figure.Segments.Add(new ArcSegment(new Point(x, y), new Size(r, r), 0, false, SweepDirection.Clockwise, true));
        Line(20.5 - r, 5.2); Corner(20.5, 5.2 + r);
        Line(20.5, 17.2 - r); Corner(20.5 - r, 17.2);
        Line(11.7, 17.2); Line(7.8, 20.1); Line(7.8, 17.2);
        Line(3.5 + r, 17.2); Corner(3.5, 17.2 - r);
        Line(3.5, 5.2 + r); Corner(3.5 + r, 5.2);
        var path = new PathGeometry([figure]); path.Freeze(); return path;
    }
    private static Geometry Dot(double x, double y, double radius) { var dot = new EllipseGeometry(new Point(x, y), radius, radius); dot.Freeze(); return dot; }
    /// A four-point star like the system's sparkle, centred on (x, y).
    internal static Geometry Star(double x, double y, double r)
    {
        var point = new Point(x, y - r);
        var figure = new PathFigure { StartPoint = point, IsClosed = true };
        foreach (var (sx, sy) in new[] { (1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0) })
        {
            bool horizontalFirst = sx * sy < 0;
            var a = horizontalFirst ? new Point(0.59 * sx, 0.049 * sy) : new Point(0.055 * sx, 0.6 * sy);
            var b = horizontalFirst ? new Point(0.945 * sx, 0.4 * sy) : new Point(0.41 * sx, 0.95 * sy);
            var end = new Point(point.X + sx * r, point.Y + sy * r);
            figure.Segments.Add(new BezierSegment(new Point(point.X + a.X * r, point.Y + a.Y * r), new Point(point.X + b.X * r, point.Y + b.Y * r), end, true));
            point = end;
        }
        var star = new PathGeometry([figure]); star.Freeze(); return star;
    }
    private static Geometry Svg(string data) { var geometry = Geometry.Parse(data); geometry.Freeze(); return geometry; }
}
