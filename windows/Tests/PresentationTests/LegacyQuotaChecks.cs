using System;
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

internal static class LegacyQuotaChecks
{
    internal static async Task Run(string output)
    {
        await using var engine = new EngineClient(); EngineSnapshot? latest = null;
        engine.Snapshot += value => latest = value;
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en",
            new { providerModes = new { codex = "enabled", claude = "disabled", deepseek = "disabled" } }, referenceFixture: true);
        await PresentationWait.UntilAsync(() => latest?.QuotaDashboard?.LegacyCodex != null,
            "The legacy drawing fixture must receive the Codex-only snapshot");
        var data = latest!.QuotaDashboard?.LegacyCodex ?? throw new InvalidOperationException("The real Codex-only engine fixture must project original Classic bars.");
        var reading = data.Buckets.First().Windows.First();
        Check(reading.RemainingPercent == 43 && reading.ValueText == "43" && reading.PaceText.Contains('%'),
            "Legacy labels and values must cross the actual engine protocol together");
        var known = reading with { RemainingPercent = 50, RemainingTimePercent = 25 };
        var fresh = RenderTrack(known, PacerPalette.Codex);
        var unknown = RenderTrack(known with { RemainingPercent = null }, PacerPalette.Codex);
        var stale = RenderTrack(known with { RemainingTimePercent = null }, PacerPalette.Secondary);
        Check(fresh.Count == 3 && ((GeometryDrawing)fresh[1].Drawing).Geometry.Bounds.Width == 50
            && ((GeometryDrawing)fresh[0].Drawing).Geometry.Bounds.Width == 100,
            "The bar must end at the quota fraction and retain the full quiet track");
        Check(unknown.Count == 2 && ((GeometryDrawing)unknown[1].Drawing).Geometry.Bounds.Width == 2
            && ((GeometryDrawing)unknown[1].Drawing).Geometry.Bounds.Height == 11,
            "Unknown quota removes its fill while retaining the known reset reference");
        Check(stale.Count == 2 && stale[1].Color == ((SolidColorBrush)PacerPalette.Secondary).Color,
            "A stale bar removes its live reset reference and retains the secondary accent");
        var view = new LegacyQuotaView(data, UiText.For(false)) { VerticalAlignment = VerticalAlignment.Center };
        var surface = new Border { Width = 392, MinHeight = 180, Background = Brushes.Black, Child = view };
        var window = new Window { Content = surface, SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None,
            ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
        try
        {
            window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle); window.UpdateLayout();
            var groups = view.Children.OfType<StackPanel>().SelectMany(value => value.Children.OfType<QuotaReadingHost>()).ToArray();
            Check(groups.Length == data.Buckets.Sum(value => value.Windows.Count), "Every original bucket window must have a rendered reading");
            var peer = UIElementAutomationPeer.CreatePeerForElement(groups.First());
            Check(peer.GetName() == reading.AccessibilityLabel && peer.GetChildren() is not { Count: > 0 },
                "A Legacy window must expose one combined reading instead of duplicate decorative values");
            var image = new RenderTargetBitmap(392, (int)Math.Ceiling(surface.ActualHeight), 96, 96, PixelFormats.Pbgra32); image.Render(surface);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var file = File.Create(Path.Combine(output, "legacy-codex-real-engine.png")); encoder.Save(file);
        }
        finally { window.Close(); }
        Console.WriteLine("PASS legacy quota: real-engine window projection, vector fill and pace marks, independent unknown/stale values and combined accessibility");
    }
    private static System.Collections.Generic.IReadOnlyList<DrawingInspection.Paint> RenderTrack(LegacyQuotaWindow reading, Brush accent)
        => DrawingInspection.Render(new LegacyQuotaTrack(reading, accent), 100, 12);
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
