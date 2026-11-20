using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class ConversationActivityChecks
{
    internal static async Task Run(string language, string output)
    {
        await using var engine = new EngineClient();
        var groups = new[] { new ConversationGroup("first", "First group", ["a1", "a2"]), new ConversationGroup("second", "Second group", ["b1", "b2"]) };
        var saved = ConversationGroups.Read(null).Update("", groups);
        var window = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false)
            { ShowActivated = false, IsHitTestVisible = false };
        var preferences = new DesktopPreferences { IslandAppearance = "classic", ShowPinnedConversations = true, ConversationGroups = saved };
        try
        {
            window.ApplyPreferences(preferences); window.Show();
            window.ReceiveSnapshot(Snapshot(1)); window.Reveal(); await window.WaitForPresentationAsync();
            Check(RowIDs().SequenceEqual(new[] { "a1", "a2", "b1", "b2", "z1" }), "Idle groups use their saved order");
            window.ReceiveSnapshot(Snapshot(2, "b2")); await Pump();
            Check(RowIDs().SequenceEqual(new[] { "b2", "b1", "a1", "a2", "z1" }), "A running chat raises both its group and its row immediately");
            var switchView = (Button)window.FindName("SwitchConversationView");
            switchView.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Pump();
            Check(RowIDs().SequenceEqual(new[] { "ordinary" }), "All tasks keeps the ordinary feed independently of pins");
            switchView.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Pump();
            var controls = Descendants(window).OfType<TaskRow>().ToArray();
            window.ReceiveSnapshot(Snapshot(3, "b2")); await Pump();
            Check(Descendants(window).OfType<TaskRow>().SequenceEqual(controls), "Unchanged activity keeps the same controls rather than repeatedly sorting the UI");
            window.CapturePreview(Path.Combine(output, "groups-active-" + language + ".png"));
            window.ReceiveSnapshot(Snapshot(4, "z1")); await Pump();
            Check(RowIDs().First() == "z1", "An active ungrouped chat also raises its section");
            window.ReceiveSnapshot(Snapshot(5)); await Pump();
            Check(RowIDs().SequenceEqual(new[] { "a1", "a2", "b1", "b2", "z1" }), "Completing activity restores the original group and row order");
            // Hold the visual list during a drag, then use the same refresh as drag completion.
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            var dragging = typeof(IslandWindow).GetField("conversationDragging", flags)!;
            dragging.SetValue(window, true); window.ReceiveSnapshot(Snapshot(6, "b2")); await Pump();
            Check(RowIDs().First() == "a1", "Activity cannot move a drag target under the pointer");
            dragging.SetValue(window, false); typeof(IslandWindow).GetMethod("InvalidatePanel", flags)!.Invoke(window, [true]); await Pump();
            Check(RowIDs().First() == "b2", "Deferred activity order is applied when dragging ends");
            window.ReceiveSnapshot(Snapshot(7)); await Pump();
            var heading = Descendants(window).OfType<Grid>().Single(g => AutomationProperties.GetAutomationId(g) == "island.group.header.first");
            var name = Descendants(heading).OfType<Button>().Last();
            ((IInvokeProvider)new ButtonAutomationPeer(name).GetPattern(PatternInterface.Invoke)).Invoke();
            await Pump(); // UI Automation dispatches the click asynchronously.
            var edit = Descendants(window).OfType<TextBox>().Single(); edit.Text = "Still editing";
            window.ReceiveSnapshot(Snapshot(8, "b2")); await Pump();
            Check(Descendants(window).Contains(edit) && edit.Text == "Still editing" && RowIDs().First() == "a1", "Activity does not discard an inline rename");
            edit.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(edit), 0, Key.Escape) { RoutedEvent = Keyboard.KeyDownEvent }); await Pump();
            Check(RowIDs().First() == "b2" && !Descendants(window).OfType<TextBox>().Any(), "Finishing rename applies the deferred ordering");
            window.ApplyPreferences(preferences with { HideProjects = true });
            await Pump();
            Check(!Descendants(window).OfType<Button>().Any(b => (b.Content as string)?.Contains("First group") == true ||
                AutomationProperties.GetName(b).Contains("First group")), "Privacy also hides custom group names");
            Check(Descendants(window).OfType<TaskRow>().All(r => ((TaskRowState)r.DataContext).Value.Title == UiText.For(language == "zh-Hans").Text("activity.hidden_name")),
                "Privacy hides pinned titles immediately, including a previous snapshot");
            Check(preferences.ConversationGroups == saved, "Presentation updates do not change stored preferences");
            var oldToggle = Descendants(window).OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == "island.group.toggle.first");
            var next = Snapshot(9);
            window.ReceiveSnapshot(next with { PinnedConversations = next.PinnedConversations! with { Profile = "another-profile" } });
            await Pump();
            int saves = 0;
            window.SaveIslandPlacement = _ => { saves++; return Task.FromResult(PreferencesApplyResult.Applied); };
            oldToggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Pump();
            Check(saves == 0, "A control from a previous Codex directory cannot edit the new directory");
            Console.WriteLine("PASS conversation activity " + language + ": group and row promotion, completion restore, stable controls, drag and rename protection");
        }
        finally { window.StopPresentation(); window.AllowClose = true; window.Close(); }
        string[] RowIDs() => Descendants(window).OfType<TaskRow>().Select(row => ((TaskRowState)row.DataContext).Value.Id).ToArray();
    }
    private static EngineSnapshot Snapshot(ulong sequence, string? active = null)
    {
        var rows = new[] { "a1", "a2", "b1", "b2", "z1" }.Select(id => new EngineTaskRow(id, "codex", "Sample chat " + id,
            id == active ? "Running" : "Idle", null, null, null, id == active ? "running" : "idle", "sparkle", null, "Demo", null, null, false, null, null, 0, false, false, false, null, false)).ToArray();
        var count = active == null ? 0 : 1;
        return new(1, "snapshot", sequence, true, 0, [], [], [], [], [], count, 0, null, false,
            Presentation: new([rows[0] with { Id = "ordinary", Provider = "claude" }], 5, 1, 1, new EngineHeader(count, null, new Dictionary<string, int>(), null, null, null, false)),
            PinnedConversations: new("", true, rows, []));
    }
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
