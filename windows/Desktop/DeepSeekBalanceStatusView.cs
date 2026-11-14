using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

/// Original eleven-point status with a six-point gap and 22-point capsules.
internal sealed class DeepSeekBalanceStatusView : StackPanel
{
    internal DeepSeekBalanceStatusView(DeepSeekBalanceStatus status, Func<Task>? retry, Action? settings)
    {
        AutomationProperties.SetAutomationId(this, "deepseek.balance.status");
        var message = new TextBlock { Text = status.Message, FontFamily = PacerFonts.Interface, FontSize = 11,
            Foreground = status.Tone == "attention" ? PacerPalette.Attention : PacerPalette.Secondary,
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
        AutomationProperties.SetAutomationId(message, "deepseek.balance.status.message");
        AutomationProperties.SetName(message, status.Message); Children.Add(message);
        if (status.Actions.Count == 0) return;
        var row = new QuotaActionRow { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var action in status.Actions)
        {
            bool supported = action.Kind == "retry" ? retry != null : action.Kind == "settings" && settings != null;
            var button = new Button { Content = action.Title, Style = (Style)FindResource("QuotaLinkButton"),
                ContentTemplate = (DataTemplate)FindResource("QuotaActionTitle"), IsEnabled = action.Enabled && supported };
            AutomationProperties.SetAutomationId(button, "deepseek.balance.status." + action.Kind); AutomationProperties.SetName(button, action.Title);
            if (action.Kind == "settings") button.Click += (_, _) => { if (button.IsVisible && button.IsEnabled) settings?.Invoke(); };
            else if (action.Kind == "retry") button.Click += async (_, _) =>
            {
                if (!button.IsVisible || !button.IsEnabled || retry == null) return;
                button.IsEnabled = false;
                try { await retry(); }
                finally { if (button.IsVisible) button.IsEnabled = action.Enabled && supported; }
            };
            row.Children.Add(button);
        }
        Children.Add(row);
    }
}

/// Recovery capsules for quota and balance, as on the Mac: side by side when the
/// column holds their natural widths, otherwise one per line and centered. Only
/// a capsule wider than the column itself trims its label.
internal sealed class QuotaActionRow : Panel
{
    private const double Gap = 6;
    private bool stacked;
    protected override Size MeasureOverride(Size available)
    {
        double total = Math.Max(0, InternalChildren.Count - 1) * Gap, height = 0, widest = 0;
        foreach (UIElement child in InternalChildren) { child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); total += child.DesiredSize.Width; }
        stacked = total > available.Width;
        if (!stacked)
        {
            foreach (UIElement child in InternalChildren) height = Math.Max(height, child.DesiredSize.Height);
            return new Size(total, height);
        }
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(available.Width, double.PositiveInfinity));
            widest = Math.Max(widest, child.DesiredSize.Width); height += child.DesiredSize.Height;
        }
        return new Size(Math.Min(widest, available.Width), height + Math.Max(0, InternalChildren.Count - 1) * Gap);
    }
    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0;
        foreach (UIElement child in InternalChildren)
        {
            var size = child.DesiredSize;
            if (!stacked) { child.Arrange(new Rect(x, 0, size.Width, finalSize.Height)); x += size.Width + Gap; continue; }
            double width = Math.Min(size.Width, finalSize.Width);
            child.Arrange(new Rect((finalSize.Width - width) / 2, y, width, size.Height)); y += size.Height + Gap;
        }
        return finalSize;
    }
}
