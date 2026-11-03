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
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class HarnessNavigationChecks
{
    internal static async Task Run(string language, bool motion, string output)
    {
        string fixture = Environment.GetEnvironmentVariable("PACER_HARNESS_DESKTOP_FIXTURE")
            ?? throw new InvalidOperationException("The synthetic Harness metadata fixture is required.");
        var native = new WindowsHarnessApplication(Path.Combine(AppContext.BaseDirectory, "Engine"));
        var opened = new List<string>(); bool launchSucceeds = false, installed = true;
        var apps = new WindowsDesktopApplications(_ => false, _ => false, () => installed ? fixture : null, native.IsApplication,
            path => { opened.Add(path); return launchSucceeds; });
        await using var engine = new EngineClient();
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: motion, desktopApplications: apps)
            { IsHitTestVisible = false, ShowActivated = false };
        var ui = UiText.For(language == "zh-Hans");
        try
        {
            island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            var buttons = (StackPanel)island.FindName("AppButtons");
            var harness = buttons.Children.OfType<Button>().Single();
            Check(AutomationProperties.GetAutomationId(harness) == "island.open.deepseek"
                && new ButtonAutomationPeer(harness).GetName() == ui.Text("windows.open.deepseek")
                && harness.Content is IconGlyph { Symbol: "water.waves" }, "The toolbar needs the shared provider symbol and localized desktop action");
            Check(Descendants(island).OfType<TaskRow>().Where(row => State(row).Provider != "deepseek").All(row =>
                row.IsEnabled == (engine.LatestSnapshot!.ActivityLinks?.Any(link => link.ActivityID == State(row).Id && link.Provider == State(row).Provider) == true)),
                "Conversation actions must be backed by the engine's current source-scoped links");
            await engine.SendAsync("configure", new { enabledProviders = new[] { "deepseek" } });
            await engine.SendAsync("demoStage", new { demoStage = 3 }); await Pump(); await island.WaitForPresentationAsync();
            await Until(() => ((Grid)island.FindName("TaskPages")).Children.Count == 1, "A replaced page must release its outgoing visual");
            var row = Descendants(island).OfType<TaskRow>().Single(); var value = State(row);
            Check(value.Unread && value.Phase == "completed" && row.IsEnabled && row.Focusable && row.ActualHeight == 54,
                "A completed Harness row must retain its native height and support keyboard activation");
            var peer = UIElementAutomationPeer.CreatePeerForElement(row);
            Check(peer.GetAutomationControlType() == AutomationControlType.Button && peer.GetChildren()?.Count is null or 0
                && peer.GetName().Contains(value.Title) && ((string)row.ToolTip).Contains(ui.Text("common.open_chat")),
                "The row must expose one named button and its original open help");
            island.ApplyPreferences(new() { IslandAppearance = "classic", ShowAppButtons = false });
            Check(buttons.Visibility == Visibility.Collapsed && row.IsEnabled, "Hiding app buttons cannot disable task navigation");
            Invoke(harness); await Pump(); Check(opened.Count == 0, "A cached toolbar button cannot bypass the hidden-app-button preference");
            Hover(row, true);
            Check(motion ? row.HasAnimatedProperties : row.HoverProgress == 1 && !row.HasAnimatedProperties,
                "Hover must use the native finite clock or settle immediately under reduced motion");
            await Until(() => row.HoverProgress == 1 && !row.HasAnimatedProperties, "The 120 ms hover must release its animation clock");
            Check(ReferenceEquals(row.Background, PacerPalette.Hover)
                && Descendants(row).OfType<Border>().Any(border => border.CornerRadius == new CornerRadius(12)),
                "Hover must retain the native palette and 12-point row surface");
            island.CapturePreview(Path.Combine(output, "harness-row-" + language + (motion ? "-motion" : "-reduced") + ".png"));
            Hover(row, false); row.SetAnimations(false);
            Check(row.HoverProgress == 0 && !row.HasAnimatedProperties, "Enabling reduced motion must cancel an in-flight hover");
            Hover(row, true); Check(row.HoverProgress == 1 && !row.HasAnimatedProperties, "Reduced hover cannot retain an idle animation");
            Hover(row, false); row.SetAnimations(motion);

            var errorClock = Stopwatch.StartNew();
            Invoke(row); await Until(() => opened.Count == 1, "A task click must reach the shared launcher"); await Pump();
            Check(opened.Single() == fixture && island.LogicalTarget.Height > 38
                && engine.LatestSnapshot!.Presentation!.Rows.Single().Unread, "Failed opens must leave the panel and unread completion intact");
            var status = (TextBlock)island.FindName("StatusLabel");
            Check(status.Text == ui.Text("windows.app.open_failed"), "A launch failure cannot be mislabeled as a missing installation");
            if (language == "en" && !motion)
            {
                await Until(() => status.Visibility == Visibility.Collapsed, "The original error lifetime must clear a failed-open message",
                    TimeSpan.FromSeconds(NativeTaskRowTiming.Shared.NavigationErrorDuration + 5));
                Check(errorClock.Elapsed.TotalSeconds >= NativeTaskRowTiming.Shared.NavigationErrorDuration - 1
                    && engine.LatestSnapshot!.Presentation!.Rows.Single().Unread,
                    $"Error expiry must retain the unread completion: elapsed={errorClock.Elapsed.TotalSeconds:0.00}, required={NativeTaskRowTiming.Shared.NavigationErrorDuration - 1}, unread={engine.LatestSnapshot!.Presentation!.Rows.Single().Unread}");
            }
            launchSucceeds = true;
            await Until(() => row.IsEnabled, "A failed open must release its shared single flight before another explicit click");
            Invoke(row);
            await Until(() => !engine.LatestSnapshot!.Presentation!.Rows.Any(item => item.Id == value.Id && item.Unread) && island.LogicalTarget.Height == 38,
                "A successful open must acknowledge only that completion before collapsing");
            await island.WaitForPresentationAsync();
            Check(opened.Count == 2 && status.Visibility == Visibility.Collapsed, "The successful row action must open once and remove an old failure");
            Invoke(row); await Pump();
            Check(opened.Count == 2, "A cached UI Automation row cannot launch while its panel is collapsed");

            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            launchSucceeds = true; island.ApplyPreferences(new() { IslandAppearance = "classic" });
            var currentHarness = buttons.Children.OfType<Button>().Single();
            Invoke(currentHarness); await Until(() => opened.Count == 3, "The toolbar must use the same launcher");
            Check(!engine.LatestSnapshot!.Presentation!.Rows.Any(item => item.Id == value.Id && item.Unread) && island.LogicalTarget.Height == 38,
                "Opening the desktop alone must collapse the panel without manufacturing an unread event");
            Invoke(currentHarness); await Pump(); Check(opened.Count == 3, "A cached toolbar button cannot launch while its panel is collapsed");
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            await engine.SendAsync("demoStage", new { demoStage = 0 }); await Pump(); await island.WaitForPresentationAsync();
            await Until(() => ((Grid)island.FindName("TaskPages")).Children.Count == 1, "The new running page must finish replacing the completion page");
            Invoke(row); await Pump();
            Check(opened.Count == 3, "A cached row from a replaced page cannot act on the new task while the panel is open");
            installed = false;
            Check(!apps.Open("deepseek"), "Fresh revalidation must detect the missing installation");
            island.ApplyPreferences(new() { IslandAppearance = "classic", ShowAppButtons = false });
            var missingRow = Descendants(island).OfType<TaskRow>().Single();
            Check(!missingRow.IsEnabled && !missingRow.Focusable && (string)missingRow.ToolTip == ui.Text("activity.no_link") && buttons.Children.Count == 0,
                "A missing app must disable its row and remove the toolbar action on refresh");
            Hover(missingRow, true);
            Check(missingRow.HoverProgress == 0 && !missingRow.HasAnimatedProperties && opened.Count == 3,
                "A disabled row cannot animate an available-action surface or launch a candidate");
            Console.WriteLine("PASS Harness navigation " + language + (motion ? "-motion" : "-reduced") + ": native metadata fixture, localized actions, row timing, UIA and acknowledged opens; installed-app acceptance pending");
        }
        finally { island.StopPresentation(); island.AllowClose = true; island.Close(); }
    }
    private static EngineTaskRow State(TaskRow row) => ((TaskRowState)row.DataContext).Value;
    private static void Hover(TaskRow row, bool inside) => row.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount)
        { RoutedEvent = inside ? Mouse.MouseEnterEvent : Mouse.MouseLeaveEvent });
    private static void Invoke(Button button)
    {
        try { ((IInvokeProvider)UIElementAutomationPeer.CreatePeerForElement(button).GetPattern(PatternInterface.Invoke)).Invoke(); }
        catch (ElementNotEnabledException)
        {
            Check(!button.IsEnabled, "UI Automation may reject a retired disabled row without dispatching its old action");
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    { for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) { var child = VisualTreeHelper.GetChild(root, index); yield return child; foreach (var value in Descendants(child)) yield return value; } }
    private static async Task Until(Func<bool> condition, string message, TimeSpan? timeout = null)
    {
        var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < (timeout ?? TimeSpan.FromSeconds(8))) await Task.Delay(20);
        Check(condition(), message); await Pump();
    }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
