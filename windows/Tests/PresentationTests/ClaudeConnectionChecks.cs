using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
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
using Microsoft.Web.WebView2.Core;

internal static class ClaudeConnectionChecks
{
    private const string First = "11111111-1111-4111-8111-111111111111", Second = "22222222-2222-4222-8222-222222222222";
    internal static async Task Run(string language, bool dark, string output)
    {
        var previous = CultureInfo.CurrentUICulture; CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(language);
        string root = Path.Combine(Path.GetTempPath(), "pacer-claude-connection-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var site = new Site(); var web = new Web(new ClaudeWebSession(UiText.For(language == "zh-Hans"), Path.Combine(root, "profile"), site.Bind, dark));
        await using var engine = new EngineClient();
        await using var coordinator = new ClaudeConnectionCoordinator(engine, web, Application.Current.Dispatcher);
        bool rejectSave = false;
        var preferences = new DesktopPreferences { LastSettingsPane = "claude", ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "enabled", ["deepseek"] = "disabled" } };
        var session = new PreferencesSession(preferences, value => engine.SendAsync("configure", value), _ => { if (!rejectSave) return true; rejectSave = false; return false; });
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = new SettingsWindow(UiText.For(language == "zh-Hans"), session, new Startup(), true, dark, engine, ready.Task, claudeConnection: coordinator)
            { IsHitTestVisible = false, ShowActivated = false };
        string scenario = language + (dark ? "-dark" : "-light");
        try
        {
            window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
                configuration: preferences.EngineConfiguration(), referenceFixture: true, claudeWebFixture: true);
            ready.SetResult(); await coordinator.StartAsync(); await Until(() => engine.LatestSnapshot?.ClaudeConnection?.State == "signedOut");
            var signIn = Find<Button>(window, "settings.claude.sign_in");
            await Until(() => signIn.IsEnabled);
            Check(engine.LatestSnapshot!.Quota.Count == 0, "No cookie must leave the native Claude quota unavailable");
            Invoke(signIn); await Until(() => Application.Current.Windows.OfType<ClaudeLoginWindow>().Any() && site.MainReady);
            var login = Application.Current.Windows.OfType<ClaudeLoginWindow>().Single(); login.IsHitTestVisible = false;
            Put(site.Main!, "sessionKey", "fixture-claude-account-a");
            Invoke(Find<Button>(login, "claude.login.continue")); await Until(() => engine.LatestSnapshot?.ClaudeConnection?.State == "workspaceNeeded" && signIn.IsEnabled);
            Check(session.Current.ClaudeOrganization == "" && engine.LatestSnapshot!.Quota.Count == 0, "A successful login cannot silently choose the first workspace");
            Invoke(signIn); var picker = await Picker();
            Check(!Find<Button>(picker, "claude.organization.continue").IsEnabled, "The native workspace dialog must require an explicit choice");
            SelectWorkspace(picker, 1);
            await Until(() => session.Current.ClaudeOrganization == First && engine.LatestSnapshot?.ClaudeConnection is { State: "signedIn", Refreshing: false } && signIn.IsEnabled);
            Check(engine.LatestSnapshot!.QuotaDashboard!.Providers.Single().Weekly.RemainingPercent == 65, "The real original client must decode the chosen workspace's quota");
            Check(engine.LatestSnapshot.QuotaDashboard.Providers.Single().History?.Chart?.Points.Count > 0, "A verified account must feed the real quota history");
            await Until(() => engine.LatestSnapshot!.Tasks.Any(task => task.SourceId == "claude-cloud"));
            Check(engine.LatestSnapshot!.Presentation!.Rows.Any(row => row.SourceKind == "cloud"), "Native cloud tasks must reach the actual row projection");
            var cloud = Find<CheckBox>(window, "settings.claude.cloud_projects");
            cloud.IsChecked = false; await Until(() => !session.Current.ShowClaudeCloudProjects && cloud.IsEnabled);
            Check(engine.LatestSnapshot!.Tasks.All(task => task.SourceId != "claude-cloud"), "Hiding cloud Projects must remove their tasks from the dashboard");
            rejectSave = true; cloud.IsChecked = true;
            await Until(() => !rejectSave && cloud.IsEnabled && cloud.IsChecked == false);
            Check(!session.Current.ShowClaudeCloudProjects && engine.LatestSnapshot!.Tasks.All(task => task.SourceId != "claude-cloud"), "A rejected cloud preference write must restore the actual source");
            cloud.IsChecked = true; await Until(() => session.Current.ShowClaudeCloudProjects && cloud.IsEnabled && engine.LatestSnapshot!.Tasks.Any(task => task.SourceId == "claude-cloud"));
            window.CapturePreview(Path.Combine(output, "claude-connected-" + scenario + ".png"));
            var options = Find<Button>(window, "settings.claude.account_options");
            var oldRefresh = await Menu(options, "settings.claude.refresh"); options.ContextMenu!.IsOpen = false;
            var choose = await Menu(options, "settings.claude.choose_organization"); Invoke(choose); picker = await Picker(); rejectSave = true; SelectWorkspace(picker, 2);
            await Until(() => !rejectSave && session.Current.ClaudeOrganization == First && engine.LatestSnapshot?.ClaudeConnection is { State: "signedIn", Refreshing: false } && options.IsEnabled);
            Check(engine.LatestSnapshot!.QuotaDashboard!.Providers.Single().Weekly.RemainingPercent == 65, "A rejected workspace write must restore the engine and quota, not only preferences");
            choose = await Menu(options, "settings.claude.choose_organization"); Invoke(choose); picker = await Picker(); SelectWorkspace(picker, 2);
            await Until(() => session.Current.ClaudeOrganization == Second && engine.LatestSnapshot?.ClaudeConnection is { State: "signedIn", Refreshing: false } && options.IsEnabled);
            Check(engine.LatestSnapshot!.QuotaDashboard!.Providers.Single().Weekly.RemainingPercent == 35, "Changing workspaces must display the new source's real reading");
            string context = engine.LatestSnapshot.ClaudeConnection!.Context; Invoke(oldRefresh); await Pump();
            Check(engine.LatestSnapshot.ClaudeConnection!.Context == context && session.Current.ClaudeOrganization == Second, "An old account menu cannot act on the new source");
            site.MainReady = false;
            var switchAccount = await Menu(options, "settings.claude.switch_account"); Invoke(switchAccount);
            await Until(() => Application.Current.Windows.OfType<ClaudeLoginWindow>().Any() && site.MainReady);
            login = Application.Current.Windows.OfType<ClaudeLoginWindow>().Single(); login.IsHitTestVisible = false;
            Put(site.Main!, "sessionKey", "fixture-claude-account-b"); Invoke(Find<Button>(login, "claude.login.continue"));
            await Until(() => engine.LatestSnapshot?.ClaudeConnection?.State == "workspaceNeeded" && signIn.IsEnabled);
            Check(session.Current.ClaudeOrganization == "" && engine.LatestSnapshot!.Quota.Count == 0, "A different account cannot inherit the old workspace or quota");
            Check(engine.LatestSnapshot.Tasks.All(task => task.SourceId != "claude-cloud"), "Account switching must remove the previous cloud graph before selecting the new workspace");
            Invoke(signIn); picker = await Picker(); SelectWorkspace(picker, 1);
            await Until(() => session.Current.ClaudeOrganization == "33333333-3333-4333-8333-333333333333" && engine.LatestSnapshot?.ClaudeConnection is { State: "signedIn", Refreshing: false } && options.IsEnabled);
            Check(engine.LatestSnapshot!.ClaudeConnection!.Context != context && engine.LatestSnapshot.QuotaDashboard!.Providers.Single().History?.Chart?.Points.Count == 1,
                "An account switch must revoke the old binding and start a fresh account chart");
            await Until(() => engine.LatestSnapshot!.Tasks.Any(task => task.SourceId == "claude-cloud" && task.SessionId == "cmsg_thread3"));
            Check(engine.LatestSnapshot!.Tasks.Where(task => task.SourceId == "claude-cloud").All(task => task.SessionId is "cmsg_thread3" or "cse_coordinator3"),
                "Only the new account's cloud graph may reappear");
            web.FailClear = true; var signOut = await Menu(options, "settings.claude.sign_out"); Invoke(signOut);
            await Until(() => engine.LatestSnapshot?.ClaudeConnection?.Paused == true && coordinator.LastFailure != null && options.IsEnabled);
            Check(engine.LatestSnapshot!.Quota.Count == 0, "Failed sign-out must still remove the old account's quota");
            Check(engine.LatestSnapshot.Tasks.All(task => task.SourceId != "claude-cloud"), "A failed profile clear must also keep the previous cloud graph stopped");
            web.RuntimeAvailable = false; await coordinator.StartAsync(); web.RuntimeAvailable = true; await coordinator.StartAsync(); await Pump();
            Check(engine.LatestSnapshot.ClaudeConnection!.Paused && engine.LatestSnapshot.Quota.Count == 0, "Runtime rediscovery cannot reconnect an account after a failed clear");
            signOut = await Menu(options, "settings.claude.sign_out"); Invoke(signOut);
            await Until(() => engine.LatestSnapshot?.ClaudeConnection?.State == "signedOut" && options.IsEnabled);
            Check(await web.ReadAsync(CancellationToken.None) == null, "Successful sign-out must clear the actual private browser profile");
            window.CapturePreview(Path.Combine(output, "claude-signed-out-" + scenario + ".png"));
            Check(Find<CheckBox>(window, "settings.claude.cloud_projects").IsEnabled && !Find<CheckBox>(window, "settings.claude.embedded").IsEnabled,
                "Cloud source preferences remain available without enabling unfinished embedding controls");
            await window.NavigateAsync("general"); bool savedCloud = session.Current.ShowClaudeCloudProjects; cloud.IsChecked = !savedCloud; await Pump();
            Check(session.Current.ShowClaudeCloudProjects == savedCloud, "A detached cloud switch cannot change the active source");
            await window.NavigateAsync("claude"); options = Find<Button>(window, "settings.claude.account_options"); signIn = Find<Button>(window, "settings.claude.sign_in");
            await engine.SendAsync("shutdown"); await Until(() => !options.IsEnabled && !signIn.IsEnabled);
            Check(site.Requests.All(uri => uri.StartsWith("https://claude.ai/", StringComparison.Ordinal)), "All fixture browser traffic must be intercepted");
            Console.WriteLine("PASS Claude connection " + scenario + ": private browser, original quota/cloud clients, explicit workspaces, history, source-toggle rollback, stale controls, account switching, failed-clear pause/recovery and shutdown; synthetic data only");
        }
        catch
        {
            var state = engine.LatestSnapshot?.ClaudeConnection;
            Console.WriteLine($"Claude fixture diagnostics {scenario}: state={state?.State}, refreshing={state?.Refreshing}, paused={state?.Paused}, runtime={state?.WebAvailable}, coordinator={coordinator.LastFailure}, cookieRead={web.LastReadState}, loginWindows={Application.Current.Windows.OfType<ClaudeLoginWindow>().Count()}, organizationSelected={session.Current.ClaudeOrganization.Length > 0}");
            throw;
        }
        finally
        {
            ready.TrySetResult(); window.AllowClose = true; window.Close(); await coordinator.DisposeAsync(); CultureInfo.CurrentUICulture = previous;
            string target = Path.GetFullPath(root), parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(target).StartsWith("pacer-claude-connection-", StringComparison.Ordinal) || new DirectoryInfo(target).LinkTarget != null)
                throw new InvalidOperationException("Unexpected Claude connection fixture directory");
            for (int attempt = 0; attempt < 30; attempt++) { try { Directory.Delete(target, true); break; } catch (IOException) { await Task.Delay(100); } catch (UnauthorizedAccessException) { await Task.Delay(100); } }
        }
    }
    private static async Task<MenuItem> Menu(Button button, string id)
    {
        Invoke(button); await Until(() => button.ContextMenu?.IsOpen == true);
        return button.ContextMenu!.Items.OfType<MenuItem>().Single(item => AutomationProperties.GetAutomationId(item) == id);
    }
    private static async Task<Window> Picker()
    {
        await Until(() => Application.Current.Windows.OfType<Window>().Any(window => Descendants(window).OfType<ComboBox>().Any(value => AutomationProperties.GetAutomationId(value) == "claude.organization.picker")));
        return Application.Current.Windows.OfType<Window>().Single(window => Descendants(window).OfType<ComboBox>().Any(value => AutomationProperties.GetAutomationId(value) == "claude.organization.picker"));
    }
    private static void SelectWorkspace(Window window, int index)
    { Find<ComboBox>(window, "claude.organization.picker").SelectedIndex = index; Invoke(Find<Button>(window, "claude.organization.continue")); }
    private static void Put(CoreWebView2 core, string name, string value)
    { var cookie = core.CookieManager.CreateCookie(name, value, ".claude.ai", "/"); cookie.IsHttpOnly = true; cookie.IsSecure = true; cookie.Expires = DateTime.UtcNow.AddHours(1); core.CookieManager.AddOrUpdateCookie(cookie); }
    private sealed class Web(ClaudeWebSession inner) : IClaudeWebSession
    {
        internal bool FailClear, RuntimeAvailable = true;
        internal string LastReadState = "none";
        public bool Available => RuntimeAvailable && inner.Available;
        public Task PrepareAsync(CancellationToken cancellation) => inner.PrepareAsync(cancellation);
        public async Task<ClaudeWebSessionValue?> ReadAsync(CancellationToken cancellation)
        { var value = await inner.ReadAsync(cancellation); LastReadState = value == null ? "absent" : "present"; return value; }
        public Task<bool> SignInAsync() => inner.SignInAsync();
        public Task ClearAsync(CancellationToken cancellation) { if (FailClear) { FailClear = false; throw new IOException("Synthetic clear failure"); } return inner.ClearAsync(cancellation); }
        public ValueTask DisposeAsync() => inner.DisposeAsync();
    }
    private sealed class Site
    {
        internal CoreWebView2? Main; internal bool MainReady; internal readonly List<string> Requests = [];
        private readonly HashSet<CoreWebView2> bound = [];
        internal void Bind(CoreWebView2 core)
        {
            if (!bound.Add(core)) return;
            core.NavigationCompleted += (_, _) => { if (core.Source.StartsWith("https://claude.ai/", StringComparison.Ordinal)) { Main = core; MainReady = true; } };
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += (_, e) => { Requests.Add(e.Request.Uri); e.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes("<!doctype html><title>Synthetic Claude</title><p>Offline fixture</p>")), 200, "Fixture", "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store"); };
        }
    }
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Invoke(MenuItem value) => ((IInvokeProvider)new MenuItemAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject => Descendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject value) { yield return value; for (int i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(value, i))) yield return child; }
    private static async Task Pump() { await Task.Delay(40); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); }
    private static async Task Until(Func<bool> condition) { var watch = Stopwatch.StartNew(); while (!condition() && watch.Elapsed.TotalSeconds < 12) await Pump(); Check(condition(), "The bounded Claude connection action did not finish"); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool value) => true; }
}
