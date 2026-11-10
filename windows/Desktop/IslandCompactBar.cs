using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private DesktopPreferences compactPreferences = new();
    private readonly Dictionary<string, Button> compactRow = new(), compactColumn = new();
    private readonly CompactStatusText compactStatus = new();
    private readonly CompactValueView compactRate = new(false), compactStripRate = new(true);
    private readonly CompactValueView compactFirst = new(false, CompactInk.Stopwatch, 11, 12), compactStripFirst = new(true);
    private readonly DeepSeekPriceClock compactClock = new() { Compact = true, Width = 20, Height = 20 }, compactStripClock = new() { Compact = true, Width = 20, Height = 20 };
    private readonly StackPanel compactTime = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel compactStripTime = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock compactStripQuotaUnit = CompactInk.Text(9, FontWeights.Medium, CompactInk.Unit);
    private CompactProjection? compactData;
    private CompactMetrics compactSizes = CompactMetrics.Standard;
    private bool quotaLinked, stripQuotaLinked;
    private double measuredStripHeight = 135;
    /// The bar size's index in Core's `CompactBarSize.allCases`, for the native layout.
    private int CompactSizeIndex => Math.Max(0, Array.IndexOf(DesktopPreferences.BarSizes, compactPreferences.CompactBarSize));

    private static StackPanel CompactStack(FrameworkElement value, FrameworkElement unit)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(value); stack.Children.Add(unit); return stack;
    }
    private void InitializeCompactBar()
    {
        HeaderLeading.Children.Clear(); HeaderTrailing.Children.Clear(); StripLeading.Children.Clear(); StripTrailing.Children.Clear();
        QuotaLabel.Margin = StripQuota.Margin = WarningGlyphs.Margin = StripWarnings.Margin = new Thickness(0);
        StripQuota.Vertical = true; compactStripQuotaUnit.HorizontalAlignment = HorizontalAlignment.Center;
        var quotaColumn = CompactStack(StripQuota, compactStripQuotaUnit);
        Add("activity", Badge, StripBadge); Add("status", compactStatus, new Border()); Add("tps", compactRate, compactStripRate);
        Add("firstOutput", compactFirst, compactStripFirst); Add("warnings", WarningGlyphs, StripWarnings);
        Add("quotaGauge", QuotaGlyph, StripQuotaGlyph); Add("priceClock", compactClock, compactStripClock);
        Add("quota", QuotaLabel, quotaColumn); Add("timeRemaining", compactTime, compactStripTime);
        // While the value takes turns, the rings show whose value it is.
        QuotaLabel.CurrentChanged += provider => QuotaGlyph.Highlighted = quotaLinked ? provider : null;
        StripQuota.CurrentChanged += provider => StripQuotaGlyph.Highlighted = stripQuotaLinked ? provider : null;
        void Add(string id, FrameworkElement row, FrameworkElement column)
        {
            compactRow[id] = Host(id, row, false); compactColumn[id] = Host(id, column, true);
        }
        Button Host(string id, FrameworkElement content, bool vertical)
        {
            content.IsHitTestVisible = false;
            var host = new CompactComponentButton { Content = content, Style = (Style)FindResource("CompactComponentButton"),
                Padding = new Thickness(0, vertical ? 2 : 4, 0, vertical ? 2 : 4), VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetAutomationId(host, "compact." + (vertical ? "strip." : "row.") + id);
            host.Click += (_, _) =>
            {
                if (presentationStopped || !host.IsVisible || !host.IsEnabled || host.Opacity < 0.05) return;
                SetPinned(!pinned); SetExpanded(true);
            };
            return host;
        }
        UpdateCompactBar();
    }
    private void UpdateCompactBar()
    {
        if (compactRow.Count == 0) return;
        var providers = NativeCompactBar.Providers(compactPreferences, latest);
        bool attached = displayMode == 1;
        var horizontal = NativeCompactBar.Shared.Read(compactPreferences, ui.Language, providers, latest?.CompactContext, attached: attached);
        bool horizontalPending = NativeCompactBar.Shared.LastPending;
        var vertical = NativeCompactBar.Shared.Read(compactPreferences, ui.Language, providers, latest?.CompactContext, strip: true);
        // Source values change with every rate update. Until their projection
        // arrives, keep the bar as displayed: clearing it removed the badge,
        // restarting its rotation and retargeting the collapse motion.
        if ((horizontalPending || NativeCompactBar.Shared.LastPending) && compactData is { Components.Length: > 0 }) return;
        compactData = horizontal;
        var sizes = compactSizes = horizontal.Sizes;
        var choices = horizontal.Choices;
        Badge.SetSize(sizes.Badge); StripBadge.SetSize(sizes.Badge);
        if (latest?.Presentation?.Header is EngineHeader header)
        {
            if (horizontal.SingleTaskCount && header.ActiveCount == 1) header = header with { CoreSymbol = null };
            var badge = new BadgeOptions(horizontal.SingleTaskPercent == true, choices.MultiRing, choices.MultiCore, choices.EndMark);
            Badge.Update(header, DecorationsAnimate, badge); StripBadge.Update(header, DecorationsAnimate, badge);
        }
        UpdateValues(horizontal, false); UpdateValues(vertical, true);
        QuotaGlyph.Update(horizontal, latest?.Wallet); StripQuotaGlyph.Update(vertical, latest?.Wallet, strip: true);
        quotaLinked = Linked(horizontal); stripQuotaLinked = Linked(vertical);
        QuotaGlyph.Highlighted = quotaLinked ? QuotaLabel.CurrentProvider : null; StripQuotaGlyph.Highlighted = stripQuotaLinked ? StripQuota.CurrentProvider : null;
        foreach (var clock in new[] { compactClock, compactStripClock }) { clock.Width = clock.Height = sizes.Gauge; clock.Update(latest?.Wallet); }
        WarningGlyphs.Update(latest?.CompactWarnings, choices.WarningStyle, choices.WarningLimit, sizes.Warning, DecorationsAnimate);
        StripWarnings.Update(latest?.CompactWarnings, choices.WarningStyle, choices.WarningLimit, sizes.Warning, DecorationsAnimate);
        Header.Margin = new Thickness(sizes.Inset, 0, sizes.Inset, 0);
        HeaderDivider.Height = sizes.Divider; StripDivider.Width = sizes.Divider;
        StripLeading.Margin = new Thickness(0, sizes.StripInset, 0, 0); StripTrailing.Margin = new Thickness(0, 0, 0, sizes.StripInset);
        Fill(HeaderLeading, horizontal.Leading, compactRow, false, sizes.Gap);
        Fill(HeaderTrailing, horizontal.Trailing, compactRow, false, sizes.Gap);
        Fill(StripLeading, vertical.Leading, compactColumn, true, sizes.StripGap); Fill(StripTrailing, vertical.Trailing, compactColumn, true, sizes.StripGap);
        if (horizontal.Components.Length == 0)
        {
            var placeholder = new Button { Name = "enginePlaceholder", IsHitTestVisible = false, IsEnabled = false, Focusable = false, IsTabStop = false,
                Content = new TextBlock { Text = !ShellProjection.HasFailure("projectCompactBar") ? "…" : ui.Text("windows.connection.refresh_failed"),
                    Foreground = PacerPalette.Secondary, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 220 },
                Style = (Style)FindResource("CompactComponentButton") };
            HeaderLeading.Children.Add(placeholder);
        }
        // The ring the alternating value is not naming dims, unless the rings' card turned that off.
        static bool Linked(CompactProjection data) => data.Choices.RingDim && data.Choices.QuotaMultiple == "alternate" && data.Rings.Length > 1
            && data.Rings.All(ring => ring.Window == null) && data.Leading.Concat(data.Trailing).Contains("quota")
            && data.Leading.Concat(data.Trailing).Contains("quotaGauge");
        void UpdateValues(CompactProjection data, bool column)
        {
            var slots = column ? compactColumn : compactRow;
            if (data.Components.Length == 0) return;
            foreach (var item in data.Components)
            {
                if (!slots.TryGetValue(item.Id, out var slot)) continue;
                AutomationProperties.SetName(slot, item.Accessibility); AutomationProperties.SetHelpText(slot, item.Help);
            }
            CompactComponent Item(string id) => data.Components.Single(value => value.Id == id);
            var metrics = data.Sizes;
            var rate = Item("tps");
            var rateView = column ? compactStripRate : compactRate;
            // A rate without a fresh measurement stays, in the secondary colour.
            rateView.Update(column ? rate.StripText : rate.Text, column ? rate.StripUnit : rate.Unit,
                latest?.RateIsFresh == true ? PacerPalette.Primary : PacerPalette.Secondary, metrics);
            rateView.Visibility = rate.Shown && rate.Visible ? Visibility.Visible : Visibility.Collapsed;
            var first = Item("firstOutput");
            (column ? compactStripFirst : compactFirst).Update(column ? first.StripText : first.Text, column ? first.StripUnit : first.Unit,
                PacerPalette.Primary, metrics);
            if (!column) { var status = Item("status"); compactStatus.Update(status.Text, status.Tone, status.MaxWidth ?? 108 * metrics.Scale, metrics.Status, DecorationsAnimate); }
            var quota = Item("quota");
            var values = column ? StripQuota : QuotaLabel;
            values.FontSize = column ? metrics.StripValue : metrics.Value; values.UnitSize = column ? metrics.StripUnit : metrics.Unit;
            values.Pair = data.Choices.QuotaMultiple == "pair";
            values.MaximumDisplayWidth = column ? Math.Max(16, metrics.StripWidth - 6) : double.PositiveInfinity;
            values.Update(quota.Entries.Select(entry => new AlternatingQuotaText.Item(entry.Provider, column ? entry.StripText : entry.Text,
                entry.Dimmed, entry.Low == true)).ToArray(), DecorationsAnimate);
            if (column)
            {
                compactStripQuotaUnit.FontSize = metrics.StripUnit; compactStripQuotaUnit.Text = quota.StripUnit ?? "";
                compactStripQuotaUnit.Visibility = quota.StripUnit == null ? Visibility.Collapsed : Visibility.Visible;
            }
            RenderTime(column ? compactStripTime : compactTime, Item("timeRemaining"), column, metrics);
        }
    }
    /// The hourglass, then each service's time left in its colour; percentages
    /// carry a unit, a countdown says its own.
    internal static void RenderTime(StackPanel host, CompactComponent value, bool column, CompactMetrics sizes)
    {
        host.Children.Clear();
        var glyph = CompactInk.Glyph(CompactInk.Hourglass, 9, 12, sizes.Scale);
        glyph.Margin = column ? new Thickness(0, 0, 0, 2 * sizes.Scale) : new Thickness(0, 0, 5 * sizes.Scale, 0);
        host.Children.Add(glyph);
        bool percent = value.StripUnit == "%";
        for (int index = 0; index < value.Entries.Length; index++)
        {
            var item = value.Entries[index];
            var ink = PacerPalette.Provider(item.Provider);
            if (column)
            {
                var text = CompactInk.Text(sizes.StripValue - 0.5, FontWeights.SemiBold, ink); text.Text = item.StripText;
                host.Children.Add(text);
                continue;
            }
            var entry = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(index == 0 ? 0 : 5 * sizes.Scale, 0, 0, 0) };
            string shown = item.Text;
            bool unit = percent && shown.Length > 1 && shown.EndsWith('%');
            var number = CompactInk.Text(sizes.Value - 1, FontWeights.SemiBold, ink); number.Text = unit ? shown[..^1] : shown;
            number.VerticalAlignment = VerticalAlignment.Bottom; entry.Children.Add(number);
            if (unit)
            {
                var sign = CompactInk.Text(sizes.Unit, FontWeights.Medium, CompactInk.Unit); sign.Text = "%";
                sign.VerticalAlignment = VerticalAlignment.Bottom; sign.Margin = new Thickness(1.5 * sizes.Scale, 0, 0, (sizes.Value - 1 - sizes.Unit) * 0.12);
                entry.Children.Add(sign);
            }
            host.Children.Add(entry);
        }
        if (column && percent) { var unit = CompactInk.Text(sizes.StripUnit, FontWeights.Medium, CompactInk.Unit); unit.Text = "%"; host.Children.Add(unit); }
    }
    /// Sets a strip number at `size`, shrinking it only if it cannot fit `width`.
    internal static void FitStripNumber(TextBlock text, string? value, double size = 11.5, double width = 22)
    {
        string number = value ?? "—";
        double natural = Math.Max(CompactInk.Measure(number, size, FontWeights.SemiBold), NativeTypography.CompactWidth(number, size) ?? 0);
        text.Text = number; text.FontSize = size * Math.Min(1, width / Math.Max(1, natural));
        text.MaxWidth = width; text.TextTrimming = TextTrimming.None;
    }
    private static void Fill(StackPanel panel, string[] ids, Dictionary<string, Button> slots, bool vertical, double gap)
    {
        // A component this host does not draw (such as a retired one) is skipped.
        ids = ids.Where(slots.ContainsKey).ToArray();
        if (!panel.Children.Cast<Button>().Select(value => value.Name).SequenceEqual(ids))
        {
            panel.Children.Clear();
            foreach (string id in ids)
            {
                var value = slots[id];
                if (value.Parent is Panel previous) previous.Children.Remove(value);
                value.Name = id; panel.Children.Add(value);
            }
        }
        for (int index = 0; index < panel.Children.Count; index++)
            ((FrameworkElement)panel.Children[index]).Margin = vertical ? new Thickness(0, index == 0 ? 0 : gap, 0, 0) : new Thickness(index == 0 ? 0 : gap, 0, 0, 0);
    }
    private (double Header, double Strip) MeasureCompactBar()
    {
        // Updated values keep the same slots. A panel measured again with the
        // same constraint returns its cached size until the next layout pass.
        foreach (var lane in new[] { HeaderLeading, HeaderTrailing, StripLeading, StripTrailing }) InvalidateLayoutTree(lane);
        var open = new Size(double.PositiveInfinity, double.PositiveInfinity);
        HeaderLeading.Measure(open); HeaderTrailing.Measure(open); StripLeading.Measure(open); StripTrailing.Measure(open);
        var sizes = compactSizes;
        double top = StripLeading.Children.Count > 0 ? StripLeading.DesiredSize.Height - StripLeading.Margin.Top : 0;
        double bottom = StripTrailing.Children.Count > 0 ? StripTrailing.DesiredSize.Height - StripTrailing.Margin.Bottom : 0;
        bool divided = top > 0 && bottom > 0;
        StripDivider.Visibility = divided ? Visibility.Visible : Visibility.Collapsed;
        StripDivider.Margin = new Thickness(0, 0, 0, sizes.StripInset + bottom + sizes.LaneGap / 2);
        measuredStripHeight = 2 * sizes.StripInset + top + bottom + (divided ? sizes.LaneGap : 0);
        double left = HeaderLeading.DesiredSize.Width, right = HeaderTrailing.DesiredSize.Width;
        bool both = left > 0 && right > 0;
        // A hairline sits halfway between the two lanes.
        HeaderDivider.Visibility = both ? Visibility.Visible : Visibility.Collapsed;
        return (left + right + (both ? sizes.LaneGap : 0) + 2 * sizes.Inset, measuredStripHeight);
    }
    private static void InvalidateLayoutTree(DependencyObject element)
    {
        if (element is UIElement value) value.InvalidateMeasure();
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(element); index++) InvalidateLayoutTree(VisualTreeHelper.GetChild(element, index));
    }
    /// Redraws what the island built in its earlier tone: the bar's values,
    /// marks and drawn glyphs, then everything that renders itself.
    private void RepaintTone()
    {
        QuotaLabel.Repaint(); StripQuota.Repaint(); WarningGlyphs.Repaint(); StripWarnings.Repaint(); compactStatus.Repaint();
        compactStripQuotaUnit.Foreground = CompactInk.Unit;
        UpdateCompactBar();
        static void Invalidate(DependencyObject node)
        {
            if (node is UIElement element) element.InvalidateVisual();
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++) Invalidate(VisualTreeHelper.GetChild(node, index));
        }
        Invalidate(this);
        RefreshSurface();
    }
    /// An attached bar keeps its free corners at the size's radius; a floating
    /// one is a full capsule and a docked strip rounds half its width.
    private double CollapsedRadius()
    {
        if (layout.Position != 0) return Math.Max(1, layout.StripWidth / 2);
        double half = Math.Max(1, layout.HeaderHeight / 2);
        return layout.Attached || layout.Dock is IslandEdge.Top or IslandEdge.Bottom ? Math.Min(compactSizes.Radius, layout.HeaderHeight) : half;
    }
    private sealed class CompactComponentButton : Button
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
        private sealed class Peer(CompactComponentButton owner) : ButtonAutomationPeer(owner)
        { protected override List<AutomationPeer>? GetChildrenCore() => null; }
    }
}
