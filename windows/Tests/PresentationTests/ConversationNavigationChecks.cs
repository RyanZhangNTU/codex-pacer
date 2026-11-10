using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class ConversationNavigationChecks
{
    internal static async Task Run(string provider, string language, bool motion)
    {
        if (provider == "codex" && language == "en" && motion) await CheckDotRoute();
        var opened = new List<EngineNavigationPlan>(); bool succeed = false;
        TaskCompletionSource<bool>? dispatch = null;
        await using var engine = new EngineClient();
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: motion,
            openConversation: (plan, _) => { opened.Add(plan); return dispatch?.Task ?? Task.FromResult(succeed); })
            { IsHitTestVisible = false, ShowActivated = false };
        var ui = UiText.For(language == "zh-Hans");
        try
        {
            island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine", "PacerEngine.exe"), true, language,
                configuration: new { enabledProviders = new[] { provider } }, referenceFixture: true);
            await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = 3 });
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            var completed = Descendants(island).OfType<TaskRow>().First(row => State(row).Unread);
            string id = State(completed).Id;
            Check(completed.IsEnabled && completed.Focusable && completed.ToolTip == null && System.Windows.Automation.AutomationProperties.GetHelpText(completed).Contains(ui.Text("common.open_chat"), StringComparison.Ordinal), "A provider row must expose its conversation action without changing geometry");
            Check(Math.Abs(completed.ActualHeight - 54) < 0.01, "Conversation actions must preserve the native task row height");
            Invoke(completed); await Until(() => opened.Count == 1 && completed.IsEnabled, "A failed open must finish its single flight");
            await Until(() => engine.LatestSnapshot?.NavigationError != null, "The failed open must publish its shared error");
            Check(Unread(engine, id) && island.LogicalTarget.Height > 36 && ((TextBlock)island.FindName("StatusLabel")).Text == ui.Text("activity.open_failed"), "Failed navigation must preserve the unread task and show its localized error");

            dispatch = new(TaskCreationOptions.RunContinuationsAsynchronously);
            Invoke(completed); await Until(() => opened.Count == 2, "The next explicit click must prepare another scoped open");
            Check(opened[^1].Provider == provider && opened[^1].Kind == "demo", "An offline engine may only return a labeled demo destination");
            // Explicit demo quota retries emit events even for unchanged data.
            // Exercise two real unrelated snapshots with dedup still enabled.
            await PresentationWait.CommandSnapshotAsync(engine, "retryQuota", new { provider });
            await PresentationWait.CommandSnapshotAsync(engine, "retryQuota", new { provider });
            Check(Unread(engine, id), "Unrelated snapshots cannot acknowledge a pending launch");
            dispatch.SetResult(true);
            await Until(() => !Unread(engine, id) && island.LogicalTarget.Height == 36, "A successful open must acknowledge despite unrelated snapshot sequences");
            await island.WaitForPresentationAsync(); Invoke(completed); await Pump();
            Check(opened.Count == 2, "A cached control cannot launch while its panel is collapsed");

            dispatch = null; succeed = true;
            await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = 0 });
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            Invoke(completed); await Pump();
            Check(opened.Count == 2, "A control from the old ending page cannot act on a replacement turn");
        }
        finally { dispatch?.TrySetResult(false); island.StopPresentation(); island.AllowClose = true; island.Close(); }
        // The fixed demo replays the same turn IDs. Use a fresh engine so an
        // intentional earlier acknowledgment cannot make this ending read.
        await NewEnding(provider, language, motion);
        Console.WriteLine("PASS conversation navigation " + provider + " " + language + (motion ? "-motion" : "-reduced") +
            ": actual engine, UIA, failed opens, rate ticks, new endings and disabled-source callbacks");
    }
    private static async Task NewEnding(string provider, string language, bool motion)
    {
        var dispatch = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); int opened = 0;
        await using var engine = new EngineClient();
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: motion,
            openConversation: (_, _) => { opened++; return dispatch.Task; }) { IsHitTestVisible = false, ShowActivated = false };
        try
        {
            island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine", "PacerEngine.exe"), true, language,
                configuration: new { enabledProviders = new[] { provider }, showClaudeCloudProjects = false }, referenceFixture: true);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            var localIDs = engine.LatestSnapshot!.Tasks.Where(task => task.SourceId == null).Select(task => task.Id).ToHashSet();
            var running = Descendants(island).OfType<TaskRow>().First(row => State(row).Phase == "running" && localIDs.Contains(State(row).Id));
            string id = State(running).Id;
            Invoke(running); await Until(() => opened == 1, "A current running conversation must be navigable");
            await PresentationWait.CommandSnapshotAsync(engine, "demoStage", new { demoStage = 3 });
            await island.WaitForPresentationAsync();
            Check(Unread(engine, id), "The new ending must be unread before the old launch returns");
            dispatch.SetResult(true); await Pump();
            await PresentationWait.CommandSnapshotAsync(engine, "refresh", new { }, waitForSnapshot: false);
            await Until(() => engine.LatestSnapshot?.OpeningActivityIDs?.Contains(id) != true,
                "The superseded running-task open must release its captured navigation operation");
            await island.WaitForPresentationAsync();
            Check(Unread(engine, id) && island.LogicalTarget.Height > 36, "An older running-task launch cannot clear a new ending or close its replacement page");
            dispatch = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var current = Descendants(island).OfType<TaskRow>().First(row => State(row).Id == id);
            Invoke(current); await Until(() => opened == 2, "A fresh ending must expose its new navigation token");
            await PresentationWait.CommandSnapshotAsync(engine, "configure", new { enabledProviders = Array.Empty<string>() });
            dispatch.SetResult(true); await Pump();
            await PresentationWait.CommandSnapshotAsync(engine, "refresh", new { }, waitForSnapshot: false);
            await island.WaitForPresentationAsync();
            Check(engine.LatestSnapshot!.Tasks.Count == 0 && island.LogicalTarget.Height > 36, "A disabled source must revoke old launch callbacks");
        }
        finally { dispatch.TrySetResult(false); island.StopPresentation(); island.AllowClose = true; island.Close(); }
    }
    private static async Task CheckDotRoute()
    {
        const string family = "OpenAI.Codex_2p2nqsd0c76g0";
        const string thread = "codex://threads/019a0000-0000-7000-8000-000000000011";
        var launches = new List<(string Family, Uri Destination)>();
        var apps = new WindowsDesktopApplications(registered: value => value == family,
            activateProtocol: (target, uri) => { launches.Add((target, uri)); return Task.FromResult(true); });
        var plan = new EngineNavigationPlan(Guid.NewGuid().ToString(), "codex", "application",
            thread + "?hostId=durable", null, null, null);
        Check(await apps.OpenConversationAsync(plan) && launches.Count == 1 && launches[0].Family == family
            && launches[0].Destination.Query == "?hostId=durable", "Dot must open in the registered Codex Desktop package");
        Check(!await apps.OpenConversationAsync(plan with { Url = thread + "?hostId=durable:other" }) && launches.Count == 1,
            "A different host cannot use the Dot route");
    }
    private static bool Unread(EngineClient engine, string id) => engine.LatestSnapshot?.Presentation?.Rows.Any(row => row.Id == id && row.Unread) == true;
    private static EngineTaskRow State(TaskRow row) => ((TaskRowState)row.DataContext).Value;
    private static void Invoke(Button button)
    {
        try { ((IInvokeProvider)UIElementAutomationPeer.CreatePeerForElement(button).GetPattern(PatternInterface.Invoke)).Invoke(); }
        catch (System.Windows.Automation.ElementNotEnabledException) { }
    }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition, string message)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < PresentationWait.Limit) await Task.Delay(20); Check(condition(), message); await Pump(); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
