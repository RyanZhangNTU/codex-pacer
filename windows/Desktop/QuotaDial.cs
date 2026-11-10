using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal static class RingDrawing
{
    internal static void Arc(DrawingContext drawing, Point centre, double radius, double start, double sweep,
        Brush ink, double thickness, bool round = true, bool dashed = false)
    {
        if (sweep <= 0 || radius <= 0) return;
        var path = new StreamGeometry();
        Point At(double angle) => new(centre.X + radius * Math.Cos(angle * Math.PI / 180), centre.Y + radius * Math.Sin(angle * Math.PI / 180));
        using (var geometry = path.Open())
        {
            geometry.BeginFigure(At(start), false, false);
            // Full circles need at least two arcs, since start and end coincide.
            int pieces = Math.Max(1, (int)Math.Ceiling(sweep / 179.9));
            for (int part = 1; part <= pieces; part++)
                geometry.ArcTo(At(start + sweep * part / pieces), new Size(radius, radius), 0, false, SweepDirection.Clockwise, true, false);
        }
        path.Freeze();
        var pen = new Pen(ink, thickness) { StartLineCap = round ? PenLineCap.Round : PenLineCap.Flat, EndLineCap = round ? PenLineCap.Round : PenLineCap.Flat };
        if (dashed) pen.DashStyle = new DashStyle(new[] { 2 / thickness, 5 / thickness }, 0);
        drawing.DrawGeometry(null, pen, path);
    }
}

/// <summary>The original quota geometry, with independently missing values and clocks.</summary>
internal sealed class QuotaDial : FrameworkElement
{
    private readonly string provider, classicPeriod;
    private readonly EngineWallet? wallet;
    private readonly bool classic;
    private readonly DashboardProvider? dashboard;
    private readonly double? dialSize;
    private readonly PanelGauge? gauge;
    private readonly bool paceTick;
    /// <param name="gauge">Core's choice of window for the panel's chosen periods; without it 5 hours splits the ring when reported.</param>
    /// <param name="paceTick">The white tick where an even pace would be.</param>
    internal QuotaDial(string provider, EngineQuota? quota, EngineWallet? wallet, bool classic = false,
        DashboardProvider? dashboard = null, string classicPeriod = "7d", double? dialSize = null, PanelGauge? gauge = null, bool paceTick = true)
    {
        this.provider = provider; this.wallet = wallet; this.classic = classic; this.dashboard = dashboard;
        this.classicPeriod = classicPeriod; this.dialSize = dialSize; this.gauge = gauge; this.paceTick = paceTick;
        _ = quota; // Raw transport data cannot replace a shared display projection.
    }
    private readonly Typeface regular = new(PacerFonts.Interface, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);
    private readonly Typeface semibold = new(PacerFonts.Interface, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    internal Typeface DetailTypeface => regular;
    internal Typeface ValueTypeface => semibold;
    private double Side => dialSize ?? (classic ? 88 : 104);
    private QuotaWindow? Short => dashboard == null ? null : Projected(dashboard.FiveHour);
    internal bool Split => !classic && (gauge?.Split ?? Short != null);
    /// The window a ring without the split draws: the week, or 5 hours when only that is chosen.
    internal bool ShortGauge => !classic && !Split && gauge?.Period == "5h";
    internal QuotaWindow? Weekly => dashboard == null ? null : Projected(dashboard.Weekly);
    /// The single ring's reading; the week unless the panel chose 5 hours alone.
    internal DashboardReading? GaugeReading => ShortGauge ? dashboard?.FiveHour : dashboard?.Weekly;
    internal QuotaWindow? GaugeWindow => ShortGauge ? Short : Weekly;
    private DashboardReading? ClassicReading => classicPeriod == "5h" ? dashboard?.FiveHour : dashboard?.Weekly;
    internal QuotaWindow? Selected => classic ? classicPeriod == "5h" ? Short : Weekly : GaugeWindow;
    internal string AccessibleName => provider == "deepseek" ? wallet?.Dial?.AccessibilityLabel ?? provider
        : classic && ClassicReading != null ? ClassicReading.ClassicAccessibilityLabel
        : dashboard != null ? string.Join("\n", Split ? new[] { dashboard.FiveHour.AccessibilityLabel, dashboard.Weekly.AccessibilityLabel } : new[] { GaugeReading!.AccessibilityLabel })
        : provider;
    private static QuotaWindow? Projected(DashboardReading value) => value.WindowID == null ? null : new(value.WindowID, value.Period,
        value.RemainingPercent, value.RemainingTimePercent, value.PacePercent, value.DurationMinutes, value.ResetsAt,
        value.ResetsAt == null ? null : value.Countdown, value.Verdict, value.VerdictText, value.Pressing, value.ValueText);
    private double ReadingOpacity(bool shortPeriod = false) => (dashboard != null && (shortPeriod ? dashboard.FiveHour : dashboard.Weekly).Availability == "stale") ? 0.55 : 1;
    protected override AutomationPeer OnCreateAutomationPeer() => new DialPeer(this);
    private sealed class DialPeer(QuotaDial owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => "PacerQuotaDial";
        protected override string GetNameCore() => owner.AccessibleName;
    }
    protected override Size MeasureOverride(Size availableSize) => new(Side, Side);
    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        if (provider == "deepseek") { DrawWallet(drawing); return; }
        if (dashboard == null || (classic ? ClassicReading?.Availability == "unavailable" : GaugeReading?.Availability == "unavailable" && !Split))
        {
            drawing.DrawEllipse(null, new Pen(PacerPalette.Hairline, 1.5), new Point(Side / 2, Side / 2), Side / 2, Side / 2);
            drawing.PushTransform(new TranslateTransform(Side / 2 - 10, Side / 2 - 10));
            IconGlyph.Draw(drawing, provider == "claude" ? "asterisk" : "chevron.left.forwardslash.chevron.right", PacerPalette.Tertiary, 20, 20);
            drawing.Pop(); return;
        }
        if (classic)
        {
            drawing.PushOpacity(ReadingOpacity(classicPeriod == "5h"));
            if (ClassicReading?.Availability == "proOnly") DrawPro(drawing);
            else
            {
                Gauge(drawing, Selected, -90, 360, false);
                Value(drawing, Selected, 24, Selected?.Countdown == null ? 53.5 : 46, null, 11);
            }
            drawing.Pop();
        }
        else if (Split)
        {
            var shortWindow = Short!;
            drawing.PushOpacity(ReadingOpacity(true));
            Gauge(drawing, shortWindow, 204, 132, true);
            Value(drawing, shortWindow, 18, 32, "5h");
            drawing.Pop();
            drawing.PushOpacity(ReadingOpacity());
            Gauge(drawing, Weekly, 348, 204, false);
            Value(drawing, Weekly, 22, 72, "7d");
            drawing.Pop();
        }
        else
        {
            var window = GaugeWindow;
            drawing.PushOpacity(ReadingOpacity(ShortGauge));
            Gauge(drawing, window, 125, 290, ShortGauge);
            Value(drawing, window, 24, 52, null);
            Centre(drawing, ShortGauge ? "5h" : "7d", 10, 90, window?.Pressing == true ? PacerPalette.Attention : PacerPalette.Secondary, true);
            drawing.Pop();
        }
    }
    private void DrawPro(DrawingContext drawing)
    {
        var centre = new Point(44, 44);
        drawing.DrawEllipse(null, new Pen(PacerPalette.Ink(219, 224, 232, 77), 1), centre, 44, 44);
        drawing.DrawEllipse(null, new Pen(PacerPalette.Ink(219, 224, 232, 31), 1), centre, 34, 34);
        // The original subscription mark has 2.5-point tracking. Draw the
        // localized glyphs individually rather than stretching the word.
        string title = UiText.For(Language.IetfLanguageTag.StartsWith("zh", StringComparison.OrdinalIgnoreCase)).Text("dashboard.pro");
        var glyphs = System.Globalization.StringInfo.GetTextElementEnumerator(title);
        var parts = new System.Collections.Generic.List<FormattedText>();
        while (glyphs.MoveNext()) parts.Add(Text(glyphs.GetTextElement(), 14, PacerPalette.Ink(219, 224, 232), true));
        double width = parts.Sum(part => part.WidthIncludingTrailingWhitespace) + Math.Max(0, parts.Count - 1) * 2.5;
        double x = (Side - width) / 2;
        foreach (var part in parts) { drawing.DrawText(part, new Point(x, (Side - part.Height) / 2)); x += part.WidthIncludingTrailingWhitespace + 2.5; }
    }
    private void Gauge(DrawingContext drawing, QuotaWindow? window, double start, double sweep, bool shortPeriod)
    {
        double radius = Side / 2;
        var centre = new Point(radius, radius);
        RingDrawing.Arc(drawing, centre, radius, start, sweep, PacerPalette.Hairline, 6, dashed: window?.RemainingPercent == null);
        if (window?.RemainingPercent is double percent && percent > 0)
            RingDrawing.Arc(drawing, centre, radius, start, sweep * Math.Clamp(percent / 100, 0, 1),
                shortPeriod && window.Pressing ? PacerPalette.Attention : PacerPalette.Provider(provider), 6);
        if (paceTick && window?.RemainingTimePercent is double time)
        {
            drawing.PushTransform(new RotateTransform(start + sweep * Math.Clamp(time / 100, 0, 1) + 90, radius, radius));
            drawing.DrawRoundedRectangle(Brushes.White, new Pen(PacerPalette.Ink(0, 0, 0, 115), 0.5), new Rect(radius - 1.25, -6, 2.5, 12), 1.25, 1.25);
            drawing.Pop();
        }
    }
    private void Value(DrawingContext drawing, QuotaWindow? window, double size, double baseline, string? period, double percentSize = 9)
    {
        bool known = window?.RemainingPercent != null;
        Brush color = !known ? PacerPalette.Tertiary : !classic && window?.Pressing == true ? PacerPalette.Attention : PacerPalette.Primary;
        var number = Text(window?.ValueText ?? "—", size, color, true);
        var unit = Text(known ? "%" : "", percentSize, PacerPalette.Secondary, true);
        var label = Text(period ?? "", 9, window?.Pressing == true ? PacerPalette.Attention : PacerPalette.Tertiary);
        double labelGap = period == null ? 0 : 3;
        double width = number.WidthIncludingTrailingWhitespace + (known ? 1 : 0) + unit.WidthIncludingTrailingWhitespace + label.WidthIncludingTrailingWhitespace + labelGap;
        double x = (Side - width) / 2;
        if (period != null) { drawing.DrawText(label, new Point(x, baseline - label.Baseline)); x += label.WidthIncludingTrailingWhitespace + labelGap; }
        drawing.DrawText(number, new Point(x, baseline - number.Baseline));
        if (known) drawing.DrawText(unit, new Point(x + number.WidthIncludingTrailingWhitespace + 1, baseline - unit.Baseline));
        if (window?.Countdown != null) Centre(drawing, window.Countdown, classic ? 10 : 9, baseline + 4, PacerPalette.Tertiary);
    }
    private void DrawWallet(DrawingContext drawing)
    {
        double k = Side / 108, radius = Side / 2 - 9 * k, centre = Side / 2;
        var point = new Point(centre, centre);
        if (wallet?.Dial == null) { drawing.DrawEllipse(null, new Pen(PacerPalette.Hairline, 1.5), point, radius, radius); return; }
        var presentation = wallet.Dial;
        drawing.PushOpacity(presentation.DimmedFace ? 0.55 : 1);
        double largest = Math.Max(0.01, wallet.Hourly.Count == 0 ? 0 : wallet.Hourly.Max());
        int currentHour = (int)(wallet.Angle / 15);
        for (int hour = 0; hour < 24; hour++)
        {
            double start = hour * 15 + 1.6, end = hour * 15 + 13.4;
            RingDrawing.Arc(drawing, point, radius, start - 90, end - start, PacerPalette.Hairline, 2.2 * k);
            double spent = hour < wallet.Hourly.Count ? wallet.Hourly[hour] : 0;
            if (spent < 0.0005 || hour > currentHour) continue;
            double stop = hour == currentHour ? Math.Min(end, Math.Max(start + 1, wallet.Angle)) : end;
            RingDrawing.Arc(drawing, point, radius, start - 90, stop - start,
                WalletInk(presentation.SegmentTone), (2.4 + 4.2 * spent / largest) * k, false);
        }
        foreach (var peak in wallet.Peak.Where(p => p.End - p.Start > 1.6))
            RingDrawing.Arc(drawing, point, radius + 6.2 * k, peak.Start + 0.8 - 90, peak.End - peak.Start - 1.6,
                PacerPalette.Ink(255, 189, 97, 217), 1.5 * k);
        double radians = (wallet.Angle - 90) * Math.PI / 180;
        var a = new Point(centre + (radius - 5 * k) * Math.Cos(radians), centre + (radius - 5 * k) * Math.Sin(radians));
        var b = new Point(centre + (radius + 5 * k) * Math.Cos(radians), centre + (radius + 5 * k) * Math.Sin(radians));
        drawing.DrawLine(new Pen(PacerPalette.Ink(0, 0, 0, 115), Math.Max(1.2, 2.4 * k)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, a, b);
        drawing.DrawLine(new Pen(PacerPalette.Tick, Math.Max(1, 1.7 * k)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, a, b);
        drawing.Pop();
        DrawWalletCentre(drawing, presentation);
    }
    internal static Brush WalletInk(string tone) => tone switch
    {
        "secondary" => PacerPalette.Secondary, "tertiary" => PacerPalette.Tertiary,
        "attention" => PacerPalette.Attention, "danger" => PacerPalette.Danger,
        "provider" => PacerPalette.DeepSeek, "staleSegment" => PacerPalette.Ink(92, 92, 92), _ => PacerPalette.Primary
    };
    internal double ConnectButtonTop
    {
        get { double k = Side / 108, dashHeight = Text("—", 18 * k, PacerPalette.Tertiary, true).Height; return (Side - dashHeight - 5 * k - 22) / 2 + dashHeight + 5 * k; }
    }
    private void DrawWalletCentre(DrawingContext drawing, DeepSeekDialPresentation presentation)
    {
        double k = Side / 108, maxWidth = Side * 0.68;
        var subtitle = Text(presentation.Subtitle, Math.Max(9, 8.6 * k), WalletInk(presentation.SubtitleTone));
        if (wallet?.Balance == null)
        {
            var dash = Text("—", 18 * k, PacerPalette.Tertiary, true);
            double height = dash.Height + 5 * k + (presentation.ConnectTitle != null ? 22 : subtitle.Height), top = (Side - height) / 2;
            drawing.DrawText(dash, new Point((Side - dash.WidthIncludingTrailingWhitespace) / 2, top));
            if (presentation.ConnectTitle == null) WalletSubtitle(drawing, subtitle, top + dash.Height + 5 * k, Side * 0.72);
            return;
        }
        var currency = Text("¥", 10 * k, PacerPalette.Secondary, true);
        var whole = Text(wallet.Whole, 21 * k, WalletInk(presentation.BalanceTone), true);
        var cents = Text(wallet.Cents, 9 * k, PacerPalette.Secondary, true);
        double width = currency.WidthIncludingTrailingWhitespace + whole.WidthIncludingTrailingWhitespace + cents.WidthIncludingTrailingWhitespace;
        double scale = Math.Max(0.6, Math.Min(1, maxWidth / Math.Max(1, width)));
        double rowHeight = whole.Height * scale, y = (Side - rowHeight - 2 * k - subtitle.Height) / 2;
        double baseline = whole.Baseline, x = 0;
        drawing.PushTransform(new TranslateTransform((Side - width * scale) / 2, y)); drawing.PushTransform(new ScaleTransform(scale, scale));
        drawing.DrawText(currency, new Point(x, baseline - currency.Baseline)); x += currency.WidthIncludingTrailingWhitespace;
        drawing.DrawText(whole, new Point(x, 0)); x += whole.WidthIncludingTrailingWhitespace;
        drawing.DrawText(cents, new Point(x, baseline - cents.Baseline)); drawing.Pop(); drawing.Pop();
        WalletSubtitle(drawing, subtitle, y + rowHeight + 2 * k, maxWidth);
    }
    private void WalletSubtitle(DrawingContext drawing, FormattedText text, double top, double maxWidth)
    {
        double scale = Math.Max(0.8, Math.Min(1, maxWidth / Math.Max(1, text.WidthIncludingTrailingWhitespace)));
        text.MaxTextWidth = maxWidth / scale; text.MaxLineCount = 1; text.Trimming = TextTrimming.CharacterEllipsis;
        drawing.PushTransform(new TranslateTransform((Side - text.WidthIncludingTrailingWhitespace * scale) / 2, top));
        drawing.PushTransform(new ScaleTransform(scale, scale)); drawing.DrawText(text, new Point()); drawing.Pop(); drawing.Pop();
    }
    private FormattedText Text(string value, double size, Brush ink, bool bold = false) => new(value, PacerFonts.Culture(this),
        FlowDirection.LeftToRight, bold ? semibold : regular, size, ink, VisualTreeHelper.GetDpi(this).PixelsPerDip);
    private void Centre(DrawingContext drawing, string value, double size, double top, Brush ink, bool bold = false)
    {
        var text = Text(value, size, ink, bold);
        drawing.DrawText(text, new Point((Side - text.WidthIncludingTrailingWhitespace) / 2, top));
    }
}

internal sealed class QuotaCell : StackPanel
{
    internal QuotaCell(string provider, EngineQuota? quota, EngineWallet? wallet, string? help = null, DashboardProvider? dashboard = null, FrameworkElement? status = null,
        PanelGauge? gauge = null, bool paceTick = true)
    {
        HorizontalAlignment = HorizontalAlignment.Stretch;
        var dial = new QuotaDial(provider, quota, wallet, dashboard: dashboard, gauge: gauge, paceTick: paceTick) { Width = 104, Height = 104, HorizontalAlignment = HorizontalAlignment.Center };
        Children.Add(dial);
        var caption = new StackPanel { Orientation = Orientation.Horizontal, Height = 15, Margin = new Thickness(0, 8, 0, 6), HorizontalAlignment = HorizontalAlignment.Center };
        caption.Children.Add(new TextBlock { Text = provider switch { "codex" => "Codex", "claude" => "Claude", _ => "DeepSeek" },
            FontSize = 11, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var shown = dial.GaugeWindow;
        string? verdict = dial.Split ? null : shown?.VerdictText;
        if (provider == "deepseek" && wallet?.PeakNow == true) verdict = "×2";
        if (verdict != null)
        {
            Brush ink = provider == "deepseek" || shown?.Verdict == "fast" ? PacerPalette.Attention : PacerPalette.Primary;
            caption.Children.Add(new Border { CornerRadius = new CornerRadius(7.5), Height = 15, Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(5, 0, 0, 0),
                Background = provider == "deepseek" || shown?.Verdict == "fast" ? PacerPalette.Ink(255, 189, 97, 36) : PacerPalette.Overlay(36),
                Child = new TextBlock { Text = verdict, FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = ink, VerticalAlignment = VerticalAlignment.Center } });
        }
        Children.Add(caption);
        if (status != null) Children.Add(status);
        string details = string.Join("\n\n", new[] { provider != "deepseek" && dial.Split ? dashboard?.FiveHour.SplitHelp : null,
            provider != "deepseek" ? dial.GaugeReading?.SplitHelp : null, provider != "deepseek" ? dashboard?.Weekly.SourceText : null, help }.Where(value => !string.IsNullOrWhiteSpace(value)));
        if (!string.IsNullOrWhiteSpace(details)) AutomationProperties.SetHelpText(this, details);
        AutomationProperties.SetName(this, dial.AccessibleName);
    }
}

/// The collapsed bar's quota rings, the expanded panel's open gauge in small:
/// 290° from the lower left with the opening at the bottom, a track in the
/// service's colour, a white tick where the window's time stands, amber when
/// low and a red track when used up. Two services nest, sit side by side, or
/// one service splits its 5-hour and weekly windows.
public sealed class CompactQuotaGlyph : FrameworkElement
{
    private const double Start = 125, Sweep = 290;
    private CompactRing[] rings = [];
    private EngineWallet? clock;
    private string layout = "concentric";
    private bool vertical;
    private string? focus;
    private double size = 20;
    internal int RingCount => rings.Length;
    internal bool ShowsPriceClock => clock != null;
    /// How the rings are arranged now: single, concentric, side or split.
    internal string Arrangement => clock != null ? "clock" : rings.Length == 0 ? "none" : Split ? "split" : rings.Length == 1 ? "single" : Side ? "side" : "concentric";
    private bool Split => rings.Length == 2 && rings.All(ring => ring.Window != null);
    private bool Side => rings.Length == 2 && !Split && layout == "sideBySide";
    internal void Update(CompactProjection value, EngineWallet? wallet, bool strip = false)
    {
        rings = value.Rings.ToArray(); clock = value.GaugeClock ? wallet : null;
        layout = value.Choices.RingLayout; vertical = strip; size = value.Sizes.Gauge;
        double unit = size / 20;
        Width = Side && !vertical ? 36 * unit : size; Height = Side && vertical ? 36 * unit : size;
        InvalidateVisual();
    }
    /// While the quota value takes turns, the other service's ring steps back.
    internal string? Highlighted { get => focus; set { if (focus == value) return; focus = value; InvalidateVisual(); } }
    protected override void OnRender(DrawingContext drawing)
    {
        double unit = size / 20;
        drawing.PushTransform(new ScaleTransform(unit, unit));
        if (clock != null) DeepSeekPriceClock.DrawCompact(drawing, clock, 20);
        else if (Split) { DrawSplit(drawing, rings[0], 204, 132); DrawSplit(drawing, rings[1], 348, 204); }
        else if (Side) { Gauge(drawing, rings[0], vertical ? new(10, 8) : new(8, 10), 6.3, 2.1); Gauge(drawing, rings[1], vertical ? new(10, 28) : new(28, 10), 6.3, 2.1); }
        else if (rings.Length == 1) Gauge(drawing, rings[0], new(10, 10), 8.5, 3);
        else for (int index = 0; index < rings.Length; index++) Gauge(drawing, rings[index], new(10, 10), index == 0 ? 8.75 : 5.45, 2.1);
        drawing.Pop();
    }
    private double Emphasis(CompactRing ring) => (ring.Dimmed ? 0.5 : 1) * (focus != null && focus != ring.Provider && rings.Length > 1 && !Split ? 0.42 : 1);
    private static Brush Track(CompactRing ring)
    {
        if (ring.Exhausted == true) { var red = PacerPalette.Danger.Clone(); red.Opacity = 0.4; red.Freeze(); return red; }
        var track = PacerPalette.Provider(ring.Provider).Clone(); track.Opacity = 0.26; track.Freeze(); return track;
    }
    private static Brush Fill(CompactRing ring) => ring.Low == true ? PacerPalette.Attention : PacerPalette.Provider(ring.Provider);
    private void Gauge(DrawingContext drawing, CompactRing ring, Point centre, double radius, double stroke)
    {
        drawing.PushOpacity(Emphasis(ring));
        // A ring without a reading, or with an old one, has a dashed track and no tick.
        RingDrawing.Arc(drawing, centre, radius, Start, Sweep, Track(ring), stroke, false, ring.Dimmed || ring.Remaining == null);
        if (ring.Remaining is double percent && percent > 0.5)
            RingDrawing.Arc(drawing, centre, radius, Start, Sweep * Math.Clamp(percent / 100, 0, 1), Fill(ring), stroke);
        if (ring.Time is double time && !ring.Dimmed) Tick(drawing, centre, Start + Sweep * Math.Clamp(time, 0, 1), radius - 2, radius + 2);
        drawing.Pop();
    }
    private void DrawSplit(DrawingContext drawing, CompactRing ring, double start, double span)
    {
        var centre = new Point(10, 10);
        drawing.PushOpacity(Emphasis(ring));
        RingDrawing.Arc(drawing, centre, 8, start, span, Track(ring), 2.1, false, ring.Dimmed || ring.Remaining == null);
        if (ring.Remaining is double percent && percent > 0.5)
            RingDrawing.Arc(drawing, centre, 8, start, span * Math.Clamp(percent / 100, 0, 1), Fill(ring), 2.1);
        if (ring.Time is double time && !ring.Dimmed) Tick(drawing, centre, start + span * Math.Clamp(time, 0, 1), 5.9, 10.1);
        drawing.Pop();
    }
    private static void Tick(DrawingContext drawing, Point centre, double angle, double inner, double outer)
    {
        double radians = angle * Math.PI / 180;
        drawing.DrawLine(new Pen(PacerPalette.Tick, 1.2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round },
            new Point(centre.X + inner * Math.Cos(radians), centre.Y + inner * Math.Sin(radians)),
            new Point(centre.X + outer * Math.Cos(radians), centre.Y + outer * Math.Sin(radians)));
    }
}

/// Original PriceClockGlyph geometry, used in Settings. It draws current
/// wallet inputs rather than an icon. The collapsed bar uses `Compact`: the
/// quota rings' drawing, with peak hours outside and today's hourly spend inside.
internal sealed class DeepSeekPriceClock : FrameworkElement
{
    private EngineWallet? wallet;
    internal bool Compact { get; init; }
    internal void Update(EngineWallet? value) { wallet = value; InvalidateVisual(); }
    protected override void OnRender(DrawingContext drawing)
    {
        if (wallet == null) return;
        if (Compact) DrawCompact(drawing, wallet, Math.Min(ActualWidth, ActualHeight)); else Draw(drawing, wallet, Math.Min(ActualWidth, ActualHeight));
    }
    /// The bar's clock: a faint dial with peak hours in amber outside, today's
    /// spend per hour in blue inside, and a hand that turns amber during a peak.
    internal static void DrawCompact(DrawingContext drawing, EngineWallet value, double side)
    {
        double scale = side / 20;
        var centre = new Point(10, 10);
        drawing.PushTransform(new ScaleTransform(scale, scale));
        drawing.PushOpacity(value.State is "stale" or "disconnected" ? .45 : 1);
        var faint = new Pen(CompactInk.Faint, 2.2);
        drawing.DrawEllipse(null, faint, centre, 8.75, 8.75); drawing.DrawEllipse(null, faint, centre, 5.45, 5.45);
        foreach (var span in value.Peak.Where(span => span.End - span.Start > 4))
            RingDrawing.Arc(drawing, centre, 8.75, span.Start + 2 - 90, span.End - span.Start - 4, PacerPalette.Attention, 2.2);
        int hourNow = (int)(value.Angle / 15);
        for (int hour = 0; hour < Math.Min(24, value.Hourly.Count); hour++)
        {
            if (value.Hourly[hour] < .0005 || hour > hourNow) continue;
            double start = hour * 15, end = hour == hourNow ? Math.Max(start + 4, value.Angle) : start + 15;
            RingDrawing.Arc(drawing, centre, 5.45, start - 90, end - start, PacerPalette.DeepSeek, 2.2, false);
        }
        double angle = (value.Angle - 90) * Math.PI / 180;
        var hand = new Pen(value.PeakNow ? PacerPalette.Attention : PacerPalette.Tick, 1.6) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        drawing.DrawLine(hand, new Point(10 + 2.4 * Math.Cos(angle), 10 + 2.4 * Math.Sin(angle)), new Point(10 + 9.6 * Math.Cos(angle), 10 + 9.6 * Math.Sin(angle)));
        drawing.Pop(); drawing.Pop();
    }
    internal static void Draw(DrawingContext drawing, EngineWallet value, double side)
    {
        double scale = side / 108, centre = side / 2;
        drawing.PushOpacity(value.State is "stale" or "disconnected" ? .45 : 1);
        drawing.DrawEllipse(null, new Pen(PacerPalette.Overlay(41), 11 * scale), new Point(centre, centre), 38 * scale, 38 * scale);
        int hourNow = (int)(value.Angle / 15);
        for (int hour = 0; hour < Math.Min(24, value.Hourly.Count); hour++)
        {
            if (value.Hourly[hour] < .0005 || hour > hourNow) continue;
            double start = hour * 15, end = hour == hourNow ? Math.Max(start + 4, value.Angle) : start + 15;
            RingDrawing.Arc(drawing, new Point(centre, centre), 38 * scale, start - 90, end - start, PacerPalette.DeepSeek, 11 * scale, false);
        }
        foreach (var span in value.Peak.Where(span => span.End - span.Start > 4))
            RingDrawing.Arc(drawing, new Point(centre, centre), 50 * scale, span.Start + 2 - 90, span.End - span.Start - 4, PacerPalette.Attention, 6 * scale);
        double angle = (value.Angle - 90) * Math.PI / 180;
        var from = new Point(centre + 26 * scale * Math.Cos(angle), centre + 26 * scale * Math.Sin(angle));
        var to = new Point(centre + 51 * scale * Math.Cos(angle), centre + 51 * scale * Math.Sin(angle));
        drawing.DrawLine(new Pen(PacerPalette.Ink(0, 0, 0, 204), 13 * scale) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, from, to);
        drawing.DrawLine(new Pen(Brushes.White, 7 * scale) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, from, to); drawing.Pop();
    }
}
