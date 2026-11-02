using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexPacer.Windows;

/// <summary>Uses the original four-second slots and 350 ms crossfade key times.</summary>
public sealed class AlternatingQuotaText : Grid
{
    private readonly List<TextBlock> layers = [];
    private bool animates = true;
    public double FontSize { get; set; } = 12;
    public FontFamily FontFamily { get; set; } = PacerFonts.Interface;
    internal double MaximumDisplayWidth { get; set; } = double.PositiveInfinity;
    public AlternatingQuotaText()
    {
        IsHitTestVisible = false;
        IsVisibleChanged += (_, _) => Refresh();
        Unloaded += (_, _) => Stop();
    }
    internal void Update(IReadOnlyList<(string Provider, string Text)> entries, bool animate, IReadOnlyList<bool>? dimmed = null)
    {
        bool restart = layers.Count != entries.Count || animate != animates;
        if (restart) Stop();
        if (layers.Count != entries.Count)
        {
            Children.Clear(); layers.Clear();
            foreach (var _ in entries)
            {
                var text = new TextBlock { TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Stretch,
                    FontFamily = FontFamily, FontSize = FontSize, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
                Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);
                layers.Add(text); Children.Add(text);
            }
        }
        animates = animate;
        AutomationProperties.SetName(this, string.Join(", ", entries.Select(entry => entry.Provider + " " + entry.Text)));
        UIElementAutomationPeer.FromElement(this)?.InvalidatePeer();
        double width = 0, height = 0;
        for (int index = 0; index < entries.Count; index++)
        {
            var text = layers[index];
            text.Text = entries[index].Text; text.Foreground = PacerPalette.Provider(entries[index].Provider);
            if (dimmed?.ElementAtOrDefault(index) == true) { var ink = text.Foreground.Clone(); ink.Opacity = .45; ink.Freeze(); text.Foreground = ink; }
            // A live label can be measured while its ancestor is clipped or
            // hidden. Probe an unattached copy, as the original fixed-size view does.
            var probe = new TextBlock { Text = text.Text, FontFamily = FontFamily, FontSize = FontSize, FontWeight = FontWeights.SemiBold };
            Typography.SetNumeralAlignment(probe, FontNumeralAlignment.Tabular);
            probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double advance = NativeTypography.CompactWidth(text.Text, FontSize) ?? probe.DesiredSize.Width;
            double scale = Math.Max(.7, Math.Min(1, MaximumDisplayWidth / Math.Max(1, Math.Max(advance, probe.DesiredSize.Width))));
            text.FontSize = FontSize * scale; text.TextTrimming = TextTrimming.CharacterEllipsis;
            width = Math.Max(width, Math.Max(advance, probe.DesiredSize.Width)); height = Math.Max(height, probe.DesiredSize.Height);
        }
        Width = Math.Min(MaximumDisplayWidth, Math.Ceiling(width)); Height = Math.Ceiling(height);
        if (restart || layers.All(text => !text.HasAnimatedProperties)) Refresh();
    }
    internal void Stop()
    {
        for (int index = 0; index < layers.Count; index++)
        {
            layers[index].BeginAnimation(OpacityProperty, null);
            layers[index].Opacity = index == 0 ? 1 : 0;
        }
    }
    private void Refresh()
    {
        if (!IsVisible || !animates || layers.Count < 2) { Stop(); return; }
        if (layers[0].HasAnimatedProperties) return;
        double total = layers.Count * 4.0;
        for (int index = 0; index < layers.Count; index++)
        {
            double start = index * 4, end = start + 4;
            double[] times, values;
            if (index == 0) { times = [0, end - 0.35, end, total - 0.35, total]; values = [1, 1, 0, 0, 1]; }
            else if (index == layers.Count - 1) { times = [0, start - 0.35, start, total - 0.35, total]; values = [0, 0, 1, 1, 0]; }
            else { times = [0, start - 0.35, start, end - 0.35, end, total]; values = [0, 0, 1, 1, 0, 0]; }
            var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(total), RepeatBehavior = RepeatBehavior.Forever };
            for (int key = 0; key < times.Length; key++) animation.KeyFrames.Add(new LinearDoubleKeyFrame(values[key], KeyTime.FromTimeSpan(TimeSpan.FromSeconds(times[key]))));
            Timeline.SetDesiredFrameRate(animation, 30);
            layers[index].BeginAnimation(OpacityProperty, animation);
        }
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new ValuePeer(this);
    private sealed class ValuePeer(AlternatingQuotaText owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => "PacerQuotaValues";
        protected override List<AutomationPeer>? GetChildrenCore() => [];
    }
}
