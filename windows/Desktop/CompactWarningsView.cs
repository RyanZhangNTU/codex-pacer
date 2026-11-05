using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The capsule is shared by the live header, vertical strip and settings
/// samples. Dimensions follow FiveHourAlertGlyph / DeepSeekAlertGlyph.
internal sealed class WarningMark : Border
{
    internal WarningMark(CompactWarningItem item)
    {
        Height = 13; MinWidth = item.Kind == "fiveHour" ? 0 : 13;
        Padding = new Thickness(3.5, 0, 3.5, 0); CornerRadius = new CornerRadius(6.5);
        VerticalAlignment = VerticalAlignment.Center;
        Brush tint = item.Provider == null ? PacerPalette.Attention : PacerPalette.Provider(item.Provider);
        Brush ink = item.Solid ? PacerPalette.Ink(0, 0, 0, 209) : tint;
        if (item.Label != null)
        {
            if (item.Solid) Background = tint;
            else { BorderBrush = tint; BorderThickness = new Thickness(1); Padding = new Thickness(2.5, 0, 2.5, 0); }
            Child = new TextBlock { Text = item.Label, FontFamily = PacerFonts.Interface, FontSize = 9, FontWeight = FontWeights.Bold,
                Foreground = ink, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Center };
        }
        else
        {
            if (item.Symbol == "flame.fill") { Background = tint; Child = new IconGlyph { Symbol = item.Symbol, Width = 7.5, Height = 9, Ink = ink, VerticalAlignment = VerticalAlignment.Center }; }
            else { Padding = new Thickness(0); MinWidth = 11; Child = new IconGlyph { Symbol = item.Symbol ?? "", Width = 11, Height = 11, Ink = tint, VerticalAlignment = VerticalAlignment.Center }; }
        }
        IsHitTestVisible = false;
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
    public CompactWarningsView() { Orientation = Orientation.Horizontal; Visibility = Visibility.Collapsed; }
    protected override AutomationPeer OnCreateAutomationPeer() => new WarningPeer(this);
    private sealed class WarningPeer(CompactWarningsView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }
    internal void Update(IReadOnlyList<CompactWarningItem>? value)
    {
        value ??= [];
        if (items.SequenceEqual(value)) return;
        items = value.ToArray(); Children.Clear();
        for (int index = 0; index < items.Count; index++)
        {
            var mark = new WarningMark(items[index]);
            if (index > 0) mark.Margin = Orientation == Orientation.Horizontal ? new Thickness(4, 0, 0, 0) : new Thickness(0, 4, 0, 0);
            Children.Add(mark);
        }
        Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        string summary = string.Join("\n", items.Select(item => item.Help));
        AutomationProperties.SetName(this, summary);
        AutomationProperties.SetHelpText(this, summary);
    }
}
