using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class ClassicQuotaChecks
{
    internal static async Task Run(string output)
    {
        await using var engine = new EngineClient(); EngineSnapshot? snapshot = null;
        engine.Snapshot += value => snapshot = value;
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
        var dashboard = snapshot!.QuotaDashboard!;
        var codex = dashboard.Providers.Single(value => value.Provider == "codex");
        var claude = dashboard.Providers.Single(value => value.Provider == "claude");
        var five = new QuotaDial("claude", null, null, classic: true, dashboard: claude, classicPeriod: "5h");
        var weekly = new QuotaDial("claude", null, null, classic: true, dashboard: claude);
        Check(five.Selected?.Id == claude.FiveHour.WindowID && weekly.Selected?.Id == claude.Weekly.WindowID
            && five.Selected?.Id != weekly.Selected?.Id, "Classic slots must select their own original periods without changing the source");
        Check(UIElementAutomationPeer.CreatePeerForElement(five).GetName() == claude.FiveHour.ClassicAccessibilityLabel,
            "The classic five-hour ring must expose the selected period, not the weekly summary");
        var stale = codex with { Weekly = codex.Weekly with { Availability = "stale", Verdict = null, VerdictText = null, Pressing = false, PacePercent = null } };
        var freshPixels = RenderDial(new QuotaDial("codex", null, null, classic: true, dashboard: codex));
        var stalePixels = RenderDial(new QuotaDial("codex", null, null, classic: true, dashboard: stale));
        double light = ArcBrightness(freshPixels), dim = ArcBrightness(stalePixels);
        Check(light > 100 && dim / light is > 0.48 and < 0.62, "Classic stale data must retain its arc with the original 0.55 opacity");
        var pro = new QuotaDial("codex", null, null, classic: true, dashboard: codex, classicPeriod: "5h");
        Check(codex.FiveHour.Availability == "proOnly" && pro.Selected == null
            && UIElementAutomationPeer.CreatePeerForElement(pro).GetName() == codex.FiveHour.ClassicAccessibilityLabel,
            "The actual weekly-only account fixture must produce a subscription mark rather than an invented five-hour value");
        var proPixels = RenderDial(pro);
        Check(!proPixels.Any(value => value.Arc) && freshPixels.Any(value => value.Arc) && proPixels.Any(value => value.Drawing is GlyphRunDrawing), "The subscription mark must differ from an empty or measured gauge");
        var wallet = snapshot.Wallet!;
        var staleWallet = wallet with { State = "stale", Dial = wallet.Dial! with { DimmedFace = true, BalanceTone = "secondary", SegmentTone = "staleSegment", SubtitleTone = "tertiary", StaleCaption = true } };
        var staleWalletPixels = RenderDial(new QuotaDial("deepseek", null, staleWallet, classic: true));
        var balanceInk = staleWalletPixels.Where(value => value.Drawing is GlyphRunDrawing
            && value.Color == ((SolidColorBrush)PacerPalette.Secondary).Color).ToArray();
        double centreInk = balanceInk.Length > 0 ? balanceInk.Max(value => value.Intensity) : 0;
        Check(centreInk is >= 145 and <= 165, "A stale DeepSeek face cannot dim the independently styled balance a second time");
        Check(UIElementAutomationPeer.CreatePeerForElement(new QuotaDial("deepseek", null, wallet, classic: true)).GetName() == wallet.Dial!.AccessibilityLabel,
            "The time dial must use the shared localized account-independent accessibility reading");
        foreach (double size in new[] { 88d, 104d, 132d })
        {
            foreach (var state in new[] { wallet, staleWallet, wallet with { Dial = wallet.Dial! with { ConnectTitle = "Connect" } } })
            {
                var dial = new QuotaDial("deepseek", null, state, dialSize: size);
                _ = DrawingInspection.Render(dial, size, size);
                Check(dial.ActualWidth == size && dial.ActualHeight == size, "Time dials must retain the supported 88/104/132 sizes in every connection state");
                Check(UIElementAutomationPeer.CreatePeerForElement(dial).GetName() == state.Dial!.AccessibilityLabel,
                    "Resizing or changing connection state must preserve the shared time-dial accessibility reading");
            }
        }
        foreach (var provider in new[] { codex, claude })
        {
            foreach (string period in new[] { "5h", "7d" })
            {
                var reading = period == "5h" ? provider.FiveHour : provider.Weekly;
                var cell = new ClassicQuotaCell(new(provider.Provider, period, false, provider.Provider + ":" + period, period), provider, null, null);
                var peer = UIElementAutomationPeer.CreatePeerForElement(cell.Ring);
                Check(peer.GetName() == reading.ClassicAccessibilityLabel && peer.GetChildren() is not { Count: > 0 },
                    "A classic reading must be announced once, without repeating its decorative caption or values");
                Check(cell.Dial.Selected?.RemainingPercent == reading.RemainingPercent,
                    "Classic readings must preserve the shared selected value, including missing and subscription-only windows");
                cell.Children.Remove(cell.Ring);
                await Capture(cell.Ring, Path.Combine(output, "classic-" + provider.Provider + "-" + period + ".png"));
                Check(cell.Dial.ActualWidth == 88 && cell.Dial.ActualHeight == 88 && cell.Ring.ActualHeight == 111,
                    "The classic component must retain the original 88-point dial, 8-point gap and 15-point caption");
            }
        }
        Console.WriteLine("PASS classic quota: original period selection, subscription mark, stale vector opacity, caption bounds and single accessibility reading");
    }
    private static IReadOnlyList<DrawingInspection.Paint> RenderDial(QuotaDial dial) => DrawingInspection.Render(dial, 88, 88);
    private static double ArcBrightness(IReadOnlyList<DrawingInspection.Paint> paints)
        => paints.First(value => value.Arc).Intensity;
    private static async Task Capture(FrameworkElement content, string path)
    {
        var surface = new Border { Width = 180, Height = 180, Background = Brushes.Black, Child = content };
        content.HorizontalAlignment = HorizontalAlignment.Stretch; content.VerticalAlignment = VerticalAlignment.Center;
        var window = new Window { Content = surface, SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None,
            ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
        try
        {
            window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle); window.UpdateLayout();
            var image = new RenderTargetBitmap(180, 180, 96, 96, PixelFormats.Pbgra32); image.Render(surface);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var file = File.Create(path); encoder.Save(file);
        }
        finally { window.Close(); }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
