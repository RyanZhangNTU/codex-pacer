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
    internal QuotaDial(string provider, EngineQuota? quota, EngineWallet? wallet, bool classic = false,
        DashboardProvider? dashboard = null, string classicPeriod = "7d", double? dialSize = null)
    {
        this.provider = provider; this.wallet = wallet; this.classic = classic; this.dashboard = dashboard;
        this.classicPeriod = classicPeriod; this.dialSize = dialSize;
        _ = quota; // Raw transport data cannot replace a shared display projection.
    }
    private readonly Typeface regular = new(PacerFonts.Interface, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);
    private readonly Typeface semibold = new(PacerFonts.Interface, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    internal Typeface DetailTypeface => regular;
    internal Typeface ValueTypeface => semibold;
    private double Side => dialSize ?? (classic ? 88 : 104);
    private QuotaWindow? Short => dashboard == null ? null : Projected(dashboard.FiveHour);
    internal bool Split => !classic && Short != null;
    internal QuotaWindow? Weekly => dashboard == null ? null : Projected(dashboard.Weekly);
    private DashboardReading? ClassicReading => classicPeriod == "5h" ? dashboard?.FiveHour : dashboard?.Weekly;
    internal QuotaWindow? Selected => classic ? classicPeriod == "5h" ? Short : Weekly : Weekly;
    internal string AccessibleName => provider == "deepseek" ? wallet?.Dial?.AccessibilityLabel ?? provider
        : classic && ClassicReading != null ? ClassicReading.ClassicAccessibilityLabel
        : dashboard != null ? string.Join("\n", Split ? new[] { dashboard.FiveHour.AccessibilityLabel, dashboard.Weekly.AccessibilityLabel } : new[] { dashboard.Weekly.AccessibilityLabel })
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
        if (dashboard == null || (classic ? ClassicReading?.Availability == "unavailable" : dashboard.Weekly.Availability == "unavailable" && !Split))
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
            drawing.PushOpacity(ReadingOpacity());
            Gauge(drawing, Weekly, 125, 290, false);
            Value(drawing, Weekly, 24, 52, null);
            Centre(drawing, "7d", 10, 90, Weekly?.Pressing == true ? PacerPalette.Attention : PacerPalette.Secondary, true);
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
        if (window?.RemainingTimePercent is double time)
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
        drawing.DrawLine(new Pen(Brushes.White, Math.Max(1, 1.7 * k)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, a, b);
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
    internal QuotaCell(string provider, EngineQuota? quota, EngineWallet? wallet, string? help = null, DashboardProvider? dashboard = null, FrameworkElement? status = null)
    {
        HorizontalAlignment = HorizontalAlignment.Stretch;
        var dial = new QuotaDial(provider, quota, wallet, dashboard: dashboard) { Width = 104, Height = 104, HorizontalAlignment = HorizontalAlignment.Center };
        Children.Add(dial);
        var caption = new StackPanel { Orientation = Orientation.Horizontal, Height = 15, Margin = new Thickness(0, 8, 0, 6), HorizontalAlignment = HorizontalAlignment.Center };
        caption.Children.Add(new TextBlock { Text = provider switch { "codex" => "Codex", "claude" => "Claude", _ => "DeepSeek" },
            FontSize = 11, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        string? verdict = dial.Split ? null : dial.Weekly?.VerdictText;
        if (provider == "deepseek" && wallet?.PeakNow == true) verdict = "×2";
        if (verdict != null)
        {
            Brush ink = provider == "deepseek" || dial.Weekly?.Verdict == "fast" ? PacerPalette.Attention : PacerPalette.Primary;
            caption.Children.Add(new Border { CornerRadius = new CornerRadius(7.5), Height = 15, Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(5, 0, 0, 0),
                Background = provider == "deepseek" || dial.Weekly?.Verdict == "fast" ? PacerPalette.Ink(255, 189, 97, 36) : PacerPalette.Ink(245, 245, 245, 36),
                Child = new TextBlock { Text = verdict, FontSize = 10, FontWeight = FontWeights.SemiBold, Foreground = ink, VerticalAlignment = VerticalAlignment.Center } });
        }
        Children.Add(caption);
        if (status != null) Children.Add(status);
        string details = string.Join("\n\n", new[] { provider != "deepseek" && dial.Split ? dashboard?.FiveHour.SplitHelp : null,
            provider != "deepseek" ? dashboard?.Weekly.SplitHelp : null, provider != "deepseek" ? dashboard?.Weekly.SourceText : null, help }.Where(value => !string.IsNullOrWhiteSpace(value)));
        if (!string.IsNullOrWhiteSpace(details)) AutomationProperties.SetHelpText(this, details);
        AutomationProperties.SetName(this, dial.AccessibleName);
    }
}

public sealed class CompactQuotaGlyph : FrameworkElement
{
    private sealed record Ring(string Provider, double? Remaining, bool Dimmed);
    private Ring[] rings = [];
    private EngineWallet? clock;
    internal int RingCount => rings.Length;
    internal bool ShowsPriceClock => clock != null;
    internal void Update(CompactProjection value, EngineWallet? wallet)
    {
        rings = value.Rings.Select(item => new Ring(item.Provider, item.Remaining, item.Dimmed)).ToArray();
        clock = value.GaugeClock ? wallet : null; InvalidateVisual();
    }
    protected override void OnRender(DrawingContext drawing)
    {
        if (clock != null) { DeepSeekPriceClock.Draw(drawing, clock, 18); return; }
        for (int index = 0; index < rings.Length; index++)
        {
            bool paired = rings.Length > 1;
            double diameter = paired ? index == 0 ? 15.4 : 7.6 : 14.8, stroke = paired ? 2.2 : 2.6;
            drawing.PushOpacity(rings[index].Dimmed ? .45 : 1);
            var track = new Pen(PacerPalette.Ink(255, 255, 255, 36), stroke);
            if (rings[index].Remaining == null) track.DashStyle = new DashStyle(new[] { 1.5 / stroke, 2 / stroke }, 0);
            drawing.DrawEllipse(null, track, new Point(9, 9), diameter / 2, diameter / 2);
            if (rings[index].Remaining is double percent && percent > 0)
                RingDrawing.Arc(drawing, new Point(9, 9), diameter / 2, -90, Math.Clamp(percent / 100, 0, 1) * 360, PacerPalette.Provider(rings[index].Provider), stroke);
            drawing.Pop();
        }
    }
}

/// Original PriceClockGlyph geometry, used at 18 points in the header and
/// 24 points in Settings. It draws current wallet inputs rather than an icon.
internal sealed class DeepSeekPriceClock : FrameworkElement
{
    private EngineWallet? wallet;
    internal void Update(EngineWallet? value) { wallet = value; InvalidateVisual(); }
    protected override void OnRender(DrawingContext drawing) { if (wallet != null) Draw(drawing, wallet, Math.Min(ActualWidth, ActualHeight)); }
    internal static void Draw(DrawingContext drawing, EngineWallet value, double side)
    {
        double scale = side / 108, centre = side / 2;
        drawing.PushOpacity(value.State is "stale" or "disconnected" ? .45 : 1);
        drawing.DrawEllipse(null, new Pen(PacerPalette.Ink(255, 255, 255, 41), 11 * scale), new Point(centre, centre), 38 * scale, 38 * scale);
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
