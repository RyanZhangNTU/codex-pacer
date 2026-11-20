using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Threading.Tasks;
using System.Windows.Threading;
using CodexPacer.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

internal static class PresentationWait
{
    // A wait for something to happen costs time only when it never happens, and
    // hosted runners are slower than a desktop, so these waits share one generous
    // limit. A check that bounds how long something may take keeps its own.
    internal static readonly TimeSpan Limit = TimeSpan.FromSeconds(30);

    /// The reset capsule under Codex's quota and the height it adds to the panel; the
    /// reference fixture's Codex account has banked resets, so a default panel shows one.
    /// The reference panel's height: 438 points, plus the reset capsule when it shows.
    internal static double ReferenceHeight(System.Windows.DependencyObject root) => 438 + ResetCapsule(root).Height;

    internal static (System.Windows.Controls.Button? Capsule, double Height) ResetCapsule(System.Windows.DependencyObject root)
    {
        var pending = new System.Collections.Generic.Stack<System.Windows.DependencyObject>(); pending.Push(root);
        while (pending.Count > 0)
        {
            var node = pending.Pop();
            if (node is System.Windows.Controls.Button button && System.Windows.Automation.AutomationProperties.GetAutomationId(button) == "island.codex.resets"
                && button.IsVisible)
                return (button, button.ActualHeight + button.Margin.Top + button.Margin.Bottom);
            for (int index = 0; index < System.Windows.Media.VisualTreeHelper.GetChildrenCount(node); index++)
                pending.Push(System.Windows.Media.VisualTreeHelper.GetChild(node, index));
        }
        return (null, 0);
    }

    // Whether a saved panel layout places the block. The saved text also lists
    // every block it knows, so searching the text for a name says nothing.
    internal static bool Places(string? layout, string block)
    {
        if (layout == null) return false;
        try
        {
            return System.Text.Json.Nodes.JsonNode.Parse(layout)?["blocks"] is System.Text.Json.Nodes.JsonArray blocks
                && System.Linq.Enumerable.Any(blocks, value => value?.GetValue<string>() == block);
        }
        catch (System.Text.Json.JsonException) { return false; }
    }

    // A WebView2 browser keeps its profile open until its processes exit. Wait for
    // the fixture profile to go, so the next browser check never starts while the
    // last one's browser is still shutting down. This runs in finally blocks, so it
    // reports a profile it could not remove instead of hiding the check's own error.
    internal static async Task RemoveBrowserFixtureAsync(string target)
    {
        var clock = Stopwatch.StartNew();
        while (Directory.Exists(target))
        {
            try { Directory.Delete(target, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (clock.Elapsed >= Limit)
                {
                    Console.Error.WriteLine($"A fixture browser kept its profile open for {Limit.TotalSeconds:0} s; {WebViewProcesses()} WebView2 processes are running.");
                    return;
                }
                await Task.Delay(100);
            }
        }
    }

    internal static int WebViewProcesses()
    {
        var processes = Process.GetProcessesByName("msedgewebview2");
        foreach (var process in processes) process.Dispose();
        return processes.Length;
    }

    internal static async Task UntilAsync(Func<bool> condition, string message, TimeSpan? timeout = null)
    {
        var clock = Stopwatch.StartNew();
        while (!condition() && clock.Elapsed < (timeout ?? Limit)) await Task.Delay(20);
        if (!condition()) throw new TimeoutException(message);
        // EngineClient publishes snapshots before IslandWindow queues its render.
        // Drain both callbacks before inspecting the resulting visual tree.
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }

    internal static async Task<(TWindow Window, CoreWebView2 Page)> LoginPageAsync<TWindow>(Func<CoreWebView2, bool> loaded) where TWindow : Window
    {
        // The app may start a private reader and capture its baseline before showing the login window.
        TWindow? window = null;
        await UntilAsync(() => (window = Application.Current.Windows.OfType<TWindow>().SingleOrDefault(value => value.IsVisible)) != null,
            typeof(TWindow).Name + " did not open after preparing the private profile",
            ProviderWebSession.StartupTimeout + ProviderWebSession.ReadTimeout);
        CoreWebView2? page = null;
        await UntilAsync(() => (page = SelfAndDescendants(window!).OfType<WebView2>()
                .Select(view => view.CoreWebView2).SingleOrDefault(core => core != null)) != null,
            typeof(TWindow).Name + " did not initialize its browser controller", ProviderWebSession.StartupTimeout);
        await UntilAsync(() => loaded(page!), typeof(TWindow).Name + " did not finish loading the intercepted login document");
        return (window!, page!);
    }

    internal static async Task CommandSnapshotAsync(EngineClient engine, string method, object parameters, bool waitForSnapshot = true)
    {
        ulong before = engine.LatestSnapshot?.Sequence ?? 0;
        await engine.SendAsync(method, parameters);
        if (!waitForSnapshot)
        {
            // Known unchanged demo/configuration inputs acknowledge normally
            // while the engine suppresses their duplicate wire projection.
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            return;
        }
        await UntilAsync(() => engine.LatestSnapshot?.Sequence > before,
            "The engine command must publish its snapshot: " + method);
    }
}
