using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexPacer.Windows;

/// One mark of the collapsed bar's single capsule family, shared by the live
/// header, the vertical strip and settings samples. An outline asks to be
/// noticed, a solid fill asks to act; the colour says where it comes from.
internal sealed class WarningMark : Border
{
    internal WarningMark(CompactWarningItem item, double height = 15, bool dot = false)
    {
        double scale = height / 15;
        VerticalAlignment = VerticalAlignment.Center; HorizontalAlignment = HorizontalAlignment.Center; IsHitTestVisible = false;
        Brush tint = item.Provider == null ? PacerPalette.Attention : PacerPalette.Provider(item.Provider);
        Brush ink = item.Solid ? PacerPalette.Ink(0, 0, 0, 209) : tint;
        if (dot)
        {
            Width = Height = Math.Round(7 * scale * 2) / 2; CornerRadius = new CornerRadius(Width / 2);
            if (item.Solid) Background = tint; else { BorderBrush = tint; BorderThickness = new Thickness(1.2 * scale); }
            return;
        }
        Height = height; MinWidth = height; CornerRadius = new CornerRadius(height / 2);
        Padding = new Thickness(4 * scale, 0, 4 * scale, 0);
        if (item.Solid) Background = tint; else { BorderBrush = tint; BorderThickness = new Thickness(1.2 * scale); Padding = new Thickness(2.8 * scale, 0, 2.8 * scale, 0); }
        if (item.Label != null)
            Child = new TextBlock { Text = item.Label, FontFamily = PacerFonts.Interface, FontSize = (item.Label == "¥" ? 9.5 : 9) * scale, FontWeight = FontWeights.Bold,
                Foreground = ink, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        else Child = new IconGlyph { Symbol = item.Symbol ?? "", Width = 9 * scale, Height = 9 * scale, Ink = ink, VerticalAlignment = VerticalAlignment.Center };
    }
    /// The mark that stands for warnings past the limit.
    internal static Border More(int count, double height, bool dot)
    {
        double scale = height / 15;
        var ink = CompactInk.Unit;
        return new Border { Height = dot ? Math.Round(7 * scale * 2) / 2 : height, MinWidth = dot ? 0 : height, CornerRadius = new CornerRadius(height / 2),
            BorderBrush = ink, BorderThickness = new Thickness(dot ? 0 : 1.2 * scale), Padding = new Thickness(dot ? 0 : 3 * scale, 0, dot ? 0 : 3 * scale, 0),
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, IsHitTestVisible = false,
            Child = new TextBlock { Text = "+" + count, FontFamily = PacerFonts.Interface, FontSize = (dot ? 8.5 : 8.5) * scale, FontWeight = FontWeights.Bold,
                Foreground = ink, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Center } };
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new DecorativePeer(this);
    private sealed class DecorativePeer(WarningMark owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override bool IsControlElementCore() => false;
        protected override bool IsContentElementCore() => false;
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }
}

public sealed class CompactWarningsView : StackPanel
{
    private IReadOnlyList<CompactWarningItem> items = [];
    private (string Style, int Limit, double Height) shape = ("capsule", 2, 15);
    private readonly List<AnimationLease> pops = [];
    /// Marks drawn now and how many folded into "+N"; read by the presentation checks.
    internal (int Shown, int Hidden, string Style) Drawn { get; private set; }
    public CompactWarningsView() { Orientation = Orientation.Horizontal; Visibility = Visibility.Collapsed; Unloaded += (_, _) => StopPops(); }
    protected override AutomationPeer OnCreateAutomationPeer() => new WarningPeer(this);
    private sealed class WarningPeer(CompactWarningsView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }
    /// Builds the marks again on the next update, in the island's current tone.
    internal void Repaint() => items = [];
    /// Marks that need the user lead, as Core orders them; past `limit` the
    /// rest fold into one "+N" mark, and a limit of zero shows them all.
    internal void Update(IReadOnlyList<CompactWarningItem>? value, string style = "capsule", int limit = 0, double height = 15, bool animate = false)
    {
        value ??= [];
        var nextShape = (style == "dot" ? "dot" : "capsule", Math.Max(0, limit), height);
        if (items.SequenceEqual(value) && shape == nextShape) return;
        var before = items;
        items = value.ToArray(); shape = nextShape; Children.Clear(); StopPops();
        bool dot = shape.Item1 == "dot";
        var ordered = items.Where(item => item.Solid).Concat(items.Where(item => !item.Solid)).ToArray();
        int shown = shape.Item2 > 0 ? Math.Min(shape.Item2, ordered.Length) : ordered.Length, hidden = ordered.Length - shown;
        double gap = (dot ? 3 : 4) * height / 15;
        for (int index = 0; index < shown; index++)
        {
            var mark = new WarningMark(ordered[index], height, dot);
            if (index > 0) mark.Margin = Orientation == Orientation.Horizontal ? new Thickness(gap, 0, 0, 0) : new Thickness(0, gap, 0, 0);
            Children.Add(mark);
            // A new mark pops in from 60%; a mark turning solid bounces once.
            var old = before.FirstOrDefault(item => item.Kind == ordered[index].Kind && item.Provider == ordered[index].Provider);
            if (animate && (old == null || !old.Solid && ordered[index].Solid)) Pop(mark, old == null ? 0.6 : 0.85);
        }
        if (hidden > 0)
        {
            var more = WarningMark.More(hidden, height, dot);
            more.Margin = Orientation == Orientation.Horizontal ? new Thickness(gap, 0, 0, 0) : new Thickness(0, gap, 0, 0);
            Children.Add(more);
        }
        Drawn = (shown, hidden, shape.Item1);
        Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        string summary = string.Join("\n", items.Select(item => item.Help));
        AutomationProperties.SetName(this, summary);
        AutomationProperties.SetHelpText(this, summary);
    }
    private void Pop(FrameworkElement mark, double from)
    {
        var scale = new ScaleTransform(from, from); mark.RenderTransform = scale; mark.RenderTransformOrigin = new Point(0.5, 0.5);
        var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.5 };
        pops.Add(new(new DoubleAnimation(from, 1, TimeSpan.FromSeconds(0.3)) { EasingFunction = ease }, clock => scale.ApplyAnimationClock(ScaleTransform.ScaleXProperty, clock)));
        pops.Add(new(new DoubleAnimation(from, 1, TimeSpan.FromSeconds(0.3)) { EasingFunction = ease }, clock => scale.ApplyAnimationClock(ScaleTransform.ScaleYProperty, clock),
            () => { scale.BeginAnimation(ScaleTransform.ScaleXProperty, null); scale.BeginAnimation(ScaleTransform.ScaleYProperty, null); scale.ScaleX = scale.ScaleY = 1; }));
    }
    private void StopPops() { foreach (var pop in pops) pop.Dispose(); pops.Clear(); }
}
