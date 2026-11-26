using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using CodexPacer.Windows;

internal static class AntigravityPresentationChecks
{
    private const string Provider = "antigravity";
    private const string Prefix = "settings.antigravity.";

    internal static async Task Run(string language, bool dark, string output)
    {
        var ui = UiText.For(language == "zh-Hans");
        string root = Path.Combine(Path.GetTempPath(), "pacer-antigravity-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var store = new PreferencesStore(Path.Combine(root, "preferences.json"));
        _ = store.Load();
        var initial = new DesktopPreferences { LastSettingsPane = "overview", MonitorSSH = false,
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled" } };
        Check(store.Save(initial), "The demo preferences must use the temporary profile");
        await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
            configuration: initial.EngineConfiguration(), referenceFixture: true, demoAntigravity: true);
        EngineModule? Module() => engine.LatestSnapshot?.Modules?.FirstOrDefault(m => m.Provider == Provider);
        await PresentationWait.UntilAsync(() => Module()?.QuotaGroups != null, "The reference engine must advertise Antigravity's groups");
        var groups = Module()!.QuotaGroups!;
        var sample = engine.LatestSnapshot!;
        Check(Module() is { Enabled: true, Installed: true } && groups.Selected == "gemini" && groups.Options.Count == 2,
            "The demo must automatically enable the installed module with Gemini selected");
        var tasks = sample.Tasks.Where(t => t.Provider == Provider).ToArray();
        Check(tasks.Length == 4 && tasks.Any(t => t.ParentThreadId != null) && tasks.Any(t => t.TokensPerSecond > 0)
            && sample.Requests.Any(r => r.Provider == Provider), "The demo must include a child, a final rate and a pending approval");
        Check(ProviderIcon.Source(Provider) != null && ProviderIcon.Source(Provider, outline: true) != null,
            "The sidebar and launch button must have packaged Antigravity icons");
        var session = new PreferencesSession(initial, value => engine.SendAsync("configure", value), store.Save);
        Uri? website = null;
        var settings = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, dark, engine,
            guideLinkLauncher: uri => { website = uri; return true; }) { ShowActivated = false };
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { ShowActivated = false, IsHitTestVisible = false };
        try
        {
            settings.Show(); island.Show(); island.ApplyPreferences(initial);
            await settings.NavigateAsync(Provider);
            await Wait(settings, Prefix + "group");
            var choice = Get<ComboBox>(settings, Prefix + "group");
            Check(Name(choice) == groups.Title && Equals(choice.SelectedValue, "gemini")
                && Texts(settings).Contains(ui.Text("harness.account.signed_in"))
                && Texts(settings).Any(t => t.Contains("66%")), "The account, weekly usage and group picker must match the reading");
            Check(Get<Button>(settings, Prefix + "open").IsVisible && Get<Button>(settings, Prefix + "refresh").IsEnabled,
                "The module must offer Open Antigravity and Refresh");
            Click(Get<Button>(settings, Prefix + "website"));
            Check(website?.AbsoluteUri == "https://antigravity.google/", "The module's website must use its descriptor URL");
            var guide = Module()!.ProgressGuide!;
            Check(guide.Stage == "allowTool" && guide.Steps.Count == 4 && guide.Steps[1].Title == ui.Text("progress_guide.plugin.restart")
                && Name(Get<Button>(settings, Prefix + "progress_copy")).Contains(guide.Steps[2].CopyText!),
                "The plugin guide must explain restarting and approving the named server");
            CheckGuideStates(settings, ui, guide);
            settings.CapturePreview(Path.Combine(output, $"antigravity-settings-{language}-{(dark ? "dark" : "light")}.png"));

            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync();
            await Wait(island, "quota.antigravity.group");
            Check(Name(Get<TextBlock>(island, "quota.antigravity.group")) == groups.Options[0].Label
                && Find<StackPanel>(island, "quota.antigravity.resetDetails") != null, "Gemini must show its group and reset details");
            choice.SelectedValue = "3p";
            await PresentationWait.UntilAsync(() => Module()?.QuotaGroups?.Selected == "3p"
                && session.Current.HarnessQuotaGroups.GetValueOrDefault(groups.DefaultsKey) == "3p",
                "Changing groups must reach the preferences session and the engine");
            Check(store.Load().Value.HarnessQuotaGroups.GetValueOrDefault(groups.DefaultsKey) == "3p", "The selected group must survive reloading preferences");
            string thirdParty = groups.Options.Single(g => g.Id == "3p").Label;
            await PresentationWait.UntilAsync(() => Find<TextBlock>(island, "quota.antigravity.group")?.Text == thirdParty, "The island must switch groups");
            Check(Find<StackPanel>(island, "quota.antigravity.resetDetails") == null && Texts(settings).Any(t => t.Contains("100%")),
                "A full group without a reset time must omit reset details and show full weekly usage");
            var withCompactQuota = await NativeCompactBar.Shared.EditAsync(session.Current, language, [Provider], new("show", "quota"));
            island.ApplyPreferences(withCompactQuota);
            await PresentationWait.UntilAsync(() => Find<Button>(island, "compact.row.quota") is { } slot &&
                UIElementAutomationPeer.CreatePeerForElement(slot)?.GetName().Contains(thirdParty) == true,
                "The rendered compact quota button must announce the selected group");
            var projection = await NativeCompactBar.Shared.ReadAsync(withCompactQuota, language, [Provider], engine.LatestSnapshot!.CompactContext);
            var quota = projection.Components.Single(c => c.Id == "quota");
            Check(quota.Help.Contains(thirdParty) && quota.Accessibility.Contains(thirdParty), "Compact help and accessibility must identify the selected group");

            await settings.NavigateAsync("collapsed"); settings.SelectCompactComponent("quota");
            await Wait(settings, "compact.window.antigravity");
            var window = Get<ComboBox>(settings, "compact.window.antigravity");
            Check(window.Items.Count == 3, "The compact quota window must offer automatic, five-hour and weekly readings");
            window.SelectedValue = "7d";
            await PresentationWait.UntilAsync(() => session.Current.ModuleWindows.GetValueOrDefault(Provider) == "7d", "The module must save its compact window");
            await settings.NavigateAsync("expandedPanel"); settings.SelectPanelBlock(Provider);
            await Wait(settings, "panel.option.antigravityPeriods.weekly");
            foreach (string style in new[] { "classic", "split" })
            {
                string id = "panel.option.antigravity.style." + style;
                await Wait(settings, id);
                Get<RadioButton>(settings, id).IsChecked = true;
                await PresentationWait.UntilAsync(() => session.Current.ExpandedQuotaStyle == style && Get<RadioButton>(settings, id).IsEnabled,
                    "The Antigravity block must save the selected quota style");
            }
            Get<RadioButton>(settings, "panel.option.antigravityPeriods.weekly").IsChecked = true;
            await PresentationWait.UntilAsync(() => session.Current.ExpandedPanelOptions?.Contains("weekly") == true, "The panel must save the module's periods");
            const string tile = "panel.block.antigravity.toggle";
            await PresentationWait.UntilAsync(() => Get<Button>(settings, tile) is { IsEnabled: true, Tag: "added" }, "Antigravity must start in the panel");
            Click(Get<Button>(settings, tile));
            await PresentationWait.UntilAsync(() => Get<Button>(settings, tile) is { IsEnabled: true, Tag: "add" }
                && !PresentationWait.Places(session.Current.ExpandedPanelLayout, Provider), "The editor must remove Antigravity");
            Click(Get<Button>(settings, tile));
            await PresentationWait.UntilAsync(() => Get<Button>(settings, tile) is { Tag: "added" }
                && PresentationWait.Places(session.Current.ExpandedPanelLayout, Provider), "The editor must add Antigravity");
            await settings.NavigateAsync("history");
            await Wait(settings, "quota.history.week.gemini");
            Check(Name(Get<TextBlock>(settings, "quota.history.week.gemini")).Contains(groups.Options[0].Label)
                && Name(Get<TextBlock>(settings, "quota.history.week.3p")).Contains(thirdParty),
                "History must keep both weekly groups when the selected group changes");
            settings.CapturePreview(Path.Combine(output, $"antigravity-history-{language}-{(dark ? "dark" : "light")}.png"));

            var reading = engine.LatestSnapshot!.QuotaDashboard!.Providers.Single(p => p.Provider == Provider);
            var weeks = reading.GroupWeeks!;
            var chart = weeks.Single(w => w.Id == "gemini").Chart;
            Check(chart != null && weeks.Single(w => w.Id == "3p").Chart == null, "Only a measured cycle can supply chart points");
            var history = new QuotaHistoryView(ui, PacerPalette.Provider(Provider), () => Task.CompletedTask);
            history.Update(reading.History, weeks.Select(w => w with { Chart = chart }).ToArray());
            Check(Descendants(history).OfType<QuotaHistoryChart>().Count() == 2, "Both measured weekly cycles must draw their own chart");

            await settings.NavigateAsync("modules");
            await Wait(settings, "settings.modules.antigravity");
            Check(Get<RadioButton>(settings, "settings.pane.antigravity").IsVisible, "An installed module belongs in the sidebar");
            await settings.NavigateAsync("help");
            await Wait(settings, "help.module.antigravity");
            Get<RadioButton>(settings, "help.module.antigravity").IsChecked = true;
            foreach (string topic in new[] { "tasks", "speed", "quota", "progress", "apps" })
                await Wait(settings, "help.antigravity." + topic);

            var catalog = await engine.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide =
                new GuideRequest("4.7.0", null, 4, language, true, false, true, false) } });
            var missing = sample with { Modules = [Module()! with { ApplicationInstalled = false }] };
            var welcome = new GuideContent(ui, session, new DemoStartupRegistration(), catalog, _ => { }, () => { },
                launch: uri => { website = uri; return true; }, snapshot: () => missing);
            var guideWindow = new GuideWindow(ui, welcome, catalog, dark) { ShowActivated = false };
            try
            {
                guideWindow.Show(); welcome.WelcomeStep(2); welcome.Refresh(); guideWindow.UpdateLayout();
                var get = Get<Button>(welcome, "welcome.module.antigravity.action");
                website = null; Click(get);
                Check(Name(get) == ui.Text("modules.get").Replace("%@", "Antigravity") && website?.AbsoluteUri == "https://antigravity.google/",
                    "Welcome must offer Get when a data folder remains without the app");
            }
            finally { guideWindow.Close(); }
            Console.WriteLine($"PASS Antigravity settings, plugin guide, island, History, Help and Welcome ({language}, {(dark ? "dark" : "light")})");
        }
        finally
        {
            settings.AllowClose = true; settings.Close();
            island.StopPresentation(); island.AllowClose = true; island.Close();
            Directory.Delete(root, true);
        }
    }

    private static void CheckGuideStates(SettingsWindow settings, UiText ui, HarnessProgressGuide guide)
    {
        foreach (var (stage, index) in new[] { ("adding", 0), ("restartForPlugin", 1), ("allowTool", 2) })
        {
            var steps = guide.Steps.Select((step, i) => step with { State = i < index ? "done" : i == index ? "current" : "pending" }).ToArray();
            settings.RefreshHarnessProgressGuide(Provider, guide with { Stage = stage, Steps = steps }, true);
            settings.UpdateLayout();
            var current = Get<Grid>(settings, Prefix + "progress_step" + index);
            Check(Name(current) == steps[index].Title && AutomationProperties.GetItemStatus(current) == ui.Text("progress_guide.state.current"),
                "The current plugin step must have a localized accessible state");
        }
        string quit = ui.Text("progress_guide.plugin.quit");
        settings.RefreshHarnessProgressGuide(Provider, guide with { Stage = "removalPending", Steps = [], Line = quit,
            Action = "retry", ActionTitle = ui.Text("progress_guide.action.retry") }, true);
        settings.UpdateLayout();
        Check(Get<TextBlock>(settings, Prefix + "progress_line").Text == quit && Get<Button>(settings, Prefix + "progress_action").IsVisible,
            "Pending removal must explain when to quit the app and offer a retry");
        settings.RefreshHarnessProgressGuide(Provider, guide with { Stage = "ready", Steps = [], Line = null, Action = null }, true);
        Check(Get<StackPanel>(settings, Prefix + "progress_guide").Visibility == Visibility.Collapsed, "A ready plugin must retire its steps");
        settings.RefreshHarnessProgressGuide(Provider, guide, true);
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static string Name(DependencyObject element) => AutomationProperties.GetName(element);
    private static Task Wait(DependencyObject root, string id) => PresentationWait.UntilAsync(
        () => Find<FrameworkElement>(root, id)?.IsVisible == true, "Expected visible control " + id);
    private static T Get<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Find<T>(root, id) ?? throw new InvalidOperationException("Missing " + id);
    private static T? Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().FirstOrDefault(x => AutomationProperties.GetAutomationId(x) == id);
    private static IEnumerable<string> Texts(DependencyObject root) => Descendants(root).OfType<TextBlock>().Select(t => t.Text);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    private static void Check(bool valid, string message) { if (!valid) throw new InvalidOperationException(message); }
}
