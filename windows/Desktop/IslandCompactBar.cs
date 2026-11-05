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
    private readonly TextBlock compactStatus = CompactText(12, FontWeights.Medium, PacerPalette.Primary);
    private readonly TextBlock compactFirst = CompactText(11, FontWeights.Medium, PacerPalette.Secondary);
    private readonly TextBlock compactStripFirst = CompactText(10, FontWeights.SemiBold, PacerPalette.Secondary);
    private readonly TextBlock compactMetric = CompactText(10, FontWeights.Medium, PacerPalette.Tertiary);
    private readonly DeepSeekPriceClock compactClock = new() { Width = 18, Height = 18 }, compactStripClock = new() { Width = 18, Height = 18 };
    private readonly StackPanel compactTime = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel compactStripTime = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock compactStripQuotaUnit = CompactText(9, FontWeights.Medium, PacerPalette.Tertiary);
    private CompactProjection? compactData;
    private double measuredStripHeight = 135;
    private bool compactDimmed;
    private readonly Dictionary<Button, AnimationLease> dimClocks = [];

    private static TextBlock CompactText(double size, FontWeight weight, Brush ink)
    {
        var text = new TextBlock { FontFamily = PacerFonts.Interface, FontSize = size, FontWeight = weight, Foreground = ink,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        System.Windows.Documents.Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular); return text;
    }
    private static StackPanel CompactStack(FrameworkElement value, FrameworkElement unit)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(value); stack.Children.Add(unit); return stack;
    }
    private void InitializeCompactBar()
    {
        HeaderLeading.Children.Clear(); HeaderTrailing.Children.Clear(); StripLeading.Children.Clear(); StripTrailing.Children.Clear();
        RatePanel.Margin = new Thickness(0); QuotaLabel.Margin = new Thickness(0); StripQuota.Margin = new Thickness(0);
        WarningGlyphs.Margin = StripWarnings.Margin = StripRatePanel.Margin = new Thickness(0);
        var firstColumn = CompactStack(compactStripFirst, new TextBlock { Text = "s", FontSize = 9, FontWeight = FontWeights.Medium,
            Foreground = PacerPalette.Tertiary, HorizontalAlignment = HorizontalAlignment.Center });
        var quotaColumn = CompactStack(StripQuota, compactStripQuotaUnit);
        Add("activity", Badge, StripBadge); Add("status", compactStatus, new Border()); Add("tps", RatePanel, StripRatePanel);
        Add("firstOutput", compactFirst, firstColumn); Add("warnings", WarningGlyphs, StripWarnings);
        Add("quotaGauge", QuotaGlyph, StripQuotaGlyph); Add("priceClock", compactClock, compactStripClock);
        Add("quota", QuotaLabel, quotaColumn); Add("quotaLabel", compactMetric, new Border()); Add("timeRemaining", compactTime, compactStripTime);
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
        if (latest?.Presentation?.Header is EngineHeader header)
        {
            if (horizontal.SingleTaskCount && header.ActiveCount == 1) header = header with { CoreSymbol = null };
            Badge.Update(header, DecorationsAnimate); StripBadge.Update(header, DecorationsAnimate);
        }
        UpdateValues(horizontal, false); UpdateValues(vertical, true);
        QuotaGlyph.Update(horizontal, latest?.Wallet); StripQuotaGlyph.Update(vertical, latest?.Wallet);
        compactClock.Update(latest?.Wallet); compactStripClock.Update(latest?.Wallet);
        WarningGlyphs.Update(latest?.CompactWarnings); StripWarnings.Update(latest?.CompactWarnings);
        Fill(HeaderLeading, horizontal.Leading, compactRow, false, attached ? 6 : 8);
        Fill(HeaderTrailing, horizontal.Trailing, compactRow, false, attached ? 6 : 8);
        Fill(StripLeading, vertical.Leading, compactColumn, true, 4); Fill(StripTrailing, vertical.Trailing, compactColumn, true, 4);
        if (horizontal.Components.Length == 0)
        {
            var placeholder = new Button { Name = "enginePlaceholder", IsHitTestVisible = false, IsEnabled = false, Focusable = false, IsTabStop = false,
                Content = new TextBlock { Text = !ShellProjection.HasFailure("projectCompactBar") ? "…" : ui.Text("windows.connection.refresh_failed"),
                    Foreground = PacerPalette.Secondary, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 220 },
                Style = (Style)FindResource("CompactComponentButton") };
            HeaderLeading.Children.Add(placeholder);
        }
        SetCompactDimState(expanded, false);
        void UpdateValues(CompactProjection data, bool column)
        {
            var slots = column ? compactColumn : compactRow;
            if (data.Components.Length == 0) return;
            foreach (var item in data.Components)
            {
                var slot = slots[item.Id]; slot.Tag = item.DimsExpanded;
                AutomationProperties.SetName(slot, item.Accessibility); AutomationProperties.SetHelpText(slot, item.Help);
            }
            var rate = data.Components.Single(value => value.Id == "tps");
            if (column) { FitStripNumber(StripRate, rate.StripText); StripRatePanel.Visibility = rate.Shown && rate.Visible ? Visibility.Visible : Visibility.Collapsed; }
            else { RateLabel.Text = rate.Text; RatePanel.Visibility = rate.Shown && rate.Visible ? Visibility.Visible : Visibility.Collapsed; }
            RateLabel.Foreground = StripRate.Foreground = latest?.RateIsFresh == true ? PacerPalette.Primary : PacerPalette.Secondary;
            var first = data.Components.Single(value => value.Id == "firstOutput");
            if (column) FitStripNumber(compactStripFirst, first.StripText); else compactFirst.Text = first.Text;
            compactStatus.Text = data.Components.Single(value => value.Id == "status").Text;
            compactMetric.Text = data.Components.Single(value => value.Id == "quotaLabel").Text;
            var quota = data.Components.Single(value => value.Id == "quota");
            var values = quota.Entries.Select(value => (value.Provider, column ? value.StripText : value.Text)).ToArray();
            var dimmed = quota.Entries.Select(value => value.Dimmed).ToArray();
            if (column) { StripQuota.MaximumDisplayWidth = 20; StripQuota.Update(values, DecorationsAnimate, dimmed); compactStripQuotaUnit.Text = quota.StripUnit ?? ""; compactStripQuotaUnit.Visibility = quota.StripUnit == null ? Visibility.Collapsed : Visibility.Visible; }
            else QuotaLabel.Update(values, DecorationsAnimate, dimmed);
            var time = data.Components.Single(value => value.Id == "timeRemaining");
            RenderTime(column ? compactStripTime : compactTime, time, column);
        }
    }
    private void RenderTime(StackPanel host, CompactComponent value, bool column)
    {
        host.Children.Clear();
        host.Children.Add(new IconGlyph { Symbol = "hourglass", Width = 9, Height = 9, Ink = PacerPalette.Tertiary,
            VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = column ? new Thickness(0) : new Thickness(0, 0, 4, 0) });
        foreach (var item in value.Entries)
        {
            if (!column && host.Children.Count > 1)
                host.Children.Add(new Border { Width = 1, Height = 10, Background = PacerPalette.Hairline, Margin = new Thickness(7, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center });
            var text = CompactText(column ? 10 : 11, column ? FontWeights.SemiBold : FontWeights.Medium, PacerPalette.Provider(item.Provider));
            text.Opacity = .85;
            if (column) text.Margin = new Thickness(0, 1, 0, 0);
            if (column) FitStripNumber(text, item.StripText); else text.Text = item.Text;
            host.Children.Add(text);
        }
        if (column) { var unit = CompactText(9, FontWeights.Medium, PacerPalette.Tertiary); unit.Text = "%"; unit.Margin = new Thickness(0, 1, 0, 0); host.Children.Add(unit); }
    }
    internal static void FitStripNumber(TextBlock text, string? value)
    {
        string number = value ?? "—";
        var probe = CompactText(10, FontWeights.SemiBold, PacerPalette.Primary); probe.Text = number;
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double width = Math.Max(probe.DesiredSize.Width, NativeTypography.CompactWidth(number, 10) ?? 0);
        text.Text = number; text.FontSize = 10 * Math.Min(1, 20 / Math.Max(1, width));
        text.MaxWidth = 20; text.TextTrimming = TextTrimming.None;
    }
    private static void Fill(StackPanel panel, string[] ids, Dictionary<string, Button> slots, bool vertical, double gap)
    {
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
        double rateWidth = NativeTypography.CompactWidth(RateLabel.Text ?? "", 12) ?? 0;
        RateLabel.Width = double.NaN; RateLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        RateLabel.Width = Math.Max(rateWidth, RateLabel.DesiredSize.Width);
        // Updated values keep the same slots. A panel measured again with the
        // same constraint returns its cached size until the next layout pass.
        foreach (var lane in new[] { HeaderLeading, HeaderTrailing, StripLeading, StripTrailing }) InvalidateLayoutTree(lane);
        HeaderLeading.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); HeaderTrailing.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        StripLeading.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); StripTrailing.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        bool divided = StripLeading.Children.Count > 0 && StripTrailing.Children.Count > 0;
        StripDivider.Visibility = divided ? Visibility.Visible : Visibility.Collapsed;
        StripDivider.Margin = new Thickness(0, 0, 0, 18 + StripTrailing.DesiredSize.Height);
        measuredStripHeight = 24 + StripLeading.DesiredSize.Height + StripTrailing.DesiredSize.Height + (divided ? 13 : 0);
        double left = HeaderLeading.DesiredSize.Width, right = HeaderTrailing.DesiredSize.Width;
        return (left + right + (left > 0 && right > 0 ? 10 : 0) + 30, measuredStripHeight);
    }
    private static void InvalidateLayoutTree(DependencyObject element)
    {
        if (element is UIElement value) value.InvalidateMeasure();
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(element); index++) InvalidateLayoutTree(VisualTreeHelper.GetChild(element, index));
    }
    private void SetCompactDimState(bool value, bool animate)
    {
        if (compactData == null) return;
        if (value == compactDimmed && animate) return;
        bool changed = value != compactDimmed; compactDimmed = value;
        foreach (var slot in compactRow.Values.Concat(compactColumn.Values))
        {
            double target = value && slot.Tag is true ? compactData.ExpandedOpacity : 1;
            dimClocks.TryGetValue(slot, out var old);
            var next = CompactComponentOpacity.Apply(slot, target, !changed && DecorationsAnimate,
                animate && DecorationsAnimate, compactData.DimDuration, old, () => dimClocks.Remove(slot));
            if (next == null) dimClocks.Remove(slot); else dimClocks[slot] = next;
        }
    }
    private bool CompactDimStateMatches()
        => compactData == null || compactRow.Values.Concat(compactColumn.Values).All(slot =>
            Math.Abs(slot.Opacity - (expanded && slot.Tag is true ? compactData.ExpandedOpacity : 1)) < .001);
    private string CompactDimDiagnostics => string.Join(";", compactRow.Values.Concat(compactColumn.Values)
        .Where(slot => compactData != null && Math.Abs(slot.Opacity - (expanded && slot.Tag is true ? compactData.ExpandedOpacity : 1)) >= .001).Select(slot =>
        $"{AutomationProperties.GetAutomationId(slot)}:{slot.Opacity:0.000}/{slot.GetAnimationBaseValue(OpacityProperty)},dim={slot.Tag},animated={slot.HasAnimatedProperties}"));
    private sealed class CompactComponentButton : Button
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
        private sealed class Peer(CompactComponentButton owner) : ButtonAutomationPeer(owner)
        { protected override List<AutomationPeer>? GetChildrenCore() => null; }
    }
}

internal static class CompactComponentOpacity
{
    internal static AnimationLease? Apply(Button slot, double target, bool preserveAnimation, bool animate, double duration,
        AnimationLease? ownedClock = null, Action? completed = null)
    {
        // A completed WPF clock still sets HasAnimatedProperties. Keep it
        // only while its base target also matches the current projection.
        if (preserveAnimation && slot.HasAnimatedProperties
            && Math.Abs((double)slot.GetAnimationBaseValue(UIElement.OpacityProperty) - target) < .001) return ownedClock;
        double from = slot.Opacity;
        ownedClock?.Dispose(); slot.ApplyAnimationClock(UIElement.OpacityProperty, null); slot.Opacity = target;
        if (animate && Math.Abs(from - target) > .001)
            return new(new DoubleAnimation(from, target, TimeSpan.FromSeconds(duration))
            { EasingFunction = NativeTaskRowTiming.Shared.Ease, FillBehavior = FillBehavior.Stop },
                clock => slot.ApplyAnimationClock(UIElement.OpacityProperty, clock), completed);
        return null;
    }
}
