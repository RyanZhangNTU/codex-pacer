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

    internal static async Task Run()
    {
        string root = Path.Combine(Path.GetTempPath(), "pacer-credits-" + Guid.NewGuid().ToString("N"));
        var ui = UiText.For(false);
        CoreWebView2? login = null;
        int reads = 0, cycles = 0, writes = 0;
        bool authenticated = false, serviceDown = false, cycleUnavailable = false;
        DateTimeOffset reset = DateTimeOffset.UtcNow.AddDays(17);
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
                else if (e.Request.Method != "GET") writes++;
                e.Response = core.Environment.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(body)),
                    status, "Fixture", "Content-Type: " + type + "\r\nCache-Control: no-store");
            };
        }
        var china = new WorkBuddyAccountSession(ui, true, Path.Combine(root, "cn"), Attach);
        var international = new WorkBuddyAccountSession(ui, false, Path.Combine(root, "ai"), Attach);
        await using var account = new HarnessAccountConnection(international, china, true, Application.Current.Dispatcher);
        await using var engine = new EngineClient();
        var choices = new DesktopPreferences
        {
            LastSettingsPane = "overview", MonitorSSH = false,
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled", ["workbuddy"] = "enabled" }
        };
        var preferences = new PreferencesSession(choices, value => engine.SendAsync("configure", value), _ => true);
        var settings = new SettingsWindow(ui, preferences, new DemoStartupRegistration(), true, engine: engine, harnessAccount: account)
            { ShowActivated = false, IsHitTestVisible = false };
        var island = new IslandWindow(engine, true, false, animationOverride: false, harnessAccount: account)
            { ShowActivated = false, IsHitTestVisible = false };
        const string readout = "island.workbuddy.account.remaining";
        const string balance = "520.5 credits available";
        const string prefix = "settings.workbuddy.account";
        try
        {
            settings.Show(); island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), false, "en",
                configuration: choices.EngineConfiguration(), readOnlyDiagnostics: true);
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.Modules?.Any(m => m is { Provider: "workbuddy", Enabled: true, ReportsAccountCredits: true }) == true,
                "A WorkBuddy-only engine must advertise its separate account capability");
            account.SetEnabled(true);
            await settings.NavigateAsync("workbuddy");
            await PresentationWait.UntilAsync(() => Find<TextBlock>(settings, prefix + ".state")?.Text == ui.Text("harness.account.sign_in"),
                "Settings should distinguish a disconnected account from zero credits");
            Invoke(Require<Button>(settings, prefix + ".connect"));
            await PresentationWait.UntilAsync(() => login != null, "The visible WorkBuddy login must use the selected site");
            var window = Application.Current.Windows.OfType<ProviderLoginWindow>().Single();
            await PresentationWait.UntilAsync(() => Require<Button>(window, "workbuddy.login.continue").IsEnabled, "The login must allow the user to verify it");
            authenticated = true;
            Invoke(Require<Button>(window, "workbuddy.login.continue"));
            await PresentationWait.UntilAsync(() => account.Reading is { Remaining: 520.5, Total: 600, Reserved: 12.25 } && !account.Busy,
                "The isolated web reader should return only credit package totals from a successful request");
            await PresentationWait.UntilAsync(() => Find<TextBlock>(settings, prefix + ".remaining")?.Text == balance,
                "The native settings page must display available credits without opening the browser");
            Check(Require<TextBlock>(settings, prefix + ".total").Text == "Credits across packs: 600", "The grants across active packs should be visible");
            Check(Require<TextBlock>(settings, prefix + ".reserved").Text == "Reserved: 12.25", "The reserved amount should remain separate");
            Check(account.Reading!.Cycle is { Remaining: 420.5, Total: 500, Used: 67.25 } cycle &&
                cycle.ResetsAt?.ToUnixTimeSeconds() == reset.ToUnixTimeSeconds() + 1 &&
                Require<TextBlock>(settings, prefix + ".reset").IsVisible &&
                Require<TextBlock>(settings, prefix + ".cycle").Text == "Plan credits left: 420.5 / 500",
                "The plan window must use the subscription's own credits and reset");
            Check(account.Reading.Expiration is { Credits: 100 } exp && exp.At.ToUnixTimeSeconds() == expiration.ToUnixTimeSeconds() &&
                Require<TextBlock>(settings, prefix + ".expiring").IsVisible, "A top-up's deduction deadline is separate from the plan reset");
            Check(reads > 0 && cycles > 0 && writes == 0, "The browser must only make the read-only billing requests");

            await settings.NavigateAsync("overview");
            Check(Require<QuotaDial>(settings, "settings.overview.workbuddy.account.remaining").AccessibleName == balance,
                "Overview must show the same account value");
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync();
            Check(Require<QuotaDial>(island, readout).AccessibleName == balance &&
                Find<FrameworkElement>(island, "island.section.quota.workbuddy") != null,
                "The expanded island must show the account value");
            Check(!Descendants(island).OfType<TextBlock>().Any(v => v.IsVisible && v.Text == ui.Text("provider.none_enabled")),
                "WorkBuddy by itself counts as an enabled service");

            await CheckTaskReading();

            await settings.NavigateAsync("expandedPanel");
            await PresentationWait.UntilAsync(() => Find<Button>(settings, "panel.block.workbuddy.toggle")?.Tag as string == "added",
                "The panel editor should list the active account credits block");
            Invoke(Require<Button>(settings, "panel.block.workbuddy"));
            await PresentationWait.UntilAsync(() => Find<RadioButton>(settings, "panel.option.workbuddy.style.classic")?.IsVisible == true &&
                Find<Button>(settings, "panel.link.workbuddy")?.IsVisible == true,
                "The WorkBuddy inspector should offer the same layout choices and a direct link to its account settings");
            Invoke(Require<Button>(settings, "panel.block.workbuddy.toggle"));
            await PresentationWait.UntilAsync(() => engine.LatestSnapshot?.ExpandedPanel?.Sections.All(s => !s.Providers.Contains("workbuddy")) == true &&
                Find<QuotaDial>(island, readout) == null, "The credits block should be removable");
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
                Check(dial.AccessibleName == balance && dials.Length == 4 &&
                    providers.All(id => ProviderIcon.Source(id) is { } icon && images.Contains(icon)),
                    "Each service in the shared section must have a dial and its official icon");
                var origins = dials.Select(item => item.TranslatePoint(new Point(), group)).ToArray();
                Check(Math.Abs(origins[0].X - origins[2].X) < 1 && Math.Abs(origins[1].X - origins[3].X) < 1 &&
                    origins[2].Y > origins[0].Y && origins[3].Y > origins[1].Y,
                    "The rendered dials must occupy two columns and two rows");
            }

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
            account.SelectSite(false);
            Check(account.Reading == null && account.State == "signIn", "Switching sites must discard the previous site's balance");
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
