using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The original solo composition. The engine owns spend, visibility, scale,
/// privacy and formatted readings; these controls only lay out and draw them.
internal sealed class DeepSeekSoloView : StackPanel
{
    internal DeepSeekSoloView(EngineWallet? wallet, UiText ui, bool detailed = true, Action? openUsage = null, string? recoveryText = null, Action? connectAction = null, string? connectUnavailable = null, FrameworkElement? balanceStatus = null)
    {
        Margin = new Thickness(9, 0, 9, 4);
        AutomationProperties.SetAutomationId(this, "quota.deepseek.solo");
        var data = wallet?.Solo;
        bool budget = data?.Budgets.Count > 0;
        var top = new Grid(); top.ColumnDefinitions.Add(new() { Width = new GridLength(132) });
        top.ColumnDefinitions.Add(new() { Width = new GridLength(20) }); top.ColumnDefinitions.Add(new());
        var face = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        if (budget) face.Children.Add(new DeepSeekBudgetDial(data!.Budgets, ui, 132));
        else
        {
            var dial = new QuotaDial("deepseek", null, wallet, dialSize: 132) { Width = 132, Height = 132 };
            var host = new Grid { Width = 132, Height = 132 }; host.Children.Add(dial);
            if (wallet?.Dial?.ConnectTitle is string title)
            {
                var connect = new Button { Content = title, Style = (Style)FindResource("QuotaLinkButton"), IsEnabled = connectAction != null,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, dial.ConnectButtonTop, 0, 0) };
                AutomationProperties.SetAutomationId(connect, "deepseek.balance.connect");
                if (connectAction == null) AutomationProperties.SetHelpText(connect, connectUnavailable ?? ui.Text("windows.deepseek.runtime_required"));
                connect.Click += (_, _) => { if (connect.IsVisible && connect.IsEnabled) connectAction?.Invoke(); };
                AutomationProperties.SetName(connect, title); host.Children.Add(connect);
            }
            face.Children.Add(host);
        }
        if (wallet?.PeakNow == true)
        {
            var label = new TextBlock { FontFamily = PacerFonts.Interface, FontSize = 11, Foreground = PacerPalette.Attention, VerticalAlignment = VerticalAlignment.Center };
            label.Inlines.Add(new Run("×2") { FontWeight = FontWeights.Bold });
            if (data?.PeakUntil is string until)
            { label.Inlines.Add(new InlineUIContainer(new Border { Width = 4, Height = 1 })); label.Inlines.Add(new Run(until) { FontWeight = FontWeights.Medium }); }
            face.Children.Add(new Border { Height = 20, CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 0, 8, 0),
                Margin = new Thickness(0, 8, 0, 0), Background = PacerPalette.Ink(255, 189, 97, 36), HorizontalAlignment = HorizontalAlignment.Center,
                Child = label });
            if (wallet.Dial?.PeakHelp is string peakHelp) AutomationProperties.SetHelpText(label, peakHelp);
        }
        top.Children.Add(face);
        var right = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        if (data != null)
        {
            if (budget) right.Children.Add(new DeepSeekBudgetDetails(data.Budgets, ui));
            else
            {
                var today = DeepSeekElements.Text(data.TodayLabel, 11, PacerPalette.Tertiary, FontWeights.SemiBold);
                today.Inlines.Add(new InlineUIContainer(new Border { Width = 10, Height = 1 }));
                today.Inlines.Add(new Run(data.TodayText) { FontSize = 20, Foreground = PacerPalette.Primary });
                AutomationProperties.SetHelpText(today, data.TodayHelp); AutomationProperties.SetAutomationId(today, "deepseek.today"); right.Children.Add(today);
            }
            if (data.Speed != null) AddSpaced(right, new DeepSeekSpeedView(data.Speed, data.TodayLabel), 12);
            if (detailed && !budget && data.Distribution != null) AddSpaced(right, new DeepSeekDistributionView(data.Distribution, openUsage), 12);
        }
        Grid.SetColumn(right, 2); top.Children.Add(right); Children.Add(top);
        if (detailed && data != null)
        {
            if (budget && data.Distribution != null) AddSpaced(this, new DeepSeekDistributionView(data.Distribution, openUsage), 14);
            if (data.Week != null) AddSpaced(this, new DeepSeekWeekView(data.Week), 14);
        }
        if (balanceStatus != null) AddSpaced(this, balanceStatus, 14);
        else if (!string.IsNullOrWhiteSpace(recoveryText))
        {
            var recovery = DeepSeekElements.Text(recoveryText, 11, PacerPalette.Secondary);
            recovery.TextWrapping = TextWrapping.Wrap; recovery.TextAlignment = TextAlignment.Center;
            AddSpaced(this, recovery, 14);
        }
    }
    private static void AddSpaced(StackPanel panel, FrameworkElement child, double spacing)
    { child.Margin = new Thickness(0, panel.Children.Count > 0 ? spacing : 0, 0, 0); panel.Children.Add(child); }
}

internal static class DeepSeekElements
{
    internal static TextBlock Text(string value, double size, Brush ink, FontWeight? weight = null)
    {
        var text = new TextBlock { Text = value, FontFamily = PacerFonts.Interface, FontSize = size, Foreground = ink,
            FontWeight = weight ?? FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        text.Typography.NumeralAlignment = FontNumeralAlignment.Tabular; return text;
    }
    internal static Grid Row(UIElement left, UIElement right, double? height = null, double gap = 6)
    {
        var row = new Grid(); if (height != null) row.Height = height.Value;
        row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = new GridLength(gap) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(left); Grid.SetColumn(right, 2); row.Children.Add(right); return row;
    }
    internal static Brush Opacity(Brush brush, double opacity)
    { var result = brush.Clone(); result.Opacity = Math.Clamp(opacity, 0, 1); result.Freeze(); return result; }
    internal static Pen Dashed(Brush ink) => new(ink, 1) { DashStyle = new DashStyle(new[] { 3.0, 3.0 }, 0) };
}

internal sealed class DeepSeekSpeedView : QuotaReadingHost
{
    internal DeepSeekSpeedView(DeepSeekSpeedPresentation data, string todayLabel)
    {
        AutomationProperties.SetName(this, data.AccessibilityLabel); AutomationProperties.SetAutomationId(this, "deepseek.speed"); AutomationProperties.SetHelpText(this, data.Help);
        var label = DeepSeekElements.Text(data.Label, 11, PacerPalette.Tertiary, FontWeights.SemiBold);
        var other = DeepSeekElements.Text(todayLabel, 11, PacerPalette.Tertiary, FontWeights.SemiBold);
        label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); other.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        label.Width = Math.Ceiling(Math.Max(label.DesiredSize.Width, other.DesiredSize.Width));
        var row = new Grid(); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new GridLength(10) });
        row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = new GridLength(10) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(label);
        var bars = new DeepSeekSpeedPlot(data) { Height = 22 }; Grid.SetColumn(bars, 2); row.Children.Add(bars);
        var rate = DeepSeekElements.Text(data.RateText, 11, data.Spiking ? PacerPalette.Danger : PacerPalette.Secondary, FontWeights.Medium);
        Grid.SetColumn(rate, 4); row.Children.Add(rate); Children.Add(row);
    }
}
internal sealed class DeepSeekSpeedPlot(DeepSeekSpeedPresentation data) : FrameworkElement
{
    protected override Size MeasureOverride(Size available) => new(0, 22);
    protected override void OnRender(DrawingContext drawing)
    {
        double step = ActualWidth / Math.Max(1, data.Fractions.Count), width = step * .68;
        for (int index = 0; index < data.Fractions.Count; index++)
        {
            double height = Math.Max(1, data.Fractions[index] * ActualHeight);
            drawing.DrawRectangle(DeepSeekElements.Opacity(PacerPalette.DeepSeek, index == data.Fractions.Count - 1 ? 1 : .5), null,
                new Rect(index * step + (step - width) / 2, ActualHeight - height, width, height));
        }
        if (data.LineFraction is double fraction)
            drawing.DrawLine(DeepSeekElements.Dashed(DeepSeekElements.Opacity(PacerPalette.Danger, .6)), new Point(0, ActualHeight * (1 - fraction)), new Point(ActualWidth, ActualHeight * (1 - fraction)));
    }
}

internal sealed class DeepSeekDistributionView : StackPanel
{
    internal DeepSeekDistributionView(DeepSeekDistribution data, Action? openUsage = null)
    {
        AutomationProperties.SetAutomationId(this, "deepseek.distribution");
        Children.Add(DeepSeekElements.Text(data.Title, 11, PacerPalette.Tertiary, FontWeights.SemiBold));
        var strip = new DeepSeekSpendStrip(data.Parts) { Height = 10, Margin = new Thickness(0, 7, 0, 0) }; Children.Add(strip);
        var legend = new DeepSeekFlowRow { Margin = new Thickness(0, 7, 0, 0) };
        foreach (var part in data.Parts)
        {
            var item = new StackPanel { Orientation = Orientation.Horizontal };
            item.Children.Add(new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(2), VerticalAlignment = VerticalAlignment.Center,
                Background = part.Elsewhere ? PacerPalette.Ink(255, 255, 255, 102) : DeepSeekElements.Opacity(PacerPalette.DeepSeek, Math.Max(.32, part.Opacity)) });
            var title = DeepSeekElements.Text(part.Title, 10.5, PacerPalette.Secondary); title.MaxWidth = 140; title.Margin = new Thickness(4, 0, 0, 0); item.Children.Add(title);
            if (part.Help != null) AutomationProperties.SetHelpText(title, part.Help);
            var amount = DeepSeekElements.Text(part.AmountText, 10.5, PacerPalette.Primary); amount.Margin = new Thickness(4, 0, 0, 0); item.Children.Add(amount);
            if (part.Elsewhere)
            {
                var link = new Button { Style = (Style)FindResource("DeepSeekInfoButton"), Width = 13, Height = 13, Margin = new Thickness(4, 0, 0, 0),
                    Padding = new Thickness(0), Content = new IconGlyph { Symbol = "info.circle", Width = 11, Height = 11, Ink = PacerPalette.Tertiary } };
                AutomationProperties.SetName(link, data.UsageTitle); AutomationProperties.SetAutomationId(link, "deepseek.usage");
                AutomationProperties.SetHelpText(link, data.UsageHelp);
                link.Click += (_, _) =>
                {
                    if (openUsage != null) { openUsage(); return; }
                    try { Process.Start(new ProcessStartInfo("https://platform.deepseek.com/usage") { UseShellExecute = true }); }
                    catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
                    { AutomationProperties.SetHelpText(link, data.UsageTitle + "\nhttps://platform.deepseek.com/usage"); }
                };
                item.Children.Add(link);
            }
            legend.Children.Add(item);
        }
        Children.Add(legend);
    }
}
internal sealed class DeepSeekFlowRow : Panel
{
    protected override Size MeasureOverride(Size available)
    {
        double x = 0, y = 0, line = 0, widest = 0;
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); var size = child.DesiredSize;
            if (x > 0 && x + size.Width > available.Width) { y += line + 4; x = 0; line = 0; }
            x += size.Width + 12; line = Math.Max(line, size.Height); widest = Math.Max(widest, x - 12);
        }
        return new Size(double.IsFinite(available.Width) ? available.Width : widest, y + line);
    }
    protected override Size ArrangeOverride(Size final)
    {
        double x = 0, y = 0, line = 0;
        foreach (UIElement child in InternalChildren)
        {
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > final.Width) { y += line + 4; x = 0; line = 0; }
            child.Arrange(new Rect(new Point(x, y), size)); x += size.Width + 12; line = Math.Max(line, size.Height);
        }
        return final;
    }
}
internal sealed class DeepSeekSpendStrip : Panel
{
    private readonly IReadOnlyList<DeepSeekPart> parts;
    internal DeepSeekSpendStrip(IReadOnlyList<DeepSeekPart> values)
    { parts = values; foreach (var part in parts) Children.Add(new DeepSeekSpendSegment(part)); }
    protected override Size MeasureOverride(Size available)
    { foreach (UIElement child in InternalChildren) child.Measure(new Size(0, 10)); return new Size(0, 10); }
    protected override Size ArrangeOverride(Size final)
    {
        double available = Math.Max(0, final.Width - Math.Max(0, parts.Count - 1) * 2), x = 0;
        for (int index = 0; index < parts.Count; index++)
        { double width = Math.Max(4, available * parts[index].Fraction); InternalChildren[index].Arrange(new Rect(x, 0, width, 10)); x += width + 2; }
        return final;
    }
}
internal sealed class DeepSeekSpendSegment(DeepSeekPart part) : FrameworkElement
{
    protected override void OnRender(DrawingContext drawing)
    {
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        drawing.DrawRoundedRectangle(part.Elsewhere ? PacerPalette.Ink(255, 255, 255, 31) : DeepSeekElements.Opacity(PacerPalette.DeepSeek, part.Opacity), null, bounds, 3, 3);
        if (!part.Elsewhere) return;
        drawing.PushClip(new RectangleGeometry(bounds, 3, 3));
        var pen = new Pen(PacerPalette.Ink(255, 255, 255, 115), 1.4);
        for (double x = -ActualHeight; x < ActualWidth; x += 4.5) drawing.DrawLine(pen, new Point(x, ActualHeight), new Point(x + ActualHeight, 0));
        drawing.Pop();
    }
}

internal sealed class DeepSeekWeekView : QuotaReadingHost
{
    internal DeepSeekWeekView(DeepSeekWeekPresentation data)
    {
        AutomationProperties.SetAutomationId(this, "deepseek.week"); AutomationProperties.SetName(this, data.AccessibilityLabel);
        Children.Add(DeepSeekElements.Row(DeepSeekElements.Text(data.Title, 11, PacerPalette.Tertiary, FontWeights.SemiBold),
            DeepSeekElements.Text(data.LineText ?? "", 9, PacerPalette.Tertiary), gap: 8));
        Children.Add(new DeepSeekWeekPlot(data) { Height = 44, Margin = new Thickness(0, 6, 0, 0) });
        var labels = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var day in data.Days)
        {
            int index = labels.ColumnDefinitions.Count; labels.ColumnDefinitions.Add(new());
            var text = DeepSeekElements.Text(day.Label, 9, day.Today ? PacerPalette.Primary : PacerPalette.Tertiary, day.Today ? FontWeights.SemiBold : FontWeights.Normal);
            text.HorizontalAlignment = HorizontalAlignment.Center; Grid.SetColumn(text, index); labels.Children.Add(text);
        }
        Children.Add(labels);
    }
}
internal sealed class DeepSeekWeekPlot : FrameworkElement
{
    private readonly DeepSeekWeekPresentation data;
    internal DeepSeekWeekPlot(DeepSeekWeekPresentation value) => data = value;
    protected override Size MeasureOverride(Size available) => new(0, 44);
    protected override void OnRender(DrawingContext drawing)
    {
        drawing.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, ActualWidth, ActualHeight));
        double step = ActualWidth / Math.Max(1, data.Days.Count);
        for (int index = 0; index < data.Days.Count; index++)
        {
            var day = data.Days[index]; double within = day.WithinFraction * 44, over = day.OverFraction * 44, x = index * step + (step - 22) / 2;
            if (within >= .5) drawing.DrawRoundedRectangle(DeepSeekElements.Opacity(PacerPalette.DeepSeek, day.Today ? 1 : .5), null, new Rect(x, 44 - within, 22, within), 2, 2);
            if (over >= .5) drawing.DrawRoundedRectangle(DeepSeekElements.Opacity(PacerPalette.Danger, day.Today ? .95 : .6), null,
                new Rect(x, 44 - (within >= .5 ? within : 0) - over, 22, over), 2, 2);
        }
        if (data.LineFraction is double fraction) drawing.DrawLine(DeepSeekElements.Dashed(DeepSeekElements.Opacity(PacerPalette.Secondary, .7)),
            new Point(0, 44 * (1 - fraction)), new Point(ActualWidth, 44 * (1 - fraction)));
    }
}

internal sealed class DeepSeekBudgetDetails : StackPanel
{
    internal DeepSeekBudgetDetails(IReadOnlyList<DeepSeekBudgetPresentation> budgets, UiText ui)
    {
        AutomationProperties.SetAutomationId(this, "deepseek.budget.details");
        if (budgets.Count > 1)
        {
            foreach (var reading in budgets)
            {
                if (Children.Count > 0) Children.Add(new Border { Height = 1, Background = PacerPalette.Hairline, Margin = new Thickness(0, 9, 0, 9) });
                var period = new QuotaReadingHost(); AutomationProperties.SetName(period, reading.Help + "\n" + ui.Text("dashboard.pace") + " " + reading.PaceText);
                var title = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                title.Children.Add(DeepSeekElements.Text(reading.Label, 11, reading.Exceeded ? PacerPalette.Danger : reading.Pressing ? PacerPalette.Attention : PacerPalette.Secondary, FontWeights.SemiBold));
                if (reading.Exceeded || reading.Verdict != null) { var chip = Chip(reading, ui); chip.Margin = new Thickness(6, 0, 0, 0); title.Children.Add(chip); }
                var pace = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var caption = DeepSeekElements.Text(ui.Text("dashboard.pace"), 10, PacerPalette.Secondary); caption.Margin = new Thickness(0, 0, 4, 0); pace.Children.Add(caption);
                pace.Children.Add(DeepSeekElements.Text(reading.PaceText, 13, reading.Verdict == "fast" ? PacerPalette.Attention : PacerPalette.Primary, FontWeights.SemiBold));
                period.Children.Add(DeepSeekElements.Row(title, pace, 16));
                var footer = DeepSeekElements.Row(DeepSeekElements.Text(reading.ResetText, 10, PacerPalette.Tertiary),
                    DeepSeekElements.Text(reading.ProjectionText ?? "", 10, reading.ProjectionWarns ? PacerPalette.Attention : PacerPalette.Tertiary));
                footer.Margin = new Thickness(0, 4, 0, 0); period.Children.Add(footer); Children.Add(period);
            }
        }
        else if (budgets.Count == 1)
        {
            var reading = budgets[0]; var pace = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            if (reading.Exceeded || reading.Verdict != null) { var chip = Chip(reading, ui); chip.Margin = new Thickness(0, 0, 6, 0); pace.Children.Add(chip); }
            pace.Children.Add(DeepSeekElements.Text(reading.Exceeded ? reading.SpentText : reading.PaceText, 13,
                reading.Exceeded ? PacerPalette.Danger : reading.Verdict == "fast" ? PacerPalette.Attention : PacerPalette.Primary, FontWeights.SemiBold));
            Children.Add(DeepSeekElements.Row(DeepSeekElements.Text(reading.Exceeded ? reading.Label : ui.Text("dashboard.pace"), 11, PacerPalette.Secondary), pace, 26));
            Children.Add(new Border { Height = 1, Background = PacerPalette.Hairline });
            Children.Add(DeepSeekElements.Row(DeepSeekElements.Text(ui.Text("dashboard.reset"), 11, PacerPalette.Secondary), DeepSeekElements.Text(reading.ResetText, 11, PacerPalette.Primary, FontWeights.Medium), 26));
            Children.Add(new Border { Height = 1, Background = PacerPalette.Hairline });
            Children.Add(DeepSeekElements.Row(DeepSeekElements.Text(ui.Text(reading.Exceeded ? "deepseek.reminder_row" : "dashboard.projection"), 11, PacerPalette.Secondary),
                DeepSeekElements.Text(reading.Exceeded ? ui.Text("deepseek.remind_only") : reading.ProjectionText ?? "—", 11,
                    reading.Exceeded ? PacerPalette.Secondary : reading.ProjectionWarns ? PacerPalette.Attention : PacerPalette.Primary, reading.Exceeded ? FontWeights.Normal : FontWeights.Medium), 26));
        }
    }
    internal static Border Chip(DeepSeekBudgetPresentation reading, UiText ui) => new()
    {
        Height = 15, CornerRadius = new CornerRadius(7.5), Padding = new Thickness(5, 0, 5, 0),
        Background = reading.Exceeded ? PacerPalette.Danger : DeepSeekElements.Opacity(reading.Verdict == "fast" ? PacerPalette.Attention : reading.Verdict == "steady" ? PacerPalette.Secondary : PacerPalette.Primary, .14),
        Child = DeepSeekElements.Text(reading.Exceeded ? ui.Text("deepseek.over") : reading.VerdictText ?? "", 10,
            reading.Exceeded ? PacerPalette.Ink(0, 0, 0, 217) : reading.Verdict == "fast" ? PacerPalette.Attention : reading.Verdict == "steady" ? PacerPalette.Secondary : PacerPalette.Primary, FontWeights.SemiBold)
    };
}

internal sealed class DeepSeekBudgetDial : FrameworkElement
{
    private readonly IReadOnlyList<DeepSeekBudgetPresentation> budgets;
    private readonly UiText ui;
    private readonly double side;
    internal DeepSeekBudgetDial(IReadOnlyList<DeepSeekBudgetPresentation> values, UiText language, double size)
    {
        budgets = values; ui = language; side = size; Width = size; Height = size;
        AutomationProperties.SetName(this, string.Join("\n\n", budgets.Select(value => value.Label + " " + value.Whole + value.Cents + "\n" + value.Help)));
        AutomationProperties.SetAutomationId(this, "deepseek.budget.dial");
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new BudgetPeer(this);
    private sealed class BudgetPeer(DeepSeekBudgetDial owner) : FrameworkElementAutomationPeer(owner)
    { protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text; }
    protected override Size MeasureOverride(Size available) => new(side, side);
    protected override void OnRender(DrawingContext drawing)
    {
        double scale = side / 104;
        if (budgets.Count > 1)
        {
            Arc(drawing, budgets[0], 204, 132); Arc(drawing, budgets[1], 348, 204);
            double first = ValueHeight(budgets[0], 17 * scale), second = ValueHeight(budgets[1], 21 * scale), gap = 6 * scale, top = (side - first - second - gap) / 2;
            Value(drawing, budgets[0], 17 * scale, top, ui.Text("deepseek.ring.day")); Value(drawing, budgets[1], 21 * scale, top + first + gap, ui.Text("deepseek.ring.week"));
        }
        else if (budgets.Count == 1)
        {
            var reading = budgets[0]; Arc(drawing, reading, 125, 290);
            Value(drawing, reading, 23 * scale, (side - ValueHeight(reading, 23 * scale)) / 2 - 4 * scale, null);
            var label = Text(reading.Label, 10 * Math.Max(1, scale * .9), reading.Exceeded ? PacerPalette.Danger : reading.Pressing ? PacerPalette.Attention : PacerPalette.Secondary, true);
            drawing.DrawText(label, new Point((side - label.WidthIncludingTrailingWhitespace) / 2, side * .91 - label.Height / 2));
        }
    }
    private void Arc(DrawingContext drawing, DeepSeekBudgetPresentation reading, double start, double sweep)
    {
        double thickness = 6 * side / 104, radius = (side - thickness) / 2, centre = side / 2;
        var point = new Point(centre, centre);
        RingDrawing.Arc(drawing, point, radius, start, sweep, reading.Exceeded ? DeepSeekElements.Opacity(PacerPalette.Danger, .3) : PacerPalette.Hairline, thickness);
        if (reading.Fraction > 0) RingDrawing.Arc(drawing, point, radius, start, sweep * reading.Fraction,
            reading.Exceeded ? PacerPalette.Danger : reading.Kind == "day" && reading.Pressing ? PacerPalette.Attention : PacerPalette.DeepSeek, thickness);
        if (reading.TimeFraction is double fraction)
        {
            drawing.PushTransform(new RotateTransform(start + sweep * fraction + 90, centre, centre));
            drawing.DrawRoundedRectangle(Brushes.White, new Pen(PacerPalette.Ink(0, 0, 0, 115), .5),
                new Rect(centre - 1.25, centre - radius - (thickness + 6) / 2, 2.5, thickness + 6), 1.25, 1.25); drawing.Pop();
        }
    }
    private double ValueHeight(DeepSeekBudgetPresentation reading, double size) => Text(reading.Whole, size, PacerPalette.Primary, true).Height + 1 + Text(reading.Countdown, Math.Max(8.5, 9 * side / 104), PacerPalette.Tertiary).Height;
    private void Value(DrawingContext drawing, DeepSeekBudgetPresentation reading, double size, double top, string? period)
    {
        double scale = side / 104;
        var whole = Text(reading.Whole, size, reading.Exceeded ? PacerPalette.Danger : reading.Pressing ? PacerPalette.Attention : PacerPalette.Primary, true);
        var cents = Text(reading.Cents, size * .45, PacerPalette.Secondary, true);
        var label = Text(period ?? "", Math.Max(8, 9 * scale), reading.Pressing ? PacerPalette.Attention : PacerPalette.Tertiary);
        double gap = period == null ? 0 : 3, width = label.WidthIncludingTrailingWhitespace + gap + whole.WidthIncludingTrailingWhitespace + cents.WidthIncludingTrailingWhitespace;
        double shrink = Math.Max(.6, Math.Min(1, side * .74 / Math.Max(1, width))), baseline = whole.Baseline, x = 0;
        drawing.PushTransform(new TranslateTransform((side - width * shrink) / 2, top)); drawing.PushTransform(new ScaleTransform(shrink, shrink));
        if (period != null) { drawing.DrawText(label, new Point(x, baseline - label.Baseline)); x += label.WidthIncludingTrailingWhitespace + gap; }
        drawing.DrawText(whole, new Point(x, 0)); drawing.DrawText(cents, new Point(x + whole.WidthIncludingTrailingWhitespace, baseline - cents.Baseline)); drawing.Pop(); drawing.Pop();
        var countdown = Text(reading.Countdown, Math.Max(8.5, 9 * scale), PacerPalette.Tertiary);
        double fit = Math.Max(.8, Math.Min(1, side * .74 / Math.Max(1, countdown.WidthIncludingTrailingWhitespace)));
        drawing.PushTransform(new TranslateTransform((side - countdown.WidthIncludingTrailingWhitespace * fit) / 2, top + whole.Height * shrink + 1)); drawing.PushTransform(new ScaleTransform(fit, fit));
        drawing.DrawText(countdown, new Point()); drawing.Pop(); drawing.Pop();
    }
    private FormattedText Text(string value, double size, Brush ink, bool bold = false) => new(value, PacerFonts.Culture(this), FlowDirection.LeftToRight,
        new Typeface(PacerFonts.Interface, FontStyles.Normal, bold ? FontWeights.SemiBold : FontWeights.Medium, FontStretches.Normal), size, ink, VisualTreeHelper.GetDpi(this).PixelsPerDip);
}
