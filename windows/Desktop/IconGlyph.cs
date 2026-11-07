using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// <summary>Original vector paths for the outline status and action family.</summary>
/// <remarks>No font glyphs, emoji, vendor logos or exported Apple symbol assets.</remarks>
public sealed class IconGlyph : FrameworkElement
{
    public static readonly DependencyProperty SymbolProperty = DependencyProperty.Register(nameof(Symbol), typeof(string),
        typeof(IconGlyph), new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty InkProperty = DependencyProperty.Register(nameof(Ink), typeof(Brush),
        typeof(IconGlyph), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));
    public string Symbol { get => (string)GetValue(SymbolProperty); set => SetValue(SymbolProperty, value); }
    public Brush Ink { get => (Brush)GetValue(InkProperty); set => SetValue(InkProperty, value); }

    private static readonly IReadOnlyDictionary<string, Geometry> Paths = CreatePaths();
    public IconGlyph() { IsHitTestVisible = false; Focusable = false; }
    internal static bool Has(string symbol) => Paths.ContainsKey(symbol) || symbol is "ellipsis" or "ellipsis.bubble";
    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        Draw(drawing, Symbol, Ink, ActualWidth, ActualHeight);
    }
    internal static void Draw(DrawingContext drawing, string symbol, Brush ink, double width, double height)
    {
        drawing.PushTransform(new ScaleTransform(width / 24, height / 24));
        var pen = new Pen(ink, 1.55) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        if (symbol.EndsWith(".circle", StringComparison.Ordinal)) drawing.DrawEllipse(null, pen, new Point(12, 12), 9.3, 9.3);
        bool filled = symbol is "pin.fill" or "sparkle" or "flame.fill" or "smallcircle.filled.circle" or "star.fill";
        if (Paths.TryGetValue(symbol, out Geometry? path)) drawing.DrawGeometry(filled ? ink : null, filled ? null : pen, path);
        if (symbol is "ellipsis" or "ellipsis.bubble")
            foreach (double x in new[] { 7.5, 12.0, 16.5 }) drawing.DrawEllipse(ink, null, new Point(x, symbol == "ellipsis" ? 12 : 10.8), 1, 1);
        drawing.Pop();
    }
    private static IReadOnlyDictionary<string, Geometry> CreatePaths()
    {
        var paths = new Dictionary<string, string>
        {
            ["sparkle"] = "M12,2 C13.1,8.8 15.2,10.9 22,12 C15.2,13.1 13.1,15.2 12,22 C10.9,15.2 8.8,13.1 2,12 C8.8,10.9 10.9,8.8 12,2 Z",
            ["star.fill"] = "M12,2.5 L14.9,8.6 L21.5,9.4 L16.6,13.9 L17.9,20.5 L12,17.2 L6.1,20.5 L7.4,13.9 L2.5,9.4 L9.1,8.6 Z",
            ["square.and.arrow.up"] = "M12,2.5 V14.5 M8,6.5 L12,2.5 L16,6.5 M8.5,10 H6 Q4.5,10 4.5,11.5 V19.5 Q4.5,21 6,21 H18 Q19.5,21 19.5,19.5 V11.5 Q19.5,10 18,10 H15.5",
            ["cup.and.saucer"] = "M4.5,7 H16.5 V12 Q16.5,17 10.5,17 Q4.5,17 4.5,12 Z M16.5,8.5 H18 Q20.5,8.5 20.5,11 Q20.5,13.5 18,13.5 H16.2 M2.5,20 H18.5 M8,2.5 Q7,3.7 8,5 M11.5,2.5 Q10.5,3.7 11.5,5",
            ["qrcode"] = "M3.5,3.5 H9.5 V9.5 H3.5 Z M14.5,3.5 H20.5 V9.5 H14.5 Z M3.5,14.5 H9.5 V20.5 H3.5 Z M14.5,14.5 H17 V17 H14.5 Z M18.5,18.5 H20.5 V20.5 H18.5 Z M6,6 H7 V7 H6 Z M17,6 H18 V7 H17 Z M6,17 H7 V18 H6 Z",
            ["flame.fill"] = "M12,1.5 C14,6 21,9 20.5,15 C20,21 15,23 10,22 C3,21 1,13 6,7 C6,11 8,12 9,10 C10,8 9,5 12,1.5 Z M12,12 C9,15 8,17 10,19 C12,22 16,19 15,17 C14,15 13,15 12,12 Z",
            ["terminal"] = "M5,4.5 H19 Q21,4.5 21,6.5 V17.5 Q21,19.5 19,19.5 H5 Q3,19.5 3,17.5 V6.5 Q3,4.5 5,4.5 Z M7,9 L10,12 L7,15 M13.5,15 H17.5",
            ["text.bubble"] = "M5,3.5 H19 Q21,3.5 21,5.5 V15 Q21,17 19,17 H10 L5,21 V17 Q3,17 3,15 V5.5 Q3,3.5 5,3.5 Z M7,8 H17 M7,11.5 H14.5",
            ["ellipsis.bubble"] = "M5,3.5 H19 Q21,3.5 21,5.5 V15 Q21,17 19,17 H10 L5,21 V17 Q3,17 3,15 V5.5 Q3,3.5 5,3.5 Z",
            ["hourglass"] = "M6,2.5 H18 M6,21.5 H18 M7,2.5 V6 Q7,9 11,12 Q7,15 7,18 V21.5 M17,2.5 V6 Q17,9 13,12 Q17,15 17,18 V21.5 M9.5,6 H14.5 M9.5,18 H14.5",
            ["smallcircle.filled.circle"] = "M16.3,12 A4.3,4.3 0 1 1 7.7,12 A4.3,4.3 0 1 1 16.3,12 Z",
            ["circle.circle"] = "M16.7,12 A4.7,4.7 0 1 1 7.3,12 A4.7,4.7 0 1 1 16.7,12 Z",
            ["text.alignleft"] = "M3,5 H21 M3,9.7 H15.5 M3,14.3 H21 M3,19 H13",
            ["speedometer"] = "M5,19 A9,9 0 1 1 19,19 M4,12 H6 M7,5.8 L8.2,7.6 M12,3 V5 M17,5.8 L15.8,7.6 M20,12 H18 M12,14 L16,9 M13.2,14 A1.2,1.2 0 1 1 10.8,14 A1.2,1.2 0 1 1 13.2,14 Z",
            ["timer"] = "M20.5,13.5 A8.5,8.5 0 1 1 3.5,13.5 A8.5,8.5 0 1 1 20.5,13.5 Z M9,2 H15 M12,2 V5 M17.7,6.7 L19.5,4.9 M12,8 V13.5 L15,15.5",
            ["percent"] = "M5,20 L19,4 M9,6 A2.5,2.5 0 1 1 4,6 A2.5,2.5 0 1 1 9,6 Z M20,18 A2.5,2.5 0 1 1 15,18 A2.5,2.5 0 1 1 20,18 Z",
            ["tag"] = "M3,3 H11 L21,13 Q22,14 21,15 L15,21 Q14,22 13,21 L3,11 Z M8,7 A1,1 0 1 1 6,7 A1,1 0 1 1 8,7 Z",
            ["exclamationmark.triangle"] = "M11,3 Q12,1 13,3 L22,19 Q23,21 21,21 H3 Q1,21 2,19 Z M12,8 V14 M12,17.5 V17.7",
            ["cloud"] = "M6,18.5 C-0.5,18.5 0,9.5 6,9 C6.4,2.5 15,1.5 17.3,8.5 C24,7.5 25,18.5 18,18.5 Z",
            // Waiting on background work until it wakes the request: three rising z, large to small.
            ["zzz"] = "M3,13 H10 L3,21 H10 M11.5,7 H16.5 L11.5,12.5 H16.5 M17.5,2.5 H21 L17.5,6.5 H21",
            ["arrow.triangle.branch"] = "M12,21 V13 M12,13 L4,3 M12,13 L20,3 M3,3 H7 M3,3 V7 M21,3 H17 M21,3 V7",
            ["moon"] = "M18.9,16.5 C10.6,18 6,11 9,3.3 C0,6.2 2,20.7 12,20.7 C15.2,20.7 17.5,19.2 18.9,16.5 Z",
            ["hand.raised"] = "M7.5,13 V6.5 Q7.5,4.5 9,4.5 Q10.5,4.5 10.5,6.5 V11 M10.5,7 V3.5 Q10.5,1.5 12,1.5 Q13.5,1.5 13.5,3.5 V11 M13.5,7 V4.7 Q13.5,2.7 15,2.7 Q16.5,2.7 16.5,4.7 V12 M16.5,8 Q16.5,6 18,6 Q19.5,6 19.5,8 V15 C19.5,23 9,24 6,18 L3,12.5 Q2,10.5 3.5,10 Q5,9.5 7.5,13 Z",
            ["checkmark.circle"] = "M7.5,12 L10.5,15 L16.8,8.7",
            ["pause.circle"] = "M9.2,8 V16 M14.8,8 V16",
            ["xmark.circle"] = "M8.5,8.5 L15.5,15.5 M15.5,8.5 L8.5,15.5",
            ["checkmark"] = "M6,12 L10,16 L18,8",
            ["checkmark.rectangle.stack"] = "M6,2 H20 Q22,2 22,4 V16 M3,6 H17 Q19,6 19,8 V20 Q19,22 17,22 H3 Q1,22 1,20 V8 Q1,6 3,6 Z M5,13 L8,16 L14,10",
            ["pause"] = "M9,7 V17 M15,7 V17",
            ["xmark"] = "M7,7 L17,17 M17,7 L7,17",
            ["pin"] = "M8,3 H16 M9,3 V9 L6,13 V15 H18 V13 L15,9 V3 M12,15 V22",
            ["pin.fill"] = "M7,2 H17 V4 H16 V8.5 L19,12 V15 H13 V22 H11 V15 H5 V12 L8,8.5 V4 H7 Z",
            ["chevron.left"] = "M14.5,5.5 L8,12 L14.5,18.5",
            ["chevron.right"] = "M9.5,5.5 L16,12 L9.5,18.5",
            ["chevron.up"] = "M5.5,15.5 L12,9 L18.5,15.5",
            ["chevron.down"] = "M5.5,8.5 L12,15 L18.5,8.5",
            ["clock"] = "M21,12 A9,9 0 1 1 3,12 A9,9 0 1 1 21,12 Z M12,6.5 V12 L15.5,14",
            ["arrow.counterclockwise"] = "M4.5,8 A8,8 0 1 1 4,15 M9,8 H4 V3",
            ["exclamationmark.circle"] = "M12,6 V13 M12,17 V17.4",
            ["info.circle"] = "M12,10 V17 M12,6.8 V7.1",
            ["ellipsis.circle"] = "M7,12 H7.2 M11.9,12 H12.1 M16.8,12 H17",
            ["arrow.clockwise"] = "M19.5,8 A8,8 0 1 0 20,15 M15,8 H20 V3",
            ["clock.arrow.circlepath"] = "M20.5,8.5 A9,9 0 1 0 20.5,15.5 M16.5,8.5 H21 V4 M12,6.5 V12 L15.5,14",
            ["network.slash"] = "M21,12 A9,9 0 1 1 3,12 A9,9 0 1 1 21,12 Z M3,12 H21 M5,6.5 Q12,10 19,6.5 M5,17.5 Q12,14 19,17.5 M12,3 C6,8 6,16 12,21 C18,16 18,8 12,3 M2,2 L22,22",
            ["server.rack"] = "M4,3 H20 V9 H4 Z M4,15 H20 V21 H4 Z M7,6 H8 M7,18 H8 M12,6 H17 M12,18 H17",
            ["person.2"] = "M9.5,4 A3,3 0 1 1 9.49,4 M15.5,5 A2.5,2.5 0 1 1 17.5,9.5 M2.5,20 V17 C2.5,11.5 14.5,11.5 14.5,17 V20 Z M16,13 Q21.5,13 21.5,17 V20 H17",
            ["chevron.left.forwardslash.chevron.right"] = "M7,6 L2,12 L7,18 M17,6 L22,12 L17,18 M15,3 L9,21",
            ["asterisk"] = "M12,2 V22 M3.3,7 L20.7,17 M3.3,17 L20.7,7",
            ["water.waves"] = "M2,6 Q5,2 8,6 T14,6 T20,6 M2,12 Q5,8 8,12 T14,12 T20,12 M2,18 Q5,14 8,18 T14,18 T20,18",
            ["gearshape"] = "M9.7,2 H14.3 L14.9,5 L16.7,6 L19.6,5.1 L21.9,9.1 L19.6,11.2 V13.1 L21.9,15.1 L19.6,19.1 L16.7,18.1 L14.9,19.2 L14.3,22 H9.7 L9.1,19.2 L7.3,18.1 L4.4,19.1 L2.1,15.1 L4.4,13.1 V11.2 L2.1,9.1 L4.4,5.1 L7.3,6 L9.1,5 Z M15.5,12 A3.5,3.5 0 1 1 8.5,12 A3.5,3.5 0 1 1 15.5,12 Z",
            ["power"] = "M12,2 V11 M7,5 A8.5,8.5 0 1 0 17,5",
            ["questionmark"] = "M8,7 C8,2 17,2 17,7 C17,10 12,10 12,14 M12,18 V18.4",
            ["heart"] = "M12,21 C7,17 2,13 2,8 C2,2 9,1 12,6 C15,1 22,2 22,8 C22,13 17,17 12,21 Z",
            ["paintpalette"] = "M21,12 C23,4 15,1 9,3 C2,5 0,12 5,18 C8,22 13,23 15,20 C17,17 10,15 15,13 C17,12 20,15 21,12 Z M8,7 V7.5 M13,6 V6.5 M17,8 V8.5 M5,12 V12.5",
            ["rectangle.topthird.inset.filled"] = "M4,4 H20 Q22,4 22,6 V18 Q22,20 20,20 H4 Q2,20 2,18 V6 Q2,4 4,4 Z M5,8 H19 M5,10.5 H19",
            ["bell.badge"] = "M5,16 H19 L17,12 V9 C17,2 7,2 7,9 V12 Z M9,19 Q12,23 15,19 M17,3 L20,6 M20,3 L17,6",
            ["point.3.connected.trianglepath.dotted"] = "M7,8 L11,15 M17,8 L13,15 M8,6 H16 M7,6 A2,2 0 1 1 3,6 A2,2 0 1 1 7,6 Z M21,6 A2,2 0 1 1 17,6 A2,2 0 1 1 21,6 Z M14,18 A2,2 0 1 1 10,18 A2,2 0 1 1 14,18 Z",
            ["switch.2"] = "M7,3.5 H17 A3.5,3.5 0 0 1 17,10.5 H7 A3.5,3.5 0 0 1 7,3.5 Z M18.5,7 A1.5,1.5 0 1 1 15.5,7 A1.5,1.5 0 1 1 18.5,7 Z M7,13.5 H17 A3.5,3.5 0 0 1 17,20.5 H7 A3.5,3.5 0 0 1 7,13.5 Z M8.5,17 A1.5,1.5 0 1 1 5.5,17 A1.5,1.5 0 1 1 8.5,17 Z",
            ["slider.horizontal.3"] = "M3,6 H13 M17,6 H21 M17,6 A2,2 0 1 1 13,6 A2,2 0 1 1 17,6 Z M3,12 H6 M10,12 H21 M10,12 A2,2 0 1 1 6,12 A2,2 0 1 1 10,12 Z M3,18 H11 M15,18 H21 M15,18 A2,2 0 1 1 11,18 A2,2 0 1 1 15,18 Z",
            ["cursorarrow.rays"] = "M10,10 L20.5,14 L16,15.8 L14.2,20.5 Z M10,2.5 V5.5 M4.2,4.2 L6.3,6.3 M2.5,10 H5.5 M4.2,15.8 L6.3,13.7 M15.8,4.2 L13.7,6.3",
            ["arrow.up.forward.app"] = "M10.5,3.5 H6 Q3.5,3.5 3.5,6 V18 Q3.5,20.5 6,20.5 H18 Q20.5,20.5 20.5,18 V13.5 M13.5,3.5 H20.5 V10.5 M20.5,3.5 L11,13",
            ["book"] = "M12,6.5 C9.5,4.5 5.5,4 2.5,5 V19.5 C5.5,18.5 9.5,19 12,21 C14.5,19 18.5,18.5 21.5,19.5 V5 C18.5,4 14.5,4.5 12,6.5 Z M12,6.5 V21",
            ["exclamationmark.bubble"] = "M5,3.5 H19 Q21,3.5 21,5.5 V15 Q21,17 19,17 H10 L5,21 V17 Q3,17 3,15 V5.5 Q3,3.5 5,3.5 Z M12,6.5 V11 M12,13.8 V14",
            ["square.on.square"] = "M10,8 H19 Q21,8 21,10 V19 Q21,21 19,21 H10 Q8,21 8,19 V10 Q8,8 10,8 Z M16,8 V5 Q16,3 14,3 H5 Q3,3 3,5 V14 Q3,16 5,16 H8",
            ["chart.pie"] = "M10.5,4.5 A8.5,8.5 0 1 0 19.5,13.5 H10.5 Z M13.5,2.5 A8,8 0 0 1 21.5,10.5 H13.5 Z",
            ["square.grid.2x2"] = "M4,3.5 H9.5 Q10.5,3.5 10.5,4.5 V9.5 Q10.5,10.5 9.5,10.5 H4.5 Q3.5,10.5 3.5,9.5 V4.5 Q3.5,3.5 4.5,3.5 Z M14.5,3.5 H19.5 Q20.5,3.5 20.5,4.5 V9.5 Q20.5,10.5 19.5,10.5 H14.5 Q13.5,10.5 13.5,9.5 V4.5 Q13.5,3.5 14.5,3.5 Z M4.5,13.5 H9.5 Q10.5,13.5 10.5,14.5 V19.5 Q10.5,20.5 9.5,20.5 H4.5 Q3.5,20.5 3.5,19.5 V14.5 Q3.5,13.5 4.5,13.5 Z M14.5,13.5 H19.5 Q20.5,13.5 20.5,14.5 V19.5 Q20.5,20.5 19.5,20.5 H14.5 Q13.5,20.5 13.5,19.5 V14.5 Q13.5,13.5 14.5,13.5 Z",
            ["chart.xyaxis.line"] = "M3.5,3 V20.5 H21 M6.5,16 L10.5,10.5 L14,13.5 L19.5,6",
            ["circle.lefthalf.filled"] = "M21,12 A9,9 0 1 1 3,12 A9,9 0 1 1 21,12 Z M12,3 V21 M12,3 A9,9 0 0 0 12,21 M5.5,8 H12 M4,12 H12 M5.5,16 H12",
            ["bell"] = "M5,16.5 H19 L17,12.5 V9.5 C17,2.5 7,2.5 7,9.5 V12.5 Z M9.5,19.5 Q12,22.5 14.5,19.5",
            ["lightbulb"] = "M9,18 H15 M10,21 H14 M9,15.5 C6.5,14 5.5,11.8 5.5,9.5 A6.5,6.5 0 0 1 18.5,9.5 C18.5,11.8 17.5,14 15,15.5 Z",
            ["ladybug"] = "M12,6 C16.5,6 19,9.5 19,13.5 C19,18 15.8,21 12,21 C8.2,21 5,18 5,13.5 C5,9.5 7.5,6 12,6 Z M12,6 V21 M9,4 L10.5,6.2 M15,4 L13.5,6.2 M5.5,11 H8.5 M15.5,11 H18.5 M5.5,16 H8.5 M15.5,16 H18.5",
            ["magnifyingglass"] = "M17,10.5 A6.5,6.5 0 1 1 4,10.5 A6.5,6.5 0 1 1 17,10.5 Z M15.3,15.3 L20.5,20.5"
        };
        var result = new Dictionary<string, Geometry>();
        foreach (var entry in paths) { Geometry geometry = Geometry.Parse(entry.Value); geometry.Freeze(); result[entry.Key] = geometry; }
        return result;
    }
}
