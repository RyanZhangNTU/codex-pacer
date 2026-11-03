using System;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// <summary>Uses the original four-second slots and 350 ms crossfade key times.</summary>
public sealed class AlternatingQuotaText : Grid
{
    private readonly List<TextBlock> layers = [];
    private bool animates = true;
    private readonly DispatcherTimer wake = new(DispatcherPriority.Background);
    private readonly List<AnimationLease> fades = [];
    private Stopwatch? cycle;
    private (string Provider, string Text)[] lastEntries = [];
    private bool[] lastDimmed = [];
    private double lastSize, lastMaximum;
    private string? lastFamily;
    private long wakeups;
    internal (bool Scheduled, int Clocks, long Wakes) Scheduling => (wake.IsEnabled, fades.Count, wakeups);
    public double FontSize { get; set; } = 12;
    public FontFamily FontFamily { get; set; } = PacerFonts.Interface;
    internal double MaximumDisplayWidth { get; set; } = double.PositiveInfinity;
    public AlternatingQuotaText()
    {
        IsHitTestVisible = false;
        wake.Tick += (_, _) => { wake.Stop(); wakeups++; Step(); };
        IsVisibleChanged += (_, _) => Refresh();
        Unloaded += (_, _) => Stop();
    }
    internal void Update(IReadOnlyList<(string Provider, string Text)> entries, bool animate, IReadOnlyList<bool>? dimmed = null)
    {
        bool[] dims = entries.Select((_, index) => dimmed?.ElementAtOrDefault(index) == true).ToArray();
        if (lastEntries.SequenceEqual(entries) && lastDimmed.SequenceEqual(dims) && animate == animates
            && FontSize == lastSize && MaximumDisplayWidth == lastMaximum && FontFamily.Source == lastFamily) return;
        bool restart = layers.Count != entries.Count || animate != animates
            || !lastEntries.Select(value => value.Provider).SequenceEqual(entries.Select(value => value.Provider));
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
        lastEntries = entries.ToArray(); lastDimmed = dims; lastSize = FontSize; lastMaximum = MaximumDisplayWidth; lastFamily = FontFamily.Source;
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
        if (restart || cycle == null) Refresh();
    }
    internal void Stop()
    {
        wake.Stop(); cycle = null; ClearFades();
        for (int index = 0; index < layers.Count; index++)
        {
            layers[index].BeginAnimation(OpacityProperty, null);
            layers[index].Opacity = index == 0 ? 1 : 0;
        }
    }
    private void Refresh()
    {
        if (!IsVisible || !animates || layers.Count < 2) { Stop(); return; }
        if (cycle != null) return;
        cycle = Stopwatch.StartNew(); Step();
    }
    private void ClearFades()
    {
        foreach (var fade in fades.ToArray()) fade.Dispose(); fades.Clear();
    }
    private void Step()
    {
        if (cycle == null || !IsVisible || !animates || layers.Count < 2) { Stop(); return; }
        ClearFades();
        double elapsed = cycle.Elapsed.TotalSeconds;
        var frame = QuotaAlternationSchedule.At(elapsed, layers.Count);
        if (frame.FadeRemaining <= 0)
        {
            for (int index = 0; index < layers.Count; index++) layers[index].Opacity = index == frame.Current ? 1 : 0;
            wake.Interval = TimeSpan.FromSeconds(Math.Max(.001, frame.NextFade - elapsed)); wake.Start(); return;
        }
        for (int index = 0; index < layers.Count; index++)
        {
            var text = layers[index];
            bool incoming = index == frame.Next, outgoing = index == frame.Current;
            double from = incoming ? frame.NextOpacity : outgoing ? 1 - frame.NextOpacity : 0;
            text.Opacity = incoming ? 1 : 0;
            if (!incoming && !outgoing) continue;
            var animation = new DoubleAnimation(from, text.Opacity, TimeSpan.FromSeconds(frame.FadeRemaining)) { FillBehavior = FillBehavior.Stop };
            Timeline.SetDesiredFrameRate(animation, 30);
            fades.Add(new(animation, clock => text.ApplyAnimationClock(OpacityProperty, clock), incoming ? Step : null));
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
