using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The original 88-point ring, caption and visible second-period summary.
/// Slot choice and all readings come from the common Swift projection.
internal sealed class ClassicQuotaCell : StackPanel
{
    internal QuotaDial Dial { get; }
    internal StackPanel Ring { get; }
    internal ClassicQuotaCell(DashboardSlot slot, DashboardProvider provider, EngineQuota? raw, EngineWallet? wallet)
    {
        var reading = slot.Period == "5h" ? provider.FiveHour : provider.Weekly;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        Ring = new QuotaReadingHost(); Children.Add(Ring);
        Dial = new QuotaDial(slot.Provider, raw, wallet, classic: true, dashboard: provider, classicPeriod: slot.Period)
            { Width = 88, Height = 88, HorizontalAlignment = HorizontalAlignment.Center };
        Ring.Children.Add(Dial);
        var caption = new StackPanel { Orientation = Orientation.Horizontal, Height = 15, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
        if (slot.IdentifiesProvider)
            caption.Children.Add(new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Fill = PacerPalette.Provider(slot.Provider), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 5, 0) });
        caption.Children.Add(Label(slot.Title, 11, slot.IdentifiesProvider ? PacerPalette.Primary : PacerPalette.Secondary, FontWeights.SemiBold));
        if (slot.IdentifiesProvider) caption.Children.Add(Label(slot.Period, 10, PacerPalette.Tertiary, margin: 5));
        if (reading.VerdictText != null) caption.Children.Add(Verdict(reading));
        if (reading.Availability == "stale")
        {
            var freshness = new IconGlyph { Symbol = "clock.arrow.circlepath", Width = 9, Height = 9, Ink = PacerPalette.Attention, Margin = new Thickness(5, 0, 0, 0) };
            caption.Children.Add(freshness);
        }
        Ring.Children.Add(caption);
        if (slot.IdentifiesProvider)
        {
            var other = slot.Period == "5h" ? provider.Weekly : provider.FiveHour;
            if (other.OtherPeriodText != null)
            {
                var summary = Label(other.OtherPeriodText, 10, other.Pressing ? PacerPalette.Attention : PacerPalette.Tertiary);
                summary.Margin = new Thickness(0, 6, 0, 0); summary.HorizontalAlignment = HorizontalAlignment.Center;
                summary.TextTrimming = TextTrimming.CharacterEllipsis;
                summary.Typography.NumeralAlignment = FontNumeralAlignment.Tabular;
                AutomationProperties.SetName(summary, other.AccessibilityLabel); Children.Add(summary);
            }
        }
        ToolTip = reading.ClassicHelp;
        AutomationProperties.SetName(Ring, reading.ClassicAccessibilityLabel);
        AutomationProperties.SetHelpText(Ring, reading.ClassicHelp);
    }
    private static TextBlock Label(string text, double size, Brush ink, FontWeight? weight = null, double margin = 0) => new()
    {
        Text = text, FontSize = size, Foreground = ink, FontWeight = weight ?? FontWeights.Medium,
        VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(margin, 0, 0, 0)
    };
    internal static Border Verdict(DashboardReading reading) => new()
    {
        CornerRadius = new CornerRadius(7.5), Height = 15, Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(5, 0, 0, 0),
        Background = reading.Verdict == "fast" ? PacerPalette.Ink(255, 189, 97, 36) : reading.Verdict == "steady" ? PacerPalette.Ink(158, 158, 158, 36) : PacerPalette.Ink(245, 245, 245, 36),
        Child = Label(reading.VerdictText ?? "", 10, reading.Verdict == "fast" ? PacerPalette.Attention : reading.Verdict == "steady" ? PacerPalette.Secondary : PacerPalette.Primary, FontWeights.SemiBold)
    };
}
