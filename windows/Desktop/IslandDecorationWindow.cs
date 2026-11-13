using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// The island's shoulders and shadow, kept out of its own window so they never
/// take a click: concave fillets where an attached island meets the screen
/// edge, and a soft shadow under a floating one. A layered tool window that
/// passes every click to the window below, owned by the island so it shows,
/// hides and stays above with it.
internal sealed class IslandDecorationWindow : Window
{
    private readonly Canvas canvas = new() { IsHitTestVisible = false };
    private readonly ShadowPaint shadow = new();
    private readonly Path shoulders = new() { IsHitTestVisible = false };
    private readonly Path shoulderRim = new() { IsHitTestVisible = false, StrokeLineJoin = PenLineJoin.Round };
    private MotionBounds? placed;
    private (Rect Shell, CornerRadius Corners, string Side, Color? Fill, Color? Rim, double Width, double Radius, bool Shadow)? drawn;
    /// The screen side the shoulders meet, or empty; read by the presentation checks.
    internal string ShoulderSide { get; private set; } = "";
    internal bool ShowsShadow => shadow.Visibility == Visibility.Visible;
    internal IslandDecorationWindow(Window owner)
    {
        AllowsTransparency = true; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false;
        Background = Brushes.Transparent; Content = canvas; IsHitTestVisible = false; Owner = owner;
        SourceInitialized += (_, _) => NativeWindowBounds.MakeInputTransparent(this);
        // Crossing a DPI boundary makes WPF apply its own size; place the window again.
        DpiChanged += (_, _) => { placed = null; };
        canvas.Children.Add(shadow); canvas.Children.Add(shoulders); canvas.Children.Add(shoulderRim);
    }
    /// `bounds` is this window in screen points and `shell` the island inside it;
    /// `side` names the screen edge for shoulders, empty for none.
    internal void Present(MotionBounds bounds, Rect shell, CornerRadius corners, string side, Brush fill, Brush? rim, double rimWidth,
        double radius, bool castShadow)
    {
        if (!IsVisible)
        {
            Left = bounds.X; Top = bounds.Y; Width = bounds.Width; Height = bounds.Height;
            Show(); placed = null;
        }
        if (placed != bounds) { NativeWindowBounds.Apply(this, bounds); placed = bounds; drawn = null; }
        canvas.Width = bounds.Width; canvas.Height = bounds.Height;
        var local = new Rect(shell.X - bounds.X, shell.Y - bounds.Y, shell.Width, shell.Height);
        // An unchanged frame keeps its geometry, so a settled island draws nothing new.
        var next = (local, corners, side, (fill as SolidColorBrush)?.Color, (rim as SolidColorBrush)?.Color, rimWidth, radius, castShadow);
        if (drawn == next) return;
        drawn = next;
        ShoulderSide = side;
        if (side.Length == 1 && radius > 0)
        {
            var (fills, curves) = Shoulders(local, side[0], radius);
            shoulders.Data = fills; shoulders.Fill = fill; shoulders.Visibility = Visibility.Visible;
            shoulderRim.Data = curves; shoulderRim.Stroke = rim; shoulderRim.StrokeThickness = rimWidth;
            shoulderRim.Visibility = rim == null ? Visibility.Collapsed : Visibility.Visible;
        }
        else { shoulders.Visibility = shoulderRim.Visibility = Visibility.Collapsed; shoulders.Data = shoulderRim.Data = null; }
        shadow.Visibility = castShadow ? Visibility.Visible : Visibility.Collapsed;
        if (castShadow) shadow.Set(local, Math.Min(corners.TopLeft, Math.Min(local.Width, local.Height) / 2), bounds.Width, bounds.Height);
    }
    internal void Conceal() { if (IsVisible) Hide(); placed = null; drawn = null; }
    /// The outer bounds of what this window draws, in screen points: the
    /// shoulders and the shadow, each empty when not drawn. Read by the overlay probe.
    internal (Rect Shoulders, Rect Shadow) Regions
    {
        get
        {
            if (!IsVisible || placed is not { } at || drawn is not { } frame) return (Rect.Empty, Rect.Empty);
            Rect Screen(Rect local) => local.IsEmpty ? local : new(local.X + at.X, local.Y + at.Y, local.Width, local.Height);
            var fills = shoulders.Visibility == Visibility.Visible && shoulders.Data != null ? shoulders.Data.Bounds : Rect.Empty;
            return (Screen(fills), Screen(ShowsShadow ? ShadowPaint.Extent(frame.Shell) : Rect.Empty));
        }
    }
    /// Two fillets at the island's ends against `side`, each a quarter circle
    /// of `radius` that flares the island into the screen edge, with a sliver
    /// reaching into the island so no seam shows between them.
    internal static (Geometry Fills, Geometry Curves) Shoulders(Rect shell, char side, double radius)
    {
        double r = radius, seam = 1.5;
        var fills = new StreamGeometry(); var curves = new StreamGeometry();
        using (var fill = fills.Open())
        using (var curve = curves.Open())
        {
            void Fillet(Point corner, Point outer, Point inner, SweepDirection sweep, Rect overlap)
            {
                fill.BeginFigure(corner, true, true); fill.LineTo(outer, false, false);
                fill.ArcTo(inner, new Size(r, r), 0, false, sweep, false, false);
                fill.BeginFigure(overlap.TopLeft, true, true); fill.LineTo(overlap.TopRight, false, false);
                fill.LineTo(overlap.BottomRight, false, false); fill.LineTo(overlap.BottomLeft, false, false);
                curve.BeginFigure(outer, false, false); curve.ArcTo(inner, new Size(r, r), 0, false, sweep, true, false);
            }
            switch (side)
            {
                case 't':
                    Fillet(shell.TopLeft, new(shell.Left - r, shell.Top), new(shell.Left, shell.Top + r), SweepDirection.Clockwise, new(shell.Left, shell.Top, seam, r));
                    Fillet(shell.TopRight, new(shell.Right + r, shell.Top), new(shell.Right, shell.Top + r), SweepDirection.Counterclockwise, new(shell.Right - seam, shell.Top, seam, r));
                    break;
                case 'b':
                    Fillet(shell.BottomLeft, new(shell.Left - r, shell.Bottom), new(shell.Left, shell.Bottom - r), SweepDirection.Counterclockwise, new(shell.Left, shell.Bottom - r, seam, r));
                    Fillet(shell.BottomRight, new(shell.Right + r, shell.Bottom), new(shell.Right, shell.Bottom - r), SweepDirection.Clockwise, new(shell.Right - seam, shell.Bottom - r, seam, r));
                    break;
                case 'l':
                    Fillet(shell.TopLeft, new(shell.Left, shell.Top - r), new(shell.Left + r, shell.Top), SweepDirection.Counterclockwise, new(shell.Left, shell.Top, r, seam));
                    Fillet(shell.BottomLeft, new(shell.Left, shell.Bottom + r), new(shell.Left + r, shell.Bottom), SweepDirection.Clockwise, new(shell.Left, shell.Bottom - seam, r, seam));
                    break;
                case 'r':
                    Fillet(shell.TopRight, new(shell.Right, shell.Top - r), new(shell.Right - r, shell.Top), SweepDirection.Clockwise, new(shell.Right - r, shell.Top, r, seam));
                    Fillet(shell.BottomRight, new(shell.Right, shell.Bottom + r), new(shell.Right - r, shell.Bottom), SweepDirection.Counterclockwise, new(shell.Right - r, shell.Bottom - seam, r, seam));
                    break;
            }
        }
        fills.Freeze(); curves.Freeze(); return (fills, curves);
    }

    /// A soft shadow below a floating island, built from rings that fade with
    /// distance. The island's own area stays clear, so nothing darkens its surface.
    private sealed class ShadowPaint : FrameworkElement
    {
        private const double Blur = 18, Fall = 6;
        private const int Steps = 10;
        private Rect shell;
        private double radius;
        internal ShadowPaint() { IsHitTestVisible = false; }
        /// The outermost ring, which contains every smaller one.
        internal static Rect Extent(Rect shell) => new(shell.X - Blur, shell.Y - Blur + Fall, shell.Width + 2 * Blur, shell.Height + 2 * Blur);
        internal void Set(Rect value, double corner, double width, double height)
        {
            if (shell == value && radius == corner && Width == width && Height == height) return;
            shell = value; radius = corner; Width = width; Height = height; InvalidateVisual();
        }
        protected override void OnRender(DrawingContext drawing)
        {
            if (shell.Width <= 0 || shell.Height <= 0) return;
            var island = new RectangleGeometry(shell, radius, radius); island.Freeze();
            for (int step = Steps; step >= 1; step--)
            {
                double t = step / (double)Steps, grow = Blur * t;
                var area = new Rect(shell.X - grow, shell.Y - grow + Fall * t, shell.Width + 2 * grow, shell.Height + 2 * grow);
                var ring = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(area, radius + grow, radius + grow), island);
                ring.Freeze();
                var ink = new SolidColorBrush(Color.FromArgb((byte)Math.Round(255 * 0.05 * (1 - t * 0.6)), 0, 0, 0)); ink.Freeze();
                drawing.DrawGeometry(ink, null, ring);
            }
        }
    }
}
