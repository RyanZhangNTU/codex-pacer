using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The original local-day pricing strip. The engine chooses the day's
/// intervals; the host uses their fractions without calculating prices.
internal sealed class DeepSeekPricingTimeline : QuotaReadingHost
{
    private readonly Strip strip = new() { Height = 8 };
    internal DeepSeekPricingTimeline(UiText ui)
    {
        Margin = new Thickness(10, 10, 10, 0); AutomationProperties.SetName(this, ui.Text("deepseek.peak_hours_help"));
        AutomationProperties.SetAutomationId(this, "settings.deepseek.pricing_timeline"); Children.Add(strip);
        var times = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        string[] hours = ["0:00", "6:00", "12:00", "18:00", "24:00"];
        for (int index = 0; index < hours.Length; index++)
        {
            int column = times.ColumnDefinitions.Count; times.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            if (index < hours.Length - 1) times.ColumnDefinitions.Add(new());
            var label = DeepSeekElements.Text(hours[index], 9, PacerPalette.Secondary); label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); Grid.SetColumn(label, column); times.Children.Add(label);
        }
        Children.Add(times);
        var legend = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var item in new[] { ("deepseek.offpeak_hours", DeepSeekElements.Opacity(PacerPalette.DeepSeek, .35)), ("deepseek.peak_hours_x2", PacerPalette.Attention) })
        {
            var part = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(legend.Children.Count > 0 ? 12 : 0, 0, 0, 0) };
            part.Children.Add(new Border { Width = 8, Height = 8, Background = item.Item2, CornerRadius = new CornerRadius(2), VerticalAlignment = VerticalAlignment.Center });
            var text = DeepSeekElements.Text(ui.Text(item.Item1), 11, PacerPalette.Secondary); text.Margin = new Thickness(4, 0, 0, 0); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); part.Children.Add(text); legend.Children.Add(part);
        }
        Children.Add(legend);
    }
    internal void Update(IReadOnlyList<WalletSpan>? values) => strip.Update(values ?? Array.Empty<WalletSpan>());
    private sealed class Strip : FrameworkElement
    {
        private IReadOnlyList<WalletSpan> spans = Array.Empty<WalletSpan>();
        internal void Update(IReadOnlyList<WalletSpan> value) { if (spans.SequenceEqual(value)) return; spans = value; InvalidateVisual(); }
        protected override void OnRender(DrawingContext drawing)
        {
            drawing.DrawRoundedRectangle(DeepSeekElements.Opacity(PacerPalette.DeepSeek, .35), null, new Rect(0, 0, ActualWidth, 8), 3, 3);
            foreach (var span in spans) drawing.DrawRoundedRectangle(PacerPalette.Attention, null, new Rect(ActualWidth * span.Start, 0, ActualWidth * (span.End - span.Start), 8), 3, 3);
        }
    }
}
