using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// The Expanded Panel page's sample task row: a DeepSeek task drawn as the
/// panel draws a row, showing only the details chosen and shrinking to one
/// line with the one-line style, so a choice shows its effect at once.
internal sealed class PanelRowPreview
{
    private readonly Border root = new() { CornerRadius = new CornerRadius(14), Padding = new Thickness(12, 10, 12, 10) };
    private readonly Grid icon = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly Ellipse track = new() { StrokeThickness = 2 }, center = new() { Width = 6, Height = 6 };
    private readonly Path arc = new() { StrokeThickness = 2.2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly TextBlock title = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock measures = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
    private readonly Run rate = new("48.2") { FontSize = 13, FontWeight = FontWeights.SemiBold }, unit = new(" t/s") { FontSize = 10, FontWeight = FontWeights.Medium },
        separator = new(" · ") { FontSize = 11, FontWeight = FontWeights.Medium }, time = new() { FontSize = 11, FontWeight = FontWeights.Medium };
    private readonly Grid secondLine = new() { Margin = new Thickness(0, 3, 0, 0) };
    private readonly TextBlock status = Small(""), agents = Small("2"), source = Small("devbox"), cost = Small("¥0.12"), model = Small("V4 Pro");
    private readonly IconGlyph agentsIcon = new() { Symbol = "person.2", Width = 10, Height = 10, Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Center },
        sourceIcon = new() { Symbol = "server.rack", Width = 10, Height = 10, Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel agentsGroup = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 0, 0, 0) },
        sourceGroup = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 0, 0, 0) };

    private readonly string turnTime;

    internal FrameworkElement Root => root;

    internal PanelRowPreview(UiText ui)
    {
        title.Text = ui.Text("panel.preview.title");
        status.Text = ui.Text("panel.preview.status");
        turnTime = ui.Text("dashboard.countdown_minutes").Replace("%d", "12", StringComparison.Ordinal);
        AutomationProperties.SetName(root, ui.Text("panel.preview.accessibility"));

        icon.Children.Add(track); icon.Children.Add(arc); icon.Children.Add(center);
        center.HorizontalAlignment = HorizontalAlignment.Center; center.VerticalAlignment = VerticalAlignment.Center;
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(icon);
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(lines, 2); row.Children.Add(lines);
        var firstLine = new Grid(); firstLine.ColumnDefinitions.Add(new ColumnDefinition()); firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        firstLine.Children.Add(title);
        measures.Inlines.Add(rate); measures.Inlines.Add(unit); measures.Inlines.Add(separator); measures.Inlines.Add(time);
        Grid.SetColumn(measures, 1); firstLine.Children.Add(measures);
        lines.Children.Add(firstLine);
        secondLine.ColumnDefinitions.Add(new ColumnDefinition()); secondLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var details = new StackPanel { Orientation = Orientation.Horizontal, ClipToBounds = true };
        details.Children.Add(status);
        agentsGroup.Children.Add(agentsIcon); agentsGroup.Children.Add(agents); details.Children.Add(agentsGroup);
        sourceGroup.Children.Add(sourceIcon); sourceGroup.Children.Add(source); details.Children.Add(sourceGroup);
        secondLine.Children.Add(details);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 0, 0, 0) };
        cost.Margin = new Thickness(0, 0, 6, 0); trailing.Children.Add(cost); trailing.Children.Add(model);
        Grid.SetColumn(trailing, 1); secondLine.Children.Add(trailing);
        lines.Children.Add(secondLine);
        root.Child = row;
    }

    private static TextBlock Small(string text) => new() { Text = text, FontSize = 11, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };

    /// Shows the details the options keep, in the island's current colors.
    internal void Update(PanelOptions options)
    {
        bool oneLine = options.OneLine;
        root.Background = PacerPalette.Light ? PacerPalette.Ink(242, 242, 245) : new SolidColorBrush(Color.FromRgb(36, 36, 40));
        root.BorderBrush = PacerPalette.Overlay(15); root.BorderThickness = new Thickness(1);
        root.Padding = oneLine ? new Thickness(12, 8, 12, 8) : new Thickness(12, 10, 12, 10);
        double size = oneLine ? 22 : 28;
        icon.Width = icon.Height = size;
        Brush tint = PacerPalette.DeepSeek;
        track.Stroke = tint; track.Opacity = 0.28; center.Fill = tint; arc.Stroke = tint;
        double radius = size / 2 - 1.1, middle = size / 2, end = 18 * Math.PI / 180;
        var figure = new PathFigure { StartPoint = new Point(middle, middle - radius) };
        figure.Segments.Add(new ArcSegment(new Point(middle + radius * Math.Cos(end), middle + radius * Math.Sin(end)), new Size(radius, radius), 0, false, SweepDirection.Clockwise, true));
        arc.Data = new PathGeometry([figure]);
        track.Margin = new Thickness(1);

        title.Foreground = PacerPalette.Primary; rate.Foreground = PacerPalette.Primary;
        unit.Foreground = separator.Foreground = PacerPalette.Tertiary; time.Foreground = PacerPalette.Secondary;
        foreach (var part in new[] { status, agents, source }) part.Foreground = PacerPalette.Secondary;
        agentsIcon.Ink = sourceIcon.Ink = PacerPalette.Secondary;
        cost.Foreground = PacerPalette.Primary; cost.Opacity = 0.85; model.Foreground = tint;

        bool showsRate = options.Shows("rate"), showsTime = options.Shows("turnTime");
        rate.Text = showsRate ? "48.2" : ""; unit.Text = showsRate ? " t/s" : "";
        separator.Text = showsRate && showsTime ? " · " : ""; time.Text = showsTime ? turnTime : "";
        measures.Visibility = showsRate || showsTime ? Visibility.Visible : Visibility.Collapsed;
        secondLine.Visibility = oneLine ? Visibility.Collapsed : Visibility.Visible;
        agentsGroup.Visibility = Show(options.Shows("subagents")); sourceGroup.Visibility = Show(options.Shows("source"));
        cost.Visibility = Show(options.Shows("cost")); model.Visibility = Show(options.Shows("model"));
    }

    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
}
