using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using CodexPacer.Windows;

internal static class WorkBuddyAccountChecks
{
    private const string Origin = "https://www.workbuddy.cn";
    private const string Billing = Origin + "/billing/meter/get-user-resource-summary";
    private const string Paid = Origin + "/billing/meter/get-user-resource-paid-packages";
    private const string Free = Origin + "/billing/meter/get-user-resource-free-packages";
    private const string Login = Origin + "/profile/plans-usage";
    private const string Accounts = Origin + "/console/accounts";
    private const string EnterpriseUsage = Origin + "/billing/meter/get-enterprise-user-usage";

    internal static async Task Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-credits-" + Guid.NewGuid().ToString("N"));
        var ui = UiText.For(false);
        CoreWebView2? login = null;
        int reads = 0, cycles = 0, writes = 0;
        bool authenticated = false, serviceDown = false, cycleUnavailable = false, enterprise = false;
        int enterpriseReads = 0; string? enterpriseHeader = null;
        DateTimeOffset reset = DateTimeOffset.UtcNow.AddDays(17);
        DateTimeOffset enterpriseEnd = DateTimeOffset.UtcNow.AddDays(9);
        DateTimeOffset expiration = reset.AddDays(-7);
        void Attach(CoreWebView2 core)
        {
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.NavigationCompleted += (_, e) => { if (e.IsSuccess && core.Source == Login) login = core; };
            core.WebResourceRequested += (_, e) =>
            {
                string url = e.Request.Uri;
                string body = "";
                string type = "text/html";
                int status = 403;
                if (url == Login && e.Request.Method == "GET") { status = 200; body = "<!doctype html><title>Test sign-in</title>"; }
                else if (url == Billing && e.Request.Method == "POST")
                {
                    reads++;
                    status = serviceDown ? 503 : authenticated ? 200 : 401;
                    type = "application/json";
                    body = """
                        {"code":0,"data":{"SubscriptionPackageName":"Fixture Plan","SubscriptionPackageCode":"fixture-monthly","IsPaidUser":true,"Packages":[
                            {"CapacityUnit":"credits","PackageCode":"fixture-monthly","CycleRemainCapacity":"420.50","CycleTotalCapacity":"500","CycleUsedCapacity":"67.25","CycleFrozenCapacity":"12.25"},
                            {"CapacityUnit":"credits","PackageCode":"fixture-topup","CycleRemainCapacity":"100","CycleTotalCapacity":"100"},
                            {"CapacityUnit":"tokens","CycleRemainCapacity":"100000","CycleTotalCapacity":"100000"}
                        ]}}
                        """;
                }
                else if (url == Paid && e.Request.Method == "POST")
                {
                    cycles++; status = cycleUnavailable ? 503 : 200; type = "application/json";
                    body = System.Text.Json.JsonSerializer.Serialize(new { code = 0, data = new { Accounts = new[] {
                        new { PackageCode = "fixture-monthly", CycleEndTime = reset.ToUnixTimeMilliseconds(),
                            CycleCapacityRemainPrecise = 420.5, DeductionEndTime = reset.ToUnixTimeMilliseconds() },
                        new { PackageCode = "fixture-topup", CycleEndTime = expiration.ToUnixTimeMilliseconds(),
                            CycleCapacityRemainPrecise = 100.0, DeductionEndTime = expiration.ToUnixTimeMilliseconds() }
                    } } });
                }
                else if (url == Free && e.Request.Method == "POST")
                {
                    status = 200; type = "application/json";
                    body = """{"code":0,"data":{"Accounts":[]}}""";
                }
                // The site lists the signed-in accounts; a personal one keeps the personal bill (#241).
                else if (url == Accounts && e.Request.Method == "GET")
                {
                    status = authenticated ? 200 : 401; type = "application/json";
                    body = enterprise
                        ? """{"code":0,"data":{"accounts":[{"type":"personal","uid":"fixture-user"},{"type":"enterprise","uid":"fixture-user","enterpriseId":"fixture-team","lastLogin":"2026-11-16 09:00:00"}]}}"""
                        : """{"code":0,"data":{"accounts":[{"type":"personal","uid":"fixture-user","lastLogin":"2026-11-16 09:00:00"}]}}""";
                }
                else if (url == EnterpriseUsage && e.Request.Method == "POST")
                {
                    enterpriseReads++; status = 200; type = "application/json";
                    enterpriseHeader = e.Request.Headers.Contains("X-Enterprise-Id") ? e.Request.Headers.GetHeader("X-Enterprise-Id") : null;
                    // workbuddy.cn writes its dates in China time, without an offset.
                    string China(DateTimeOffset value) => value.ToOffset(TimeSpan.FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
                    body = System.Text.Json.JsonSerializer.Serialize(new { code = 0, data = new {
                        credit = 250.0, limitNum = 1000, cycleStartTime = China(enterpriseEnd.AddDays(-30)), cycleEndTime = China(enterpriseEnd),
                        exclusiveGift = new { hasGift = true, usedCredits = 50, totalCredits = 200, remainCredits = 150, nextResetAt = China(enterpriseEnd) } } });
                }
                else if (e.Request.Method != "GET") writes++;
                e.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(body)),
                    status, "Fixture", "Content-Type: " + type + "\r\nCache-Control: no-store");
            };
        }
        // WorkBuddy signs in on workbuddy.cn and WorkBuddy AI on workbuddy.ai, each with its own profile and account.
        var account = new HarnessAccountConnection("workbuddy", new WorkBuddyAccountSession(ui, true, Path.Combine(root, "cn"), Attach), Application.Current.Dispatcher);
        var international = new HarnessAccountConnection("workbuddy-ai", new WorkBuddyAccountSession(ui, false, Path.Combine(root, "ai"), Attach), Application.Current.Dispatcher);
        await using var accounts = new HarnessAccounts([account, international]);
        await using var engine = new EngineClient();
        var choices = new DesktopPreferences
        {
            LastSettingsPane = "overview", MonitorSSH = false,
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled", ["workbuddy"] = "enabled", ["workbuddy-ai"] = "disabled" }
        };
        var preferences = new PreferencesSession(choices, value => engine.SendAsync("configure", value), _ => true);
        var settings = new SettingsWindow(ui, preferences, new DemoStartupRegistration(), true, engine: engine, harnessAccounts: accounts)
            { ShowActivated = false, IsHitTestVisible = false };
        var island = new IslandWindow(engine, true, false, animationOverride: false, harnessAccounts: accounts)
            { ShowActivated = false, IsHitTestVisible = false };
        const string readout = "island.workbuddy.account.remaining";
        const string monthly = "420.5";
        const string prefix = "settings.workbuddy";
        try
        {
            settings.Show(); island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), false, "en",
                configuration: choices.EngineConfiguration(), readOnlyDiagnostics: true);
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.Modules?.Any(m => m is { Provider: "workbuddy", Enabled: true, ReportsAccountCredits: true }) == true,
                "A WorkBuddy-only engine must advertise its separate account capability");
            account.SetEnabled(true);
            await settings.NavigateAsync("workbuddy");
            await PresentationWait.UntilAsync(() => Find<TextBlock>(settings, prefix + ".account_state")?.Text == ui.Text("harness.account.signed_out")
                && Find<TextBlock>(settings, prefix + ".credits")?.Text == ui.Text("harness.account.sign_in"),
                "Settings should distinguish a disconnected account from zero credits");
            Check(Require<Button>(settings, prefix + ".sign_in").IsVisible && Find<Button>(settings, prefix + ".account_options")?.IsVisible != true,
                "Signing in is the one action while signed out, as on Claude's page");
            Invoke(Require<Button>(settings, prefix + ".sign_in"));
            await PresentationWait.UntilAsync(() => login != null, "The visible WorkBuddy login must use the selected site");
            var window = Application.Current.Windows.OfType<ProviderLoginWindow>().Single();
            Check(Require<TextBlock>(window, "workbuddy.login.heading").Text == ui.Text("workbuddy.login.prompt")
                && window.Title == ui.Text("workbuddy.login.title") + " · www.workbuddy.cn"
                && Require<Button>(window, "workbuddy.login.later").IsVisible && !Require<Button>(window, "workbuddy.login.done").IsVisible,
                "The WorkBuddy sign-in uses the shared banner, with nothing to confirm while signed out");
            int signedOutReads = reads;
            await PresentationWait.UntilAsync(() => reads > signedOutReads, "The window must check the account through its own profile while it is open");
            Check(window.IsVisible && Require<TextBlock>(window, "workbuddy.login.heading").Text == ui.Text("workbuddy.login.prompt"),
                "A signed-out reading keeps the window open");
            authenticated = true;
            await PresentationWait.UntilAsync(() => Find<TextBlock>(window, "workbuddy.login.heading")?.Text == ui.Text("workbuddy.login.signed_in"),
                "The first reading with credits must confirm the sign-in, wherever the page is");
            await PresentationWait.UntilAsync(() => !window.IsVisible, "The window must close by itself after confirming");
            await PresentationWait.UntilAsync(() => account.Reading is { Remaining: 520.5, Total: 600, Reserved: 12.25 } && !account.Busy,
                "The isolated web reader should return only credit package totals from a successful request");
            Check(international.Reading == null && international.State == "signIn", "WorkBuddy AI keeps its own account, untouched by WorkBuddy's sign-in");
            Check(ProviderWebDefinition.WorkBuddy(false).ID == "workbuddy-ai" && ui.Has("workbuddy-ai.login.title") && ProviderWebDefinition.WorkBuddy(true).ID == "workbuddy",
                "Each edition's sign-in window uses its own wording");
            // The host forwards the bill to the engine, which words the dial and the breakdown for every view.
            await PresentationWait.CommandSnapshotAsync(engine, "setAccountCredits", new { provider = "workbuddy", accountCredits = account.EngineCredits(), stale = false });
            string Spoken(string field) => Find<FrameworkElement>(settings, prefix + "." + field) is { } element ? AutomationProperties.GetName(element) : "";
            await PresentationWait.UntilAsync(() => Spoken("credits_line2").Contains("520.5", StringComparison.Ordinal),
                "The native settings page must display available credits without opening the browser");
            Check(Require<TextBlock>(settings, prefix + ".account_state").Text.StartsWith(ui.Text("harness.account.signed_in"), StringComparison.Ordinal)
                && Require<Button>(settings, prefix + ".account_options").IsVisible && Find<Button>(settings, prefix + ".sign_in")?.IsVisible != true,
                "Once signed in, the account row offers its menu instead of Sign In");
            Check(account.Reading!.Cycle is { Remaining: 420.5, Total: 500, Used: 67.25 } cycle &&
                cycle.ResetsAt?.ToUnixTimeSeconds() == reset.ToUnixTimeSeconds() + 1 &&
                Spoken("credits_line0").Contains("420.5 / 500", StringComparison.Ordinal) && Spoken("credits_line0").Contains("Refreshes", StringComparison.Ordinal),
                "This month's line must use the subscription's own credits and refresh");
            Check(account.Reading.Expiration is { Credits: 100 } exp && exp.At.ToUnixTimeSeconds() == expiration.ToUnixTimeSeconds() &&
                Spoken("credits_line1").Contains("100 credits", StringComparison.Ordinal) && Spoken("credits_line1").Contains("Earliest expiry", StringComparison.Ordinal),
                "Extra credits show as an amount with their own expiry, separate from the plan refresh");
            Check(Spoken("credits_planBase").Contains("420.5 / 500", StringComparison.Ordinal) && Spoken("credits_reward").StartsWith("Reward credits 100", StringComparison.Ordinal)
                && !Spoken("credits_reward").Contains('/'), "The breakdown groups refreshing and lapsing credits, and extra credits have no share");
            Check(reads > 0 && cycles > 0 && writes == 0, "The browser must only make the read-only billing requests");
            // The page's dial draws with the page's ink: the island's light figure vanished on a light page (11/16 review).
            Check(Require<QuotaDial>(settings, prefix + ".credits_dial").FigureInk.ToString() == settings.TryFindResource("SettingsPrimary")?.ToString(),
                "The settings credits dial must draw its figure in the page's own primary ink");

            await settings.NavigateAsync("overview");
            await PresentationWait.UntilAsync(() => Find<QuotaDial>(settings, "settings.overview.workbuddy.account.remaining")?.AccessibleName.Contains(monthly, StringComparison.Ordinal) == true,
                "Overview must show the same account value");
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync();
            Check(Require<QuotaDial>(island, readout).AccessibleName.Contains(monthly, StringComparison.Ordinal) &&
                Find<FrameworkElement>(island, "island.section.quota.workbuddy") != null,
                "The expanded island must show the account value");
            Check(!Descendants(island).OfType<TextBlock>().Any(v => v.IsVisible && v.Text == ui.Text("provider.none_enabled")),
                "WorkBuddy by itself counts as an enabled service");
            // With the row to itself, each credit line reads as a label, a value and its date like Codex's
            // single view, and the dial keeps that view's inset in both styles (classic once sat 9 px out).
            double? splitInset = null;
            foreach (string style in new[] { "split", "classic" })
            {
                island.ApplyPreferences(choices with { ExpandedQuotaStyle = style }); await island.WaitForPresentationAsync();
                var alone = Require<FrameworkElement>(island, "island.section.quota.workbuddy");
                double inset = Require<QuotaDial>(alone, readout).TranslatePoint(new Point(), alone).X;
                splitInset ??= inset;
                var line = Require<FrameworkElement>(alone, "island.workbuddy.account.line0");
                var parts = Descendants(line).OfType<TextBlock>().ToArray();
                var label = parts.FirstOrDefault(text => text.Text == "Monthly");
                var value = parts.FirstOrDefault(text => text.Text == "420.5 / 500");
                // The values end at the section's right edge, as Codex's single view does (11/15 they stopped short).
                double right = value?.TranslatePoint(new Point(value.ActualWidth, 0), alone).X ?? 0;
                Check(Math.Abs(right - alone.ActualWidth) < 12, "WorkBuddy's credit values must reach the section's right edge: " + right + " of " + alone.ActualWidth);
                Check(label != null && value != null && parts.Any(text => text.Text.StartsWith("Refreshes", StringComparison.Ordinal)) &&
                    value.TranslatePoint(new Point(), line).X > label.TranslatePoint(new Point(), line).X + label.ActualWidth &&
                    AutomationProperties.GetName(line).Contains("420.5 / 500", StringComparison.Ordinal) && Math.Abs(inset - splitInset.Value) < 1,
                    "WorkBuddy's own row must read label, value and date per line, its " + style + " dial inset like the single view: " + inset);
            }
            island.ApplyPreferences(choices); await island.WaitForPresentationAsync();

            await CheckTaskReading();
            await CheckSwitchAndSleep();

            await settings.NavigateAsync("expandedPanel");
            await PresentationWait.UntilAsync(() => Find<Button>(settings, "panel.block.workbuddy.toggle")?.Tag as string == "added",
                "The panel editor should list the active account credits block");
            Invoke(Require<Button>(settings, "panel.block.workbuddy"));
            await PresentationWait.UntilAsync(() => Find<RadioButton>(settings, "panel.option.workbuddy.style.classic")?.IsVisible == true &&
                Find<Button>(settings, "panel.link.workbuddy")?.IsVisible == true,
                "The WorkBuddy inspector should offer the same layout choices and a direct link to its account settings");
            Invoke(Require<Button>(settings, "panel.block.workbuddy.toggle"));
            // The page finishes saving before its blocks take another edit; the engine and island can be faster.
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.ExpandedPanel?.Sections.All(s => !s.Providers.Contains("workbuddy")) == true &&
                Find<QuotaDial>(island, readout) == null && Find<Button>(settings, "panel.block.workbuddy.toggle") is { IsEnabled: true, Tag: "add" },
                "The credits block should be removable");
            Invoke(Require<Button>(settings, "panel.block.workbuddy.toggle"));
            await PresentationWait.UntilAsync(() => Find<QuotaDial>(island, readout) != null,
                "Restoring the credits block should use the current account reading without reconnecting");

            string[] providers = ["codex", "claude", "deepseek", "workbuddy"];
            await PresentationWait.CommandSnapshotAsync(engine, "configure", (choices with
            {
                ProviderModes = providers.ToDictionary(id => id, _ => "enabled")
            }).EngineConfiguration());
            await island.WaitForPresentationAsync();
            var section = engine.LatestSnapshot!.ExpandedPanel!.Sections.Single(s => s.Kind == "quota");
            Check(section.Providers.SequenceEqual(providers) && section.Split?.Columns == 2 && section.Classic?.Columns == 2,
                "All four services must share one two-column quota section in both styles");
            string groupId = "island.section.quota." + string.Join("-", providers);
            foreach (string style in new[] { "split", "classic" })
            {
                island.ApplyPreferences(choices with { ExpandedQuotaStyle = style });
                await island.WaitForPresentationAsync();
                var group = Require<FrameworkElement>(island, groupId);
                var dial = Require<QuotaDial>(group, readout);
                var images = Descendants(group).OfType<Image>().Select(image => image.Source).ToArray();
                var dials = Descendants(group).OfType<QuotaDial>().Where(item => item.IsVisible).ToArray();
                Check(dial.AccessibleName.Contains(monthly, StringComparison.Ordinal) && dials.Length == 4 &&
                    providers.All(id => ProviderIcon.Source(id) is { } icon && images.Contains(icon)),
                    "Each service in the shared section must have a dial and its official icon: " + style + ", " + dial.AccessibleName + ", " + dials.Length
                    + " dials, no icon for " + string.Join("/", providers.Where(id => ProviderIcon.Source(id) is not { } icon || !images.Contains(icon))));
                var origins = dials.Select(item => item.TranslatePoint(new Point(), group)).ToArray();
                Check(Math.Abs(origins[0].X - origins[2].X) < 1 && Math.Abs(origins[1].X - origins[3].X) < 1 &&
                    origins[2].Y > origins[0].Y && origins[3].Y > origins[1].Y,
                    "The rendered dials must occupy two columns and two rows");
            }

            // An enterprise member's credits are the quota the team assigns, plus any gift, for the account
            // the site has chosen (#241): 1000 assigned with 250 used, and 150 of a 200 gift left.
            int personalReads = reads;
            enterprise = true;
            await account.RefreshAsync();
            Check(account.Reading is { Remaining: 900, Total: 1200, Plan: "企业版", Cycle: { Total: 1200, Remaining: 900, Used: 300 } } enterpriseReading
                && enterpriseReading.Cycle.ResetsAt?.ToUnixTimeSeconds() == enterpriseEnd.ToUnixTimeSeconds() + 1
                && enterpriseReads > 0 && enterpriseHeader == "fixture-team" && reads == personalReads && writes == 0,
                "An enterprise member reads the team's assigned quota and gift, for the chosen team, without the personal bill");
            await PresentationWait.CommandSnapshotAsync(engine, "setAccountCredits", new { provider = "workbuddy", accountCredits = account.EngineCredits(), stale = false });
            await settings.NavigateAsync("workbuddy");
            await PresentationWait.UntilAsync(() => Find<TextBlock>(settings, prefix + ".account_state")?.Text.EndsWith(" · 企业版", StringComparison.Ordinal) == true
                && Spoken("credits_line0").Contains("900 / 1,200", StringComparison.Ordinal) && Spoken("credits_line1").Contains("900", StringComparison.Ordinal),
                "Settings must name the enterprise plan and show its remaining credits");
            Check(Find<FrameworkElement>(settings, prefix + ".credits_line0") is { } planLine && Descendants(planLine).OfType<TextBlock>().Any(text => text.Text == "企业版")
                && Find<FrameworkElement>(settings, prefix + ".credits_line2") == null,
                "The enterprise plan's badge sits with the month's credits, and a team quota has no extra-credit line");
            enterprise = false;
            await account.RefreshAsync();
            Check(account.Reading is { Remaining: 520.5, Total: 600 } && account.Reading.Plan != "企业版" && reads > personalReads,
                "A personal account goes back to the personal bill");
            await PresentationWait.CommandSnapshotAsync(engine, "setAccountCredits", new { provider = "workbuddy", accountCredits = account.EngineCredits(), stale = false });

            cycleUnavailable = true;
            await account.RefreshAsync();
            Check(account.Reading is { Remaining: 520.5, Cycle: { ResetsAt: null }, Expiration: null },
                "Missing package details must keep the current balance and plan totals");
            serviceDown = true;
            await account.RefreshAsync();
            Check(account.Reading?.Remaining == 520.5 && account.State == "unavailable",
                "A transient billing failure must keep the last amount marked as stale");
            serviceDown = false;
            await account.RefreshAsync();
            Check(account.Reading?.Remaining == 520.5, "A later refresh must restore the reading");
            await account.DisconnectAsync();
            Check(account.Reading == null && account.State == "signIn", "Disconnect must clear the displayed reading");
            int beforeDisconnectedRefresh = reads;
            await account.RefreshAsync();
            Check(reads == beforeDisconnectedRefresh && !account.CanDisconnect, "A disconnected browser profile cannot resume account polling");
            Check(international.Reading == null && international.State == "signIn", "Signing out of WorkBuddy leaves WorkBuddy AI's account alone");
            Console.WriteLine("PASS WorkBuddy account credits, plan reset and pack expiry, Settings, Overview, both shared quota layouts, official icons, refresh recovery and site isolation.");
        }
        finally
        {
            account.SetEnabled(false); island.StopPresentation(); island.AllowClose = true; island.Close();
            settings.AllowClose = true; settings.Close();
            await account.DisposeAsync();
            await PresentationWait.RemoveBrowserFixtureAsync(root);
        }
    }

    private static T? Find<T>(DependencyObject root, string id) where T : DependencyObject =>
        Descendants(root).OfType<T>().FirstOrDefault(value => AutomationProperties.GetAutomationId(value) == id);
    private static T Require<T>(DependencyObject root, string id) where T : DependencyObject =>
        Find<T>(root, id) ?? throw new InvalidOperationException("Missing control: " + id);
    private static System.Collections.Generic.IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var value in Descendants(child)) yield return value;
        }
    }
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }

    /// A switch clears the browser profile before the sign-in (Windows kept the old
    /// session and the window closed itself), and sleep keeps the last reading so a
    /// failed first read after waking marks it stale instead of emptying it.
    private static async Task CheckSwitchAndSleep()
    {
        var fake = new RecordingSession();
        await using var connection = new HarnessAccountConnection("workbuddy", fake, Application.Current.Dispatcher);
        connection.SetEnabled(true);
        await PresentationWait.UntilAsync(() => connection.Reading != null && !connection.Busy, "The recording account reads at once");
        fake.Calls.Clear();
        await connection.SwitchAsync();
        Check(fake.Calls.SequenceEqual(["clear", "signIn", "read"]), "Switching accounts must clear the browser profile first: " + string.Join(",", fake.Calls));
        connection.SetSleeping(true);
        Check(connection.Reading != null, "Sleep keeps the last reading");
        fake.FailReads = true;
        connection.SetSleeping(false);
        await PresentationWait.UntilAsync(() => !connection.Busy && connection.State == "unavailable", "A failed read after waking marks the account unavailable");
        Check(connection.Reading != null && connection.EngineCredits() != null, "A failed first read after waking keeps the last reading for the engine");
    }

    private sealed class RecordingSession : IHarnessAccountSession
    {
        internal readonly System.Collections.Generic.List<string> Calls = [];
        internal bool FailReads;
        public bool Available => true;
        public bool IsConnected => true;
        public Task<HarnessAccountReply> ReadCreditsAsync(System.Threading.CancellationToken cancellation)
        {
            Calls.Add("read");
            return FailReads ? Task.FromException<HarnessAccountReply>(new IOException("offline")) : new DemoHarnessAccountSession().ReadCreditsAsync(cancellation);
        }
        public Task<bool> SignInAsync(System.Threading.CancellationToken cancellation) { Calls.Add("signIn"); return Task.FromResult(true); }
        public Task ClearAsync(System.Threading.CancellationToken cancellation) { Calls.Add("clear"); return Task.CompletedTask; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private static async Task CheckTaskReading()
    {
        var value = new EngineTaskRow("workbuddy-row-fixture", "workbuddy", "Fixture task", "Working",
            null, null, null, "running", "sparkle", null, "Deepseek-V4.1-Flash", "High", 6.8, true,
            null, "0:03", 0, false, false, false, "0.57 credits", false, RateText: "6.8",
            ProgressState: "reported", ProgressFraction: 0.73, ProgressText: "73%", ProgressMode: "working");
        var row = new TaskRow(value); row.SetAnimations(false);
        var window = new Window { Content = row, Width = 430, Height = 110, ShowActivated = false, ShowInTaskbar = false };
        window.Show();
        try
        {
            await PresentationWait.UntilAsync(() => row.IsLoaded, "The task row must be in the visual tree");
            window.UpdateLayout();
            Check(Descendants(row).OfType<TextBlock>().Where(label => label.IsVisible).Select(label => label.Text)
                .Contains("0.57 credits"), "The task charge must appear on the row, separate from account credits");
            string name = new ButtonAutomationPeer(row).GetName();
            Check(name.Contains("Deepseek-V4.1-Flash") && name.Contains("High") && name.Contains("6.8 t/s") &&
                name.Contains("0.57 credits") && name.Contains("73%"), "The task reading must expose model, effort, rate, cost and reported progress");
            Check(Math.Abs(row.StatusIcon.Ring.DisplayFraction - 0.73) < 0.001, "The native icon must draw the actual reported progress");
        }
        finally { window.Close(); }
    }
}
