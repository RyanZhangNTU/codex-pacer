using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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

internal static class ProviderHistoryChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
        var ui = UiText.For(language == "zh-Hans"); string scenario = language + (dark ? "-dark" : "-light");
        foreach (string provider in new[] { "codex", "claude" })
        {
            var data = engine.LatestSnapshot!.QuotaDashboard!.Providers.Single(value => value.Provider == provider).History!;
            Check(data.Chart?.Points.Count > 20 && data.Buckets.Count > 0, "Both providers expose the shared current-cycle projection");
            var view = new QuotaHistoryView(ui, provider == "claude" ? PacerPalette.Claude : PacerPalette.Codex,
                () => engine.SendAsync("retryQuota", new { provider }));
            view.Update(data);
            var surface = new Border { Width = 529, Background = dark ? Brushes.Black : Brushes.White, Child = view };
            var window = Host(surface, dark);
            try
            {
                window.Show(); await Pump(); await ShellProjection.WhenIdleAsync(); await Pump(); surface.UpdateLayout();
                var chart = view.Chart!; Check(chart.InputSurface.ActualHeight == 118, "Both providers use the same plot control");
                var peer = UIElementAutomationPeer.CreatePeerForElement(chart.InputSurface);
                var pattern = (IValueProvider)peer.GetPattern(PatternInterface.Value);
                Press(chart.InputSurface, Key.Home); Check(pattern.Value == data.Chart!.Points[0].AccessibilityLabel, "Home selects a persisted sample");
                Press(chart.InputSurface, Key.End); Check(pattern.Value == data.Chart!.Points[^1].AccessibilityLabel, "End selects the latest persisted sample");
                Press(chart.InputSurface, Key.Escape); Check(chart.SelectionText == null, "A history tooltip dismisses independently of its window");
                Check(provider != "claude" || data.Account == null && chart.Markers.Count == 0, "Claude cannot inherit Codex Credits or banked resets");
                view.Update(data with { Warning = "Synthetic cache write failed" }); await Pump();
                Check(Descendants(view).OfType<TextBlock>().Any(value => value.IsVisible && value.Text == ui.Text("quota.chart_warning"))
                    && Descendants(view).OfType<FrameworkElement>().Any(value => value.IsVisible && value.ToolTip as string == "Synthetic cache write failed"), "A cache warning remains visible alongside the live curve");
                view.Update(data); Save(surface, Path.Combine(output, "persisted-history-" + provider + "-" + scenario + ".png"));
                view.Update(data with { Chart = null, Buckets = [], Account = null, Placeholder = ui.Text("quota.loading") }); await Pump();
                Check(view.Chart == null, "Revoking a provider removes its old account curve");
            }
            finally { window.Close(); }
        }
        var week = engine.LatestSnapshot!.Wallet!.Solo!.Week!;
        Check(week.Days.Count == 7, "DeepSeek retains its existing seven-day display over the eight-day balance history");
        var weekView = new DeepSeekWeekView(week);
        var weekSurface = new Border { Width = 400, Padding = new Thickness(12), Background = Brushes.Black, Child = weekView };
        var weekWindow = Host(weekSurface, dark);
        try
        {
            weekWindow.Show(); await Pump();
            Check(UIElementAutomationPeer.CreatePeerForElement(weekView).GetName() == week.AccessibilityLabel, "The account-spend history announces the shared formatted summary");
            Check(Descendants(weekView).OfType<DeepSeekWeekPlot>().Single().ActualHeight == 44, "The balance history keeps its existing plot geometry");
            Check(week.Days.All(day => Descendants(weekView).OfType<TextBlock>().Any(label => label.Text == day.Label)), "Every shared day label reaches the native view");
            Save(weekSurface, Path.Combine(output, "persisted-history-deepseek-" + scenario + ".png"));
        }
        finally { weekWindow.Close(); }
        Console.WriteLine("PASS provider histories " + scenario + ": two quota curves, keyboard/UIA, isolated account details, cache warning and DeepSeek week");
    }
    private static Window Host(FrameworkElement content, bool dark)
    {
        var window = new Window { Content = content, SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None,
            ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
        WindowRendering.Prepare(window);
        window.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        SettingsPalette.Apply(window.Resources, dark, true); return window;
    }
    private static void Save(FrameworkElement content, string path)
    {
        content.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(content);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap)); using var file = File.Create(path); png.Save(file);
    }
    private static void Press(FrameworkElement target, Key key) => target.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(target), Environment.TickCount, key) { RoutedEvent = Keyboard.KeyDownEvent });
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); yield return child; foreach (var item in Descendants(child)) yield return item; } }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
