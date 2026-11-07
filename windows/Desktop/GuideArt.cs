using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// Drawings for the guide windows, sized like the Mac welcome guide.
internal static class GuideArt
{
    internal static readonly Color CodexTile = Color.FromRgb(125, 214, 196), ClaudeTile = Color.FromRgb(242, 156, 107), DeepSeekTile = Color.FromRgb(123, 147, 255);
    internal static Color ProviderTile(string provider) => provider == "claude" ? ClaudeTile : provider == "deepseek" ? DeepSeekTile : CodexTile;
    internal static string ProviderSymbol(string provider) => provider == "claude" ? "asterisk" : provider == "deepseek" ? "water.waves" : "chevron.left.forwardslash.chevron.right";

    /// Release highlights name Mac symbols; the nearest drawn glyph stands in.
    internal static string Symbol(string symbol) => IconGlyph.Has(symbol) ? symbol : symbol switch
    {
        "flame" => "flame.fill", "network" => "point.3.connected.trianglepath.dotted", "cpu" => "speedometer", "hand.wave" => "hand.raised",
        "macwindow" => "rectangle.topthird.inset.filled", "sidebar.left" or "list.bullet.rectangle" => "text.alignleft",
        "circle.dashed" => "circle.circle", "circle.bottomhalf.filled" => "smallcircle.filled.circle",
        _ => "sparkle"
    };

    /// The same tinted tile as the Settings sidebar, at any size.
    internal static Border Tile(string symbol, Color color, double size, bool darkGlyph = false)
    {
        Color lighter = Color.FromRgb((byte)Math.Min(255, color.R + 10), (byte)Math.Min(255, color.G + 10), (byte)Math.Min(255, color.B + 10));
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.26), Background = new LinearGradientBrush(lighter, color, 90),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new IconGlyph { Symbol = symbol, Width = size * 0.68, Height = size * 0.68, Ink = darkGlyph ? new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)) : Brushes.White }
        };
    }

    /// Blue to violet with a warm glow, as on the Mac Appearance wallpaper.
    internal static Brush Wallpaper()
    {
        var group = new DrawingGroup();
        var bounds = new RectangleGeometry(new Rect(0, 0, 1, 1));
        group.Children.Add(new GeometryDrawing(new LinearGradientBrush(new GradientStopCollection
        {
            new(Color.FromRgb(104, 132, 196), 0), new(Color.FromRgb(118, 112, 160), 0.48), new(Color.FromRgb(188, 150, 150), 1)
        }, new Point(0, 0.3), new Point(1, 0.7)), null, bounds));
        group.Children.Add(new GeometryDrawing(new RadialGradientBrush(Color.FromArgb(170, 240, 206, 150), Color.FromArgb(0, 240, 206, 150))
        { Center = new Point(0.74, 0.62), GradientOrigin = new Point(0.74, 0.62), RadiusX = 0.42, RadiusY = 0.7 }, null, bounds));
        var brush = new DrawingBrush(group) { Stretch = Stretch.Fill }; brush.Freeze(); return brush;
    }

    internal static Ellipse Dot(Brush fill, double size = 6) => new() { Width = size, Height = size, Fill = fill, VerticalAlignment = VerticalAlignment.Center };

    /// The standard arrow pointer, tip at the top-left corner.
    internal static Path Pointer(double height)
    {
        double scale = height / 19.5;
        var points = new[] { new Point(0, 0), new Point(0, 17), new Point(4, 13), new Point(7, 19.5), new Point(9.5, 18.5), new Point(6.7, 12.2), new Point(12, 12.2) };
        var figure = new PathFigure { StartPoint = points[0], IsClosed = true };
        foreach (var point in points.Skip(1)) figure.Segments.Add(new LineSegment(point, true));
        return new Path { Data = new PathGeometry(new[] { figure }) { Transform = new ScaleTransform(scale, scale) }, Fill = Brushes.White, Stroke = Brushes.Black, StrokeThickness = 1.2 / scale * 0.6 };
    }
}

/// The collapsed bar hanging from the top of a desktop, with callouts tied
/// to each part by measured anchors.
internal sealed class WelcomeIslandMap : Grid
{
    private readonly Canvas leaders = new() { IsHitTestVisible = false };
    private readonly List<(FrameworkElement Part, FrameworkElement Label)> links = [];

    internal WelcomeIslandMap(UiText ui, Func<int, ActivityBadge> badge, FrameworkElement rings, FrameworkElement warning)
    {
        Height = 176; ClipToBounds = true;
        Clip = new RectangleGeometry(new Rect(0, 0, 0, 0)); SizeChanged += (_, args) => Clip = new RectangleGeometry(new Rect(args.NewSize), 10, 10);
        Children.Add(new Border { Background = GuideArt.Wallpaper(), CornerRadius = new CornerRadius(10) });

        var menu = new Grid { Height = 32, VerticalAlignment = VerticalAlignment.Top, Background = new SolidColorBrush(Color.FromArgb(56, 0, 0, 0)) };
        var leftMenu = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        foreach (double width in new[] { 12.0, 26, 22 }) leftMenu.Children.Add(Capsule(width));
        var rightMenu = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 14, 0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        foreach (double width in new[] { 14.0, 34 }) rightMenu.Children.Add(Capsule(width));
        menu.Children.Add(leftMenu); menu.Children.Add(rightMenu); Children.Add(menu);

        var task = badge(0);
        var rate = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        rate.Children.Add(new TextBlock { Text = "42", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Primary, VerticalAlignment = VerticalAlignment.Center });
        rate.Children.Add(new TextBlock { Text = " t/s", FontSize = 9, FontWeight = FontWeights.Medium, Foreground = PacerPalette.Tertiary, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 2) });
        var quota = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        rings.Margin = new Thickness(0, 0, 5, 0); quota.Children.Add(rings);
        quota.Children.Add(new TextBlock { Text = "81%", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Claude, VerticalAlignment = VerticalAlignment.Center });
        warning.VerticalAlignment = VerticalAlignment.Center;

        var bar = new Grid { Height = 32, Width = 330, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
        bar.Children.Add(new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(0, 0, 12, 12) });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        task.Margin = new Thickness(0, 0, 8, 0); left.Children.Add(task); left.Children.Add(rate);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 18, 0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        quota.Margin = new Thickness(0, 0, 8, 0); right.Children.Add(quota); right.Children.Add(warning);
        bar.Children.Add(left); bar.Children.Add(right); Children.Add(bar);

        var labels = new Grid { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12, 0, 12, 14) };
        labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        labels.ColumnDefinitions.Add(new ColumnDefinition()); labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); labels.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var quotaDetail = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        quotaDetail.Children.Add(GuideArt.Dot(PacerPalette.Codex)); quotaDetail.Children.Add(Detail("Codex", new Thickness(4, 0, 8, 0)));
        quotaDetail.Children.Add(GuideArt.Dot(PacerPalette.Claude)); quotaDetail.Children.Add(Detail("Claude", new Thickness(4, 0, 0, 0)));
        var parts = new (FrameworkElement Part, string Title, UIElement Detail, int Column)[]
        {
            (task, ui.Text("welcome.part.task"), Detail(ui.Text("welcome.part.task_detail")), 0),
            (rate, ui.Text("welcome.part.rate"), Detail(ui.Text("welcome.part.rate_detail")), 1),
            (quota, ui.Text("welcome.part.quota"), quotaDetail, 3),
            (warning, ui.Text("welcome.part.warning"), Detail(ui.Text("welcome.part.warning_detail")), 4)
        };
        foreach (var part in parts)
        {
            var content = new StackPanel();
            content.Children.Add(new TextBlock { Text = part.Title, FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center });
            content.Children.Add(part.Detail);
            var label = new Border { Child = content, Padding = new Thickness(10, 6, 10, 6), CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(Color.FromArgb(102, 0, 0, 0)),
                Margin = new Thickness(part.Column == 0 ? 0 : 8, 0, 0, 0) };
            Grid.SetColumn(label, part.Column); labels.Children.Add(label); links.Add((part.Part, label));
        }
        Children.Add(labels); Children.Add(leaders);
        LayoutUpdated += (_, _) => DrawLeaders();
    }

    private static Border Capsule(double width) => new() { Width = width, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 10, 0), Background = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)) };
    private static TextBlock Detail(string text, Thickness? margin = null) => new()
    { Text = text, FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(191, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center, Margin = margin ?? new Thickness(0) };

    private Rect? lastLayout;
    private void DrawLeaders()
    {
        if (!IsLoaded || ActualWidth <= 0) return;
        var boxes = links.Select(link => (Bounds(link.Part), Bounds(link.Label))).ToArray();
        var signature = new Rect(boxes.Sum(box => box.Item1.X + box.Item2.X), boxes.Sum(box => box.Item1.Y + box.Item2.Y), ActualWidth, ActualHeight);
        if (signature == lastLayout) return; lastLayout = signature;
        leaders.Children.Clear();
        foreach (var (part, label) in boxes)
        {
            var start = new Point(part.X + part.Width / 2, part.Bottom + 3); var end = new Point(label.X + label.Width / 2, label.Top);
            leaders.Children.Add(new Line { X1 = start.X, Y1 = start.Y, X2 = end.X, Y2 = end.Y, Stroke = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)), StrokeThickness = 1 });
            var dot = GuideArt.Dot(Brushes.White, 4); Canvas.SetLeft(dot, start.X - 2); Canvas.SetTop(dot, start.Y - 2); leaders.Children.Add(dot);
        }
    }
    private Rect Bounds(FrameworkElement value) => value.IsLoaded && value.ActualWidth > 0
        ? value.TransformToAncestor(this).TransformBounds(new Rect(0, 0, value.ActualWidth, value.ActualHeight)) : Rect.Empty;
}

/// Pictures beside text that already says the same thing stay out of the
/// accessibility tree.
internal sealed class DecorativePeer(FrameworkElement owner) : FrameworkElementAutomationPeer(owner)
{
    protected override bool IsControlElementCore() => false;
    protected override bool IsContentElementCore() => false;
    protected override List<AutomationPeer>? GetChildrenCore() => null;
}

internal sealed class DecorativeImage : Image
{
    protected override AutomationPeer OnCreateAutomationPeer() => new DecorativePeer(this);
}

/// The bar opened under a pointer, drawn at a quarter of its size. Motion
/// is left to the island itself; this is its resting open state.
internal sealed class WelcomeGestureScene : Grid
{
    protected override AutomationPeer OnCreateAutomationPeer() => new DecorativePeer(this);
    internal WelcomeGestureScene()
    {
        Width = 132; Height = 88; ClipToBounds = true; Clip = new RectangleGeometry(new Rect(0, 0, 132, 88), 8, 8);
        Children.Add(new Border { Background = GuideArt.Wallpaper() });
        Children.Add(new Border { Height = 8, VerticalAlignment = VerticalAlignment.Top, Background = new SolidColorBrush(Color.FromArgb(56, 0, 0, 0)) });
        var panel = new Border { Width = 101, Height = 58, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Center,
            Background = Brushes.Black, CornerRadius = new CornerRadius(0, 0, 9, 9) };
        var content = new StackPanel { Margin = new Thickness(8, 12, 8, 0) };
        foreach (var tint in new[] { PacerPalette.Codex, PacerPalette.Claude })
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 4) };
            row.Children.Add(new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2.5), Background = tint, Opacity = 0.45 });
            var lines = new StackPanel { Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            lines.Children.Add(new Border { Width = 42, Height = 3, CornerRadius = new CornerRadius(1.5), Background = new SolidColorBrush(Color.FromArgb(178, 255, 255, 255)), Margin = new Thickness(0, 0, 0, 2) });
            lines.Children.Add(new Border { Width = 28, Height = 2, CornerRadius = new CornerRadius(1), Background = new SolidColorBrush(Color.FromArgb(77, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Left });
            row.Children.Add(lines); content.Children.Add(row);
        }
        var ringRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 1, 0, 0) };
        foreach (var (tint, fraction) in new[] { (PacerPalette.Codex, 0.58), (PacerPalette.Claude, 0.81) }) ringRow.Children.Add(Ring(tint, fraction));
        content.Children.Add(ringRow); panel.Child = content; Children.Add(panel);
        var pointer = GuideArt.Pointer(16); pointer.HorizontalAlignment = HorizontalAlignment.Left; pointer.VerticalAlignment = VerticalAlignment.Top; pointer.Margin = new Thickness(76, 4, 0, 0);
        Children.Add(pointer);
    }
    private static Path Ring(Brush tint, double fraction)
    {
        const double radius = 6; double angle = fraction * 2 * Math.PI - Math.PI / 2;
        var end = new Point(radius + radius * Math.Cos(angle), radius + radius * Math.Sin(angle));
        var figure = new PathFigure { StartPoint = new Point(radius, 0) };
        figure.Segments.Add(new ArcSegment(end, new Size(radius, radius), 0, fraction > 0.5, SweepDirection.Clockwise, true));
        return new Path { Data = new PathGeometry(new[] { figure }), Stroke = tint, StrokeThickness = 2.2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            Width = 14, Height = 14, Margin = new Thickness(0, 0, 14, 0) };
    }
}

internal sealed class WelcomeMoveScene : Grid
{
    protected override AutomationPeer OnCreateAutomationPeer() => new DecorativePeer(this);
    /// <param name="tall">Settings' position tile: the same strip on a 1.5:1 desktop, as the Mac's tiles share one shape.</param>
    internal WelcomeMoveScene(bool tall = false)
    {
        Width = 132; Height = tall ? 88 : 46;
        if (tall) { Background = GuideArt.Wallpaper(); Clip = new RectangleGeometry(new Rect(0, 0, 132, 88), 8, 8); }
        var art = new Canvas { Width = 132, Height = 46, Clip = tall ? null : new RectangleGeometry(new Rect(0, 0, 132, 46), 8, 8),
            Background = tall ? null : GuideArt.Wallpaper(), VerticalAlignment = VerticalAlignment.Center };
        Add(new Border { Width = 39, Height = 11, CornerRadius = new CornerRadius(5.5), Background = Brushes.Black }, 22, 17);
        Add(new Path { Data = Geometry.Parse("M 0 4 L 34 4 M 29 0 L 34 4 L 29 8"), Stroke = Brushes.White, StrokeThickness = 1.5 }, 68, 19);
        Add(new Border { Width = 12, Height = 29, CornerRadius = new CornerRadius(5, 0, 0, 5), Background = Brushes.Black,
            BorderBrush = PacerPalette.Codex, BorderThickness = new Thickness(1) }, 120, 8);
        Add(GuideArt.Pointer(14), 52, 23);
        Children.Add(new Viewbox { Child = art });

        void Add(UIElement element, double x, double y)
        { Canvas.SetLeft(element, x); Canvas.SetTop(element, y); art.Children.Add(element); }
    }
}
