using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

internal static class HarnessAccountCard
{
    internal static FrameworkElement Build(UiText ui, HarnessAccountConnection? connection, bool island, string id,
        bool classic = false, bool details = true, bool showsName = false, Action? openSettings = null)
    {
        var body = new StackPanel();
        bool compact = island && !details;
        string Format(double value) => Amount(ui, value);
        string Date(DateTimeOffset value) => value.ToLocalTime().ToString("g", Culture(ui));
        void Line(string text, string field, bool strong = false, bool attention = false)
        {
            var label = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = strong ? 18 : 12,
                FontWeight = strong ? FontWeights.SemiBold : FontWeights.Normal, Margin = new Thickness(0, strong ? 0 : 3, 0, 0) };
            if (island) label.Foreground = attention ? PacerPalette.Attention : strong ? PacerPalette.Primary : PacerPalette.Secondary;
            else label.SetResourceReference(TextBlock.ForegroundProperty, strong ? "SettingsPrimary" : "SettingsSecondary");
            AutomationProperties.SetAutomationId(label, id + "." + field);
            AutomationProperties.SetName(label, text);
            body.Children.Add(label);
        }
        string state = connection?.Busy == true ? "reading" : connection?.State == "unavailable" ? "unavailable" : "sign_in";
        string stateText = ui.Text("harness.account." + state);
        string help = stateText;
        if (connection?.Reading is { } reading)
        {
            if (!island) Line(AvailableText(ui, reading.Remaining), "remaining", strong: true);
            string total = Fields(ui, "harness.account.total", Format(reading.Total));
            var readings = new List<string> { total };
            if (!compact && reading.Plan is string plan) Line(plan, "plan");
            if (reading.Cycle is { } cycle)
            {
                string left = Fields(ui, "harness.account.cycle_remaining", Format(cycle.Remaining), Format(cycle.Total));
                readings.Add(left);
                if (!compact) Line(left, "cycle");
                if (!compact && cycle.Used is double used) Line(Fields(ui, "harness.account.cycle_used", Format(used)), "used");
                if (cycle.ResetsAt is { } reset && reset > DateTimeOffset.UtcNow)
                {
                    string renews = Fields(ui, "harness.account.cycle_reset", Date(reset));
                    readings.Add(renews);
                    if (!compact) Line(renews, "reset");
                }
            }
            if (reading.Expiration is { } expiration && expiration.At > DateTimeOffset.UtcNow)
            {
                string expires = Fields(ui, "harness.account.expiring", Format(expiration.Credits), Date(expiration.At));
                readings.Add(expires);
                if (!compact || connection.State == "ready")
                    Line(expires, "expiring", attention: expiration.At - DateTimeOffset.UtcNow < TimeSpan.FromDays(3));
            }
            if (!island)
            {
                Line(total, "total");
                if (reading.Reserved > 0) Line(Fields(ui, "harness.account.reserved", Format(reading.Reserved)), "reserved");
            }
            if (connection.State == "unavailable") Line(compact ? ui.Text("common.not_updated") : stateText, "state");
            help = string.Join("\n", readings);
        }
        else if (!compact) Line(stateText, "state");
        if (island && connection?.Reading == null && openSettings != null)
        {
            var open = new Button { Content = ui.Text("harness.account.connect"), HorizontalAlignment = compact ? HorizontalAlignment.Center : HorizontalAlignment.Left,
                Margin = new Thickness(0, 3, 0, 0), FontSize = 11 };
            open.SetResourceReference(FrameworkElement.StyleProperty, "QuotaLinkButton");
            AutomationProperties.SetAutomationId(open, id + ".settings");
            AutomationProperties.SetHelpText(open, stateText);
            open.Click += (_, _) => { if (open.IsVisible) openSettings(); };
            body.Children.Add(open);
        }

        if (!island) return body;
        double size = classic ? 88 : 104;
        var dial = new QuotaDial("workbuddy", null, null, classic: classic, dialSize: size, account: connection?.Reading,
            accountText: ui, accountStale: connection?.State == "unavailable")
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
            caption.Children.Add(ProviderIcon.Caption("workbuddy"));
            caption.Children.Add(new TextBlock { Text = "WorkBuddy", FontSize = 11, FontWeight = FontWeights.SemiBold,
                Foreground = PacerPalette.Primary, VerticalAlignment = VerticalAlignment.Center });
            cell.Children.Add(caption);
        }
        body.HorizontalAlignment = HorizontalAlignment.Center;
        body.MaxWidth = 130;
        cell.Children.Add(body);
        return cell;
    }

    private static CultureInfo Culture(UiText ui) => CultureInfo.GetCultureInfo(ui.Language == "zh-Hans" ? "zh-CN" : "en-US");
    internal static string Amount(UiText ui, double value) => value > 0 && value < 0.01 ? "<0.01" : value.ToString("#,0.##", Culture(ui));
    internal static string AvailableText(UiText ui, double amount) => Fields(ui, "harness.account.remaining", Amount(ui, amount));
    private static string Fields(UiText ui, string key, params string[] values)
    {
        var pieces = ui.Text(key).Split("%@", StringSplitOptions.None);
        return pieces.Length == values.Length + 1 ? string.Concat(System.Linq.Enumerable.Select(pieces, (piece, i) => piece + (i < values.Length ? values[i] : ""))) : ui.Text(key);
    }
}
