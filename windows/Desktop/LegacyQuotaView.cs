using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The original Codex-only multi-bucket bars, including nonstandard windows.
internal sealed class LegacyQuotaView : StackPanel
{
    internal LegacyQuotaView(LegacyQuotaDashboard data, UiText ui, string? help = null, FrameworkElement? status = null)
    {
        string details = string.Join("\n\n", new[] { data.Help, help }.Where(value => !string.IsNullOrWhiteSpace(value)));
        Margin = new Thickness(9, 0, 9, 0); AutomationProperties.SetHelpText(this, details);
        if (!data.Fresh)
        {
            var freshness = new StackPanel { Orientation = Orientation.Horizontal, Height = 15 };
            freshness.Children.Add(new IconGlyph { Symbol = "clock.arrow.circlepath", Ink = PacerPalette.Attention, Width = 11, Height = 11, Margin = new Thickness(0, 0, 5, 0) });
            freshness.Children.Add(Label(ui.Text("common.not_updated"), 11, PacerPalette.Attention, FontWeights.Medium));
            Children.Add(freshness);
        }
        foreach (var bucket in data.Buckets)
        {
            var group = new StackPanel { Margin = new Thickness(0, Children.Count > 0 ? 16 : 0, 0, 0) };
            if (bucket.Title != null) group.Children.Add(Label(bucket.Title, 11, PacerPalette.Secondary, FontWeights.SemiBold));
            foreach (var window in bucket.Windows)
            {
                var reading = new QuotaReadingHost { Margin = new Thickness(0, group.Children.Count > 0 ? 14 : 0, 0, 0) };
                reading.Children.Add(new LegacyQuotaHeading(window));
                reading.Children.Add(new LegacyQuotaTrack(window, data.Fresh ? PacerPalette.Codex : PacerPalette.Secondary)
                    { Margin = new Thickness(0, 8, 0, 0) });
                var footer = new Grid { Margin = new Thickness(0, 8, 0, 0) };
                footer.ColumnDefinitions.Add(new()); footer.ColumnDefinitions.Add(new() { Width = new GridLength(8) }); footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                var reset = Label(window.Countdown, 11, PacerPalette.Secondary); footer.Children.Add(reset);
                Brush ink = window.PacePercent is < 85 ? PacerPalette.LegacyPace : window.PacePercent is > 115 ? PacerPalette.Codex : PacerPalette.Secondary;
                var pace = Label(window.PaceText, 11, ink); Grid.SetColumn(pace, 2); footer.Children.Add(pace); reading.Children.Add(footer);
                AutomationProperties.SetName(reading, window.AccessibilityLabel);
                AutomationProperties.SetHelpText(reading, window.ResetDate + "\n" + ui.Text("quota.track_help"));
                group.Children.Add(reading);
            }
            Children.Add(group);
        }
        // The original provider-status view occupies a final stack slot even
        // when a connected provider has no message or action to show.
        status ??= new Border { Height = 0 };
        status.Margin = new Thickness(0, 16, 0, 0); Children.Add(status);
        AutomationProperties.SetHelpText(this, details);
    }
    private static TextBlock Label(string text, double size, Brush ink, FontWeight? weight = null)
    {
        var label = new TextBlock { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, Foreground = ink, TextTrimming = TextTrimming.CharacterEllipsis };
        label.Typography.NumeralAlignment = FontNumeralAlignment.Tabular; return label;
    }
}

internal sealed class LegacyQuotaTrack(LegacyQuotaWindow reading, Brush accent) : FrameworkElement
{
    internal static readonly DependencyProperty ReferenceProperty = DependencyProperty.Register(nameof(Reference), typeof(Brush), typeof(LegacyQuotaTrack), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    internal Brush? Reference { get => (Brush?)GetValue(ReferenceProperty); set => SetValue(ReferenceProperty, value); }
    protected override Size MeasureOverride(Size availableSize) => new(double.IsFinite(availableSize.Width) ? availableSize.Width : 0, 12);
    protected override void OnRender(DrawingContext drawing)
    {
        drawing.DrawRoundedRectangle(Reference == null ? PacerPalette.Hairline : QuotaHistoryChart.WithOpacity(Reference, 0.08), null, new Rect(0, 3, ActualWidth, 6), 3, 3);
        if (reading.RemainingPercent is double remaining)
            drawing.DrawRoundedRectangle(accent, null, new Rect(0, 3, ActualWidth * Math.Clamp(remaining / 100, 0, 1), 6), 3, 3);
        if (reading.RemainingTimePercent is double time)
        {
            double x = Math.Max(0, Math.Min(Math.Max(0, ActualWidth - 2), ActualWidth * Math.Clamp(time / 100, 0, 1) - 1));
            drawing.DrawRoundedRectangle(Reference == null ? PacerPalette.Ink(255, 255, 255, 166) : QuotaHistoryChart.WithOpacity(Reference, 0.65), null, new Rect(x, 0.5, 2, 11), 1, 1);
        }
    }
}

internal sealed class LegacyQuotaHeading(LegacyQuotaWindow reading) : FrameworkElement
{
    internal static readonly DependencyProperty PrimaryProperty = DependencyProperty.Register(nameof(Primary), typeof(Brush), typeof(LegacyQuotaHeading), new FrameworkPropertyMetadata(PacerPalette.Primary, FrameworkPropertyMetadataOptions.AffectsRender));
    internal static readonly DependencyProperty SecondaryProperty = DependencyProperty.Register(nameof(Secondary), typeof(Brush), typeof(LegacyQuotaHeading), new FrameworkPropertyMetadata(PacerPalette.Secondary, FrameworkPropertyMetadataOptions.AffectsRender));
    internal Brush Primary { get => (Brush)GetValue(PrimaryProperty); set => SetValue(PrimaryProperty, value); }
    internal Brush Secondary { get => (Brush)GetValue(SecondaryProperty); set => SetValue(SecondaryProperty, value); }
    private readonly Typeface face = new(PacerFonts.Interface, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    internal Typeface FontFace => face;
    private FormattedText Text(string text, double size, Brush ink) => new(text, PacerFonts.Culture(this),
        FlowDirection.LeftToRight, face, size, ink, VisualTreeHelper.GetDpi(this).PixelsPerDip);
    protected override Size MeasureOverride(Size availableSize) => new(0, Text(reading.ValueText, 24, PacerPalette.Primary).Height);
    protected override void OnRender(DrawingContext drawing)
    {
        bool known = reading.RemainingPercent != null;
        var label = Text(reading.Label, 12, Secondary);
        var number = Text(reading.ValueText, 24, known ? Primary : Secondary);
        var unit = Text(known ? "%" : "", 12, Secondary);
        double x = ActualWidth - number.WidthIncludingTrailingWhitespace - (known ? 1 + unit.WidthIncludingTrailingWhitespace : 0);
        drawing.DrawText(label, new Point(0, number.Baseline - label.Baseline));
        drawing.DrawText(number, new Point(Math.Max(0, x), 0));
        if (known) drawing.DrawText(unit, new Point(x + number.WidthIncludingTrailingWhitespace + 1, number.Baseline - unit.Baseline));
    }
}
