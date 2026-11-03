using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
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

internal static class QuotaConnectionChecks
{
    internal static async Task Run(string output)
    {
        await using var engine = new EngineClient(); EngineSnapshot? latest = null;
        engine.Snapshot += value => latest = value;
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
        await PresentationWait.UntilAsync(() => latest != null, "The recovery fixture must receive its initial snapshot");
        foreach (bool chinese in new[] { false, true })
        {
            var ui = UiText.For(chinese); string language = chinese ? "zh-Hans" : "en";
            var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            int retries = 0, settings = 0; bool acknowledged = false;
            var failure = new QuotaConnectionStatus("error", "Synthetic failure",
                [new("retry", ui.Text("common.retry"), true), new("settings", ui.Text("common.settings"), true)]);
            var view = new QuotaConnectionView("codex", failure, ui, async () =>
            {
                retries++; await engine.SendAsync("retryQuota", new { provider = "codex" }); acknowledged = true; await gate.Task;
            }, settings: null);
            var surface = new Border { Width = 374, Padding = new Thickness(8), Background = Brushes.Black, Child = view };
            var window = new Window { Content = surface, SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None,
                ShowActivated = false, ShowInTaskbar = false, IsHitTestVisible = false };
            try
            {
                window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle); window.UpdateLayout();
                var text = Descendants(view).OfType<TextBox>().Single();
                Check(text.IsReadOnly && !text.IsReadOnlyCaretVisible && text.Text == failure.Message,
                    "The original selectable failure message must remain read-only");
                var retry = Button(view, "quota.codex.retry"); var config = Button(view, "quota.codex.settings");
                Check(retry.IsEnabled && !config.IsEnabled && retry.ActualHeight == 22 && retry.Padding == new Thickness(9, 0, 9, 0),
                    "Recovery must retain the original capsule geometry and disable an unavailable settings action");
                ulong before = latest!.Sequence; Invoke(retry);
                await Until(() => acknowledged && retries == 1 && latest!.Sequence > before, "An accessible retry must receive the real engine acknowledgement");
                Check(!retry.IsEnabled, "An in-flight retry cannot issue another command");
                bool blocked = false;
                try { Invoke(retry); } catch (ElementNotEnabledException) { blocked = true; }
                Check(blocked && retries == 1, "UI Automation must reject duplicate retry activation while pending");
                gate.SetResult(); await Until(() => retry.IsEnabled, "The retry control must recover after the acknowledged action completes");
                Capture(surface, Path.Combine(output, "quota-connection-" + language + "-error.png"));
                var waiting = new QuotaConnectionStatus("error", "Synthetic failure",
                    [new("retry", ui.Text("common.retrying"), false), new("settings", ui.Text("common.settings"), true)]);
                var reading = new QuotaConnectionView("codex", waiting, ui, () => Task.CompletedTask, () => settings++);
                surface.Child = reading; window.UpdateLayout();
                Check(!Button(reading, "quota.codex.retry").IsEnabled, "The projected refreshing state must disable retry independently of local clicks");
                Invoke(Button(reading, "quota.codex.settings")); await Until(() => settings == 1, "A supported settings action must reach its owner");
                var unavailable = new QuotaConnectionStatus("unavailable", "Synthetic unavailable", [new("settings", ui.Text("common.open_settings"), true)]);
                var disconnected = new QuotaConnectionView("codex", unavailable, ui, null, () => settings++);
                surface.Child = disconnected; window.UpdateLayout();
                Check(Descendants(disconnected).OfType<Button>().Count() == 1, "Unread data must offer settings without inventing a quota retry");
                Capture(surface, Path.Combine(output, "quota-connection-" + language + "-unavailable.png"));
            }
            finally { gate.TrySetResult(); window.Close(); }
        }
        Console.WriteLine("PASS quota recovery: selectable messages, native capsules, acknowledged real-engine retry, duplicate rejection and supported settings dispatch in both languages");
    }
    private static Button Button(DependencyObject root, string id) => Descendants(root).OfType<Button>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Capture(FrameworkElement surface, string path)
    {
        surface.UpdateLayout(); var image = new RenderTargetBitmap((int)Math.Ceiling(surface.ActualWidth), (int)Math.Ceiling(surface.ActualHeight), 96, 96, PixelFormats.Pbgra32); image.Render(surface);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image)); using var file = File.Create(path); encoder.Save(file);
    }
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(25);
        Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
