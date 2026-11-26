using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace CodexPacer.Windows;

/// Tags and a title on the left, readings on the right, as the Mac's
/// TaskLineLayout. When the line is narrow the title shrinks first, down to
/// <see cref="TitleMinimum"/>, while the tags and readings stay whole; past that
/// the readings drop the model, then the time, and the speed stays. Each
/// reading variant is its own child, fullest first; only the chosen one shows,
/// so choosing never edits text during layout.
internal sealed class TaskLinePanel : Panel
{
    internal const double TitleMinimum = 48, Gap = 8, TagGap = 4;
    private readonly FrameworkElement? tags;
    private readonly FrameworkElement title;
    private readonly IReadOnlyList<FrameworkElement> readings;
    /// The reading variant shown: 0 is the fullest.
    internal int Chosen { get; private set; }
    internal FrameworkElement ShownReadings => readings[Chosen];
    /// How many reading variants the line has: only those that read differently.
    internal int VariantCount => readings.Count;
    internal FrameworkElement Title => title;

    internal TaskLinePanel(FrameworkElement? tags, FrameworkElement title, IReadOnlyList<FrameworkElement> readings)
    {
        if (readings.Count == 0) throw new ArgumentException("A line needs its readings.", nameof(readings));
        this.tags = tags; this.title = title; this.readings = readings;
        if (tags != null) Children.Add(tags);
        Children.Add(title);
        foreach (var value in readings) Children.Add(value);
    }

    private double TagsWidth => tags is { DesiredSize.Width: > 0 } ? tags.DesiredSize.Width + TagGap : 0;
    private double ReadingsWidth(int index) => readings[index].DesiredSize.Width;
    private double GapBefore(int index) => ReadingsWidth(index) > 0 ? Gap : 0;

    /// The first variant whose readings fit beside the tags and the shortest title.
    internal static int Choose(double width, double tags, double title, IReadOnlyList<double> readings)
    {
        double least = tags + Math.Min(TitleMinimum, title);
        for (int index = 0; index < readings.Count; index++)
            if (least + (readings[index] > 0 ? Gap : 0) + readings[index] <= width + 0.5) return index;
        return readings.Count - 1;
    }

    protected override Size MeasureOverride(Size available)
    {
        var open = new Size(double.PositiveInfinity, available.Height);
        tags?.Measure(open); title.Measure(open);
        foreach (var value in readings) value.Measure(open);
        double tagsWidth = TagsWidth, titleWidth = title.DesiredSize.Width, width;
        if (double.IsInfinity(available.Width)) { Chosen = 0; width = tagsWidth + titleWidth + GapBefore(0) + ReadingsWidth(0); }
        else
        {
            Chosen = Choose(available.Width, tagsWidth, titleWidth, readings.Select(value => value.DesiredSize.Width).ToArray());
            width = available.Width;
        }
        title.Measure(new Size(Math.Max(0, width - tagsWidth - GapBefore(Chosen) - ReadingsWidth(Chosen)), available.Height));
        double height = Math.Max(title.DesiredSize.Height, Math.Max(tags?.DesiredSize.Height ?? 0, readings.Max(value => value.DesiredSize.Height)));
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double Top(FrameworkElement value) => Math.Max(0, (final.Height - value.DesiredSize.Height) / 2);
        double x = 0;
        if (tags != null) { tags.Arrange(new Rect(0, Top(tags), tags.DesiredSize.Width, tags.DesiredSize.Height)); x = TagsWidth; }
        double readingsWidth = ReadingsWidth(Chosen);
        double titleWidth = Math.Max(0, final.Width - x - GapBefore(Chosen) - readingsWidth);
        title.Arrange(new Rect(x, Top(title), titleWidth, title.DesiredSize.Height));
        for (int index = 0; index < readings.Count; index++)
        {
            var value = readings[index];
            bool shown = index == Chosen;
            // Opacity and hit testing change only what draws, never the measured layout.
            value.Opacity = shown ? 1 : 0; value.IsHitTestVisible = shown;
            double width = shown ? readingsWidth : 0;
            value.Arrange(new Rect(Math.Max(0, final.Width - width), Top(value), width, value.DesiredSize.Height));
        }
        return final;
    }
}
