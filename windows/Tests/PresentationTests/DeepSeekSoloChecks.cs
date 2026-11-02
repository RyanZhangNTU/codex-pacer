using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class DeepSeekSoloChecks
{
    internal static async Task Run(string language, bool motion, string output)
    {
        CultureInfo before = CultureInfo.CurrentUICulture;
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
        await using var engine = new EngineClient();
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: motion) { IsHitTestVisible = false, ShowActivated = false };
        var ui = UiText.For(language == "zh-Hans");
        try
        {
            island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            await engine.SendAsync("configure", new { enabledProviders = new[] { "deepseek" } });
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            var view = Descendants(island).OfType<DeepSeekSoloView>().Single();
            var wallet = engine.LatestSnapshot!.Wallet!;
            Check(Descendants(view).OfType<QuotaDial>().Single().ActualWidth == 132, "DeepSeek alone must use the original 132-point time dial");
            Check(Descendants(view).OfType<DeepSeekSpeedView>().Count() == 1 && Descendants(view).OfType<DeepSeekDistributionView>().Count() == 1
                && Descendants(view).OfType<DeepSeekWeekView>().Count() == 1, "The actual shared engine fixture must expose speed, spend and seven-day history");
            Check(Descendants(view).OfType<DeepSeekWeekPlot>().Single().ActualHeight == 44 && Descendants(view).OfType<DeepSeekSpeedPlot>().Single().ActualHeight == 22,
                "The original chart heights must remain 44 and 22 points");
            Check(UIElementAutomationPeer.CreatePeerForElement(Descendants(view).OfType<DeepSeekSpeedView>().Single()).GetName() == wallet.Solo!.Speed!.AccessibilityLabel
                && UIElementAutomationPeer.CreatePeerForElement(Descendants(view).OfType<DeepSeekWeekView>().Single()).GetName() == wallet.Solo.Week!.AccessibilityLabel,
                "Charts must expose their actual shared readings once to accessibility");
            CheckBounds(view);
            Check(Descendants(island).OfType<ScrollViewer>().First().ScrollableHeight < .1,
                "A naturally fitted solo panel must not introduce a scrollbar for a fractional text line");
            island.CapturePreview(Path.Combine(output, "deepseek-solo-" + language + (motion ? "-motion" : "-reduced") + ".png"));
            string[] titles = wallet.Solo!.Distribution!.Parts.Where(part => !part.Elsewhere && part.Opacity >= .6).Select(part => part.Title).ToArray();
            await engine.SendAsync("configure", new { hideProjects = true }); await Pump();
            await island.WaitForPresentationAsync();
            Check(!Descendants(island).OfType<TextBlock>().Any(text => titles.Contains(text.Text))
                && titles.All(title => !JsonSerializer.Serialize(engine.LatestSnapshot).Contains(title, StringComparison.Ordinal)),
                "Changing privacy must remove every task name from the live solo panel and snapshot");
            island.ApplyPreferences(new DesktopPreferences { ExpandedQuotaStyle = "classic" }); await island.WaitForPresentationAsync();
            Check(Descendants(island).OfType<DeepSeekSoloView>().Count() == 1 && Descendants(island).OfType<QuotaDial>().Single().ActualWidth == 132,
                "The original DeepSeek solo exception applies in both dashboard styles");
            if (!motion) await States(wallet, ui, language, output);
            await engine.SendAsync("configure", new { enabledProviders = new[] { "codex", "claude", "deepseek" }, hideProjects = false });
            island.ApplyPreferences(new DesktopPreferences()); await island.WaitForPresentationAsync();
            Check(!Descendants(island).OfType<DeepSeekSoloView>().Any() && Descendants(island).OfType<QuotaDial>().Count() == 3
                && island.LogicalTarget.Height == 440, "Returning to all providers must restore the original compact quota row without stale solo height");
            Console.WriteLine("PASS DeepSeek solo " + language + (motion ? "-motion" : "-reduced") + ": real engine routing, 132-point dial, charts, privacy, classic exception and multi-provider restore");
        }
        finally { island.StopPresentation(); island.AllowClose = true; island.Close(); CultureInfo.CurrentUICulture = before; }
    }
    private static async Task States(EngineWallet original, UiText ui, string language, string output)
    {
        var solo = original.Solo!;
        var fixtures = new List<(string Name, EngineWallet Wallet, bool Detailed)>
        {
            ("quiet", original with { Solo = solo with { Speed = null, Distribution = null, Week = null } }, true),
            ("simple", original, false),
            ("detailed", original, true),
            ("daily", original with { Solo = solo with { Budgets = new[] { Budget("day", false, ui) } } }, true),
            ("dual", original with { Solo = solo with { Budgets = new[] { Budget("day", false, ui), Budget("week", false, ui) } } }, true),
            ("exceeded", original with { Solo = solo with { Budgets = new[] { Budget("day", true, ui) } } }, true)
        };
        var measurements = new List<object>();
        foreach (var (name, wallet, detailed) in fixtures)
        {
            int opened = 0;
            var view = new DeepSeekSoloView(wallet, ui, detailed, () => opened++);
            Check(Descendants(view).OfType<DeepSeekWeekView>().Count() == (detailed && wallet.Solo!.Week != null ? 1 : 0),
                "History must appear exactly once when the shared projection supplies it and detailed mode is enabled");
            var host = new Grid { Background = Brushes.Black }; var panel = new Border { Width = 392, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(10), Child = view }; host.Children.Add(panel);
            var window = new Window { Width = 412, Height = 360, Content = host, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
            try
            {
                window.Show(); await Pump(); view.UpdateLayout(); CheckBounds(view);
                bool budget = wallet.Solo!.Budgets.Count > 0;
                Check(Descendants(view).OfType<DeepSeekBudgetDial>().Count() == (budget ? 1 : 0) && Descendants(view).OfType<QuotaDial>().Count() == (budget ? 0 : 1), "A budget replaces the price dial without stacking both faces");
                if (name == "quiet") Check(!Descendants(view).OfType<DeepSeekSpeedView>().Any() && !Descendants(view).OfType<DeepSeekDistributionView>().Any() && !Descendants(view).OfType<DeepSeekWeekView>().Any(), "A quiet day must omit inactive sections");
                if (name == "simple") Check(Descendants(view).OfType<DeepSeekSpeedView>().Any() && !Descendants(view).OfType<DeepSeekDistributionView>().Any() && !Descendants(view).OfType<DeepSeekWeekView>().Any(), "The original simple panel keeps speed while omitting distribution and history");
                if (detailed && wallet.Solo.Distribution != null)
                {
                    var link = Descendants(view).OfType<Button>().Single(value => AutomationProperties.GetAutomationId(value) == "deepseek.usage");
                    Check(new ButtonAutomationPeer(link).GetName() == wallet.Solo.Distribution.UsageTitle, "The usage link needs the original accessible action name");
                    ((IInvokeProvider)new ButtonAutomationPeer(link).GetPattern(PatternInterface.Invoke)).Invoke(); await Pump();
                    Check(opened == 1, "The information mark must invoke the usage action exactly once");
                }
                if (budget)
                {
                    Check(UIElementAutomationPeer.CreatePeerForElement(Descendants(view).OfType<DeepSeekBudgetDial>().Single()).GetName().Contains(wallet.Solo.Budgets[0].Whole + wallet.Solo.Budgets[0].Cents), "Budget accessibility must include the actual money remaining");
                    var compact = new DeepSeekQuotaCell(wallet with { Dial = wallet.Dial! with { StaleCaption = true } }, ui, 88);
                    compact.Measure(new Size(120, double.PositiveInfinity)); compact.Arrange(new Rect(0, 0, 120, compact.DesiredSize.Height));
                    Check(compact.Face.Children.Count == 1 && compact.Face.Children[0] is DeepSeekBudgetDial && compact.ToolTip is string help && help.Contains(wallet.Solo.Budgets[0].Help),
                        "The compact provider cell must switch to the same budget and its help, including while the unrelated account balance is stale");
                    Check(!UIElementAutomationPeer.CreatePeerForElement(compact.Children.OfType<QuotaReadingHost>().Single()).GetName().Contains(ui.Text("common.not_updated")),
                        "A live local budget caption must not announce the stale account balance");
                }
                var bitmap = new RenderTargetBitmap(412, 360, 96, 96, PixelFormats.Pbgra32); bitmap.Render(host);
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(Path.Combine(output, "deepseek-solo-state-" + name + "-" + language + ".png")); png.Save(stream);
                measurements.Add(new { name, contentWidth = 392, contentHeight = view.ActualHeight + 4, dpi = VisualTreeHelper.GetDpi(window).PixelsPerInchX, acceptance = "pending" });
            }
            finally { window.Close(); }
        }
        File.WriteAllText(Path.Combine(output, "deepseek-solo-states-" + language + ".json"), JsonSerializer.Serialize(measurements, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static DeepSeekBudgetPresentation Budget(string kind, bool exceeded, UiText ui) => new(kind, ui.Text("deepseek.budget." + kind), exceeded ? 0 : .6, .5,
        exceeded ? 0 : 120, exceeded ? "0%" : "120%", exceeded ? null : "spare", exceeded ? null : ui.Text("quota.verdict.spare"), exceeded, false,
        exceeded ? "−¥3" : "¥64", ".20", "2h 10m", ui.Text(kind == "day" ? "deepseek.reset_day" : "deepseek.reset_week"),
        exceeded ? ui.Text("deepseek.over") + " ¥3.20" : null, exceeded, "Synthetic " + kind + " budget", "¥13.20 / ¥10");
    private static void CheckBounds(DeepSeekSoloView view)
    {
        foreach (var child in Descendants(view).OfType<FrameworkElement>().Where(value => value is DeepSeekSpeedView or DeepSeekDistributionView or DeepSeekWeekView or DeepSeekBudgetDetails))
        {
            var point = child.TranslatePoint(new Point(), view);
            Check(point.X >= -.1 && point.X + child.ActualWidth <= view.ActualWidth + .1 && point.Y + child.ActualHeight <= view.ActualHeight + .1,
                $"The {child.GetType().Name} must fit its measured solo column: {point}, {child.ActualWidth}×{child.ActualHeight}, root {view.ActualWidth}×{view.ActualHeight}");
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); yield return child; foreach (var value in Descendants(child)) yield return value; } }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
