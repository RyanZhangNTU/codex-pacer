using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;
using Microsoft.Web.WebView2.Wpf;

internal static class DeepSeekWebConnectionChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        string directory = Path.Combine(Path.GetTempPath(), "pacer-web-fixture-" + Guid.NewGuid().ToString("N"));
        var site = new DeepSeekWebSessionChecks.Site(); var ui = UiText.For(language == "zh-Hans");
        await using var engine = new EngineClient();
        var browser = new DeepSeekWebSession(ui, directory, site.Install, dark);
        var session = new Faults(browser);
        await using var connection = new DeepSeekConnectionCoordinator(engine, session, Application.Current.Dispatcher);
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "deepseek",
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "enabled" } };
        var settings = new PreferencesSession(preferences, value => engine.SendAsync("configure", value), _ => true);
        var window = new SettingsWindow(ui, settings, new Startup(), true, dark, engine, webConnection: connection)
            { ShowActivated = false, IsHitTestVisible = false };
        bool browserActions = true;
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: !dark,
            canConnectDeepSeekWeb: () => browserActions && connection.Available) { ShowActivated = false, IsHitTestVisible = false };
        island.ApplyPreferences(preferences);
        island.DeepSeekWebSignInRequested += async context => await connection.ConnectAsync(context);
        try
        {
            window.Show(); island.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, preferences.EngineConfiguration(), true);
            await connection.StartAsync();
            await Until(() => engine.LatestSnapshot?.DeepseekConnection is { WebAvailable: true, Refreshing: false, Reading.Connected: false } &&
                Find<Button>(window, "settings.deepseek.sign_in").IsEnabled);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            browserActions = false; island.ApplyPreferences(preferences with { DeepSeekPanelStyle = "simple" });
            await island.WaitForPresentationAsync();
            var offlineConnect = Find<Button>(island, "deepseek.balance.connect");
            Check(!offlineConnect.IsEnabled && offlineConnect.ToolTip == null && System.Windows.Automation.AutomationProperties.GetHelpText(offlineConnect) == ui.Text("windows.deepseek.demo_web_help"),
                "A synthetic web reader cannot advertise a real login action in the offline demo");
            browserActions = true; island.ApplyPreferences(preferences);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            var connect = Find<Button>(island, "deepseek.balance.connect");
            Check(connect.IsEnabled && (string)connect.Content == ui.Text("deepseek.sign_in"), "The real web dial must open the original sign-in action");
            Invoke(connect);
            var login = await Login(site); await site.Main!.ExecuteScriptAsync("document.getElementById('signin').click()");
            await Continue(login);
            await Until(() => engine.LatestSnapshot?.Wallet?.Balance == 86.4 && engine.LatestSnapshot.DeepseekConnection!.Reading.Connected);
            Check(!JsonSerializer.Serialize(engine.LatestSnapshot).Contains(DeepSeekWebSessionChecks.Site.Key, StringComparison.Ordinal) &&
                !JsonSerializer.Serialize(settings.Current).Contains(DeepSeekWebSessionChecks.Site.Key, StringComparison.Ordinal),
                "Only the reduced wallet can leave the browser profile");
            if (language == "en" && !dark) await SlowReply(engine, island, site);
            await Recovery(engine, island, site, preferences, ui, language + (dark ? "-dark" : "-light"), output);
            await Menu(window, "settings.deepseek.account.switch");
            login = await Login(site); site.NormalBalance = "35.60"; await Continue(login);
            await Until(() => engine.LatestSnapshot?.Wallet?.Balance == 42);
            site.Hold = true;
            await engine.SendAsync("retryDeepSeekBalance", new { balanceContext = engine.LatestSnapshot!.DeepseekConnection!.Context });
            await Until(() => site.Deferred != null);
            // The old-account read must begin before login revokes profile reads.
            await Menu(window, "settings.deepseek.account.switch"); login = await Login(site);
            await Source(window, settings, "apiKey");
            var key = Find<PasswordBox>(window, "settings.deepseek.key.input"); key.Password = "sk-synthetic-web-switch-key-0000";
            Invoke(Find<Button>(window, "settings.deepseek.key.save"));
            await Until(() => engine.LatestSnapshot?.DeepseekConnection?.HasKey == true && engine.LatestSnapshot.Wallet?.Balance == 86.4);
            string apiContext = engine.LatestSnapshot!.DeepseekConnection!.Context;
            site.Release(); site.Hold = false; await Continue(login);
            Check(engine.LatestSnapshot.DeepseekConnection is { Source: "apiKey", HasKey: true } &&
                engine.LatestSnapshot.DeepseekConnection.Context == apiContext && engine.LatestSnapshot.Wallet?.Balance == 86.4,
                "A stale login and cancelled read cannot clear or overwrite the new API connection");
            await Source(window, settings, "web"); await Until(() => engine.LatestSnapshot?.Wallet?.Balance == 42);
            await Menu(window, "settings.deepseek.account.sign_out");
            await Until(() => engine.LatestSnapshot?.Wallet?.Balance == null && engine.LatestSnapshot?.DeepseekConnection is { Refreshing: false, Reading.Connected: false });
            Check((await browser.ReadAsync(CancellationToken.None)).State == "signedOut", "The real profile must be empty after the menu sign-out");
            await Source(window, settings, "apiKey");
            Check(engine.LatestSnapshot!.DeepseekConnection?.HasKey == false, "The original disconnect action removes the independent API key too");
            await Source(window, settings, "web");
            Invoke(Find<Button>(window, "settings.deepseek.sign_in")); login = await Login(site);
            await site.Main!.ExecuteScriptAsync("document.getElementById('signin').click()"); await Continue(login);
            await Until(() => engine.LatestSnapshot?.Wallet?.Balance == 42);
            session.FailClear = true; await Menu(window, "settings.deepseek.account.sign_out");
            await Until(() => engine.LatestSnapshot?.DeepseekConnection is { Refreshing: false, Reading.Color: "orange" } &&
                SelfAndDescendants(window).OfType<TextBlock>().Any(value => value.IsVisible && value.Text == ui.Text("windows.connection.refresh_failed")));
            int reads = site.Reads; await engine.SendAsync("configure", settings.Current.EngineConfiguration()); await Pump();
            Check(site.Reads == reads && engine.LatestSnapshot?.Wallet?.Balance == null, "A failed profile clear cannot silently reconnect the old account");
            session.Unavailable = true; await connection.StartAsync();
            await Until(() => engine.LatestSnapshot?.DeepseekConnection?.WebAvailable == false);
            await island.WaitForPresentationAsync();
            session.Unavailable = false; await connection.StartAsync();
            await Until(() => engine.LatestSnapshot?.DeepseekConnection is { WebAvailable: true, Refreshing: false });
            Check(site.Reads == reads && engine.LatestSnapshot?.Wallet?.Balance == null,
                "Rediscovering the browser runtime cannot reconnect an account whose sign-out failed");
            session.FailClear = false;
            Invoke(Find<Button>(window, "settings.deepseek.sign_in")); login = await Login(site); await Continue(login);
            await Until(() => engine.LatestSnapshot?.Wallet?.Balance == 42);
            await Menu(window, "settings.deepseek.account.sign_out");
            await Until(() => engine.LatestSnapshot?.DeepseekConnection is { Refreshing: false, Reading.Connected: false });
            session.Unavailable = true; await connection.StartAsync();
            await Until(() => engine.LatestSnapshot?.DeepseekConnection?.WebAvailable == false);
            await island.WaitForPresentationAsync();
            Check(!Find<Button>(window, "settings.deepseek.sign_in").IsEnabled, "A missing runtime cannot advertise a working sign-in");
            // A collapsed island builds no hidden panel; open it to inspect the dial.
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            Check(!Find<Button>(island, "deepseek.balance.connect").IsEnabled, "The island must also disable web sign-in without a runtime");
            session.Unavailable = false; await connection.StartAsync();
            await Until(() => engine.LatestSnapshot?.DeepseekConnection is { WebAvailable: true, Refreshing: false } &&
                Find<Button>(window, "settings.deepseek.sign_in").IsEnabled);
            await island.WaitForPresentationAsync();
            await Pump(); Check(Find<Button>(island, "deepseek.balance.connect").IsEnabled, "Restoring the runtime must restore the actual dial action");
            Check(site.Outside == 0, "The real browser integration must keep all page traffic inside its fixture");
            Console.WriteLine("PASS web connection " + language + (dark ? "-dark" : "-light") +
                ": actual dial/Settings SDK login, switch/sign-out, API coexistence, stale callbacks, cancellation, runtime availability and failed-clear recovery; isolated data only");
        }
        catch
        {
            Console.WriteLine("Web connection state: " + JsonSerializer.Serialize(engine.LatestSnapshot?.DeepseekConnection));
            Console.WriteLine("Web dial state: " + JsonSerializer.Serialize(new { engine.LatestSnapshot?.Wallet?.Balance, engine.LatestSnapshot?.Wallet?.Dial }));
            Console.WriteLine("Web host failure: " + connection.LastFailure);
            Console.WriteLine("WebView2 processes: " + PresentationWait.WebViewProcesses());
            throw;
        }
        finally
        {
            site.Release(); window.AllowClose = true; window.Close(); island.StopPresentation(); island.AllowClose = true; island.Close(); await connection.DisposeAsync();
            string target = Path.GetFullPath(directory), parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(target).StartsWith("pacer-web-fixture-", StringComparison.Ordinal))
                throw new InvalidOperationException("Unexpected browser fixture directory");
            if (Directory.Exists(target) && new DirectoryInfo(target).LinkTarget != null) throw new InvalidOperationException("Unexpected fixture link");
            await PresentationWait.RemoveBrowserFixtureAsync(target);
        }
    }
    private static async Task SlowReply(EngineClient engine, IslandWindow island, DeepSeekWebSessionChecks.Site site)
    {
        site.Hold = true;
        try
        {
            await engine.SendAsync("retryDeepSeekBalance", new { balanceContext = engine.LatestSnapshot!.DeepseekConnection!.Context });
            await Until(() => site.Deferred != null && engine.LatestSnapshot?.DeepseekConnection?.Refreshing == true);
            await Until(() => engine.LatestSnapshot?.DeepseekConnection?.Refreshing == false);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            Check(engine.LatestSnapshot?.DeepseekConnection is { Status: null } && engine.LatestSnapshot.Wallet?.Balance == 86.4 &&
                !SelfAndDescendants(island).OfType<DeepSeekBalanceStatusView>().Any(view => view.IsVisible),
                "The engine deadline must keep the last wallet balance without an offline error in the island");
            Console.WriteLine("PASS DeepSeek WebView2 timeout retains the wallet without a connection error");
        }
        finally { site.Hold = false; site.Release(); }
    }
    private static async Task Recovery(EngineClient engine, IslandWindow island, DeepSeekWebSessionChecks.Site site,
        DesktopPreferences preferences, UiText ui, string name, string output)
    {
        string? requested = null; void OpenSettings(string provider) => requested = provider;
        island.ProviderSettingsRequested += OpenSettings;
        try
        {
            foreach (string layout in new[] { "solo", "split", "classic", "three", "classic-three" })
            {
                await PresentationWait.CommandSnapshotAsync(engine, "configure", new { providerModes = new { codex = layout == "solo" ? "disabled" : "enabled", claude = layout.Contains("three", StringComparison.Ordinal) ? "enabled" : "disabled", deepseek = "enabled" } }, waitForSnapshot: !layout.StartsWith("classic", StringComparison.Ordinal));
                island.ApplyPreferences(preferences with { ExpandedQuotaStyle = layout.StartsWith("classic", StringComparison.Ordinal) ? "classic" : "split" });
                site.Status = 503;
                await engine.SendAsync("retryDeepSeekBalance", new { balanceContext = engine.LatestSnapshot!.DeepseekConnection!.Context });
                await Until(() => engine.LatestSnapshot?.DeepseekConnection is { Refreshing: false, Status.Actions.Count: 2 });
                island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
                var message = Find<TextBlock>(island, "deepseek.balance.status.message");
                var retry = Find<Button>(island, "deepseek.balance.status.retry");
                var settings = Find<Button>(island, "deepseek.balance.status.settings");
                Check(message.Text == engine.LatestSnapshot!.DeepseekConnection!.Status!.Message && retry.IsEnabled && settings.IsEnabled &&
                    retry.ActualHeight == 22 && settings.ActualHeight == 22 && engine.LatestSnapshot.Wallet?.Balance == 86.4,
                    "A transient read must retain the wallet and show the original status and 22-point actions in " + layout);
                var statusView = SelfAndDescendants(island).OfType<DeepSeekBalanceStatusView>().Single();
                var retryBounds = retry.TransformToAncestor(statusView).TransformBounds(new Rect(retry.RenderSize));
                var settingsBounds = settings.TransformToAncestor(statusView).TransformBounds(new Rect(settings.RenderSize));
                Check(retryBounds.Left >= -.1 && settingsBounds.Right <= statusView.ActualWidth + .1 && retryBounds.Right + 5.9 <= settingsBounds.Left,
                    "Recovery capsules must fit the real provider column without overlap in " + layout);
                island.CapturePreview(Path.Combine(output, "deepseek-recovery-" + name + "-" + layout + ".png"));
                site.Hold = true; Invoke(retry); await Until(() => site.Deferred != null);
                await Until(() => !Find<Button>(island, "deepseek.balance.status.retry").IsEnabled);
                Check((string)Find<Button>(island, "deepseek.balance.status.retry").Content == ui.Text("common.retrying"), "An active read must show Retrying and reject duplicate activation");
                int reads = site.Reads; retry.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Pump();
                Check(site.Reads == reads, "A detached retry cannot duplicate the current read");
                requested = null; Invoke(Find<Button>(island, "deepseek.balance.status.settings")); await Until(() => requested == "deepseek");
                site.Status = 200; site.Hold = false; site.Release();
                await Until(() => engine.LatestSnapshot?.DeepseekConnection is { Refreshing: false, Status: null });
                reads = site.Reads; requested = null;
                retry.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); settings.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Pump();
                Check(reads == site.Reads && requested == null, "Removed recovery controls cannot act after the error clears");
            }
        }
        finally
        {
            island.ProviderSettingsRequested -= OpenSettings; site.Hold = false; site.Release(); site.Status = 200;
            await PresentationWait.CommandSnapshotAsync(engine, "configure", preferences.EngineConfiguration()); island.ApplyPreferences(preferences);
            await island.WaitForPresentationAsync();
        }
    }
    private static async Task<DeepSeekLoginWindow> Login(DeepSeekWebSessionChecks.Site site)
    {
        await Until(() => Application.Current.Windows.OfType<DeepSeekLoginWindow>().Any(value =>
            SelfAndDescendants(value).OfType<WebView2>().Any(view => view.CoreWebView2 != null && view.CoreWebView2.Source == "https://platform.deepseek.com/usage")) && site.Ready);
        return Application.Current.Windows.OfType<DeepSeekLoginWindow>().Single();
    }
    private static async Task Continue(DeepSeekLoginWindow window)
    { Invoke(Find<Button>(window, "deepseek.login.continue")); await Pump(); await window.CheckCompletion; await Until(() => !window.IsVisible); }
    private static async Task Source(SettingsWindow window, PreferencesSession settings, string source)
    {
        var button = Find<Button>(window, "settings.deepseek.account_options"); Invoke(button); await Until(() => button.ContextMenu?.IsOpen == true);
        var item = button.ContextMenu!.Items.OfType<MenuItem>().Single(value => (string?)value.Tag == source);
        Invoke(item); await Until(() => settings.Current.DeepSeekBalanceSource == source && Find<Button>(window, "settings.deepseek.account_options").IsEnabled);
    }
    private static async Task Menu(SettingsWindow window, string id)
    {
        var button = Find<Button>(window, "settings.deepseek.account_options"); Invoke(button); await Until(() => button.ContextMenu?.IsOpen == true);
        var item = button.ContextMenu!.Items.OfType<MenuItem>().Single(value => AutomationProperties.GetAutomationId(value) == id);
        Check(item.IsVisible && item.IsEnabled, "The actual account menu action must be available"); Invoke(item); await Pump();
    }
    private static T Find<T>(DependencyObject value, string id) where T : DependencyObject =>
        SelfAndDescendants(value).OfType<T>().First(item => AutomationProperties.GetAutomationId(item) == id);
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Invoke(MenuItem item) => ((IInvokeProvider)new MenuItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Pump() { await Task.Delay(40); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); }
    private static async Task Until(Func<bool> condition)
    { var start = Stopwatch.StartNew(); while (!condition() && start.Elapsed.TotalSeconds < PresentationWait.Limit.TotalSeconds) await Pump(); Check(condition(), "The web connection did not settle"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
    private sealed class Faults(IDeepSeekWebSession session) : IDeepSeekWebSession
    {
        internal bool FailClear;
        internal bool Unavailable;
        public bool Available => !Unavailable && session.Available;
        public bool SignInWasNew => session.SignInWasNew;
        public Task<DeepSeekWebReply> ReadAsync(CancellationToken cancellation) => session.ReadAsync(cancellation);
        public Task<bool> SignInAsync() => session.SignInAsync();
        public Task ClearAsync(CancellationToken cancellation) => FailClear ? Task.FromException(new IOException("Synthetic profile clear failure")) : session.ClearAsync(cancellation);
        public ValueTask DisposeAsync() => session.DisposeAsync();
    }
}
