using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// The time dial keeps its original 88/104-point face, provider caption,
/// stale marker and doubled-price chip in both dashboard styles.
internal sealed class DeepSeekQuotaCell : StackPanel
{
    internal Grid Face { get; }
    /// <param name="showsName">Overview's card already names the service, so its dial leaves the name out, as on the Mac.</param>
    /// <param name="budgetDial">The panel shows the budget dial when a budget is set; off keeps today's dial.</param>
    internal DeepSeekQuotaCell(EngineWallet? wallet, UiText ui, double size = 104, Action? connectAction = null, string? connectUnavailable = null, FrameworkElement? balanceStatus = null, bool showsName = true,
        bool budgetDial = true)
    {
        var budget = budgetDial ? wallet?.Solo?.Budgets : null;
        var dial = new QuotaDial("deepseek", null, wallet, dialSize: size) { Width = size, Height = size };
        var face = new Grid { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center }; Face = face;
        face.Children.Add(budget?.Count > 0 ? new DeepSeekBudgetDial(budget, ui, size) : dial); Children.Add(face);
        if (budget?.Count is not > 0 && wallet?.Dial?.ConnectTitle is string title)
        {
            var connect = new Button { Content = title, Style = (Style)FindResource("QuotaLinkButton"), IsEnabled = connectAction != null,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, dial.ConnectButtonTop, 0, 0) };
            AutomationProperties.SetAutomationId(connect, "deepseek.balance.connect");
            if (connectAction == null) AutomationProperties.SetHelpText(connect, connectUnavailable ?? ui.Text("windows.deepseek.runtime_required"));
            connect.Click += (_, _) => { if (connect.IsVisible && connect.IsEnabled) connectAction?.Invoke(); };
            AutomationProperties.SetName(connect, title); face.Children.Add(connect);
        }
        var caption = new QuotaReadingHost { Orientation = Orientation.Horizontal, Height = 15, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 6) };
        AutomationProperties.SetName(caption, budget?.Count > 0 ? "DeepSeek" + (budget[0].Verdict == "fast" ? ", " + budget[0].VerdictText : "")
            : wallet?.Dial?.StaleCaption == true ? "DeepSeek, " + ui.Text("common.not_updated") : "DeepSeek" + (wallet?.Dial?.PeakText is string peak ? ", " + peak : ""));
        if (showsName)
        {
            caption.Children.Add(ProviderIcon.Caption("deepseek"));
            caption.Children.Add(new TextBlock { Text = "DeepSeek", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = PacerPalette.Primary, VerticalAlignment = VerticalAlignment.Center });
        }
        if (budget?.Count > 0)
        {
            if (budget[0].Verdict == "fast")
            { var chip = DeepSeekBudgetDetails.Chip(budget[0], ui); chip.Margin = new Thickness(showsName ? 5 : 0, 0, 0, 0); caption.Children.Add(chip); }
        }
        else if (wallet?.Dial?.StaleCaption == true)
        {
            var stale = new IconGlyph { Symbol = "clock.arrow.circlepath", Width = 9, Height = 9, Ink = PacerPalette.Attention, Margin = new Thickness(5, 0, 0, 0) };
            caption.Children.Add(stale);
        }
        else if (wallet?.Dial?.PeakText is string peakText)
        {
            caption.Children.Add(new Border { CornerRadius = new CornerRadius(7.5), Height = 15, Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(5, 0, 0, 0),
                Background = PacerPalette.Ink(255, 189, 97, 36),
                Child = new TextBlock { Text = peakText, FontFamily = PacerFonts.Interface, FontSize = 10, FontWeight = FontWeights.Bold, Foreground = PacerPalette.Attention, VerticalAlignment = VerticalAlignment.Center } });
            if (wallet?.Dial?.PeakHelp is string peakHelp) AutomationProperties.SetHelpText(caption, peakHelp);
        }
        Children.Add(caption);
        if (balanceStatus != null) Children.Add(balanceStatus);
        string? help = budget?.Count > 0 ? string.Join("\n\n", System.Linq.Enumerable.Select(budget, value => value.Help)) : wallet?.Dial?.Help;
        if (help != null) AutomationProperties.SetHelpText(this, help);
    }
}
