using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class QuotaHistoryChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
        await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.QuotaDashboard?.Providers
            .Any(value => value.Provider == "codex" && value.History?.Chart != null) == true,
            "The history fixture must receive the projected quota samples");
        var data = engine.LatestSnapshot!.QuotaDashboard!.Providers.Single(value => value.Provider == "codex").History!;
        Check(data.Chart?.Points.Count > 20 && data.Account?.Expiries.Count == 2, "The actual engine must publish original synthetic samples and reset details");
        UiText ui = UiText.For(language == "zh-Hans"); int retries = 0;
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        bool reject = false;
        var history = new QuotaHistoryView(ui, PacerPalette.Codex, async () =>
        { retries++; await gate.Task; if (reject) throw new IOException("Synthetic offline engine"); await engine.SendAsync("retryQuota", new { provider = "codex" }); });
        var surface = new Border { Width = 529, Background = dark ? Brushes.Black : Brushes.White, Child = history };
        var window = new Window { Content = surface, SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None,
            ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
        window.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        SettingsPalette.Apply(window.Resources, dark, true); history.Update(data);
        try
        {
            window.Show(); await Pump();
            await ShellProjection.WhenIdleAsync(); await Pump();
            string name = language + (dark ? "-dark" : "-light");
            var chart = history.Chart!;
            Check(chart.ActualWidth == 509 && chart.InputSurface.ActualHeight == 118 && chart.ActualHeight > 138 && chart.ActualHeight < 145,
                $"The live chart must preserve the native 509-point width, 118-point plot and footer spacing ({chart.ActualWidth}×{chart.ActualHeight})");
            Check(chart.Markers.Sum(value => value.Count) == 2 && chart.Markers.Sum(value => value.Count) == data.Chart!.Expiries.Sum(value => value.Count)
                && chart.Markers.All(value => value.X + value.Width / 2 <= chart.PlotWidth), "Shared reset markers must retain every expiry count and stay inside the plot");
            var plot = chart.InputSurface;
            var peer = UIElementAutomationPeer.CreatePeerForElement(plot);
            var valuePattern = (IValueProvider)peer.GetPattern(PatternInterface.Value);
            Check(valuePattern.IsReadOnly && valuePattern.Value.Contains("43%") && peer.GetName() == data.Chart!.AccessibilityLabel,
                "Accessibility must expose the actual latest reading without making the historical series editable");
            var balancePeer = UIElementAutomationPeer.CreatePeerForElement(Find<QuotaReadingHost>(history, "quota.history.credits"));
            Check(balancePeer.GetName() == data.Account!.BalanceAccessibility && balancePeer.GetChildren()?.Count is null or 0,
                "Credit balance must be announced once using the shared account label");
            PressKey(plot, Key.Home); Check(valuePattern.Value == data.Chart!.Points[0].AccessibilityLabel, "Home must select the first actual reading");
            PressKey(plot, Key.Right); Check(valuePattern.Value == data.Chart!.Points[1].AccessibilityLabel, "Arrow keys must walk actual samples");
            PressKey(plot, Key.End); Check(valuePattern.Value == data.Chart!.Points[^1].AccessibilityLabel, "End must select the latest reading");
            PressKey(plot, Key.Escape); Check(chart.SelectionText == null, "Escape must dismiss the tooltip without closing settings");
            var last = data.Chart!.Points[^1];
            double x = 4 + last.Fraction * (chart.PlotWidth - 8);
            chart.SelectAt(new Point(x, 70)); Check(chart.SelectionText == last.AccessibilityLabel, "Pointer mapping must select the nearest actual sample");
            chart.SelectAt(new Point(Math.Min(chart.PlotWidth - 1, x + 30), 70)); Check(chart.SelectionText == null, "The unsampled future cannot invent a quota reading");
            var marker = chart.Markers[0]; chart.SelectAt(new Point(marker.X, 13));
            Check(chart.SelectionText == marker.AccessibilityLabel, "Expiry hit regions must take precedence over the series");
            Save(surface, Path.Combine(output, "history-" + name + "-expiry.png"));
            var markerButton = Find<Button>(chart, "quota.chart.expiry." + marker.Id.ToString("R", System.Globalization.CultureInfo.InvariantCulture));
            chart.SelectAt(new Point(-1, -1)); Invoke(markerButton);
            await Until(() => chart.SelectionText == marker.AccessibilityLabel);
            chart.SelectAt(new Point(-1, -1));
            var details = Find<Expander>(history, "quota.history.details");
            ((IExpandCollapseProvider)new ExpanderAutomationPeer(details).GetPattern(PatternInterface.ExpandCollapse)).Expand(); await Pump();
            Check(Descendants(history).OfType<LegacyQuotaTrack>().Any(value => value.IsVisible), "The quota disclosure must reveal the actual per-window tracks");
            var resetButton = Find<Button>(history, "quota.history.resets"); Invoke(resetButton); await Pump();
            Check(AutomationProperties.GetItemStatus(resetButton) == ui.Text("account.expiries_expanded")
                && Descendants(history).OfType<TextBlock>().Any(value => value.IsVisible && value.Text == data.Account!.TimeZoneText),
                "Reset disclosure must show all deadlines and the local time zone");
            Save(surface, Path.Combine(output, "history-" + name + "-details.png"));
            history.Update(data with { Account = data.Account! with { Context = "new-synthetic-account" } }); await Pump();
            Check(AutomationProperties.GetItemStatus(resetButton) == ui.Text("account.expiries_collapsed"), "An account change must close old expiry details");
            var refresh = Find<Button>(history, "quota.history.refresh"); Invoke(refresh);
            await Until(() => !refresh.IsEnabled && retries == 1);
            gate.TrySetResult(); await Until(() => refresh.IsEnabled);
            history.Update(data with { Refreshing = true }); Check(!refresh.IsEnabled, "A pending quota read must keep Refresh disabled");
            history.Update(data); reject = true; Invoke(refresh); await Until(() => retries == 2 && refresh.IsEnabled);
            Check(Descendants(history).OfType<TextBlock>().Any(value => value.IsVisible && value.Text == ui.Text("windows.quota.refresh_failed")), "A command failure must be visible without crashing the UI dispatcher");
            history.Update(data with { Chart = null, Account = null, Buckets = [], Placeholder = ui.Text("quota.loading"), Refreshing = true }); await Pump();
            Check(history.Chart == null && !resetButton.IsVisible && !details.IsVisible, "A revoked source must immediately remove old chart, quota windows and account details");
            Console.WriteLine("PASS quota history " + name + ": real engine data, native vector plot, keyboard/UIA, actual samples, expiry precedence, disclosures, account reset and refresh failure");
        }
        finally { window.Close(); gate.TrySetResult(); }
    }
    private static void Save(FrameworkElement surface, string path)
    {
        surface.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(surface.ActualWidth), (int)Math.Ceiling(surface.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(surface);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var file = File.Create(path); encoder.Save(file);
    }
    private static void PressKey(FrameworkElement target, Key key) => target.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(target), Environment.TickCount, key) { RoutedEvent = Keyboard.KeyDownEvent });
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static System.Collections.Generic.IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); yield return child; foreach (var value in Descendants(child)) yield return value; } }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    { var watch = Stopwatch.StartNew(); while (!condition() && watch.Elapsed.TotalSeconds < 6) await Task.Delay(20); Check(condition(), "The bounded async quota command must finish"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
