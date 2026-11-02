using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace CodexPacer.Windows;

/// Native vector chart of actual samples. Swift owns dates, expiry groups and
/// capsule placement; the host owns drawing, input and accessibility.
internal sealed class QuotaHistoryChart : Grid
{
    // The original 509-point component reserves 36 points for the trailing
    // Charts axis; its separate date footer keeps a 34-point inset.
    internal const double AxisWidth = 36;
    internal static readonly Brush ExpiryInk = Frozen(Color.FromRgb(232, 191, 122));
    private readonly NativeQuotaChart native = new(Path.Combine(AppContext.BaseDirectory, "Engine"));
    private readonly QuotaHistoryPlot plot;
    private readonly Canvas markers = new(), tooltip = new() { IsHitTestVisible = false };
    private readonly TextBlock start = ChartText("", 12), end = ChartText("", 12);
    private QuotaChartPresentation data;
    private QuotaChartMarker[] layouts = [];
    private double layoutWidth = -1;
    private double? selectedExpiry;
    private double? selectedTimestamp;
    private QuotaChartMarker? shownMarker;
    private QuotaChartPoint? shownPoint;
    private double shownWidth = -1;
    internal IReadOnlyList<QuotaChartMarker> Markers => layouts;
    internal string? SelectionText => selectedExpiry is double id ? layouts.FirstOrDefault(value => value.Id == id)?.AccessibilityLabel
        : plot.Selected?.AccessibilityLabel;
    internal FrameworkElement InputSurface => plot;
    internal double PlotWidth => Math.Max(0, ActualWidth - AxisWidth);

    internal QuotaHistoryChart(QuotaChartPresentation data, Brush accent)
    {
        this.data = data;
        RowDefinitions.Add(new() { Height = new GridLength(118) }); RowDefinitions.Add(new() { Height = GridLength.Auto });
        plot = new QuotaHistoryPlot(data, accent);
        plot.SetResourceReference(QuotaHistoryPlot.ReferenceProperty, "SettingsChartReference");
        plot.SetResourceReference(QuotaHistoryPlot.SecondaryProperty, "SettingsChartSecondary");
        Children.Add(plot); Children.Add(markers); Children.Add(tooltip);
        var dates = new ChartDecoration { Margin = new Thickness(4, 8, 34, 0), IsHitTestVisible = false };
        dates.Children.Add(start); end.HorizontalAlignment = HorizontalAlignment.Right; dates.Children.Add(end); SetRow(dates, 1); Children.Add(dates);
        SizeChanged += (_, _) => LayoutMarkers();
        Loaded += (_, _) => { ShellProjection.Changed += ProjectionChanged; ProjectionChanged(""); };
        Unloaded += (_, _) => ShellProjection.Changed -= ProjectionChanged;
        AddHandler(Mouse.MouseMoveEvent, new MouseEventHandler((_, e) => SelectAt(e.GetPosition(plot))), true);
        MouseLeave += (_, _) => ClearSelection();
        AddHandler(Mouse.MouseDownEvent, new MouseButtonEventHandler((_, e) =>
        { if (e.ChangedButton == MouseButton.Left) SelectAt(e.GetPosition(plot)); }), true);
        plot.KeyDown += OnKey;
        plot.MouseLeftButtonDown += (_, _) => plot.Focus();
        plot.PaletteChanged += () => { shownWidth = -1; UpdateSelection(); };
        Update(data);
    }
    internal void Update(QuotaChartPresentation next)
    {
        bool same = Same(data, next);
        bool cycleChanged = data.StartedAt != next.StartedAt || data.ResetsAt != next.ResetsAt;
        data = next; start.Text = data.StartText; end.Text = data.EndText;
        start.ToolTip = end.ToolTip = data.LineHelp;
        if (cycleChanged) { selectedExpiry = null; selectedTimestamp = null; }
        if (!same || layoutWidth < 0) { layoutWidth = -1; LayoutMarkers(); }
        plot.Update(data); UpdateSelection();
    }
    private static bool Same(QuotaChartPresentation left, QuotaChartPresentation right)
        => left.Language == right.Language && left.StartedAt == right.StartedAt && left.ResetsAt == right.ResetsAt
        && left.StartText == right.StartText && left.EndText == right.EndText && left.HasPartialExpiryDetails == right.HasPartialExpiryDetails
        && left.AccessibilityLabel == right.AccessibilityLabel && left.LineHelp == right.LineHelp
        && left.Points.SequenceEqual(right.Points) && left.Expiries.SequenceEqual(right.Expiries);
    private void ProjectionChanged(string method)
    {
        if (method.Length > 0 && method != "layoutQuotaChart") return;
        _ = Dispatcher.InvokeAsync(() => { if (IsLoaded) { layoutWidth = -1; LayoutMarkers(); } });
    }
    private void LayoutMarkers()
    {
        double width = PlotWidth;
        if (width < 43 || Math.Abs(width - layoutWidth) < 0.01) return;
        layouts = native.Layout(data, width); layoutWidth = width; markers.Children.Clear();
        foreach (var marker in layouts)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            content.Children.Add(new IconGlyph { Symbol = "clock", Width = 12, Height = 12, Ink = ExpiryInk });
            if (marker.CountText != null)
            {
                var count = Text(marker.CountText, 11, ExpiryInk, FontWeights.Medium); count.Margin = new Thickness(4, 0, 0, 0); content.Children.Add(count);
            }
            var material = new ChartMaterial(plot, new Rect(marker.X - marker.Width / 2, 1.5, marker.Width, 23), 11.5, WithOpacity(ExpiryInk, 0.3));
            material.Children.Add(content);
            var button = new Button { Width = marker.Width, Height = 23, Content = material, Style = MarkerStyle() };
            Canvas.SetLeft(button, marker.X - marker.Width / 2); Canvas.SetTop(button, 1.5);
            AutomationProperties.SetAutomationId(button, "quota.chart.expiry." + marker.Id.ToString("R", CultureInfo.InvariantCulture));
            AutomationProperties.SetName(button, marker.AccessibilityLabel);
            button.Click += (_, _) => SelectExpiry(marker.Id);
            button.GotKeyboardFocus += (_, _) => SelectExpiry(marker.Id);
            button.KeyDown += (_, e) => { if (e.Key == Key.Escape) { ClearSelection(); e.Handled = true; } };
            markers.Children.Add(button);
        }
        plot.Markers = layouts; UpdateSelection();
    }
    internal void SelectAt(Point location)
    {
        var marker = layouts.FirstOrDefault(value => Math.Abs(location.X - value.X) <= value.Width / 2 + 4 && location.Y >= 0 && location.Y <= 30);
        if (marker != null) { SelectExpiry(marker.Id); return; }
        selectedExpiry = null;
        selectedTimestamp = location.X >= 0 && location.X <= PlotWidth && location.Y >= 0 && location.Y <= 118 && PlotWidth > 8
            ? data.StartedAt + (location.X - 4) / (PlotWidth - 8) * (data.ResetsAt - data.StartedAt) : null;
        UpdateSelection();
    }
    private void SelectExpiry(double id) { selectedExpiry = id; selectedTimestamp = null; UpdateSelection(); }
    private void ClearSelection() { selectedExpiry = null; selectedTimestamp = null; UpdateSelection(); }
    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { ClearSelection(); e.Handled = true; return; }
        if (data.Points.Count == 0 || e.Key is not (Key.Left or Key.Right or Key.Home or Key.End)) return;
        int index = plot.Selected == null ? data.Points.Count - 1 : data.Points.ToList().FindIndex(value => value.Timestamp == plot.Selected.Timestamp);
        index = e.Key == Key.Home ? 0 : e.Key == Key.End ? data.Points.Count - 1 : Math.Clamp(index + (e.Key == Key.Left ? -1 : 1), 0, data.Points.Count - 1);
        selectedTimestamp = data.Points[index].Timestamp; selectedExpiry = null; UpdateSelection(); e.Handled = true;
    }
    private void UpdateSelection()
    {
        QuotaChartPoint? selected = null;
        if (selectedTimestamp is double date && data.Points.Count > 0 && date >= data.Points[0].Timestamp && date <= data.Points[^1].Timestamp)
            selected = data.Points.MinBy(point => Math.Abs(point.Timestamp - date));
        plot.Select(selected);
        var marker = selectedExpiry is double id ? layouts.FirstOrDefault(value => value.Id == id) : null;
        if (shownMarker == marker && shownPoint == selected && shownWidth == PlotWidth) return;
        shownMarker = marker; shownPoint = selected; shownWidth = PlotWidth; tooltip.Children.Clear();
        if (marker != null)
        {
            var rows = new StackPanel { Width = 174, Margin = new Thickness(11, 9, 11, 9) };
            rows.Children.Add(Text(marker.Title, 13, ExpiryInk, FontWeights.Medium));
            foreach (var detail in marker.Details)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
                row.Children.Add(ChartText(detail.DateText, 12));
                if (marker.Details.Count > 1) { var count = ChartText(detail.CountText, 12); count.Margin = new Thickness(10, 0, 0, 0); row.Children.Add(count); }
                rows.Children.Add(row);
            }
            if (marker.MoreText != null) { var more = ChartText(marker.MoreText, 12); more.Margin = new Thickness(0, 6, 0, 0); rows.Children.Add(more); }
            ShowTooltip(rows, Math.Max(0, Math.Min(PlotWidth - 196, marker.X - 98)), 30, 196, 9, WithOpacity(ExpiryInk, 0.2));
        }
        else if (selected != null)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 7, 10, 7) };
            row.Children.Add(ChartText(selected.DateText, 12)); var value = Text(selected.ValueText, 13, plot.Accent, FontWeights.SemiBold);
            value.Margin = new Thickness(10, 0, 0, 0); row.Children.Add(value);
            row.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double width = row.DesiredSize.Width, height = row.DesiredSize.Height;
            double center = Math.Max(88, Math.Min(PlotWidth - 88, plot.PointPosition(selected).X));
            ShowTooltip(row, center - width / 2, 14 - height / 2, width, 8, WithOpacity(plot.Reference, 0.1));
        }
    }
    private void ShowTooltip(FrameworkElement content, double left, double top, double width, double radius, Brush stroke)
    {
        content.Measure(new Size(width, double.PositiveInfinity));
        var material = new ChartMaterial(plot, new Rect(left, top, width, content.DesiredSize.Height), radius, stroke) { Width = width };
        material.Children.Add(content); Canvas.SetLeft(material, left); Canvas.SetTop(material, top); tooltip.Children.Add(material);
    }
    internal static TextBlock Text(string value, double size, Brush? ink = null, FontWeight? weight = null)
    {
        var text = new TextBlock { Text = value, FontFamily = PacerFonts.Interface, FontSize = size, FontWeight = weight ?? FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center };
        if (ink == null) text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); else text.Foreground = ink;
        text.Typography.NumeralAlignment = FontNumeralAlignment.Tabular; return text;
    }
    private static TextBlock ChartText(string value, double size)
    { var text = Text(value, size); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsChartSecondary"); return text; }
    private static Style MarkerStyle()
    {
        var root = new FrameworkElementFactory(typeof(Grid));
        root.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter)));
        var border = new FrameworkElementFactory(typeof(Border), "focus"); border.SetValue(Border.CornerRadiusProperty, new CornerRadius(11.5));
        border.SetValue(Border.BorderBrushProperty, Brushes.Transparent); border.SetValue(Border.BorderThicknessProperty, new Thickness(0.7));
        border.SetValue(IsHitTestVisibleProperty, false); root.AppendChild(border);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = root };
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BorderBrushProperty, new DynamicResourceExtension("SettingsAccent"), "focus")); template.Triggers.Add(focus);
        var style = new Style(typeof(Button)); style.Setters.Add(new Setter(Control.TemplateProperty, template));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        style.Setters.Add(new Setter(Control.VerticalContentAlignmentProperty, VerticalAlignment.Stretch)); return style;
    }
    internal static Brush WithOpacity(Brush ink, double opacity) { var copy = ink.Clone(); copy.Opacity *= opacity; copy.Freeze(); return copy; }
    private static Brush Frozen(Color color) { var brush = new SolidColorBrush(color); brush.Freeze(); return brush; }
}

/// Samples only this chart's live vector backdrop, then applies blur and the
/// theme's material tint. No screenshot or exported native surface is used.
internal sealed class ChartMaterial : Grid
{
    internal ChartMaterial(Visual backdrop, Rect sample, double radius, Brush stroke)
    {
        var texture = new Border { Background = new VisualBrush(backdrop) { ViewboxUnits = BrushMappingMode.Absolute, Viewbox = sample, Stretch = Stretch.Fill },
            Effect = new BlurEffect { Radius = 14, RenderingBias = RenderingBias.Quality } };
        Children.Add(texture);
        var tint = new Border { CornerRadius = new CornerRadius(radius) }; tint.SetResourceReference(Border.BackgroundProperty, "SettingsChartMaterial"); Children.Add(tint);
        var edge = new Border { CornerRadius = new CornerRadius(radius), BorderBrush = stroke, BorderThickness = new Thickness(0.5), IsHitTestVisible = false };
        Children.Add(edge);
        SizeChanged += (_, _) => Clip = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight), radius, radius);
    }
}

internal sealed class QuotaHistoryPlot : FrameworkElement
{
    internal static readonly DependencyProperty ReferenceProperty = DependencyProperty.Register(nameof(Reference), typeof(Brush), typeof(QuotaHistoryPlot), new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender, OnPaletteChanged));
    internal static readonly DependencyProperty SecondaryProperty = DependencyProperty.Register(nameof(Secondary), typeof(Brush), typeof(QuotaHistoryPlot), new FrameworkPropertyMetadata(Brushes.Gray, FrameworkPropertyMetadataOptions.AffectsRender, OnPaletteChanged));
    internal Brush Reference { get => (Brush)GetValue(ReferenceProperty); set => SetValue(ReferenceProperty, value); }
    internal Brush Secondary { get => (Brush)GetValue(SecondaryProperty); set => SetValue(SecondaryProperty, value); }
    internal Brush Accent { get; }
    internal event Action? PaletteChanged;
    private static void OnPaletteChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args) => ((QuotaHistoryPlot)owner).PaletteChanged?.Invoke();
    internal QuotaChartPoint? Selected { get; private set; }
    private QuotaChartPresentation data;
    private IReadOnlyList<QuotaChartMarker> markers = [];
    private Geometry? line, area;
    internal IReadOnlyList<QuotaChartMarker> Markers { set { markers = value; InvalidateVisual(); } }
    private double PlotWidth => Math.Max(0, ActualWidth - QuotaHistoryChart.AxisWidth);
    internal QuotaHistoryPlot(QuotaChartPresentation data, Brush accent)
    {
        this.data = data; Accent = accent; Focusable = true;
        AutomationProperties.SetAutomationId(this, "quota.chart.samples");
        SizeChanged += (_, _) => RebuildGeometry();
        GotKeyboardFocus += (_, _) => InvalidateVisual(); LostKeyboardFocus += (_, _) => InvalidateVisual();
        Update(data);
    }
    internal void Update(QuotaChartPresentation value)
    {
        bool changed = data.StartedAt != value.StartedAt || data.ResetsAt != value.ResetsAt || !data.Points.SequenceEqual(value.Points);
        data = value; AutomationProperties.SetName(this, data.AccessibilityLabel); AutomationProperties.SetHelpText(this, data.LineHelp);
        if (changed || line == null) RebuildGeometry();
    }
    internal void Select(QuotaChartPoint? value)
    {
        if (Selected == value) return;
        string before = AccessibleValue; Selected = value; InvalidateVisual();
        if (UIElementAutomationPeer.FromElement(this) is QuotaHistoryPlotPeer peer)
            peer.RaisePropertyChangedEvent(ValuePatternIdentifiers.ValueProperty, before, AccessibleValue);
    }
    internal string AccessibleValue => (Selected ?? data.Points.LastOrDefault())?.AccessibilityLabel ?? "";
    internal Point PointPosition(QuotaChartPoint point) => new(4 + point.Fraction * Math.Max(0, PlotWidth - 8), 5 + (100 - point.Remaining) / 100 * 108);
    private void RebuildGeometry()
    {
        var path = new StreamGeometry(); var fill = new StreamGeometry();
        if (data.Points.Count > 0)
        {
            using (var drawing = path.Open())
            { drawing.BeginFigure(PointPosition(data.Points[0]), false, false); foreach (var point in data.Points.Skip(1)) drawing.LineTo(PointPosition(point), true, false); }
            using (var drawing = fill.Open())
            {
                drawing.BeginFigure(new Point(PointPosition(data.Points[0]).X, 113), true, true);
                foreach (var point in data.Points) drawing.LineTo(PointPosition(point), true, false);
                drawing.LineTo(new Point(PointPosition(data.Points[^1]).X, 113), true, false);
            }
        }
        path.Freeze(); fill.Freeze(); line = path; area = fill; InvalidateVisual();
    }
    protected override Size MeasureOverride(Size available) => new(double.IsFinite(available.Width) ? available.Width : 0, 118);
    protected override void OnRender(DrawingContext drawing)
    {
        drawing.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, ActualWidth, 118));
        double width = PlotWidth; if (width < 43) return;
        var face = new Typeface(PacerFonts.Interface, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        foreach (int value in new[] { 0, 50, 100 })
        {
            double y = 5 + (100 - value) / 100.0 * 108;
            // Charts applies its axis treatment in addition to the view's
            // foreground style. These values match the captured native axis.
            drawing.DrawLine(new Pen(QuotaHistoryChart.WithOpacity(Reference, 0.0235), 1), new Point(0, y), new Point(width, y));
            var label = new FormattedText(value + "%", PacerFonts.Culture(this), FlowDirection.LeftToRight, face, 11, QuotaHistoryChart.WithOpacity(Secondary, 0.5), VisualTreeHelper.GetDpi(this).PixelsPerDip);
            drawing.DrawText(label, new Point(width + 4, y - label.Height / 2));
        }
        drawing.PushClip(new RectangleGeometry(new Rect(0, 0, width, 118)));
        if (Accent is SolidColorBrush accent)
        {
            var gradient = new LinearGradientBrush(Color.FromArgb(33, accent.Color.R, accent.Color.G, accent.Color.B), Color.FromArgb(4, accent.Color.R, accent.Color.G, accent.Color.B), 90);
            drawing.DrawGeometry(gradient, null, area);
        }
        var reference = new Pen(QuotaHistoryChart.WithOpacity(Reference, 0.23), 1) { DashStyle = new DashStyle(new double[] { 3, 5 }, 0), DashCap = PenLineCap.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        drawing.DrawLine(reference, new Point(4, 5), new Point(width - 4, 113));
        var stroke = new Pen(Accent, 2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        drawing.DrawGeometry(null, stroke, line);
        if (Selected != null) drawing.DrawLine(new Pen(QuotaHistoryChart.WithOpacity(Reference, 0.24), 1), new Point(PointPosition(Selected).X, 0), new Point(PointPosition(Selected).X, 118));
        var highlighted = Selected ?? data.Points.LastOrDefault();
        if (highlighted != null)
        {
            var position = PointPosition(highlighted); double glow = Math.Sqrt((Selected == null ? 80 : 130) / Math.PI), solid = Math.Sqrt((Selected == null ? 18 : 30) / Math.PI);
            drawing.DrawEllipse(QuotaHistoryChart.WithOpacity(Accent, 0.16), null, position, glow, glow);
            drawing.DrawEllipse(Accent, null, position, solid, solid);
        }
        foreach (var marker in markers)
        {
            var guide = new StreamGeometry(); using (var context = guide.Open())
            { context.BeginFigure(new Point(marker.X, 27), false, false); context.LineTo(new Point(marker.DateX, 34), true, false); context.LineTo(new Point(marker.DateX, 118), true, false); }
            drawing.DrawGeometry(null, new Pen(QuotaHistoryChart.WithOpacity(QuotaHistoryChart.ExpiryInk, 0.25), 1) { DashStyle = new DashStyle(new double[] { 2, 4 }, 0) }, guide);
        }
        drawing.Pop();
        if (IsKeyboardFocused) drawing.DrawRoundedRectangle(null, new Pen(Secondary, 0.7), new Rect(0.5, 0.5, ActualWidth - 1, 117), 5, 5);
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new QuotaHistoryPlotPeer(this);
}

internal sealed class QuotaHistoryPlotPeer(QuotaHistoryPlot owner) : FrameworkElementAutomationPeer(owner), IValueProvider
{
    protected override string GetClassNameCore() => "QuotaHistoryPlot";
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Custom;
    public override object? GetPattern(PatternInterface patternInterface) => patternInterface == PatternInterface.Value ? this : base.GetPattern(patternInterface);
    public bool IsReadOnly => true;
    public string Value => owner.AccessibleValue;
    public void SetValue(string value) => throw new InvalidOperationException("Historical samples are read-only.");
}

internal sealed class ChartDecoration : Grid
{
    protected override AutomationPeer OnCreateAutomationPeer() => new DecorationPeer(this);
    private sealed class DecorationPeer(FrameworkElement owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override bool IsControlElementCore() => false;
        protected override bool IsContentElementCore() => false;
        protected override List<AutomationPeer> GetChildrenCore() => [];
    }
}
