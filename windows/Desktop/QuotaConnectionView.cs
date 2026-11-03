using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed class QuotaConnectionView : StackPanel
{
    internal QuotaConnectionView(string provider, QuotaConnectionStatus status, UiText ui, Func<Task>? retry, Action? settings)
    {
        HorizontalAlignment = HorizontalAlignment.Stretch;
        if (status.State == "hidden") return;
        if (!string.IsNullOrEmpty(status.Message))
        {
            var message = new TextBox { Text = status.Message, IsReadOnly = true, IsReadOnlyCaretVisible = false,
                BorderThickness = new Thickness(0), Padding = new Thickness(0), Background = Brushes.Transparent,
                Foreground = status.State == "error" ? PacerPalette.Attention : PacerPalette.Secondary,
                FontFamily = PacerFonts.Interface, FontSize = 11, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
            AutomationProperties.SetName(message, status.Message); Children.Add(message);
        }
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, Children.Count > 0 && status.Actions.Count > 0 ? 6 : 0, 0, 0) };
        foreach (var action in status.Actions)
        {
            bool supported = action.Kind == "retry" ? retry != null : action.Kind == "settings" && settings != null;
            var button = new Button { Style = (Style)FindResource("QuotaLinkButton"), Content = action.Title,
                IsEnabled = action.Enabled && supported, Margin = new Thickness(actions.Children.Count > 0 ? 6 : 0, 0, 0, 0) };
            AutomationProperties.SetName(button, action.Title); AutomationProperties.SetAutomationId(button, "quota." + provider + "." + action.Kind);
            if (!supported)
            {
                button.ToolTip = ui.Text(action.Kind == "settings" ? "windows.settings.pane_pending" : "windows.quota.retry_pending");
                ToolTipService.SetShowOnDisabled(button, true);
            }
            if (action.Kind == "settings") button.Click += (_, _) => settings?.Invoke();
            else if (action.Kind == "retry") button.Click += async (_, _) =>
            {
                if (retry == null) return;
                button.IsEnabled = false;
                try { await retry(); }
                finally { button.IsEnabled = action.Enabled && supported; }
            };
            actions.Children.Add(button);
        }
        Children.Add(actions);
    }
}
