using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

internal sealed class QuotaHistoryView : StackPanel
{
    private readonly UiText ui;
    private readonly Brush accent;
    private readonly TextBlock source = Text("", 11.5), freshness = Text("", 11.5), error = Text("", 12), placeholder = Text("", 12), retryError = Text("", 11);
    private readonly StackPanel stale, warning, buckets = new(), expiryDetails = new();
    private readonly Border chartHost = new(), accountDetails;
    private readonly Expander details;
    private readonly Grid accountRow;
    private readonly Button resets, refresh;
    private readonly TextBlock resetText = Text("", 13), balance = Text("", 13);
    private readonly IconGlyph resetArrow, resetChevron;
    private readonly StackPanel account = new();
    private QuotaHistoryChart? chart;
    private QuotaHistoryPresentation? data;
    private bool showExpiries, requestPending, interactionEnabled = true, sourceAvailable = true;
    private string? accountContext;
    internal QuotaHistoryChart? Chart => chart;

    /// <param name="inset">Space around the view; History's card already pads its content, as on the Mac.</param>
    internal QuotaHistoryView(UiText ui, Brush accent, Func<Task> retry, double inset = 10)
    {
        this.ui = ui; this.accent = accent; Margin = new Thickness(inset);
        // One line, as on the Mac: the source, then "Not updated", the freshness and Refresh at its end.
        var heading = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        heading.ColumnDefinitions.Add(new()); for (int column = 0; column < 3; column++) heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        source.Margin = new Thickness(0, 0, 8, 0); source.VerticalAlignment = VerticalAlignment.Center; heading.Children.Add(source);
        stale = Status("clock.arrow.circlepath", ui.Text("common.not_updated")); stale.Margin = new Thickness(0, 0, 6, 0); stale.VerticalAlignment = VerticalAlignment.Center;
        foreach (var part in stale.Children) { if (part is IconGlyph glyph) glyph.Ink = PacerPalette.Attention; else if (part is TextBlock label) { label.Foreground = PacerPalette.Attention; label.FontSize = 11.5; } }
        Grid.SetColumn(stale, 1); heading.Children.Add(stale);
        freshness.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(freshness, 2); heading.Children.Add(freshness);
        refresh = new Button { Content = ui.Text("common.refresh"), Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(refresh, 3); heading.Children.Add(refresh); Children.Add(heading);
        error.Margin = new Thickness(0, 0, 0, 8); error.TextWrapping = TextWrapping.Wrap; error.Foreground = PacerPalette.Attention; Children.Add(error);
        AutomationProperties.SetLiveSetting(error, AutomationLiveSetting.Polite);
        chartHost.Margin = new Thickness(0, 8, 0, 8); Children.Add(chartHost);
        placeholder.Margin = new Thickness(0, 0, 0, 8); Children.Add(placeholder);
        details = new Expander { Header = ui.Text("settings.quota_details"), Content = buckets };
        details.SetResourceReference(StyleProperty, "SettingsCompactDisclosure"); Identify(details, "quota.history.details", ui.Text("settings.quota_details"));
        accountRow = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        accountRow.ColumnDefinitions.Add(new()); accountRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        resets = new Button { Style = PlainButton(), HorizontalAlignment = HorizontalAlignment.Left };
        var resetLabel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 3) };
        resetArrow = new IconGlyph { Symbol = "arrow.counterclockwise", Width = 13, Height = 13, Margin = new Thickness(0, 0, 6, 0) };
        resetChevron = new IconGlyph { Symbol = "chevron.down", Width = 9, Height = 9, Margin = new Thickness(6, 0, 0, 0) };
        resetLabel.Children.Add(resetArrow); resetLabel.Children.Add(resetText); resetLabel.Children.Add(resetChevron); resets.Content = resetLabel;
        resets.Click += (_, _) => { showExpiries = !showExpiries; UpdateDisclosure(); };
        Identify(resets, "quota.history.resets", ""); accountRow.Children.Add(resets);
        var credits = new QuotaReadingHost { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0), ToolTip = ui.Text("account.credits_help") };
        balance.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); credits.Children.Add(balance);
        var creditLabel = Text(ui.Text("account.credits"), 13); creditLabel.Margin = new Thickness(5, 0, 0, 0); credits.Children.Add(creditLabel);
        Grid.SetColumn(credits, 1); accountRow.Children.Add(credits); Identify(credits, "quota.history.credits", ""); account.Children.Add(accountRow);
        accountDetails = new Border { Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromArgb(10, 255, 255, 255)), Child = expiryDetails, Margin = new Thickness(0, 12, 0, 0) };
        account.Children.Add(accountDetails);
        // Chart, then the account, then the details, each after a hairline, as on the Mac.
        Children.Add(Hairline(account)); Children.Add(account); Children.Add(Hairline(details)); Children.Add(details);
        warning = Status("exclamationmark.circle", ui.Text("quota.chart_warning")); Children.Add(warning);
        Identify(refresh, "quota.history.refresh", ui.Text("common.refresh"));
        refresh.Click += async (_, _) =>
        {
            if (requestPending || data?.Refreshing == true || !interactionEnabled) return;
            requestPending = true; retryError.Visibility = Visibility.Collapsed; RefreshButton();
            try { await retry(); }
            catch (Exception exception) when (exception is IOException or InvalidOperationException or OperationCanceledException)
            { retryError.Text = ui.Text("windows.quota.refresh_failed"); retryError.Visibility = Visibility.Visible; }
            finally { requestPending = false; RefreshButton(); }
        };
        retryError.Visibility = Visibility.Collapsed; retryError.Margin = new Thickness(0, 6, 0, 0); retryError.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetLiveSetting(retryError, AutomationLiveSetting.Polite); Children.Add(retryError);
        Update(null);
    }
    internal void SetInteractionEnabled(bool value) { interactionEnabled = value; RefreshButton(); }
    internal void Update(QuotaHistoryPresentation? next)
    {
        sourceAvailable = true;
        var previous = data; data = next;
        source.Text = next?.SourceText ?? ""; freshness.Text = next?.FreshnessText ?? ui.Text("quota.reading");
        stale.Visibility = next?.NotUpdated == true ? Visibility.Visible : Visibility.Collapsed;
        SetText(error, next?.ErrorText); SetText(placeholder, next?.Placeholder ?? (next == null ? ui.Text("quota.loading") : null));
        warning.Visibility = next?.Warning != null ? Visibility.Visible : Visibility.Collapsed; warning.ToolTip = next?.Warning;
        if (next?.Chart != null)
        {
            if (chart == null) { chart = new QuotaHistoryChart(next.Chart, accent); chartHost.Child = chart; }
            else chart.Update(next.Chart);
            chartHost.Visibility = Visibility.Visible;
        }
        else { chartHost.Visibility = Visibility.Collapsed; chartHost.Child = null; chart = null; }
        details.Visibility = next?.Buckets.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (next != null && (previous == null || !SameBuckets(previous, next))) BuildBuckets(next);
        else if (next == null) buckets.Children.Clear();
        account.Visibility = next?.Account != null ? Visibility.Visible : Visibility.Collapsed;
        if (next?.Account is QuotaAccountPresentation usage)
        {
            if (accountContext != usage.Context) { accountContext = usage.Context; showExpiries = false; }
            resetText.Text = usage.ResetText; resets.ToolTip = usage.ExpiryDescription;
            string ink = usage.ExpirySoon ? "SettingsWarning" : "SettingsSecondary";
            resetText.SetResourceReference(TextBlock.ForegroundProperty, ink); resetArrow.SetResourceReference(IconGlyph.InkProperty, ink); resetChevron.SetResourceReference(IconGlyph.InkProperty, ink);
            AutomationProperties.SetName(resets, usage.ResetsAccessibility);
            balance.Text = usage.BalanceText;
            AutomationProperties.SetName(accountRow.Children[1], usage.BalanceAccessibility);
            if (previous?.Account != usage) BuildExpiryDetails(usage);
        }
        else
        {
            accountContext = null; showExpiries = false; expiryDetails.Children.Clear(); resetText.Text = balance.Text = "";
            resets.ToolTip = null; AutomationProperties.SetName(resets, ""); AutomationProperties.SetName(accountRow.Children[1], "");
        }
        UpdateDisclosure(); RefreshButton();
    }
    internal void ShowUnavailable(string message)
    {
        Update(null); sourceAvailable = false; freshness.Text = ui.Text("quota.not_read"); placeholder.Text = message; RefreshButton();
    }
    private static bool SameBuckets(QuotaHistoryPresentation left, QuotaHistoryPresentation right)
        => left.Buckets.Count == right.Buckets.Count && left.Buckets.Zip(right.Buckets).All(pair => pair.First.Id == pair.Second.Id && pair.First.Title == pair.Second.Title && pair.First.Windows.SequenceEqual(pair.Second.Windows));
    private void BuildBuckets(QuotaHistoryPresentation value)
    {
        buckets.Children.Clear();
        foreach (var bucket in value.Buckets)
        {
            var group = new StackPanel { Margin = new Thickness(0, 8, 0, 8) };
            if (bucket.Title != null) group.Children.Add(Text(bucket.Title, 12, FontWeights.Medium));
            foreach (var window in bucket.Windows)
            {
                var reading = new QuotaReadingHost { Margin = new Thickness(0, group.Children.Count > 0 ? 12 : 0, 0, 0) };
                var heading = new LegacyQuotaHeading(window); heading.SetResourceReference(LegacyQuotaHeading.PrimaryProperty, "SettingsPrimary"); heading.SetResourceReference(LegacyQuotaHeading.SecondaryProperty, "SettingsSecondary"); reading.Children.Add(heading);
                var track = new LegacyQuotaTrack(window, accent) { Margin = new Thickness(0, 8, 0, 0), ToolTip = ui.Text("quota.track_help") };
                track.SetResourceReference(LegacyQuotaTrack.ReferenceProperty, "SettingsChartReference"); reading.Children.Add(track);
                var footer = new Grid { Margin = new Thickness(0, 8, 0, 0) };
                footer.ColumnDefinitions.Add(new()); footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                var reset = Text(window.Countdown, 11); reset.ToolTip = window.ResetDate; footer.Children.Add(reset);
                var pace = Text(window.PaceText, 11); pace.Margin = new Thickness(8, 0, 0, 0);
                if (window.PacePercent is < 85) pace.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning"); else if (window.PacePercent is > 115) pace.Foreground = accent;
                Grid.SetColumn(pace, 1); footer.Children.Add(pace); reading.Children.Add(footer);
                AutomationProperties.SetName(reading, window.AccessibilityLabel); AutomationProperties.SetHelpText(reading, window.ResetDate); group.Children.Add(reading);
            }
            buckets.Children.Add(group);
        }
    }
    private void BuildExpiryDetails(QuotaAccountPresentation value)
    {
        expiryDetails.Children.Clear(); var title = Text(ui.Text("account.expiry_title"), 12, FontWeights.Medium); title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); expiryDetails.Children.Add(title);
        void Add(FrameworkElement child) { child.Margin = new Thickness(0, 10, 0, 0); expiryDetails.Children.Add(child); }
        if (value.DetailMessage != null) Add(Text(value.DetailMessage, 12));
        foreach (var expiry in value.Expiries)
        {
            var row = new Grid(); row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var date = Text(expiry.DateText, 12); date.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary"); date.TextWrapping = TextWrapping.Wrap; date.Margin = new Thickness(0, 0, 12, 0); row.Children.Add(date);
            var count = Text(expiry.CountText, 12); Grid.SetColumn(count, 1); row.Children.Add(count);
            var reading = new QuotaReadingHost(); reading.Children.Add(row); AutomationProperties.SetName(reading, expiry.AccessibilityLabel); Add(reading);
        }
        if (value.NonExpiringText != null) Add(Text(value.NonExpiringText, 12));
        if (value.UnknownText != null) { var unknown = Text(value.UnknownText, 12); unknown.TextWrapping = TextWrapping.Wrap; Add(unknown); }
        if (value.TimeZoneText != null) { var zone = Text(value.TimeZoneText, 11); zone.TextWrapping = TextWrapping.Wrap; Add(zone); }
    }
    private void UpdateDisclosure()
    {
        resetChevron.Symbol = showExpiries ? "chevron.up" : "chevron.down";
        accountDetails.Visibility = showExpiries && data?.Account != null ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetHelpText(resets, ui.Text(showExpiries ? "account.hide_expiries" : "account.show_expiries"));
        AutomationProperties.SetItemStatus(resets, ui.Text(showExpiries ? "account.expiries_expanded" : "account.expiries_collapsed"));
    }
    private void RefreshButton()
    {
        bool refreshing = requestPending || data?.Refreshing == true;
        refresh.Content = refreshing ? ui.Text("common.retrying") : data?.RefreshTitle ?? ui.Text("common.refresh");
        AutomationProperties.SetName(refresh, refresh.Content.ToString()); refresh.IsEnabled = !refreshing && interactionEnabled && sourceAvailable;
    }
    private static void SetText(TextBlock control, string? value) { control.Text = value ?? ""; control.Visibility = value == null ? Visibility.Collapsed : Visibility.Visible; }
    private static TextBlock Text(string value, double size, FontWeight? weight = null) => QuotaHistoryChart.Text(value, size, weight: weight);
    /// A hairline that shows and hides with the part it introduces.
    private static Border Hairline(FrameworkElement follows)
    {
        var line = new Border { Height = 1, Margin = new Thickness(0, 4, 0, 4) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
        line.SetBinding(VisibilityProperty, new System.Windows.Data.Binding(nameof(Visibility)) { Source = follows }); return line;
    }
    private static StackPanel Status(string symbol, string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        var icon = new IconGlyph { Symbol = symbol, Width = 11, Height = 11, Margin = new Thickness(0, 0, 5, 0) }; icon.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); row.Children.Add(icon); row.Children.Add(Text(text, 11)); return row;
    }
    private static Style PlainButton()
    {
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        var border = new FrameworkElementFactory(typeof(Border), "focus"); border.SetValue(Border.BorderThicknessProperty, new Thickness(0.5)); border.SetValue(Border.BorderBrushProperty, Brushes.Transparent); border.SetValue(Border.CornerRadiusProperty, new CornerRadius(3)); border.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true }; focus.Setters.Add(new Setter(Border.BorderBrushProperty, new DynamicResourceExtension("SettingsAccent"), "focus")); template.Triggers.Add(focus);
        var style = new Style(typeof(Button)); style.Setters.Add(new Setter(Control.TemplateProperty, template)); return style;
    }
    private static void Identify(DependencyObject target, string id, string name) { AutomationProperties.SetAutomationId(target, id); AutomationProperties.SetName(target, name); }
}
