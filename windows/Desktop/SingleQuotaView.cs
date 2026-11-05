using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// One provider keeps the original left ring and right-hand period details.
internal sealed class SingleQuotaView : Grid
{
    internal QuotaDial Dial { get; }
    internal SingleQuotaView(DashboardProvider provider, EngineQuota? raw, UiText ui, string? help = null, FrameworkElement? status = null)
    {
        Margin = new Thickness(9, 0, 9, 0);
        RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto });
        ColumnDefinitions.Add(new() { Width = new GridLength(104) });
        ColumnDefinitions.Add(new() { Width = new GridLength(20) });
        ColumnDefinitions.Add(new());
        Dial = new QuotaDial(provider.Provider, raw, null, dashboard: provider) { Width = 104, Height = 104, VerticalAlignment = VerticalAlignment.Center };
        Children.Add(Dial);
        AutomationProperties.SetHelpText(this, string.Join("\n\n", new[] { Dial.Split ? provider.FiveHour.SplitHelp : null, provider.Weekly.SplitHelp,
            provider.Weekly.SourceText, help }.Where(value => !string.IsNullOrWhiteSpace(value))));
        var details = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        if (Dial.Split)
        {
            details.Children.Add(Period(provider.FiveHour, ui));
            details.Children.Add(Separator(new Thickness(0, 9, 0, 9)));
            details.Children.Add(Period(provider.Weekly, ui));
        }
        else
        {
            var weekly = provider.Weekly;
            var pace = Pace(weekly, false, ui);
            if (weekly.Availability == "stale") pace.Children.Insert(0, Freshness());
            else if (weekly.VerdictText != null)
            {
                var verdict = ClassicQuotaCell.Verdict(weekly); verdict.Margin = new Thickness(0, 0, 6, 0); pace.Children.Insert(0, verdict);
            }
            details.Children.Add(Row(Text(ui.Text("dashboard.pace"), 11, PacerPalette.Secondary), pace, 26));
            details.Children.Add(Separator());
            details.Children.Add(Row(Text(ui.Text("dashboard.reset"), 11, PacerPalette.Secondary), Text(weekly.ResetMoment ?? "—", 11, PacerPalette.Primary), 26));
            details.Children.Add(Separator());
            Brush ink = weekly.ProjectionWarns ? PacerPalette.Attention : weekly.ProjectionText == null || weekly.ProjectionEarly ? PacerPalette.Tertiary : PacerPalette.Primary;
            details.Children.Add(Row(Text(ui.Text("dashboard.projection"), 11, PacerPalette.Secondary), Text(weekly.ProjectionText ?? "—", 11, ink), 26));
        }
        Grid.SetColumn(details, 2); Children.Add(details);
        status ??= new Border { Height = 0 };
        status.Margin = new Thickness(0, 6, 0, 0); Grid.SetRow(status, 1); Grid.SetColumnSpan(status, 3); Children.Add(status);
    }
    private static StackPanel Period(DashboardReading reading, UiText ui)
    {
        var group = new StackPanel();
        var title = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(Text(reading.Period, 11, reading.Pressing ? PacerPalette.Attention : PacerPalette.Secondary, true));
        if (reading.Availability == "stale") title.Children.Add(Freshness());
        else if (reading.VerdictText != null) title.Children.Add(ClassicQuotaCell.Verdict(reading));
        group.Children.Add(Row(title, Pace(reading, true, ui), 16));
        var reset = Text(reading.ResetAtText ?? ui.Text("quota.reset_unknown"), 10, PacerPalette.Tertiary);
        var projection = Text(reading.ProjectionInline ?? "", 10, reading.ProjectionWarns ? PacerPalette.Attention : PacerPalette.Tertiary);
        var footer = Row(reset, projection, 12); footer.Margin = new Thickness(0, 4, 0, 0); group.Children.Add(footer);
        AutomationProperties.SetHelpText(group, reading.SplitHelp); return group;
    }
    private static StackPanel Pace(DashboardReading reading, bool showsLabel, UiText ui)
    {
        var value = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (showsLabel) { var label = Text(ui.Text("dashboard.pace"), 10, PacerPalette.Secondary); label.Margin = new Thickness(0, 0, 4, 0); value.Children.Add(label); }
        value.Children.Add(Text(reading.PaceText, 13, reading.Verdict == "fast" ? PacerPalette.Attention : PacerPalette.Primary, true));
        return value;
    }
    private static Grid Row(UIElement left, UIElement right, double height)
    {
        var row = new Grid { Height = height };
        row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = new GridLength(6) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(left); Grid.SetColumn(right, 2); row.Children.Add(right); return row;
    }
    private static IconGlyph Freshness() => new() { Symbol = "clock.arrow.circlepath", Ink = PacerPalette.Attention, Width = 9, Height = 9, Margin = new Thickness(5, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
    private static Border Separator(Thickness margin = default) => new() { Height = 1, Background = PacerPalette.Hairline, Margin = margin };
    private static TextBlock Text(string text, double size, Brush ink, bool bold = false)
    {
        var value = new TextBlock { Text = text, FontSize = size, Foreground = ink, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        value.Typography.NumeralAlignment = FontNumeralAlignment.Tabular; return value;
    }
}
