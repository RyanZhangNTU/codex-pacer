using System;
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

/// The Expanded Panel page and the island it edits, with the real offline
/// engine: the automatic layout keeps the reference panel, block moves and
/// arrangements reorder the actual sections and their header, row choices
/// redraw the task pages, and unchecked buttons move into the More menu.
internal static class ExpandedPanelChecks
{
    internal static async Task Run(string language, bool dark, string output)
    {
        var engine = new EngineClient();
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "expandedPanel" };
        int configurations = 0;
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => true);
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { IsHitTestVisible = false, ShowActivated = false };
        session.Changed += island.ApplyPreferences;
        var ui = UiText.For(language == "zh-Hans");
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine) { IsHitTestVisible = false, ShowActivated = false };
        string name = language + (dark ? "-dark" : "-light");
        try
        {
            island.Show(); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, configuration: preferences.EngineConfiguration(), referenceFixture: true);
            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync(); await Pump();
            var content = (StackPanel)island.FindName("PanelContent");
            var actions = (FrameworkElement)island.FindName("PanelActions");
            Check(island.LogicalTarget.Width == 404 && island.LogicalTarget.Height == 438 && ReferenceEquals(content.Children[0], island.FindName("TasksSection"))
                && ReferenceEquals(actions.Parent, island.FindName("TaskHeaderTrailing")),
                "Without a saved layout the panel keeps the reference tasks-then-quota panel with its buttons in the task header");

            await Until(() => Present<Button>(window, "panel.block.tasks"));
            Check(Equals(Find<Button>(window, "panel.block.codex.toggle").Tag, "added") && Equals(Find<Button>(window, "panel.block.deepseekWeek.toggle").Tag, "add")
                && Find<TextBlock>(window, "panel.automatic").Text == ui.Text("main.panel.automatic_short") && !Find<Button>(window, "panel.restore").IsVisible,
                "The page shows the automatic layout's blocks and offers no restore before an edit");
            Check(Present<Button>(window, "panel.editor.tasks") && Present<Button>(window, "panel.editor.codex") && Present<Button>(window, "panel.editor.actions"),
                "The outline draws each shown block and the header's buttons");
            Check(Descendants(Find<Button>(window, "panel.editor.tasks")).OfType<TextBlock>().Any(text => text.Text == AutomationProperties.GetName(Find<Button>(window, "panel.block.tasks"))),
                "An outline block draws its name, not its content's type");
            window.CapturePreview(Path.Combine(output, "settings-panel-" + name + "-automatic.png"));

            // Moving Codex above the tasks splits it from the other quotas and hands it the buttons.
            int before = configurations;
            window.SelectPanelBlock("codex"); await Pump();
            // The keyboard moves a block in the outline, as dragging does.
            var codex = Find<Button>(window, "panel.editor.codex");
            codex.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(codex), Environment.TickCount,
                System.Windows.Input.Key.Up) { RoutedEvent = System.Windows.Input.Keyboard.KeyDownEvent });
            await Until(() => session.Current.ExpandedPanelLayout?.StartsWith("{\"blocks\":[\"codex\",\"tasks\"", StringComparison.Ordinal) == true);
            await Until(() => ReferenceEquals(content.Children[0], island.FindName("QuotaSection")));
            await island.WaitForPresentationAsync();
            Check(configurations > before && ReferenceEquals(actions.Parent, island.FindName("QuotaHeaderTrailing"))
                && ((FrameworkElement)island.FindName("PageDivider")).Visibility == Visibility.Collapsed
                && ((TextBlock)island.FindName("QuotaDetail")).Text == "Codex" && Descendants(island).OfType<QuotaDial>().Count() == 3,
                "The first section carries the buttons and a lone service is named beside its title");
            Check(Find<Button>(window, "panel.restore").IsVisible && Find<TextBlock>(window, "panel.automatic").Text == ui.Text("main.panel.custom"),
                "A saved layout offers to restore the automatic one");

            // One row each: every quota service gets a section of its own.
            Select(Find<RadioButton>(window, "panel.option.codex.arrange.stack"));
            await Until(() => island.IsLoaded && Descendants(island).OfType<FrameworkElement>()
                .Count(value => AutomationProperties.GetAutomationId(value).StartsWith("island.section.quota.", StringComparison.Ordinal)) == 3);
            await island.WaitForPresentationAsync();
            Check(Descendants(island).OfType<SingleQuotaView>().Any(), "A service with a row to itself shows its details beside the ring");

            // The task list: five rows of one line.
            window.SelectPanelBlock("tasks"); await Pump();
            Select(Find<RadioButton>(window, "panel.option.pageSize.5"));
            await Until(() => engine.LatestSnapshot?.Presentation?.PageSize == 5);
            Select(Find<RadioButton>(window, "panel.option.rowStyle.oneLine"));
            await Until(() => Descendants(island).OfType<TaskRow>().Any() && Descendants(island).OfType<TaskRow>().All(row => row.Height == TaskRow.OneLineHeight));
            await island.WaitForPresentationAsync();
            int rows = Math.Min(5, engine.LatestSnapshot!.Presentation!.Rows.Count);
            Check(Descendants(island).OfType<TaskRow>().Count() == rows
                && Math.Abs(((Grid)island.FindName("TaskPages")).Height - (rows * TaskRow.OneLineHeight + (rows - 1) * 2)) < 0.01,
                "The page holds the chosen number of one-line rows");
            Check(!Find<CheckBox>(window, "panel.option.field.model").IsEnabled && Find<CheckBox>(window, "panel.option.field.rate").IsEnabled,
                "One line keeps only the speed and turn time to choose");

            // Unchecked buttons leave the header for the More menu.
            window.SelectPanelBlock("actions"); await Pump();
            Toggle(Find<CheckBox>(window, "panel.option.action.pin"));
            await Until(() => ((Button)island.FindName("PinButton")).Visibility == Visibility.Collapsed);
            var menu = ((Button)island.FindName("MoreButton")).ContextMenu;
            Check(menu.Items.OfType<MenuItem>().Any(item => AutomationProperties.GetAutomationId(item) == "island.menu.pin")
                && menu.Items.OfType<MenuItem>().Any(item => ReferenceEquals(item, island.FindName("RefreshMenu")))
                && !menu.Items.OfType<MenuItem>().Any(item => ReferenceEquals(item, island.FindName("SettingsMenu"))),
                "Keep Expanded joins Refresh in the menu while Settings stays in the header");

            // Removing DeepSeek's balance hides it; the automatic layout returns everything.
            window.SelectPanelBlock("deepseek"); await Pump();
            Invoke(Find<Button>(window, "panel.inspector.toggle"));
            // With one row each, DeepSeek alone draws its full dial view.
            await Until(() => !Descendants(island).OfType<DeepSeekQuotaCell>().Any() && !Descendants(island).OfType<DeepSeekSoloView>().Any()
                && Equals(Find<Button>(window, "panel.block.deepseek.toggle").Tag, "add"));
            Check(Find<TextBlock>(window, "panel.inspector.notice").Text == ui.Text("main.library.not_added") && Find<CheckBox>(window, "panel.option.peak").IsVisible,
                "A removed block keeps its settings open with a note that they apply once it is added");

            // A tile only selects; its round button adds the block and keeps the selection.
            string? layout = session.Current.ExpandedPanelLayout;
            var week = Find<Button>(window, "panel.block.deepseekWeek");
            Invoke(week); await Pump();
            Check(session.Current.ExpandedPanelLayout == layout && Find<TextBlock>(window, "panel.inspector.title").Text == AutomationProperties.GetName(week)
                && Find<CheckBox>(window, "panel.option.weekLine").IsVisible && Find<TextBlock>(window, "panel.inspector.notice").IsVisible,
                "Clicking a tile selects it without adding it");
            Invoke(Find<Button>(window, "panel.block.deepseekWeek.toggle"));
            await Until(() => session.Current.ExpandedPanelLayout?.Contains("deepseekWeek", StringComparison.Ordinal) == true
                && Equals(Find<Button>(window, "panel.block.deepseekWeek.toggle").Tag, "added"));
            Check(Find<TextBlock>(window, "panel.inspector.title").Text == AutomationProperties.GetName(week) && !Find<TextBlock>(window, "panel.inspector.notice").IsVisible
                && Present<Button>(window, "panel.editor.deepseekWeek"),
                "The round button adds the block to the outline and keeps it selected");
            window.CapturePreview(Path.Combine(output, "settings-panel-" + name + "-edited.png"));
            island.CapturePreview(Path.Combine(output, "panel-" + name + "-edited.png"));
            Invoke(Find<Button>(window, "panel.restore"));
            await Until(() => session.Current.ExpandedPanelLayout == null && Descendants(island).OfType<DeepSeekSoloView>().Any());
            await session.ChangeAsync(p => p with { ExpandedPanelOptions = null, ShowAppButtons = true });
            await Until(() => ((Button)island.FindName("PinButton")).Visibility == Visibility.Visible
                && Descendants(island).OfType<TaskRow>().All(row => row.Height == TaskRow.TwoLineHeight));
            await island.WaitForPresentationAsync();
            Check(island.LogicalTarget.Height == 438 && ReferenceEquals(actions.Parent, island.FindName("TaskHeaderTrailing")),
                "Restoring the layout and choices returns the reference panel");
            Console.WriteLine("PASS expanded panel " + name + ": automatic layout, block moves, arrangement, rows, header buttons, removal and restore");
        }
        finally { window.AllowClose = true; window.Close(); island.StopPresentation(); island.AllowClose = true; island.Close(); await engine.DisposeAsync(); }
    }
    private static bool Present<T>(DependencyObject root, string id) where T : FrameworkElement
        => Descendants(root).OfType<T>().Any(value => AutomationProperties.GetAutomationId(value) == id);
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement
        => Descendants(root).OfType<T>().SingleOrDefault(value => AutomationProperties.GetAutomationId(value) == id)
            ?? throw new InvalidOperationException("Missing " + id);
    private static void Select(RadioButton value) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(value).GetPattern(PatternInterface.SelectionItem)).Select();
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static async Task Pump() => await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    private static async Task Until(Func<bool> condition)
    {
        var watch = Stopwatch.StartNew();
        while (!condition() && watch.Elapsed < PresentationWait.Limit) await Task.Delay(20);
        Check(condition(), "The expanded panel action must finish"); await Pump();
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
