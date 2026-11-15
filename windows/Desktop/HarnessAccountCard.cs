using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

/// A credits module in the island, Overview or a quota cell: Core's dial, and
/// its summary lines beside it when there is room. The ring is the month's
/// credits; extra credits sit in its gap as an amount.
internal static class HarnessAccountCard
{
    internal static FrameworkElement Build(UiText ui, string provider, HarnessAccountConnection? connection, EngineAccountCredits? credits,
        bool island, string id, bool classic = false, bool details = true, bool showsName = false, Action? openSettings = null, string? name = null)
    {
        var presentation = credits?.Presentation;
        bool stale = credits?.Stale == true || connection?.State == "unavailable";
        var body = new StackPanel();
        void Line(string text, string field, bool attention = false)
        {
            var label = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 3, 0, 0) };
            if (island) label.Foreground = attention ? PacerPalette.Attention : PacerPalette.Secondary;
            else label.SetResourceReference(TextBlock.ForegroundProperty, attention ? "SettingsWarning" : "SettingsSecondary");
            AutomationProperties.SetAutomationId(label, id + "." + field);
            AutomationProperties.SetName(label, text);
            body.Children.Add(label);
        }
        string state = connection?.Busy == true ? "reading" : connection?.State == "unavailable" ? "unavailable" : "sign_in";
        string stateText = ui.Text("harness.account." + state);
        string help = presentation == null ? stateText
            : string.Join("\n", presentation.Lines.Select(line => line.Label + " " + line.Value + (line.Detail is string detail ? " · " + detail : "")));
        if (presentation != null)
        {
            if (details)
                for (int index = 0; index < presentation.Lines.Count; index++)
                {
                    var line = presentation.Lines[index];
                    Line(line.Label + "  " + line.Value + (line.Detail is string detail ? " · " + detail : ""), "line" + index, line.Warns);
                }
            if (stale) Line(ui.Text("common.not_updated"), "state");
        }
        else if (details) Line(stateText, "state");
        // Signing in starts here, as DeepSeek's and Claude's do.
        if (presentation == null && (connection != null || openSettings != null))
        {
            var open = new Button { Content = ui.Text("welcome.module.sign_in"), HorizontalAlignment = details ? HorizontalAlignment.Left : HorizontalAlignment.Center,
                Margin = new Thickness(0, 3, 0, 0), FontSize = 11 };
            open.SetResourceReference(FrameworkElement.StyleProperty, "QuotaLinkButton");
            // The same title template as DeepSeek's actions, so the text follows the island's light or dark ink.
            open.SetResourceReference(ContentControl.ContentTemplateProperty, "QuotaActionTitle");
            AutomationProperties.SetAutomationId(open, id + ".sign_in");
            AutomationProperties.SetHelpText(open, stateText);
            open.Click += async (_, _) =>
            {
                if (!open.IsVisible) return;
                if (connection is { Available: true, Busy: false }) await connection.ConnectAsync();
                else openSettings?.Invoke();
            };
            body.Children.Add(open);
        }

        double size = classic ? 88 : 104;
        var dial = new QuotaDial(provider, null, null, classic: classic, dialSize: size, credits: presentation?.Dial, creditsText: ui, creditsStale: stale)
        { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center };
        AutomationProperties.SetAutomationId(dial, id + ".remaining");
        AutomationProperties.SetHelpText(dial, help);
        dial.ToolTip = help;
        if (details)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new() { Width = new GridLength(size) });
            row.ColumnDefinitions.Add(new() { Width = new GridLength(20) });
            row.ColumnDefinitions.Add(new());
            row.Children.Add(dial);
            body.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(body, 2); row.Children.Add(body);
            return row;
        }
        var cell = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch };
        cell.Children.Add(dial);
        if (showsName)
        {
            var caption = new StackPanel { Orientation = Orientation.Horizontal, Height = 15, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 3) };
            caption.Children.Add(ProviderIcon.Caption(provider));
            caption.Children.Add(new TextBlock { Text = name ?? provider, FontSize = 11, FontWeight = FontWeights.SemiBold,
                Foreground = PacerPalette.Primary, VerticalAlignment = VerticalAlignment.Center });
            cell.Children.Add(caption);
        }
        body.HorizontalAlignment = HorizontalAlignment.Center;
        body.MaxWidth = 130;
        cell.Children.Add(body);
        return cell;
    }

    internal static CultureInfo Culture(UiText ui) => CultureInfo.GetCultureInfo(ui.Language == "zh-Hans" ? "zh-CN" : "en-US");
    internal static string Amount(UiText ui, double value) => value > 0 && value < 0.01 ? "<0.01" : value.ToString("#,0.##", Culture(ui));
    internal static string AvailableText(UiText ui, double amount) => Fields(ui, "harness.account.remaining", Amount(ui, amount));
    internal static string Fields(UiText ui, string key, params string[] values)
    {
        var pieces = ui.Text(key).Split("%@", StringSplitOptions.None);
        return pieces.Length == values.Length + 1 ? string.Concat(pieces.Select((piece, i) => piece + (i < values.Length ? values[i] : ""))) : ui.Text(key);
    }
}
