using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// Help → Collaboration: how Claude and Codex work together, as a sequence
/// diagram, through Pacer or the typical way. Both share one 420 × 422 grid,
/// so You, Claude and Codex stay put and only Pacer's lane comes and goes; the
/// numbered marks are where the two differ. It scales with the page and reads
/// as one picture whose name tells the whole sequence.
internal sealed class CollaborationDiagram : Viewbox
{
    internal const double GridWidth = 420, GridHeight = 422;
    private const double You = 30, Claude = 118, Pacer = 240, Codex = 370;
    private const string Good = "SettingsTintCodex", Bad = "SettingsWarning";
    private readonly UiText ui;
    private readonly Canvas canvas = new() { Width = GridWidth, Height = GridHeight };

    internal CollaborationDiagram(UiText ui)
    {
        this.ui = ui; Stretch = Stretch.Uniform; Child = canvas; IsHitTestVisible = false;
        Show(true);
    }

    internal bool ThroughPacer { get; private set; }
    /// Every label as drawn, with its box on the grid; read by the presentation checks.
    internal IEnumerable<(string Text, Rect Bounds)> Labels => canvas.Children.OfType<Words>().Select(words => (words.Text, words.Bounds));

    internal void Show(bool throughPacer)
    {
        ThroughPacer = throughPacer; canvas.Children.Clear();
        if (throughPacer) DrawPacer(); else DrawTypical();
        AutomationProperties.SetName(this, ui.Text(throughPacer ? "help.collaboration.pacer.summary" : "help.collaboration.typical.summary"));
    }

    private string T(string key) => ui.Text("help.collaboration." + key);

    private void DrawTypical()
    {
        Cast(false);
        Lifeline(You, 320); Lifeline(Claude, 320); Lifeline(Codex, 362);
        Labelled(You, Claude - 2, 106, T("ask"));
        // 1 Claude runs Codex itself: which model and what access are out of sight.
        Labelled(Claude, Codex - 6, 148, T("run"));
        Mark(256, 172, "1", T("typical.1"), Bad);
        // 2 Claude waits in the foreground and you can't interact; nothing shows the subtask's progress.
        Bar(Claude, 152, 128, "SettingsSegment"); Label(Claude - 12, 190, T("waits"), 10.5, "SettingsSecondary", anchor: Anchor.End);
        Bar(Codex, 148, 128, "SettingsDisabled");
        Label((You + Claude) / 2, 228, T("blocked"), 10.5, "SettingsSecondary"); Arrow(You, Claude - 30, 238, dashed: true);
        Stroke(Bad, 1.8, (Claude - 26, 232, Claude - 16, 244), (Claude - 16, 232, Claude - 26, 244));
        Mark(146, 215, "2", T("typical.2"), Bad);
        // The result comes back and Claude delivers it.
        Labelled(Codex - 6, Claude + 6, 276, T("result"));
        Labelled(Claude, You + 2, 310, T("deliver"));
        // 3 Every run's conversation stays in Codex.
        for (int index = 0; index < 3; index++)
        {
            var sheet = new Rectangle { Width = 24, Height = 13, RadiusX = 3, RadiusY = 3, StrokeThickness = 1.2 };
            sheet.SetResourceReference(Shape.FillProperty, "SettingsCard"); sheet.SetResourceReference(Shape.StrokeProperty, Bad);
            Place(sheet, Codex - 14 + index * 3, 368 + index * 8);
        }
        Mark(256, 388, "3", T("typical.3"), Bad);
    }

    private void DrawPacer()
    {
        Cast(true);
        Lifeline(You, 320); Lifeline(Claude, 346); Lifeline(Pacer, 388); Lifeline(Codex, 362);
        Labelled(You, Claude - 2, 106, T("ask"));
        // 1 Claude hands Pacer a task brief; Pacer starts Codex with your model and access.
        Labelled(Claude, Pacer - 6, 148, T("brief")); Labelled(Pacer + 6, Codex - 6, 148, T("start"));
        Mark(256, 172, "1", T("pacer.1"), Good);
        // 2 Codex works in the background; you keep interacting with Claude; Pacer watches the subtask live.
        Bar(Pacer, 148, 132, "SettingsPrimary"); Bar(Codex, 148, 128, Good);
        foreach (double y in new double[] { 206, 246 })
        {
            Label((You + Claude) / 2, y - 10, T("interact"), 10.5, "SettingsSecondary"); Arrow(You, Claude - 2, y, dashed: true, both: true);
        }
        Label((Pacer + Codex) / 2, 200, T("progress"), 10.5, "SettingsSecondary");
        foreach (double y in new double[] { 208, 228, 248 }) Arrow(Codex - 6, Pacer + 6, y, dashed: true);
        Mark(136, 215, "2", T("pacer.2"), Good);
        // Codex finishes; Pacer hands the result to Claude, who delivers it.
        Labelled(Codex - 6, Pacer + 6, 276, T("done")); Labelled(Pacer - 6, Claude + 2, 276, T("result"));
        Labelled(Claude, You + 2, 310, T("deliver"));
        // 3 Only when the Claude conversation ends does Claude tell Pacer, and Pacer then clears Codex's session.
        Bar(Pacer, 336, 44, "SettingsPrimary");
        Labelled(Claude, Pacer - 6, 342, T("ended"));
        Labelled(Pacer + 6, Codex - 12, 374, T("clear"));
        Stroke(Good, 1.8, (Codex - 7, 367, Codex + 7, 381), (Codex + 7, 367, Codex - 7, 381));
        Mark(256, 400, "3", T("pacer.3"), Good);
    }

    /// The participants across the top: you, then each app by its own icon.
    private void Cast(bool pacer)
    {
        var head = new Ellipse { Width = 14, Height = 14, StrokeThickness = 1.6 }; head.SetResourceReference(Shape.StrokeProperty, "SettingsPrimary"); Place(head, You - 7, 15);
        var body = new System.Windows.Shapes.Path { Data = Geometry.Parse($"M {You - 13},48 A 13 11 0 0 1 {You + 13},48"), StrokeThickness = 1.6 };
        body.SetResourceReference(Shape.StrokeProperty, "SettingsPrimary"); canvas.Children.Add(body);
        Place(ProviderIcon.Create("claude", 30), Claude - 15, 12);
        if (pacer) Place(PacerIcon(), Pacer - 15, 12);
        Place(ProviderIcon.Create("codex", 30), Codex - 15, 12);
        Label(You, 66, T("you"), 12.5, weight: FontWeights.SemiBold);
        Label(Claude, 66, "Claude", 12.5, weight: FontWeights.SemiBold);
        if (pacer) Label(Pacer, 66, "Pacer", 12.5, weight: FontWeights.SemiBold);
        Label(Codex, 66, "Codex", 12.5, weight: FontWeights.SemiBold);
    }

    /// Pacer's own app icon at its sharpest size, or a plain tile where the build has none.
    private static FrameworkElement PacerIcon()
    {
        string file = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Pacer.ico");
        if (File.Exists(file))
        {
            var frame = BitmapDecoder.Create(new Uri(file), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames.OrderByDescending(value => value.PixelWidth).First();
            return new Image { Source = frame, Width = 30, Height = 30, Stretch = Stretch.Uniform };
        }
        var tile = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(8) }; tile.SetResourceReference(Border.BackgroundProperty, "SettingsPrimary"); return tile;
    }

    private void Place(UIElement element, double x, double y) { Canvas.SetLeft(element, x); Canvas.SetTop(element, y); canvas.Children.Add(element); }

    private void Lifeline(double x, double end)
    {
        var line = new Line { X1 = x, X2 = x, Y1 = 78, Y2 = end, StrokeThickness = 1.2, StrokeDashArray = new DoubleCollection { 2.5, 3.3 }, Opacity = 0.55 };
        line.SetResourceReference(Shape.StrokeProperty, "SettingsSecondary"); canvas.Children.Add(line);
    }

    /// A message from one lane to the next; a dashed one is background traffic, drawn softer.
    private void Arrow(double from, double to, double y, bool dashed = false, bool both = false)
    {
        string ink = dashed ? "SettingsSecondary" : "SettingsPrimary";
        double direction = Math.Sign(to - from), back = to - direction * 8, start = both ? from + direction * 8 : from;
        var line = new Line { X1 = start, X2 = back, Y1 = y, Y2 = y, StrokeThickness = 1.5 };
        if (dashed) line.StrokeDashArray = new DoubleCollection { 3.3, 2.7 };
        line.SetResourceReference(Shape.StrokeProperty, ink); canvas.Children.Add(line);
        Head(to, back, y, ink);
        if (both) Head(from, start, y, ink);
    }

    private void Head(double tip, double back, double y, string ink)
    {
        var head = new Polygon { Points = new PointCollection { new(tip, y), new(back, y - 4.5), new(back, y + 4.5) } };
        head.SetResourceReference(Shape.FillProperty, ink); canvas.Children.Add(head);
    }

    private void Labelled(double from, double to, double y, string label)
    {
        Label((from + to) / 2, y - 8, label, 12); Arrow(from, to, y);
    }

    /// The span a participant is busy: Codex at work, Claude waiting, Pacer watching.
    private void Bar(double x, double y, double height, string fill)
    {
        var bar = new Rectangle { Width = 12, Height = height, RadiusX = 3, RadiusY = 3 }; bar.SetResourceReference(Shape.FillProperty, fill); Place(bar, x - 6, y);
    }

    private void Stroke(string ink, double thickness, params (double X1, double Y1, double X2, double Y2)[] segments)
    {
        foreach (var (x1, y1, x2, y2) in segments)
        {
            var line = new Line { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, StrokeThickness = thickness, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
            line.SetResourceReference(Shape.StrokeProperty, ink); canvas.Children.Add(line);
        }
    }

    /// A difference: its number on a tone-colored dot, then its words in one or two lines.
    private void Mark(double x, double y, string number, string text, string tone)
    {
        var dot = new Ellipse { Width = 16, Height = 16 }; dot.SetResourceReference(Shape.FillProperty, tone); Place(dot, x - 8, y - 8);
        Label(x, y + 3.8, number, 10.5, "SettingsCard", FontWeights.Bold);
        string[] lines = text.Split('\n');
        for (int index = 0; index < lines.Length; index++)
            Label(x + 13, y + 4 + (index - (lines.Length - 1) / 2.0) * 13, lines[index], 10.5, tone, FontWeights.SemiBold, Anchor.Start);
    }

    private void Label(double x, double baseline, string text, double size, string ink = "SettingsPrimary", FontWeight? weight = null, Anchor anchor = Anchor.Middle)
    {
        var words = new Words(text, size, weight ?? FontWeights.Normal, anchor); words.SetResourceReference(Words.InkProperty, ink); Place(words, x, baseline);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new PicturePeer(this);

    private enum Anchor { Start, Middle, End }

    /// One label, placed by its baseline and anchor as the design grid draws it, in the page's font.
    private sealed class Words(string text, double size, FontWeight weight, Anchor anchor) : FrameworkElement
    {
        internal static readonly DependencyProperty InkProperty = DependencyProperty.Register(nameof(Ink), typeof(Brush), typeof(Words),
            new FrameworkPropertyMetadata(Brushes.Black, FrameworkPropertyMetadataOptions.AffectsRender));
        internal static readonly DependencyProperty FontFamilyProperty = TextElement.FontFamilyProperty.AddOwner(typeof(Words),
            new FrameworkPropertyMetadata(SystemFonts.MessageFontFamily, FrameworkPropertyMetadataOptions.Inherits | FrameworkPropertyMetadataOptions.AffectsRender));
        internal Brush Ink { get => (Brush)GetValue(InkProperty); set => SetValue(InkProperty, value); }
        internal string Text => text;

        private FormattedText Layout() => new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface((FontFamily)GetValue(FontFamilyProperty), FontStyles.Normal, weight, FontStretches.Normal), size, Ink, VisualTreeHelper.GetDpi(this).PixelsPerDip);

        private double Offset(FormattedText layout) => anchor switch
        {
            Anchor.Middle => -layout.WidthIncludingTrailingWhitespace / 2, Anchor.End => -layout.WidthIncludingTrailingWhitespace, _ => 0
        };

        /// The label's box on the grid, from cap height to just under the baseline.
        internal Rect Bounds
        {
            get
            {
                var layout = Layout(); double left = Canvas.GetLeft(this) + Offset(layout), baseline = Canvas.GetTop(this);
                return new Rect(left, baseline - size * 0.78, layout.WidthIncludingTrailingWhitespace, size * 0.95);
            }
        }

        protected override void OnRender(DrawingContext context)
        {
            var layout = Layout(); context.DrawText(layout, new Point(Offset(layout), -layout.Baseline));
        }
    }

    /// The whole drawing is one picture to assistive technology, named by its summary.
    private sealed class PicturePeer(CollaborationDiagram owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;
        protected override string GetClassNameCore() => nameof(CollaborationDiagram);
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }
}
