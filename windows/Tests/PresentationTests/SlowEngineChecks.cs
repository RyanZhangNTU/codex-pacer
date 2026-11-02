using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;
internal static class SlowEngineChecks
{
    // A blocking stdin read belongs to this headless synthetic engine process,
    // never to the WPF dispatcher being tested.
    internal static int Fixture(string mode)
    {
        Console.InputEncoding = new UTF8Encoding(false); Console.OutputEncoding = new UTF8Encoding(false);
        void Reply(object data) { lock (Console.Out) { Console.WriteLine(JsonSerializer.Serialize(data)); Console.Out.Flush(); } }
        Reply(new { protocolVersion = 1, type = "hello", engine = "PacerEngine" });
        int requests = 0;
        while (Console.ReadLine() is { } line)
        {
            using var json = JsonDocument.Parse(line); string id = json.RootElement.GetProperty("id").GetString()!;
            string method = json.RootElement.GetProperty("method").GetString()!;
            if (method is "projectCompactBar" or "layoutQuotaChart")
            {
                requests++;
                if (mode == "exit") return 0;
                if (mode == "slow") _ = Task.Run(async () =>
                {
                    await Task.Delay(1000);
                    try { Reply(new { protocolVersion = 1, type = "result", id, ok = true, value = new { version = 1 } }); }
                    catch (IOException) { }
                });
            }
            else
            {
                Reply(new { protocolVersion = 1, type = "result", id, ok = true, value = new { requests } });
                if (method == "shutdown") return 0;
            }
        }
        return 0;
    }
    internal static async Task Run()
    {
        var previous = ShellProjection.Client; TimeSpan timeout = ShellProjection.RequestTimeout;
        try
        {
            ShellProjection.RequestTimeout = TimeSpan.FromMilliseconds(250);
            foreach (string mode in new[] { "silent", "slow", "exit" })
            {
                await using var engine = new EngineClient(TimeSpan.FromMilliseconds(500));
                await engine.StartAsync(Environment.ProcessPath!, true, mode);
                ShellProjection.Client = engine;
                var window = new IslandWindow(engine, true, false, animationOverride: false) { ShowActivated = false, IsHitTestVisible = false };
                int beats = 0; var pulse = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
                pulse.Tick += (_, _) => beats++;
                try
                {
                    window.Show(); pulse.Start();
                    var watch = Stopwatch.StartNew();
                    _ = NativeCompactBar.Shared.Read(new(), "en", []);
                    Check(watch.Elapsed < TimeSpan.FromMilliseconds(125), "A cache read must return before the request deadline, without waiting on the UI thread");
                    await Task.Delay(450); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                    Check(beats >= 5, "The UI dispatcher must keep processing input/heartbeat callbacks while the engine does not answer");
                    Check(ShellProjection.LastFailure != null && NativeCompactBar.Shared.Read(new(), "en", []).Components.Length == 0,
                        "A timeout or engine exit must show an unavailable presentation, rather than retain a pending wait");
                    Check(Texts(window).Any(text => text.Text == UiText.For(false).Text("windows.connection.refresh_failed")),
                        "The real window must show its connection error placeholder");
                    for (int repeat = 0; repeat < 100; repeat++) _ = NativeCompactBar.Shared.Read(new(), "en", []);
                    if (mode != "exit")
                    {
                        var count = await engine.QueryAsync<JsonElement>("inspectRequests", timeout: TimeSpan.FromMilliseconds(250));
                        Check(count.GetProperty("requests").GetInt32() <= 2, "Repeated renders must coalesce requests and must not retry a failed input in a busy loop");
                    }
                    if (mode == "slow")
                    {
                        await Task.Delay(1000);
                        Check(NativeCompactBar.Shared.Read(new(), "en", []).Components.Length == 0,
                            "A reply after its deadline cannot overwrite the error placeholder");
                    }
                    window.Reveal(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
                    Check(window.LogicalTarget.Height > 38, "The panel must remain interactive after an engine timeout or exit");
                    Console.WriteLine("PASS UI responsiveness: " + mode + ", dispatcher heartbeat, bounded deadline, placeholder, coalescing and input");
                }
                finally { pulse.Stop(); window.StopPresentation(); window.AllowClose = true; window.Close(); }
            }
        }
        finally { ShellProjection.RequestTimeout = timeout; ShellProjection.Client = previous; }
    }
    private static System.Collections.Generic.IEnumerable<TextBlock> Texts(DependencyObject root)
    {
        if (root is TextBlock text) yield return text;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            foreach (var item in Texts(VisualTreeHelper.GetChild(root, index))) yield return item;
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
