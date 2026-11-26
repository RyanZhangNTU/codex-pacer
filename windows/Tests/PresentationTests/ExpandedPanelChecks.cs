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
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "expandedPanel", ShowInFullscreen = true };
        int configurations = 0;
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => true);
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false,
            screenGeometry: PresentationWait.ReferenceScreen) { IsHitTestVisible = false, ShowActivated = false };
        session.Changed += island.ApplyPreferences;
        var ui = UiText.For(language == "zh-Hans");
        var window = new SettingsWindow(ui, session, new Startup(), true, dark, engine) { IsHitTestVisible = false, ShowActivated = false };
        string name = language + (dark ? "-dark" : "-light");
        try
        {
            island.ApplyPreferences(preferences); island.Show(); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, configuration: preferences.EngineConfiguration(), referenceFixture: true);
            await PresentationWait.RevealReferencePanelAsync(island, engine);
            var content = (StackPanel)island.FindName("PanelContent");
            var actions = (FrameworkElement)island.FindName("PanelActions");
            // The reference Codex account has banked resets, so its capsule adds its own row.
            Check(island.LogicalTarget.Width == 404 && island.LogicalTarget.Height == 438 + PresentationWait.ResetCapsule(island).Height
                && ReferenceEquals(content.Children[0], island.FindName("TasksSection"))
                && ReferenceEquals(actions.Parent, island.FindName("TaskHeaderTrailing")),
                $"Expected the automatic tasks and quota layout, width 404 and height {PresentationWait.ReferenceHeight(island)}. Got {island.LogicalTarget}, first={content.Children.OfType<FrameworkElement>().FirstOrDefault()?.Name}, actions={((FrameworkElement?)actions.Parent)?.Name}");

            await Until(() => Present<Button>(window, "panel.block.tasks"));
            Check(Equals(Find<Button>(window, "panel.block.codex.toggle").Tag, "added") && Equals(Find<Button>(window, "panel.block.deepseekWeek.toggle").Tag, "add")
                && Find<TextBlock>(window, "panel.automatic").Text == ui.Text("main.panel.automatic_short") && !Find<Button>(window, "panel.restore").IsVisible,
                "The page shows the automatic layout's blocks and offers no restore before an edit");
            Check(Present<Button>(window, "panel.editor.tasks") && Present<Button>(window, "panel.editor.codex") && Present<Button>(window, "panel.editor.actions"),
                "The outline draws each shown block and the header's buttons");
            Check(Descendants(Find<Button>(window, "panel.editor.tasks")).OfType<TextBlock>().Any(text => text.Text == AutomationProperties.GetName(Find<Button>(window, "panel.block.tasks"))),
                "An outline block draws its name, not its content's type");
            window.CapturePreview(Path.Combine(output, "settings-panel-" + name + "-automatic.png"));
            var hover = Find<RadioButton>(window, "panel.option.expand.hover");
            var click = Find<RadioButton>(window, "panel.option.expand.click");
            Check(hover.IsChecked == true && Equals(hover.Content, ui.Text("main.panel.expand.hover")) && Equals(click.Content, ui.Text("main.panel.expand.click")),
                "The panel offers both expand modes and starts on hover");
            Select(click);
            await Until(() => session.Current.IslandExpandMode == "click" && click.IsEnabled);
            Check(session.Current.ExpandedPanelLayout == null && !Find<Button>(window, "panel.restore").IsVisible,
                "Changing how the bar opens keeps the automatic block layout and has nothing to restore");
            island.CollapseForAutomation(); await island.WaitForPresentationAsync();
            Invoke((Button)island.FindName("HeaderAction"));
            await Until(() => island.IsExpandedForAutomation && island.IsActive);
            Check(!((Button)island.FindName("HeaderAction")).IsKeyboardFocused, "A click-opened panel takes focus without drawing a focus ring on the bar");
            window.Activate();
            await Until(() => !island.IsExpandedForAutomation, "Returning to Settings dismisses the click-opened panel");
            Select(hover);
            await Until(() => session.Current.IslandExpandMode == "hover" && hover.IsChecked == true);
            island.Reveal(); await island.WaitForPresentationAsync();

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
            // The page keeps its choices disabled until the previous one has saved.
            var oneLine = Find<RadioButton>(window, "panel.option.rowStyle.oneLine");
            await Until(() => oneLine.IsEnabled);
            Select(oneLine);
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
            var pinSwitch = Find<CheckBox>(window, "panel.option.action.pin");
            await Until(() => pinSwitch.IsEnabled);
            Toggle(pinSwitch);
            await Until(() => ((Button)island.FindName("PinButton")).Visibility == Visibility.Collapsed);
            var menu = ((Button)island.FindName("MoreButton")).ContextMenu;
            Check(menu.Items.OfType<MenuItem>().Any(item => AutomationProperties.GetAutomationId(item) == "island.menu.pin")
                && menu.Items.OfType<MenuItem>().Any(item => ReferenceEquals(item, island.FindName("RefreshMenu")))
                && !menu.Items.OfType<MenuItem>().Any(item => ReferenceEquals(item, island.FindName("SettingsMenu"))),
                "Keep Expanded joins Refresh in the menu while Settings stays in the header");

            // Return to Top Center is opt-in: off, it is in neither the header nor the menu.
            var recenter = (Button)island.FindName("RecenterButton");
            string recenterName = ui.Text("appearance.position_reset");
            Check(Find<CheckBox>(window, "panel.option.action.recenter").IsChecked == false && recenter.Visibility == Visibility.Collapsed
                && AutomationProperties.GetName(recenter) == recenterName && menu.Items.OfType<MenuItem>().All(item => !Equals(item.Header, recenterName)),
                "Return to Top Center starts off and stays out of the More menu");
            island.SaveIslandPlacement = edit => session.ChangeAsync(edit);
            var recenterSwitch = Find<CheckBox>(window, "panel.option.action.recenter");
            await Until(() => recenterSwitch.IsEnabled);
            Toggle(recenterSwitch);
            await Until(() => recenter.Visibility == Visibility.Visible && session.Current.ExpandedPanelOptions?.Contains("\"recenter\"", StringComparison.Ordinal) == true);
            // The island's button and the editor's outline follow the saved choice a frame or so later.
            await Until(() => !recenter.IsEnabled && Descendants(Find<Button>(window, "panel.editor.actions")).OfType<IconGlyph>().Any(glyph => glyph.Symbol == "arrow.up.to.line")
                && menu.Items.OfType<MenuItem>().All(item => !Equals(item.Header, recenterName)),
                "Turned on, it waits while the island already sits at the top center, and the outline shows it");
            await session.ChangeAsync(p => p with { DisplayMode = "floating", IslandPlacement = new(IslandEdge.Free, .3, .4) });
            await Until(() => recenter.IsEnabled);
            Invoke(recenter);
            await Until(() => session.Current is { IslandPlacement: null, Position: "center", PositionChosen: false, DisplayMode: "floating" } && !recenter.IsEnabled);
            await session.ChangeAsync(p => p with { DisplayMode = "notch" });
            await Until(() => recenter.Visibility == Visibility.Collapsed);
            island.SaveIslandPlacement = null;
            await session.ChangeAsync(p => p with { DisplayMode = preferences.DisplayMode });
            await Until(() => recenter.Visibility == Visibility.Visible && !recenter.IsEnabled);

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
            await Until(() => PresentationWait.Places(session.Current.ExpandedPanelLayout, "deepseekWeek")
                && Equals(Find<Button>(window, "panel.block.deepseekWeek.toggle").Tag, "added"));
            Check(Find<TextBlock>(window, "panel.inspector.title").Text == AutomationProperties.GetName(week) && !Find<TextBlock>(window, "panel.inspector.notice").IsVisible
                && Present<Button>(window, "panel.editor.deepseekWeek"),
                "The round button adds the block to the outline and keeps it selected");
            window.CapturePreview(Path.Combine(output, "settings-panel-" + name + "-edited.png"));
            island.CapturePreview(Path.Combine(output, "panel-" + name + "-edited.png"));
            Invoke(Find<Button>(window, "panel.restore"));
            await Until(() => session.Current.ExpandedPanelLayout == null && Descendants(island).OfType<DeepSeekSoloView>().Any());
            await session.ChangeAsync(p => p with { ExpandedPanelOptions = null, ShowAppButtons = true });
            await Until(() => ((Button)island.FindName("PinButton")).Visibility == Visibility.Visible && recenter.Visibility == Visibility.Collapsed
                && Descendants(island).OfType<TaskRow>().All(row => row.Height == TaskRow.TwoLineHeight));
            await island.WaitForPresentationAsync();
            Check(island.LogicalTarget.Height == PresentationWait.ReferenceHeight(island) && ReferenceEquals(actions.Parent, island.FindName("TaskHeaderTrailing")),
                "Restoring the layout and choices returns the reference panel");
            Console.WriteLine("PASS expanded panel " + name + ": automatic layout, block moves, arrangement, rows, header buttons, Return to Top Center, removal and restore");
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
    private static async Task Until(Func<bool> condition, string message = "The expanded panel action must finish")
    {
        var watch = Stopwatch.StartNew();
        while (!condition() && watch.Elapsed < PresentationWait.Limit) await Task.Delay(20);
        Check(condition(), message); await Pump();
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
