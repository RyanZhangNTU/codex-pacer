using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// The Mac main window's card pieces: gray section titles over rounded cards of
/// 44-point rows, explanations behind an ⓘ that opens under the row, status
/// rows with a colored dot, and folding rows.
internal sealed partial class SettingsWindow
{
    /// A small gray title over a card, like the Mac's section labels.
    private TextBlock SectionTitle(string text, double top = 10)
    {
        var title = Label(text, 12, FontWeights.SemiBold); title.Margin = new Thickness(4, top, 0, 8);
        title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2);
        return title;
    }

    /// A gray note under a card.
    private TextBlock CardFooter(string text)
    {
        var note = Detail(text); note.FontSize = 11.5; note.Margin = new Thickness(4, -4, 4, 12); return note;
    }

    /// One row: a title with an optional ⓘ, an optional line under it, then the
    /// row's own control at its end. The ⓘ opens the explanation under the row.
    private Grid InfoRow(string title, UIElement? trailing, string? info = null, TextBlock? detail = null, string? id = null, double minHeight = 44)
    {
        var row = new Grid { MinHeight = minHeight, Margin = new Thickness(14, 0, 14, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 8, 8, 8) };
        // A wrap panel lets a long title wrap in a narrow card instead of being clipped.
        var heading = new WrapPanel();
        var label = Label(title); label.TextWrapping = TextWrapping.Wrap; heading.Children.Add(label);
        text.Children.Add(heading);
        if (detail != null) { detail.Margin = new Thickness(0, 2, 0, 0); text.Children.Add(detail); }
        row.Children.Add(text);
        if (trailing is FrameworkElement end) { end.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(end, 1); row.Children.Add(end); }
        else if (trailing != null) { Grid.SetColumn(trailing, 1); row.Children.Add(trailing); }
        if (info != null)
        {
            var box = InfoBox(info); Grid.SetRow(box, 1); Grid.SetColumnSpan(box, 2); row.Children.Add(box);
            heading.Children.Add(InfoButton(title, box, id));
            if (trailing != null) AutomationProperties.SetHelpText(trailing, info);
        }
        return row;
    }

    private Border InfoBox(string text)
    {
        var body = Label(text, 12); body.TextWrapping = TextWrapping.Wrap; body.LineHeight = 17;
        body.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        var box = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(11, 9, 11, 9), Margin = new Thickness(0, 0, 0, 10), Child = body, Visibility = Visibility.Collapsed };
        box.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        return box;
    }

    /// The ⓘ beside a title; it shows or hides the explanation under the row.
    private Button InfoButton(string title, UIElement box, string? id)
    {
        var glyph = new IconGlyph { Symbol = "info.circle", Width = 14, Height = 14 };
        glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var button = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 22, Height = 22, Padding = new Thickness(0), Margin = new Thickness(3, -2, 0, -2), Content = glyph, VerticalAlignment = VerticalAlignment.Center };
        string name = ui.Text("main.info").Replace("%@", title, StringComparison.Ordinal);
        Identify(button, (id ?? "settings.row") + ".info", name);
        AutomationProperties.SetItemStatus(button, ui.Text("main.info_hidden"));
        button.Click += (_, _) =>
        {
            bool show = box.Visibility != Visibility.Visible;
            box.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            glyph.SetResourceReference(IconGlyph.InkProperty, show ? "SettingsPrimary" : "SettingsSecondary");
            AutomationProperties.SetItemStatus(button, ui.Text(show ? "main.info_shown" : "main.info_hidden"));
        };
        return button;
    }

    /// A row that only reports: a colored dot and its state, then any action.
    private Grid StatusRow(string title, out Ellipse dot, out TextBlock state, UIElement? action = null, TextBlock? detail = null)
    {
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        dot = new Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        dot.SetResourceReference(Shape.FillProperty, "SettingsSecondary");
        state = Label("", 12.5); state.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        trailing.Children.Add(dot); trailing.Children.Add(state);
        if (action is FrameworkElement end) { end.Margin = new Thickness(8, 0, 0, 0); trailing.Children.Add(end); }
        return InfoRow(title, trailing, detail: detail);
    }

    /// Colors a status row: green when ready, amber when it needs the user, gray otherwise.
    private static void SetStatus(Ellipse? dot, TextBlock? state, string text, string tone)
    {
        if (state != null)
        {
            state.Text = text; AutomationProperties.SetName(state, text);
            state.SetResourceReference(TextBlock.ForegroundProperty, tone == "attention" ? "SettingsWarning" : "SettingsSecondary");
        }
        dot?.SetResourceReference(Shape.FillProperty, tone switch { "positive" => "SettingsSuccess", "attention" => "SettingsWarning", _ => "SettingsSecondary" });
    }

    /// A folding row: chevron, title and a summary (its Tag) at the end; its content follows while open.
    private Expander Disclosure(string title, UIElement content, bool expanded, string id)
    {
        var expander = new Expander { Header = title, Style = (Style)FindResource("SettingsDisclosure"), IsExpanded = expanded, Content = content };
        Identify(expander, id, title); return expander;
    }

    /// The page header for a service: its tile, name and detection line, a way
    /// back to automatic detection, and the module switch at the end.
    private Grid ProviderHeader(string provider, out TextBlock detection, out CheckBox module, out Button automatic)
    {
        var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Color color = ProviderTint(provider);
        Color lighter = Color.FromRgb((byte)Math.Min(255, color.R + 10), (byte)Math.Min(255, color.G + 10), (byte)Math.Min(255, color.B + 10));
        var tile = new Border { Width = 40, Height = 40, CornerRadius = new CornerRadius(10.4), Background = new LinearGradientBrush(lighter, color, 90), Margin = new Thickness(0, 0, 14, 0),
            Child = new IconGlyph { Symbol = PaneSymbol(provider), Width = 26, Height = 26, Ink = new SolidColorBrush(Color.FromArgb(184, 0, 0, 0)) }, VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(tile);
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = Label(PaneTitle(provider), 22, FontWeights.Bold); AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1); names.Children.Add(title);
        var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
        detection = Label("", 12.5); detection.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); line.Children.Add(detection);
        automatic = new Button { Content = ui.Text("provider.restore_automatic"), Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        line.Children.Add(automatic); names.Children.Add(line);
        Grid.SetColumn(names, 1); header.Children.Add(names);
        module = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(module, 2); header.Children.Add(module);
        return header;
    }

    private readonly System.Collections.Generic.Dictionary<string, (TextBlock Summary, Button Trend, Button Retry)> quotaRows = new();

    /// Shown in place of a service page's cards while its module is off.
    private Border ModuleOffCard()
    {
        var hint = Label(ui.Text("main.module_off_hint")); hint.TextWrapping = TextWrapping.Wrap; hint.Margin = new Thickness(0, 12, 0, 12);
        var card = Card(Row(hint, new Border())); card.Visibility = Visibility.Collapsed; return card;
    }

    /// A service's quota in one line: what is left in each window and a link to
    /// its trend on History, or the error with Retry.
    private Grid ProviderQuotaRow(string provider)
    {
        var end = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var summary = Label("", 12.5); summary.TextTrimming = TextTrimming.CharacterEllipsis; summary.MaxWidth = 360;
        Identify(summary, "settings." + provider + ".quota", ""); end.Children.Add(summary);
        var trend = new Button { Content = ui.Text("main.quota.trend"), Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Identify(trend, "settings." + provider + ".quota_trend", ui.Text("main.quota.trend"));
        trend.Click += async (_, _) => { historyProvider = provider; await NavigateAsync("history"); };
        end.Children.Add(trend);
        var retry = new Button { Content = ui.Text("connections.retry"), Margin = new Thickness(8, 0, 0, 0), Visibility = Visibility.Collapsed };
        Identify(retry, "settings." + provider + ".quota_retry", ui.Text("connections.retry"));
        retry.Click += async (_, _) => { await sourceReady; if (!sourceClosed && engine != null) await engine.SendAsync("retryQuota", new { provider }); };
        end.Children.Add(retry);
        quotaRows[provider] = (summary, trend, retry);
        return InfoRow(ui.Text("main.quota"), end);
    }

    private void RefreshProviderQuotaRow(string provider)
    {
        if (!quotaRows.TryGetValue(provider, out var row)) return;
        var dashboard = engine?.LatestSnapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == provider);
        bool closed = providerConnectionClosed || engine?.IsConnectionClosed != false;
        string? error = closed ? ui.Text("windows.connection.closed") : dashboard?.Status is { State: "error" } status ? status.Message ?? ui.Text("provider.state.failed") : null;
        if (error != null)
        {
            row.Summary.Text = error; row.Summary.ToolTip = error; row.Summary.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
            row.Trend.Visibility = Visibility.Collapsed; row.Retry.Visibility = Visibility.Visible;
            row.Retry.IsEnabled = !closed && !busy && !session.RequiresRestart && dashboard?.History?.Refreshing != true;
        }
        else
        {
            var parts = new System.Collections.Generic.List<string>();
            foreach (var (reading, key) in new[] { (dashboard?.FiveHour, "main.quota.left_5h"), (dashboard?.Weekly, "main.quota.left_7d") })
                if (reading?.RemainingPercent != null)
                    parts.Add(ui.Text(key).Replace("%@", reading.ValueText, StringComparison.Ordinal).Replace("%%", "%", StringComparison.Ordinal));
            row.Summary.Text = parts.Count > 0 ? string.Join(" · ", parts) : dashboard?.FiveHour.FreshnessText is { Length: > 0 } fresh ? fresh : ui.Text("provider.state.searching");
            row.Summary.ToolTip = null; row.Summary.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            row.Trend.Visibility = Visibility.Visible; row.Retry.Visibility = Visibility.Collapsed;
        }
        AutomationProperties.SetName(row.Summary, row.Summary.Text);
    }

    /// Replaces the plain page title with a page's own header.
    private void SetPaneHeader(UIElement content)
    {
        headerColumn.Children.Clear(); headerColumn.Children.Add(content);
    }
}
