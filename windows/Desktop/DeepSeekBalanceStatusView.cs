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
        var row = new DeepSeekActionRow { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
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

/// Keep natural capsule widths when possible. In narrow provider columns,
/// divide remaining space between flexible labels instead of overlapping them.
internal sealed class DeepSeekActionRow : Panel
{
    private double[] natural = [];
    protected override Size MeasureOverride(Size available)
    {
        natural = new double[InternalChildren.Count]; double total = Math.Max(0, InternalChildren.Count - 1) * 6;
        for (int i = 0; i < InternalChildren.Count; i++)
        { InternalChildren[i].Measure(new Size(double.PositiveInfinity, available.Height)); natural[i] = InternalChildren[i].DesiredSize.Width; total += natural[i]; }
        double width = Math.Min(total, available.Width), height = 0;
        var sizes = Widths(width);
        for (int i = 0; i < InternalChildren.Count; i++)
        { InternalChildren[i].Measure(new Size(sizes[i], available.Height)); height = Math.Max(height, InternalChildren[i].DesiredSize.Height); }
        return new Size(width, height);
    }
    private double[] Widths(double width)
    {
        var result = (double[])natural.Clone(); double remaining = Math.Max(0, width - Math.Max(0, result.Length - 1) * 6);
        var order = new int[result.Length]; for (int i = 0; i < order.Length; i++) order[i] = i;
        Array.Sort(order, (a,b) => natural[a].CompareTo(natural[b]));
        for (int i = 0; i < order.Length; i++) { int index = order[i]; result[index] = Math.Min(natural[index], remaining / (order.Length - i)); remaining -= result[index]; }
        return result;
    }
    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0; var sizes = Widths(finalSize.Width);
        for (int i = 0; i < InternalChildren.Count; i++) { InternalChildren[i].Arrange(new Rect(x, 0, sizes[i], finalSize.Height)); x += sizes[i] + 6; }
        return finalSize;
    }
}
