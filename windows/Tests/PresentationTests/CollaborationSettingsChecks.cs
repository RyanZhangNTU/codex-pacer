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
using System.Windows.Threading;
using CodexPacer.Windows;

/// Settings → Collaboration with a demo engine and synthetic preferences: the
/// pair card and its switch, the basic choices with Follow Codex | Pick and
/// Restore Defaults, the advanced choices folded away, ⓘ that open on click,
/// and no hover popups anywhere on the page.
internal static class CollaborationSettingsChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        await using var engine = new EngineClient();
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "collaboration", ProviderModes = new()
            { ["codex"] = "enabled", ["claude"] = "enabled", ["deepseek"] = "enabled" } };
        var session = new PreferencesSession(preferences, async value => await engine.SendAsync("configure", value), _ => true);
        UiText ui = UiText.For(language == "zh-Hans");
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine) { ShowActivated = false, IsHitTestVisible = false };
        string name = language + (dark ? "-dark" : "-light");
        try
        {
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, preferences.EngineConfiguration(), referenceFixture: true);
            window.Show(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            await Until(() => Find<CheckBox>(window, "settings.collaboration.enabled").IsEnabled, "Both modules are on");
            Check(Find<TextBlock>(window, "settings.subtitle").Text == ui.Text("main.subtitle.collaboration"), "The page says what it is for");
            var beta = Find<Border>(window, "settings.pane.collaboration.beta");
            Check(beta.IsVisible && ((TextBlock)beta.Child).Text == ui.Text("main.beta") && beta.ActualHeight == 16
                && AutomationProperties.GetItemStatus(Find<RadioButton>(window, "settings.pane.collaboration")) == ui.Text("main.beta"),
                "Collaboration's sidebar row carries a Beta badge at its end, and screen readers hear it");
            var toggle = Find<CheckBox>(window, "settings.collaboration.enabled");
            Check(toggle.IsChecked == false && !Find<Button>(window, "settings.collaboration.restore").IsEnabled,
                "The pair starts off, and Restore Defaults has nothing to restore");
            Check(Find<RadioButton>(window, "settings.collaboration.model.follow").IsChecked == true
                && Find<RadioButton>(window, "settings.collaboration.effort.follow").IsChecked == true
                && Find<RadioButton>(window, "settings.collaboration.fast.follow").IsChecked == true
                && !Find<ComboBox>(window, "settings.collaboration.effort").IsVisible && !Find<ComboBox>(window, "settings.collaboration.records_hours").IsVisible,
                "Model, effort and fast mode follow Codex, and their pickers wait until the user picks");
            var advanced = Find<Expander>(window, "settings.collaboration.advanced");
            Check(!advanced.IsExpanded && advanced.Tag as string == ui.Text("collab.advanced.summary") && !Find<ComboBox>(window, "settings.collaboration.sandbox").IsVisible,
                "The advanced choices fold into one row with a summary");
            Check(!Descendants(Find<ScrollViewer>(window, "settings.content")).OfType<FrameworkElement>().Any(value => value.ToolTip != null),
                "Nothing on the page explains itself on hover");
            window.CapturePreview(Path.Combine(output, "settings-" + name + "-collaboration.png"));
            var intro = await CheckIntroOpening(window, session, ui);

            Toggle(toggle);
            await Until(() => session.Current.CodexDelegation && toggle.IsEnabled, "The pair's switch saves and reaches the engine");
            await Until(() => intro.Ticks[0] && intro.TurnOnButton == null, "Turning the pair on ticks the guide's first step");
            await session.ChangeAsync(p => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = "disabled" } });
            await Until(() => engine.LatestSnapshot?.Modules?.Any(module => module.Provider == "codex" && !module.Enabled) == true && !toggle.IsEnabled,
                "Turning Codex off disables the pair");
            Check(toggle.IsChecked == true && !Find<ComboBox>(window, "settings.collaboration.trigger").IsEnabled,
                "The saved switch stays on and the choices are disabled");
            var codexPage = Find<Button>(window, "settings.collaboration.pair.action");
            Check(Find<TextBlock>(window, "settings.collaboration.pair.reason").Text == ui.Text("collab.reason.codex_off")
                && codexPage.IsEnabled && Equals(codexPage.Content, ui.Text("collab.go_codex")),
                "The card explains how to turn Codex on");
            Check(!intro.Ticks[0] && intro.TurnOnButton == null && Equals(Find<Button>(window, "settings.collaboration.intro.fix").Content, ui.Text("collab.go_codex")),
                "The guide's first step says what keeps the pair from working, with the same way to fix it");
            await session.ChangeAsync(p => p with { ProviderModes = new(p.ProviderModes) { ["codex"] = "enabled" } });
            await Until(() => toggle.IsEnabled && toggle.IsChecked == true && Find<ComboBox>(window, "settings.collaboration.trigger").IsEnabled,
                "Turning Codex on restores the saved choice");
            Select(Find<RadioButton>(window, "settings.collaboration.effort.pick"));
            await Until(() => !session.Current.CodexDelegationFollowEffort && Find<ComboBox>(window, "settings.collaboration.effort").IsVisible,
                "Picking an effort shows its menu");
            Select(Find<RadioButton>(window, "settings.collaboration.records.timed"));
            await Until(() => session.Current.CodexDelegationRecords == "timed" && Find<ComboBox>(window, "settings.collaboration.records_hours").IsVisible
                && (string?)Find<ComboBox>(window, "settings.collaboration.records_hours").SelectedValue == "24", "Timed records show their hours, a day by default");
            var info = Find<Button>(window, "settings.collaboration.records_row.info");
            Check(AutomationProperties.GetItemStatus(info) == ui.Text("main.info_hidden"), "ⓘ starts closed");
            Invoke(info); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Check(AutomationProperties.GetItemStatus(info) == ui.Text("main.info_shown")
                && Descendants(window).OfType<TextBlock>().Any(value => value.IsVisible && value.Text == ui.Text("collab.info.records")),
                "ⓘ opens its explanation under the row on click");
            ((IExpandCollapseProvider)new ExpanderAutomationPeer(advanced).GetPattern(PatternInterface.ExpandCollapse)).Expand();
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var sandbox = Find<ComboBox>(window, "settings.collaboration.sandbox");
            Check(sandbox.IsVisible && (string?)sandbox.SelectedValue == "workspace-write-network" && Find<RadioButton>(window, "settings.collaboration.location.project").IsEnabled,
                "Expanded, the access choices show, writing in the project with network by default");
            sandbox.SelectedValue = "read-only";
            await Until(() => session.Current.CodexDelegationSandbox == "read-only" && !Find<RadioButton>(window, "settings.collaboration.location.worktree").IsEnabled
                && advanced.Tag as string == ui.Text("collab.advanced.summary_changed"), "A read-only run has no work location, and the summary says something changed");
            Check(Find<TextBlock>(window, "settings.collaboration.instructions").Text == ui.Text("collab.instructions.none"), "No standing instructions reads as not set");
            await Until(() => Find<Button>(window, "settings.collaboration.restore").IsEnabled, "Changed choices can be restored");
            window.CapturePreview(Path.Combine(output, "settings-" + name + "-collaboration-changed.png"));
            var scroller = Find<ScrollViewer>(window, "settings.content"); scroller.ScrollToEnd(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            window.CapturePreview(Path.Combine(output, "settings-" + name + "-collaboration-advanced.png"));
            scroller.ScrollToTop(); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            Invoke(Find<Button>(window, "settings.collaboration.restore"));
            await Until(() => session.Current.DelegationIsDefault && session.Current.CodexDelegation && toggle.IsChecked == true,
                "Restore Defaults resets the pair's choices and keeps its switch");
            Check(Find<RadioButton>(window, "settings.collaboration.effort.follow").IsChecked == true && !Find<ComboBox>(window, "settings.collaboration.effort").IsVisible,
                "Restored choices follow Codex again");
            Toggle(toggle);
            await Until(() => !session.Current.CodexDelegation && toggle.IsEnabled, "The pair can be turned off again");
            await CheckIntroSteps(window, session, ui, intro, toggle, Path.Combine(output, "settings-" + name + "-collaboration-intro-done.png"));
            Console.WriteLine("PASS collaboration settings " + name + ": pair switch, follow and pick, records, info, advanced, restore and the first-run guide");
        }
        catch
        {
            try { window.CapturePreview(Path.Combine(output, "failed-settings-" + name + "-collaboration.png")); } catch { }
            throw;
        }
        finally { window.AllowClose = true; window.Close(); }
    }
    /// The first-run guide on a fresh page: open by itself beside its demo, three steps to do, phrases that copy,
    /// and a demo that holds still without motion, moves between steps on its dots and keeps its pictures from screen readers.
    private static async Task<CollaborationIntro> CheckIntroOpening(SettingsWindow window, PreferencesSession session, UiText ui)
    {
        var intro = Descendants(window).OfType<CollaborationIntro>().Single();
        var reopen = Find<Button>(window, "settings.collaboration.intro.reopen");
        Check(intro.IsVisible && !reopen.IsVisible && intro.Ticks.SequenceEqual([false, false, false]) && intro.TurnOnButton is { IsEnabled: true }
            && intro.PhraseButtons.Count() == 2 && Equals(intro.Finish?.Content, ui.Text("collab.intro.got_it")) && intro.Wide,
            "The guide opens by itself beside its demo: three steps to do, Turn On, two phrases to copy, and Got It");
        // Settings' button style draws content as text; the guide's drawn buttons must not show a type name.
        Check(!Descendants(intro).OfType<TextBlock>().Any(text => text.Text.StartsWith("System.", StringComparison.Ordinal)), "Every button in the guide draws its own content");
        intro.Demo.SetMotion(false);
        Check(!intro.Demo.Playing && intro.Demo.Beat == 2 && intro.Demo.Caption == ui.Text("collab.intro.demo.3"), "Without motion the demo holds its progress frame");
        // A button's automation Invoke clicks it on the dispatcher's next turn.
        Invoke(Find<Button>(window, "collaboration.intro.demo.step.1")); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        Check(intro.Demo.Beat == 0 && intro.Demo.Typed == ui.Text("collab.intro.phrase.review"), "A dot shows its step: the request typed in Claude");
        Invoke(Find<Button>(window, "collaboration.intro.demo.step.5")); await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        Check(intro.Demo.Beat == 4 && intro.Demo.Caption == ui.Text("collab.intro.demo.5"), "The last dot shows the cleanup");
        intro.Demo.SetMotion(true);
        Check(intro.Demo.Playing, "With motion the demo loops while it is on screen");
        static IEnumerable<AutomationPeer> Walk(AutomationPeer peer) => (peer.GetChildren() ?? []).SelectMany(child => Walk(child).Prepend(child));
        var demo = UIElementAutomationPeer.CreatePeerForElement(intro.Demo);
        var heard = Walk(demo).ToArray();
        Check(demo.GetName() == ui.Text("collab.intro.demo") && heard.Count(peer => peer.GetAutomationControlType() == AutomationControlType.Button) == 5
            && !heard.Any(peer => peer.GetName() == ui.Text("collab.intro.demo.task") || peer.GetName() == ui.Text("collab.intro.demo.run")),
            "Screen readers hear the demo's name and its five steps, not its pictures");
        string? copied = null; var write = CollaborationIntro.WriteClipboard;
        CollaborationIntro.WriteClipboard = text => { copied = text; return true; };
        try { Invoke(intro.PhraseButtons.First()); await Dispatcher.Yield(DispatcherPriority.ContextIdle); } finally { CollaborationIntro.WriteClipboard = write; }
        Check(copied == ui.Text("collab.intro.phrase.review"), "A phrase copies with one click");
        Check(intro.PhraseButtons.First().Content is StackPanel chip && chip.Children.OfType<StackPanel>().SelectMany(part => part.Children.OfType<TextBlock>())
            .Any(text => text.Text == ui.Text("collab.intro.copied")), "A copied phrase says so");
        await session.ChangeAsync(p => p with { CodexDelegationTrigger = "command" });
        await Until(() => intro.PhraseButtons.Count() == 1 && AutomationProperties.GetName(intro.PhraseButtons.First()).Contains("/pacer:codex", StringComparison.Ordinal),
            "With Command only, the phrase to copy is the command");
        await session.ChangeAsync(p => p with { CodexDelegationTrigger = "ask" });
        await Until(() => intro.PhraseButtons.Count() == 2, "Back to When asked, two phrases again");
        return intro;
    }
    /// The guide's own Turn On, the steps that tick as Codex is called and a run ends, Done, and closing and reopening it.
    private static async Task CheckIntroSteps(SettingsWindow window, PreferencesSession session, UiText ui, CollaborationIntro intro, CheckBox toggle, string capture)
    {
        var reopen = Find<Button>(window, "settings.collaboration.intro.reopen");
        Invoke(Find<Button>(window, "settings.collaboration.intro.close"));
        await Until(() => !intro.IsVisible && reopen.IsVisible && session.Current.CodexDelegationIntroDone, "Closing the guide keeps it closed, and How It Works waits beside Pairs");
        Invoke(reopen);
        await Until(() => intro.IsVisible && !reopen.IsVisible, "How It Works opens the guide again");
        Invoke(intro.TurnOnButton!);
        await Until(() => session.Current.CodexDelegation && toggle.IsChecked == true && intro.Ticks[0], "The guide's Turn On turns the pair on");
        await session.ChangeAsync(p => p with { CodexDelegationIntroRan = true });
        await Until(() => intro.Ticks.SequenceEqual([true, true, false]) && !intro.PhraseButtons.Any(), "Once Codex has been called, the second step ticks and its phrases fold away");
        await session.ChangeAsync(p => p with { CodexDelegationIntroFinished = true });
        await Until(() => intro.Ticks.All(tick => tick) && Equals(intro.Finish?.Content, ui.Text("collab.done")), "A finished run ticks the last step and Got It becomes Done");
        window.CapturePreview(capture);
        Invoke(intro.Finish!);
        await Until(() => !intro.IsVisible && reopen.IsVisible, "Done closes the guide");
        Toggle(toggle);
        await Until(() => !session.Current.CodexDelegation && toggle.IsEnabled, "The pair goes back off");
    }
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement
        => Descendants(root).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Toggle(CheckBox check) => ((IToggleProvider)new CheckBoxAutomationPeer(check).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Select(RadioButton choice) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(choice).GetPattern(PatternInterface.SelectionItem)).Select();
    private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Until(Func<bool> condition, string message)
    { var clock = Stopwatch.StartNew(); while (!condition() && clock.Elapsed < PresentationWait.Limit) await Task.Delay(25); Check(condition(), message); await Dispatcher.Yield(DispatcherPriority.ContextIdle); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration
    { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
