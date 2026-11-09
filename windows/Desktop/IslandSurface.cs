using System;
using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The island's material and its edge, chosen in Appearance: black, dark or
/// light Liquid Glass, or graphite. A fine rim follows the free edges only,
/// never the side against the screen.
public partial class IslandWindow
{
    private static readonly Brush SurfaceGraphite = PacerPalette.Ink(0x16, 0x17, 0x1B);
    /// The free edges the rim draws now: t, b, l and r; read by the presentation checks.
    internal string RimSides { get; private set; } = "";
    private static readonly Brush SurfaceLight = PacerPalette.Ink(236, 236, 240);
    // Light glass without the system material keeps a light face, so its dark ink stays readable.
    private Brush MaterialFill() => islandAppearance switch { "graphite" => SurfaceGraphite, "liquidGlassLight" => SurfaceLight, _ => SurfaceBlack };
    private (Brush Ink, double Width, Brush? Highlight) RimStyle()
    {
        if (islandAppearance == "liquidGlassLight") return (PacerPalette.Ink(0, 0, 0, 31), 0.75, null);
        if (GlassVisible) return (PacerPalette.Ink(255, 255, 255, 66), 0.75, PacerPalette.Ink(255, 255, 255, 46));
        return islandAppearance == "graphite" ? (PacerPalette.Ink(0x30, 0x33, 0x3A), 1, null)
            : (PacerPalette.Ink(255, 255, 255, 38), 0.75, PacerPalette.Ink(255, 255, 255, 20));
    }
    /// The screen side has no edge to draw: an attached or top-docked bar
    /// keeps its top, a bottom dock its bottom and a strip its outer side.
    private string FreeSides() => layout.Position is 1 or 2 ? "tbr" : layout.Position is 3 or 4 ? "tbl"
        : layout.Attached || layout.Dock == IslandEdge.Top ? "blr" : layout.Dock == IslandEdge.Bottom ? "tlr" : "tblr";
    private (double Width, double Height, CornerRadius Corners, string Sides, Color? Ink, double Thickness, Color? Highlight, bool Glass)? rimDrawn;
    private void UpdateRim(double width, double height, CornerRadius corners)
    {
        if (appearance.Current.HighContrast || width <= 2 || height <= 2) { Rim.Data = RimHighlight.Data = null; RimSides = ""; rimDrawn = null; return; }
        var (ink, thickness, highlight) = RimStyle();
        string sides = FreeSides(); RimSides = sides;
        // The same frame keeps its geometry, so a settled island draws nothing new.
        var key = (width, height, corners, sides, (ink as SolidColorBrush)?.Color, thickness, (highlight as SolidColorBrush)?.Color, GlassVisible);
        if (rimDrawn == key) return;
        rimDrawn = key;
        // Glass clips its window to whole pixels; keep the line just inside that edge.
        double inset = thickness / 2 + (GlassVisible ? 0.5 : 0);
        Rim.Stroke = ink; Rim.StrokeThickness = thickness; Rim.Data = Outline(width, height, corners, sides, inset);
        RimHighlight.Stroke = highlight;
        RimHighlight.Data = highlight != null && sides.Contains('t') ? TopEdge(width, corners, inset + thickness / 2 + 0.5) : null;
    }
    /// The rounded outline inset by `inset`, along the free sides only; corners
    /// between two free sides are traced, others end at the side.
    internal static Geometry Outline(double width, double height, CornerRadius corners, string sides, double inset)
    {
        double d = inset, w = width, h = height;
        double tl = Math.Max(0, corners.TopLeft - d), tr = Math.Max(0, corners.TopRight - d), br = Math.Max(0, corners.BottomRight - d), bl = Math.Max(0, corners.BottomLeft - d);
        // Each side runs clockwise between its corners' tangent points.
        var edges = new (char Side, Point From, Point To)[]
        {
            ('t', new(d + tl, d), new(w - d - tr, d)), ('r', new(w - d, d + tr), new(w - d, h - d - br)),
            ('b', new(w - d - br, h - d), new(d + bl, h - d)), ('l', new(d, h - d - bl), new(d, d + tl))
        };
        double[] radius = [tr, br, bl, tl];
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            bool all = sides.Length == 4;
            // Start after a side that is not drawn so each figure is one continuous run.
            int start = all ? 0 : Array.FindIndex(edges, edge => !sides.Contains(edge.Side));
            int first = all ? 0 : (start + 1) % 4;
            bool open = false;
            for (int step = 0; step < 4; step++)
            {
                int index = (first + step) % 4;
                var edge = edges[index];
                if (!sides.Contains(edge.Side)) { open = false; continue; }
                if (!open) { context.BeginFigure(edge.From, false, all); open = true; }
                context.LineTo(edge.To, true, false);
                var next = edges[(index + 1) % 4];
                // The corner after this side, when the next side is drawn too.
                if (sides.Contains(next.Side) && (all || step < 3) && radius[index] > 0)
                    context.ArcTo(next.From, new Size(radius[index], radius[index]), 0, false, SweepDirection.Clockwise, true, false);
                else if (sides.Contains(next.Side) && (all || step < 3)) context.LineTo(next.From, true, false);
            }
        }
        geometry.Freeze(); return geometry;
    }
    private IslandDecorationWindow? decoration;
    internal IntPtr DecorationWindowHandle => decoration == null ? IntPtr.Zero : new System.Windows.Interop.WindowInteropHelper(decoration).Handle;
    internal (string Shoulders, bool Shadow) Decoration => decoration?.IsVisible == true ? (decoration.ShoulderSide, decoration.ShowsShadow) : ("", false);
    /// Shoulders where an attached island meets the screen edge, and a shadow
    /// under a floating one, drawn in a window that never takes a click.
    private void UpdateDecoration(MotionFrame frame)
    {
        bool still = !presentationStopped && IsVisible && move?.Active != true && !appearance.Current.HighContrast && frame.Window.Width > 0;
        string sides = FreeSides();
        string screen = sides.Length == 4 ? "" : "tblr".First(side => !sides.Contains(side)).ToString();
        double radius = compactSizes.Shoulder;
        // Glass cannot be painted outside its window; an attached glass header is black, so its shoulders match that.
        double black = GlassVisible ? layout.Attached ? Math.Clamp(frame.BlackOpacity, 0, 1) : 0 : 1;
        bool shoulders = screen.Length > 0 && radius > 0 && black > 0.01;
        bool shadow = screen.Length == 0;
        if (!still || !shoulders && !shadow) { decoration?.Conceal(); return; }
        decoration ??= new IslandDecorationWindow(this);
        double margin = shadow ? 26 : radius + 2;
        var bounds = new MotionBounds(surfaceBounds.X - margin, surfaceBounds.Y - margin, surfaceBounds.Width + 2 * margin, surfaceBounds.Height + 2 * margin);
        var (rim, width, _) = RimStyle();
        Brush fill = GlassVisible ? PacerPalette.Ink(0, 0, 0, (byte)Math.Round(255 * black)) : MaterialFill();
        decoration.Present(bounds, new Rect(frame.Window.X, frame.Window.Y, frame.Window.Width, frame.Window.Height), Shell.CornerRadius,
            shoulders ? screen : "", fill, GlassVisible ? null : rim, width, radius, shadow);
    }
    private static Geometry TopEdge(double width, CornerRadius corners, double y)
    {
        double left = Math.Max(corners.TopLeft, y), right = width - Math.Max(corners.TopRight, y);
        var line = new LineGeometry(new Point(left, y), new Point(Math.Max(left, right), y)); line.Freeze(); return line;
    }
}
