using System;
using System.IO;
using System.Linq;
using CodexPacer.Windows;

internal static class QuotaChartBridgeChecks
{
    internal static async System.Threading.Tasks.Task Run()
    {
        var native = new NativeQuotaChart(Path.Combine(AppContext.BaseDirectory, "Engine"));
        var data = new QuotaChartPresentation("zh-Hans", 0, 100, "", "", [],
            [new(1, .01, 2, "synthetic", "", "synthetic"), new(2, .02, 1, "synthetic", "", "synthetic")], true, "synthetic", "synthetic");
        var markers = await native.LayoutAsync(data, 475);
        Check(markers.Length == 1 && markers[0].Count == 3 && markers[0].Width == 43 && markers[0].X == 21.5,
            "The managed renderer must use the original Swift capsule grouping and edge clamp");
        Check(markers[0].Title.Any(value => value > 127) && !markers[0].Title.Contains("chart.") && markers[0].Details.Count == 2,
            "Chinese marker labels must resolve from the packaged shared strings in the engine process");
        var english = await native.LayoutAsync(data with { Language = "en" }, 475);
        Check(english[0].Title != markers[0].Title && !english[0].Title.Contains("chart."),
            "The explicit model language must override the engine process language");
        Console.WriteLine("PASS chart protocol: shared marker geometry, bounded managed calls and local packaged EN/ZH resources");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
