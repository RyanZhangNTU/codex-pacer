using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexPacer.Windows;

// Settings after an update check that could not reach GitHub, as behind a
// network without it: Overview's banner, the sidebar's Help & Updates line
// and the recovery panel in Help & Updates' card.
internal static class UpdateFailureSettingsChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        var ui = UiText.For(language == "zh-Hans");
        string root = Path.Combine(Path.GetTempPath(), "pacer-update-failure-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var channel = new WindowsUpdateChannel(new Uri(WindowsUpdateChannel.ReleaseFeed), Convert.ToBase64String(new byte[32]), null);
        await using var updates = new WindowsUpdateService(action => action(),
            new UpdateFeedClient(channel, "x64", new Version(4, 5, 0, 87), new Version(10, 0, 26100), language, new Offline()),
            new WindowsUpdateState(Path.Combine(root, "state.json")));
        await updates.InitializeAsync(channel, new WindowsInstallationIdentity(Path.Combine(root, "app"), null), language, false, () => { });
        Check(!await updates.CheckAsync() && updates.CheckFailed && updates.LastSuccess == null, "A check that cannot reach GitHub fails and is kept for Settings");
        await using var engine = new EngineClient();
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "overview", ProviderModes = new()
            { ["codex"] = "enabled", ["claude"] = "enabled", ["deepseek"] = "enabled" } };
        var session = new PreferencesSession(preferences, async value => await engine.SendAsync("configure", value), _ => true);
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, preferences.EngineConfiguration(), referenceFixture: true);
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine, Task.CompletedTask, updater: updates)
            { ShowActivated = false, IsHitTestVisible = false, Width = 1000, Height = 780 };
        string name = language + (dark ? "-dark" : "-light");
        try
        {
            window.Show(); await Pump();
            await Until(() => Has(window, "settings.overview.update_failure"), "Overview shows the failed check");
            Capture(window, Path.Combine(output, "update-failure-overview-" + name + ".png"));
            await window.NavigateAsync("about"); await Pump();
            await Until(() => Find<FrameworkElement>(window, "settings.update.recovery") is { IsVisible: true } && Has(window, "update.recovery.retry"),
                "Help & Updates shows what to try and where else to get Pacer");
            Capture(window, Path.Combine(output, "update-failure-about-" + name + ".png"));
        }
        finally
        {
            window.AllowClose = true; window.Close();
            try { Directory.Delete(root, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        Console.WriteLine("PASS update failure in Settings " + name + ": Overview banner, sidebar line and Help & Updates' recovery panel after an offline check");
    }
    private sealed class Offline : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
            => throw new HttpRequestException("Synthetic network without GitHub");
    }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition, string message)
    {
        var clock = Stopwatch.StartNew();
        while (!condition() && clock.Elapsed < PresentationWait.Limit) { await Task.Delay(50); await Pump(); }
        Check(condition(), message); await Pump();
    }
    private static void Capture(Window window, string file)
    {
        var value = (FrameworkElement)window.Content; value.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(value.ActualWidth), (int)Math.Ceiling(value.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(value);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(file); encoder.Save(stream);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (object child in LogicalTreeHelper.GetChildren(root)) if (child is DependencyObject node) foreach (var value in Descendants(node)) yield return value;
        if (root is Visual or System.Windows.Media.Media3D.Visual3D)
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var value in Descendants(VisualTreeHelper.GetChild(root, i))) yield return value;
    }
    private static bool Has(DependencyObject root, string id) => Descendants(root).OfType<FrameworkElement>().Any(value => AutomationProperties.GetAutomationId(value) == id);
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
}
