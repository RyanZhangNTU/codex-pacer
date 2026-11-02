using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
internal static class DrawingInspection
{
    internal sealed record Paint(Drawing Drawing, double Opacity)
    {
        internal Brush? Brush => Drawing switch { GeometryDrawing g => g.Brush ?? g.Pen?.Brush, GlyphRunDrawing g => g.ForegroundBrush, _ => null };
        internal Color? Color => Brush is SolidColorBrush solid ? solid.Color : null;
        internal double Intensity => Color is { } color ? Opacity * (Brush?.Opacity ?? 1) * color.A / 255 * Math.Max(color.R, Math.Max(color.G, color.B)) : 0;
        internal bool Arc => Drawing is GeometryDrawing { Pen.Thickness: 6 } && Color is { A: > 200 };
    }
    internal static IReadOnlyList<Paint> Render(FrameworkElement element, double width, double height)
    {
        element.Width = width; element.Height = height;
        element.Measure(new Size(width, height)); element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout();
        // Force WPF to commit its retained drawing; no pixels are read or compared.
        new RenderTargetBitmap((int)Math.Ceiling(width), (int)Math.Ceiling(height), 96, 96, PixelFormats.Pbgra32).Render(element);
        var paints = new List<Paint>();
        void Visit(Drawing drawing, double opacity)
        {
            if (drawing is DrawingGroup group) { foreach (var child in group.Children) Visit(child, opacity * group.Opacity); }
            else paints.Add(new(drawing, opacity));
        }
        if (VisualTreeHelper.GetDrawing(element) is { } root) Visit(root, 1);
        return paints;
    }
}
