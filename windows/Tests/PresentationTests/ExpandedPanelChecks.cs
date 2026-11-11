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
            CheckClockSnapshots(island, engine.LatestSnapshot!);

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
            var codex = Find<Button>(window, "panel.editor.codex");
            bool checkFocus = language == "en" && !dark;
            if (checkFocus)
            {
                window.Activate();
                Check(codex.Focus(), "The outline block can receive keyboard focus");
            }
            Invoke(codex); await Pump();
            Check(ReferenceEquals(codex, Find<Button>(window, "panel.editor.codex")) && AutomationProperties.GetItemStatus(codex) == ui.Text("main.panel.selected"),
                "Selecting an outline block keeps the same focusable button");
            await engine.SendAsync("refresh", new { discover = false }); await Pump();
            Check(ReferenceEquals(codex, Find<Button>(window, "panel.editor.codex")), "A refresh with the same outline keeps its focusable buttons");
            // The keyboard moves a block in the outline, as dragging does.
            MoveUp(codex);
            await Until(() => session.Current.ExpandedPanelLayout?.StartsWith("{\"blocks\":[\"codex\",\"tasks\"", StringComparison.Ordinal) == true);
            if (checkFocus)
            {
                await Until(() => Present<Button>(window, "panel.editor.codex") && !ReferenceEquals(codex, Find<Button>(window, "panel.editor.codex")));
                Check(Find<Button>(window, "panel.editor.codex").IsKeyboardFocused, "Saving a move returns keyboard focus to the moved outline block");
            }
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

            await session.ChangeAsync(p => p with
            {
                ExpandedPanelLayout = "{\"blocks\":[\"tasks\",\"deepseek\",\"deepseekSpend\"],\"version\":1}",
                ExpandedPanelOptions = "{\"deepseekDial\":\"day\",\"version\":1}"
            });
            await Until(() => Present<Button>(window, "panel.editor.deepseekSpend") && engine.LatestSnapshot?.ExpandedPanel?.Sections.Any(section => section.SpendBeside) == true);
            var spend = Find<Button>(window, "panel.editor.deepseekSpend");
            Check(spend.AllowDrop && spend.IsEnabled, "Merged spend keeps its own enabled drag target in the outline");
            MoveUp(spend);
            await Until(() => session.Current.ExpandedPanelLayout?.Contains("\"deepseekSpend\",\"deepseek\"", StringComparison.Ordinal) == true);
            if (checkFocus)
            {
                await CheckBudgetClock(island, engine, session);
                await CheckUnavailableProjection(window, session, () => configurations);
            }
            Console.WriteLine("PASS expanded panel " + name + ": automatic layout, clock updates, focusable blocks, merged spend, rows, buttons and restore");
        }
        finally { window.AllowClose = true; window.Close(); island.StopPresentation(); island.AllowClose = true; island.Close(); await engine.DisposeAsync(); }
    }
    private static async Task CheckBudgetClock(IslandWindow island, EngineClient engine, PreferencesSession session)
    {
        DeepSeekBudgetDial Dial() => Descendants(island).OfType<DeepSeekBudgetDial>().Single();
        string[] Glyphs(DeepSeekBudgetDial dial) => DrawingInspection.Render(dial, dial.Width, dial.Height).Select(value => value.Drawing)
            .OfType<GlyphRunDrawing>().Select(value => string.Join(",", value.GlyphRun.GlyphIndices)).ToArray();

        foreach (bool solo in new[] { true, false })
        {
            string blocks = solo ? "\"tasks\",\"deepseek\"" : "\"tasks\",\"codex\",\"deepseek\"";
            await session.ChangeAsync(p => p with
            {
                ExpandedPanelLayout = "{\"blocks\":[" + blocks + "],\"version\":1}", ExpandedPanelOptions = null,
                DeepSeekMode = "budget", DeepSeekDailyBudget = 20, DeepSeekWeeklyBudget = 80
            });
            await Until(() => engine.LatestSnapshot?.Wallet?.Solo?.Budgets.Count == 2 && Descendants(island).OfType<DeepSeekBudgetDial>().Any()
                && Descendants(island).OfType<DeepSeekBudgetDetails>().Any() == solo);
            await island.WaitForPresentationAsync();
            var snapshot = engine.LatestSnapshot!;
            var wallet = snapshot.Wallet!;
            var data = wallet.Solo!;
            var tick = data.Budgets.Select((budget, index) => index == 0 ? budget with
            {
                TimeFraction = 0.32, PacePercent = 77.7, PaceText = "78%", Countdown = "13m",
                ProjectionText = "Clock projection fixture", Help = "Clock accessibility fixture"
            } : budget with { }).ToArray();
            EngineSnapshot Project(IReadOnlyList<DeepSeekBudgetPresentation> values) => snapshot with
            { CapturedAt = snapshot.CapturedAt + 5, Sequence = snapshot.Sequence + 1, Wallet = wallet with { Solo = data with { Budgets = values } } };

            var dial = Dial(); var details = Descendants(island).OfType<DeepSeekBudgetDetails>().SingleOrDefault();
            string[] before = Glyphs(dial);
            island.ReceiveSnapshot(Project(tick));
            Check(ReferenceEquals(dial, Dial()) && !Glyphs(dial).SequenceEqual(before) && AutomationProperties.GetName(dial).Contains(tick[0].Help, StringComparison.Ordinal),
                "A budget tick redraws countdown glyphs and updates accessibility on the same dial");
            if (details != null)
            {
                Check(ReferenceEquals(details, Descendants(island).OfType<DeepSeekBudgetDetails>().Single()) &&
                    Descendants(details).OfType<TextBlock>().Any(text => text.Text == tick[0].PaceText) &&
                    Descendants(details).OfType<TextBlock>().Any(text => text.Text == tick[0].ProjectionText),
                    "Budget pace and projection advance on the same detail rows");
            }
            else
            {
                var cell = Descendants(island).OfType<DeepSeekQuotaCell>().Single();
                Check(AutomationProperties.GetHelpText(cell).Contains(tick[0].Help, StringComparison.Ordinal), "The paired card updates its budget help text");
            }

            var changed = tick.ToArray(); changed[0] = tick[0] with { Whole = "¥17", Fraction = 0.63 };
            island.ReceiveSnapshot(Project(changed));
            Check(!ReferenceEquals(dial, Dial()) && AutomationProperties.GetName(Dial()).Contains("¥17", StringComparison.Ordinal),
                "A new budget amount refreshes the section and its accessibility reading");
            island.ReceiveSnapshot(snapshot);
        }
        Console.WriteLine("PASS DeepSeek budgets: retained solo and paired dials update their clock and labels; new amounts refresh the section");
    }
    private static async Task CheckUnavailableProjection(SettingsWindow window, PreferencesSession session, Func<int> configurationCount)
    {
        var previous = ShellProjection.Client;
        await Until(() => Present<Button>(window, "panel.editor.codex") && Find<Button>(window, "panel.block.codex.toggle").IsEnabled);
        var block = Find<Button>(window, "panel.editor.codex");
        var toggle = Find<Button>(window, "panel.block.codex.toggle");
        var restore = Find<Button>(window, "panel.restore");
        var before = session.Current; int configured = configurationCount();
        try
        {
            ShellProjection.Client = null;
            await Until(() => !block.IsEnabled && !toggle.IsEnabled && !restore.IsEnabled);
            MoveUp(block);
            toggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            restore.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Pump();
            Check(session.Current == before && configurationCount() == configured, "An unavailable projection blocks stale outline, library and restore edits");
        }
        finally { ShellProjection.Client = previous; }
        await Until(() => block.IsEnabled && toggle.IsEnabled && restore.IsEnabled);
        Check(ReferenceEquals(block, Find<Button>(window, "panel.editor.codex")), "Restoring the same projection re-enables the existing outline");
        Console.WriteLine("PASS unavailable panel projection: stale edits blocked and existing outline restored");
    }
    private static void CheckClockSnapshots(IslandWindow island, EngineSnapshot snapshot)
    {
        QuotaDial Dial(string provider) => Descendants(island).OfType<QuotaDial>().Single(value => value.Provider == provider);
        EngineSnapshot Tick(EngineSnapshot prior, double time, double? quota = null)
        {
            var dashboard = prior.QuotaDashboard!;
            return prior with
            {
                CapturedAt = prior.CapturedAt + 5, Sequence = prior.Sequence + 1,
                QuotaDashboard = dashboard with { Providers = dashboard.Providers.Select(provider => provider.Provider == "codex"
                    ? provider with { Weekly = provider.Weekly with
                    {
                        RemainingTimePercent = time,
                        RemainingPercent = quota ?? provider.Weekly.RemainingPercent,
                        ValueText = quota?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? provider.Weekly.ValueText
                    } }
                    : provider with { }).ToArray() },
                Wallet = prior.Wallet is { } wallet ? wallet with { Angle = wallet.Angle + 0.02 } : null
            };
        }

        var codex = Dial("codex"); var claude = Dial("claude");
        var tick = Tick(snapshot, 52);
        island.ReceiveSnapshot(tick);
        Check(ReferenceEquals(codex, Dial("codex")) && ReferenceEquals(claude, Dial("claude")) && codex.Selected?.RemainingTimePercent == 52,
            "A running quota clock updates the dial without replacing unchanged controls");

        double? oldQuota = codex.Selected?.RemainingPercent;
        island.CollapseForAutomation(); island.ReceiveSnapshot(Tick(tick, 51, 61));
        Check(ReferenceEquals(codex, Dial("codex")) && codex.Selected?.RemainingPercent == oldQuota,
            "While collapsed the panel does no work on a newer reading");
        island.Reveal();
        Check(Dial("codex").Selected?.RemainingPercent == 61, "Reopening renders the latest reading immediately");

        codex = Dial("codex"); island.Hide(); island.ReceiveSnapshot(Tick(tick, 50, 62));
        Check(ReferenceEquals(codex, Dial("codex")) && codex.Selected?.RemainingPercent == 61,
            "A hidden window leaves its expanded controls untouched");
        island.Show();
        Check(Dial("codex").Selected?.RemainingPercent == 62, "Showing an expanded window paints the latest reading");
        island.ReceiveSnapshot(snapshot);
    }
    private static void MoveUp(Button block) => block.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,
        PresentationSource.FromVisual(block), Environment.TickCount, Key.Up) { RoutedEvent = Keyboard.KeyDownEvent });
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
