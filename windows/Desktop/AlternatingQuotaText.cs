using System;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace CodexPacer.Windows;

/// <summary>Uses the original four-second slots and 350 ms key times; the
/// outgoing value slides up as the next one rises into place. Each value is a
/// number with its unit, in its service's colour or amber when low. Paired
/// values sit side by side instead.</summary>
public sealed class AlternatingQuotaText : Grid
{
    internal readonly record struct Item(string Provider, string Text, bool Dimmed, bool Low = false);
    private readonly List<FrameworkElement> layers = [];
    private readonly List<TranslateTransform> offsets = [];
    private Item[] items = [];
    private bool lastPair, lastVertical;
    private double lastUnit;
    private string? currentProvider;
    /// The service whose value shows now, or null for none or a pair.
    internal string? CurrentProvider => currentProvider;
    internal event Action<string?>? CurrentChanged;
    /// Unit size; NaN follows the value at 10/13 of its size.
    public double UnitSize { get; set; } = double.NaN;
    /// All values side by side instead of taking turns.
    internal bool Pair { get; set; }
    /// The strip stacks a pair and leaves units to its own cell.
    internal bool Vertical { get; set; }
    internal string[] ShownTexts => items.Select(item => item.Text).ToArray();
    /// Builds the values again on the next update, in the island's current tone.
    internal void Repaint() => items = [];
    private bool animates = true;
    private readonly DispatcherTimer wake = new(DispatcherPriority.Background);
    private readonly List<AnimationLease> fades = [];
    private Stopwatch? cycle;
    private double lastSize, lastMaximum;
    private string? lastFamily;
    private long wakeups;
    private long completedCycles, settledSlot;
    private double nextFade;
    private readonly QuotaCycleCompletion completedCycle = new();
    internal (bool Scheduled, int Clocks, long Wakes) Scheduling => (wake.IsEnabled, fades.Count, wakeups);
    internal string CycleDiagnostics => $"visible={IsVisible}, animate={animates}, entries={layers.Count}, elapsed={cycle?.Elapsed.TotalSeconds:0.000}, completed={completedCycles}, slot={settledSlot}, deadline={nextFade:0.000}";
    internal Task WaitForNextCycleAsync(TimeSpan timeout, CancellationToken cancellation = default)
        => completedCycle.AfterAsync(completedCycles, timeout, cancellation);
    internal event Action<TimeSpan>? FadeStartedForAutomation;
    internal void SeekFadeForAutomation(TimeSpan position)
    { foreach (var fade in fades.ToArray()) fade.Seek(position); }
    public double FontSize { get; set; } = 12;
    public FontFamily FontFamily { get; set; } = PacerFonts.Interface;
    internal double MaximumDisplayWidth { get; set; } = double.PositiveInfinity;
    public AlternatingQuotaText()
    {
        IsHitTestVisible = false;
        wake.Tick += (_, _) => { wake.Stop(); wakeups++; Step(nextFade); };
        IsVisibleChanged += (_, _) => Refresh();
        Unloaded += (_, _) => Stop();
    }
    internal void Update(IReadOnlyList<(string Provider, string Text)> entries, bool animate, IReadOnlyList<bool>? dimmed = null)
        => Update(entries.Select((entry, index) => new Item(entry.Provider, entry.Text, dimmed?.ElementAtOrDefault(index) == true)).ToArray(), animate);
    internal void Update(IReadOnlyList<Item> entries, bool animate)
    {
        if (items.SequenceEqual(entries) && animate == animates && Pair == lastPair && Vertical == lastVertical && UnitSize.Equals(lastUnit)
            && FontSize == lastSize && MaximumDisplayWidth == lastMaximum && FontFamily.Source == lastFamily) return;
        bool restart = layers.Count != entries.Count || animate != animates || Pair != lastPair
            || !items.Select(value => value.Provider).SequenceEqual(entries.Select(value => value.Provider));
        if (restart) Stop();
        animates = animate;
        items = entries.ToArray(); lastPair = Pair; lastVertical = Vertical; lastUnit = UnitSize;
        lastSize = FontSize; lastMaximum = MaximumDisplayWidth; lastFamily = FontFamily.Source;
        AutomationProperties.SetName(this, string.Join(", ", entries.Select(entry => entry.Provider + " " + entry.Text)));
        UIElementAutomationPeer.FromElement(this)?.InvalidatePeer();
        Children.Clear(); layers.Clear(); offsets.Clear(); ColumnDefinitions.Clear(); RowDefinitions.Clear();
        double width = 0, height = 0, gap = Math.Round(FontSize * 6 / 13);
        for (int index = 0; index < items.Length; index++)
        {
            var layer = Build(items[index]);
            // A live label can be measured while its ancestor is clipped or
            // hidden. Measure the layer before it joins the tree.
            layer.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double scale = Math.Min(1, MaximumDisplayWidth / Math.Max(1, layer.DesiredSize.Width));
            if (scale < 1) { layer.LayoutTransform = new ScaleTransform(scale, scale); layer.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); }
            var offset = new TranslateTransform(); layer.RenderTransform = offset;
            if (Pair && Vertical) { RowDefinitions.Add(new() { Height = GridLength.Auto }); SetRow(layer, index); layer.Margin = new Thickness(0, index == 0 ? 0 : 2, 0, 0); }
            else if (Pair) { ColumnDefinitions.Add(new() { Width = GridLength.Auto }); SetColumn(layer, index); layer.Margin = new Thickness(index == 0 ? 0 : gap, 0, 0, 0); }
            layers.Add(layer); offsets.Add(offset); Children.Add(layer);
            double w = layer.DesiredSize.Width, h = layer.DesiredSize.Height;
            if (Pair && Vertical) { width = Math.Max(width, w); height += h + (index == 0 ? 0 : 2); }
            else if (Pair) { width += w + (index == 0 ? 0 : gap); height = Math.Max(height, h); }
            else { width = Math.Max(width, w); height = Math.Max(height, h); }
        }
        Width = Pair ? Math.Ceiling(width) : Math.Min(MaximumDisplayWidth, Math.Ceiling(width)); Height = Math.Ceiling(height);
        // Taking turns, the values move a whole line inside this slot, so two never overlap.
        ClipToBounds = !Pair;
        for (int index = 0; index < layers.Count; index++) layers[index].Opacity = Pair || index == 0 ? 1 : 0;
        // Rebuilt values take the running rotation's frame at once, mid-slide
        // included; left to the next turn, a new reading would show two values
        // in one place until then.
        if (restart || cycle == null) Refresh(); else Step();
        Report(Pair || items.Length == 0 ? null : items[Math.Clamp(ShownIndex, 0, items.Length - 1)].Provider);
    }
    private int ShownIndex { get { for (int index = 0; index < layers.Count; index++) if (layers[index].Opacity >= 0.5) return index; return 0; } }
    private void Report(string? provider)
    {
        if (provider == currentProvider) return;
        currentProvider = provider; CurrentChanged?.Invoke(provider);
    }
    private FrameworkElement Build(Item item)
    {
        Brush ink = item.Low ? PacerPalette.Attention : PacerPalette.Provider(item.Provider);
        if (item.Dimmed) { ink = ink.Clone(); ink.Opacity = .45; ink.Freeze(); }
        double unitSize = double.IsNaN(UnitSize) ? Math.Round(FontSize * 10 / 13 * 2) / 2 : UnitSize;
        TextBlock Text(string text, double size, FontWeight weight, Brush brush)
        {
            var value = new TextBlock { Text = text, FontFamily = FontFamily, FontSize = size, FontWeight = weight, Foreground = brush,
                VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.None };
            Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular); return value;
        }
        // In the bar a shorter value keeps its place beside its neighbour; the strip centres it.
        var panel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = Vertical ? HorizontalAlignment.Center : HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        bool percent = !Vertical && item.Text.Length > 1 && item.Text.EndsWith('%');
        var number = Text(percent ? item.Text[..^1] : item.Text, FontSize, FontWeights.SemiBold, ink);
        panel.Children.Add(number);
        if (percent)
        {
            var unit = Text("%", unitSize, FontWeights.Medium, CompactInk.Unit);
            unit.Margin = new Thickness(Math.Max(1, FontSize * 1.5 / 13), 0, 0, Math.Max(0, (FontSize - unitSize) * 0.12));
            panel.Children.Add(unit);
        }
        return panel;
    }
    internal void Stop()
    {
        wake.Stop(); cycle = null; settledSlot = 0; ClearFades();
        for (int index = 0; index < layers.Count; index++)
        {
            layers[index].BeginAnimation(OpacityProperty, null);
            layers[index].Opacity = Pair || index == 0 ? 1 : 0;
            offsets[index].BeginAnimation(TranslateTransform.YProperty, null); offsets[index].Y = 0;
        }
        if (!Pair && items.Length > 0) Report(items[0].Provider);
    }
    private void Refresh()
    {
        if (!IsVisible || !animates || layers.Count < 2 || Pair) { Stop(); return; }
        if (cycle != null) return;
        cycle = Stopwatch.StartNew(); Step();
    }
    private void ClearFades()
    {
        foreach (var fade in fades.ToArray()) fade.Dispose(); fades.Clear();
    }
    private void Step(double reached = 0)
    {
        if (cycle == null || !IsVisible || !animates || layers.Count < 2 || Pair) { Stop(); return; }
        ClearFades();
        double elapsed = cycle.Elapsed.TotalSeconds;
        var plan = QuotaAlternationSchedule.AtDeadline(elapsed, layers.Count, reached);
        var frame = plan.Frame;
        // The old value leaves through the top as the next enters from below, one line apart.
        double rise = Math.Max(1, double.IsNaN(Height) ? Math.Ceiling(FontSize * 1.35) : Height);
        if (frame.FadeRemaining <= 0)
        {
            for (int index = 0; index < layers.Count; index++)
            {
                layers[index].Opacity = index == frame.Current ? 1 : 0;
                offsets[index].BeginAnimation(TranslateTransform.YProperty, null); offsets[index].Y = 0;
            }
            Report(items.ElementAtOrDefault(frame.Current).Provider);
            nextFade = frame.NextFade;
            wake.Interval = TimeSpan.FromSeconds(plan.NextWakeAfter); wake.Start();
            if (plan.Slot > settledSlot)
            {
                settledSlot = plan.Slot;
                completedCycle.Notify(++completedCycles);
            }
            return;
        }
        for (int index = 0; index < layers.Count; index++)
        {
            var text = layers[index];
            bool incoming = index == frame.Next, outgoing = index == frame.Current;
            double from = incoming ? frame.NextOpacity : outgoing ? 1 - frame.NextOpacity : 0;
            double target = incoming ? 1 : 0;
            text.Opacity = from;
            if (!incoming && !outgoing) continue;
            var animation = new DoubleAnimation(from, target, TimeSpan.FromSeconds(frame.FadeRemaining))
                { BeginTime = TimeSpan.FromSeconds(plan.WaitBeforeFade), FillBehavior = FillBehavior.Stop };
            Timeline.SetDesiredFrameRate(animation, 30);
            fades.Add(new(animation, clock => text.ApplyAnimationClock(OpacityProperty, clock), incoming ? () => Step(plan.EndsAt) : null));
            // The old value leaves upward while the next one rises into its place.
            var offset = offsets[index];
            double start = incoming ? rise * (1 - frame.NextOpacity) : -rise * frame.NextOpacity, end = incoming ? 0 : -rise;
            offset.Y = start;
            var slide = new DoubleAnimation(start, end, TimeSpan.FromSeconds(frame.FadeRemaining))
                { BeginTime = TimeSpan.FromSeconds(plan.WaitBeforeFade), FillBehavior = FillBehavior.Stop, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            Timeline.SetDesiredFrameRate(slide, 30);
            fades.Add(new(slide, clock => offset.ApplyAnimationClock(TranslateTransform.YProperty, clock)));
            if (incoming) Report(items.ElementAtOrDefault(index).Provider);
        }
        FadeStartedForAutomation?.Invoke(TimeSpan.FromSeconds(plan.WaitBeforeFade + frame.FadeRemaining));
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new ValuePeer(this);
    private sealed class ValuePeer(AlternatingQuotaText owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => "PacerQuotaValues";
        protected override List<AutomationPeer>? GetChildrenCore() => [];
    }
}
