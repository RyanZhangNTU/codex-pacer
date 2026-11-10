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
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class CollapsedLayoutChecks
{
    internal static async Task Run(string language, bool dark, bool animations, string output)
    {
        var engine = new EngineClient();
        var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "collapsed" };
        int configurations = 0, saves = 0; bool reject = false;
        var session = new PreferencesSession(preferences, async value => { configurations++; await engine.SendAsync("configure", value); }, _ => { saves++; if (reject) { reject = false; return false; } return true; });
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: animations) { IsHitTestVisible = false, ShowActivated = false };
        session.Changed += island.ApplyPreferences;
        var window = new SettingsWindow(UiText.For(language == "zh-Hans"), session, new Startup(), true, dark, engine) { IsHitTestVisible = false, ShowActivated = false };
        string name = language + (dark ? "-dark" : "-light") + (animations ? "-motion" : "-reduced");
        try
        {
            island.Show(); window.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language, referenceFixture: true);
            await Pump(); await island.WaitForPresentationAsync();
            var editor = SelfAndDescendants(window).OfType<CompactLayoutEditorView>().Single();
            Check(Math.Abs(window.ClientContent.ActualWidth - SettingsWindow.DefaultWidth) < 0.5 && Math.Abs(window.ClientContent.ActualHeight - SettingsWindow.DefaultHeight) < 0.5 && editor.ActualWidth <= SettingsWindow.ColumnWidth,
                "The inline editor must fit the main window's page column");
            Check(engine.LatestSnapshot!.CompactContext != null, "The engine must provide a sanitized compact context");
            string[] everyProvider = ["codex", "claude", "deepseek"];
            var context = engine.LatestSnapshot!.CompactContext!.Value;
            await Until(() => NativeCompactBar.Shared.Read(session.Current, language, everyProvider, context).Components.Length > 0);
            var faster = System.Text.Json.Nodes.JsonNode.Parse(context.GetRawText())!.AsObject();
            faster["rate"] = (faster["rate"] is { } rate ? rate.GetValue<double>() : 0) + 17.5;
            var pending = NativeCompactBar.Shared.Read(session.Current, language, everyProvider, System.Text.Json.JsonSerializer.SerializeToElement(faster));
            Check(pending.Components.Length == 0 && NativeCompactBar.Shared.LastPending, "A new rate reports a pending projection, so the island can keep its displayed bar");
            var leading = (StackPanel)island.FindName("HeaderLeading"); var watch = Stopwatch.StartNew();
            while (watch.Elapsed < TimeSpan.FromSeconds(1.5))
            {
                Check(leading.Children.Count > 0 && leading.Children.Cast<FrameworkElement>().All(value => value.Name != "enginePlaceholder"),
                    "Live source updates never blank the collapsed bar between projections");
                await Task.Delay(20);
            }
            window.CapturePreview(Path.Combine(output, "settings-collapsed-" + name + "-initial.png"));
            var tps = Find<FrameworkElement>(window, "compact.chip.tps");
            Point start = Centre(tps, editor); string? unchanged = session.Current.CompactLayout;
            Check(editor.BeginPointer("tps", start), "A visible chip must accept its pointer");
            editor.MovePointer(start + new Vector(2, 0), true); await editor.EndPointer(start + new Vector(2, 0));
            Check(session.Current.CompactLayout == unchanged && saves == 0, "A movement below the original five-point drag threshold cannot edit");
            var lane = Find<FrameworkElement>(window, "compact.lane.trailing"); var box = new Rect(lane.TranslatePoint(new Point(), editor), lane.RenderSize);
            Point end = new(box.Right - 2, box.Bottom - 2);
            ulong before = engine.LatestSnapshot!.Sequence;
            Check(editor.BeginPointer("tps", start), "The source chip must remain usable"); editor.MovePointer(end, true); await editor.EndPointer(end); await Pump();
            var state = await NativeCompactBar.Shared.ReadAsync(session.Current, language, ["codex", "claude", "deepseek"]);
            Check(state.EditorTrailing.Last() == "tps" && !state.EditorLeading.Contains("tps"), "Dropping at the lane end must move the actual shared component");
            Check(configurations == 0 && engine.LatestSnapshot.Sequence == before, "Layout edits cannot configure the engine or request another snapshot");
            await Until(() => ((StackPanel)island.FindName("HeaderTrailing")).Children.Cast<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "compact.row.tps"));
            await island.WaitForPresentationAsync();
            Check(((StackPanel)island.FindName("HeaderTrailing")).Children.Cast<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "compact.row.tps"),
                "The real header must reflect the changed lane");
            await Until(() => editor.IsEnabled);
            var moved = Find<FrameworkElement>(window, "compact.chip.tps");
            int beforeKeyboard = saves;
            Check(PressKey(window, moved, Key.Left), "The enabled current chip must handle keyboard reordering");
            await session.WaitForChangesAsync();
            state = await NativeCompactBar.Shared.ReadAsync(session.Current, language, ["codex", "claude", "deepseek"]);
            Check(saves == beforeKeyboard + 1 && state.EditorTrailing.LastOrDefault() is { } last && last != "tps",
                "Keyboard ordering must save once and move the shared component left");
            Check(configurations == 0, "Keyboard ordering is a presentation-only edit");
            state = await NativeCompactBar.Shared.ReadAsync(session.Current, language, ["codex", "claude", "deepseek"]);
            string[] missing = state.Components.Where(value => value.Available && !value.Shown).Select(value => value.Id).ToArray();
            // A tile only selects: its settings open with a note, and the bar stays as it was.
            string? arranged = session.Current.CompactLayout;
            Invoke(Find<Button>(window, "compact.component." + missing[0])); await Pump();
            Check(session.Current.CompactLayout == arranged && Find<TextBlock>(window, "compact.inspector.title").Text == state.Components.Single(value => value.Id == missing[0]).Label
                && Find<TextBlock>(window, "compact.inspector.notice").IsVisible, "Clicking a tile selects its component without adding it to the bar");
            foreach (string id in missing)
            {
                await Until(() => editor.IsEnabled);
                var add = Find<Button>(window, "compact.component." + id + ".toggle"); Invoke(add);
                await Until(() => Equals(add.Tag, "added") && add.IsEnabled);
            }
            Check(Find<TextBlock>(window, "compact.inspector.title").Text == state.Components.Single(value => value.Id == missing[0]).Label
                && !Find<TextBlock>(window, "compact.inspector.notice").IsVisible, "The round buttons add components and keep the selection");
            // Each component's settings live in the inspector once it is selected, as on the Mac.
            window.SelectCompactComponent("activity"); await Pump();
            Check(Find<TextBlock>(window, "compact.inspector.title").Text == state.Components.Single(value => value.Id == "activity").Label && Find<ComboBox>(window, "compact.singleTask").IsVisible
                && !Find<Border>(window, "compact.metric.quota").IsVisible, "The inspector shows only the selected component's settings");
            Select(Find<ComboBox>(window, "compact.singleTask"), "count"); await Until(() => session.Current.CompactSingleTask == "count");
            window.SelectCompactComponent("quota"); await Pump();
            Check(Find<TextBlock>(window, "compact.window_label.codex").IsVisible && Find<TextBlock>(window, "compact.window_label.claude").IsVisible, "Quota windows follow the components that show a quota");
            Select(Find<RadioButton>(window, "compact.metric.pace")); await Until(() => session.Current.CompactMetric == "pace");
            window.SelectCompactComponent("quotaGauge"); await Pump();
            // The rings' card can keep both rings lit while the quota value alternates.
            Select(Find<RadioButton>(window, "compact.option.ringDim.off"));
            await Until(() => !CompactChoices.Parse(session.Current.CompactComponentOptions).RingDim);
            await island.WaitForPresentationAsync();
            Check(SelfAndDescendants(island).OfType<CompactQuotaGlyph>().All(glyph => glyph.Highlighted == null), "With alternate dimming off, no ring dims");
            Select(Find<RadioButton>(window, "compact.option.ringDim.on"));
            await Until(() => CompactChoices.Parse(session.Current.CompactComponentOptions).RingDim);
            Select(Find<ComboBox>(window, "compact.ring.0"), "deepseek"); await Until(() => session.Current.QuotaRingOuter == "deepseek");
            Check(configurations == 0, "Readout and ring choices cannot restart sources");
            island.Reveal(); await island.WaitForPresentationAsync();
            var header = ((StackPanel)island.FindName("HeaderLeading")).Children.Cast<Button>()
                .Concat(((StackPanel)island.FindName("HeaderTrailing")).Children.Cast<Button>()).ToArray();
            var surface = (Grid)island.FindName("Header");
            foreach (var button in header)
            {
                var bounds = new Rect(button.TranslatePoint(new Point(), surface), button.RenderSize);
                Check(bounds.Left >= -1 && bounds.Right <= surface.ActualWidth + 1, "The actual compact values must fit their measured header");
            }
            island.CapturePreview(Path.Combine(output, "collapsed-all-components-" + name + ".png"));
            // The open panel leaves the bar's own components at full strength.
            Check(header.All(value => Math.Abs(value.Opacity - 1) < .001), "Expanding keeps every bar component at full strength");
            PressKey(island, island, Key.Escape); await island.WaitForPresentationAsync();
            Check(header.All(value => Math.Abs(value.Opacity - 1) < .001), "Collapsing keeps every bar component at full strength");
            var status = Find<Button>(window, "compact.component.status.toggle"); bool original = Equals(status.Tag, "added");
            reject = true; Invoke(status); await Until(() => !reject && status.IsEnabled);
            await island.WaitForPresentationAsync();
            Check(Equals(status.Tag, "added") == original && SelfAndDescendants(island).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "compact.row.status") == original,
                "A failed write must restore the editor's acknowledged state");
            Check(configurations == 0, "A failed presentation write cannot reconfigure a source");
            var scroller = Find<ScrollViewer>(window, "settings.content"); scroller.ScrollToTop(); await Pump();
            foreach (var chip in SelfAndDescendants(editor).OfType<FrameworkElement>().Where(value => AutomationProperties.GetAutomationId(value).StartsWith("compact.chip.", StringComparison.Ordinal)))
            {
                Rect bounds = new(chip.TranslatePoint(new Point(), editor), chip.RenderSize);
                Check(bounds.Left >= -1 && bounds.Right <= editor.ActualWidth + 1, "Wrapped chips cannot clip outside either lane");
                Check(UIElementAutomationPeer.CreatePeerForElement(chip)?.GetName().Length > 0, "Every reorder handle must expose a readable accessibility name");
            }
            window.CapturePreview(Path.Combine(output, "settings-collapsed-" + name + "-top.png"));
            scroller.ScrollToBottom(); await Pump(); window.CapturePreview(Path.Combine(output, "settings-collapsed-" + name + "-bottom.png"));
            var hidden = Find<FrameworkElement>(window, "compact.chip.firstOutput");
            string? old = session.Current.CompactLayout; int oldSaves = saves;
            await window.NavigateAsync("appearance");
            PressKey(window, hidden, Key.Right); await Pump();
            Check(session.Current.CompactLayout == old && saves == oldSaves + 1, "Cached handles from a removed pane cannot reorder");
            await window.NavigateAsync("collapsed"); await Pump();
            string? beforeRestore = session.Current.CompactLayout;
            Invoke(Find<Button>(window, "compact.restore"));
            await Until(() => session.Current.CompactLayout != beforeRestore && Find<Button>(window, "compact.restore").IsEnabled);
            Check(session.Current.CompactSingleTask == "count" && session.Current.CompactMetric == "pace" && session.Current.QuotaRingOuter == "deepseek",
                "Restore Arrangement must retain the independent display choices, like the original");
            var warning = Find<Button>(window, "compact.component.warnings.toggle"); Invoke(warning);
            await Until(() => Equals(warning.Tag, "add") && warning.IsEnabled);
            await window.NavigateAsync("reminders"); await Pump();
            var fiveHour = Find<CheckBox>(window, "settings.reminders.fiveHour");
            await Until(() => fiveHour.IsEnabled);
            Check(!fiveHour.IsChecked.GetValueOrDefault(), "Removing the warnings slot must make its reminder switches read off");
            Toggle(fiveHour);
            await Until(() => session.Current.WarningKinds.SequenceEqual(new[] { "fiveHour" }));
            Check((await NativeCompactBar.Shared.ReadAsync(session.Current, language, ["codex", "claude", "deepseek"])).EditorTrailing.First() == "warnings",
                "Choosing one reminder must restore the slot at the start with only that kind");
            await window.NavigateAsync("collapsed"); await Pump();
            // The warnings card keeps their style and limit and links to Notifications for the kinds.
            window.SelectCompactComponent("warnings"); await Pump();
            var chooseKinds = Find<Button>(window, "compact.warnings.choose");
            await Until(() => chooseKinds.IsVisible);
            Invoke(chooseKinds);
            await Until(() => Find<RadioButton>(window, "settings.pane.notifications").IsChecked == true);
            await window.NavigateAsync("collapsed"); await Pump();
            window.SelectCompactComponent("warnings"); await Pump();
            var dot = Find<RadioButton>(window, "compact.option.warningStyle.dot"); Select(dot);
            await Until(() => CompactChoices.Parse(session.Current.CompactComponentOptions).WarningStyle == "dot");
            Check(CompactChoices.Parse(session.Current.CompactComponentOptions).WarningLimit == 2, "Each choice is saved on its own, keeping the others");
            await session.ChangeAsync(p => p with { Position = "bottomLeft", DisplayMode = "floating" }); await island.WaitForPresentationAsync();
            Check(SelfAndDescendants(island).OfType<Button>().Where(value => AutomationProperties.GetAutomationId(value).StartsWith("compact.strip.", StringComparison.Ordinal)).All(value =>
                !AutomationProperties.GetAutomationId(value).EndsWith(".status", StringComparison.Ordinal)),
                "The side strip must retain its saved components while omitting the two word labels");
            island.CapturePreview(Path.Combine(output, "collapsed-strip-" + name + ".png"));
            // Each size scales the live bar and strip; materials repaint the same bar.
            island.CollapseForAutomation();
            foreach (var (size, height, strip, material) in new[] { ("small", 32.0, 28.0, "liquidGlass"), ("large", 42.0, 37.0, "graphite"), ("extraLarge", 48.0, 43.0, "liquidGlassLight"), ("standard", 36.0, 32.0, "classic") })
            {
                await session.ChangeAsync(p => p with { CompactBarSize = size, IslandAppearance = material, Position = "center", DisplayMode = "floating", IslandPlacement = null });
                await island.WaitForPresentationAsync();
                Check(island.LogicalTarget.Height == height && island.VisibleHeight == height, $"The {size} bar is {height} points high");
                Check(PacerPalette.Light == (material == "liquidGlassLight"), "Only Light Liquid Glass turns the island's inks light");
                if (PacerPalette.Light)
                {
                    // Every word on the light bar and in the light panel takes a dark ink.
                    PaleText(island, "The light bar");
                    Check(SelfAndDescendants(island).OfType<ActivityBadge>().Where(badge => badge.IsVisible).All(badge =>
                        badge.OrbitCodexShade == ((SolidColorBrush)PacerPalette.Codex).Color), "The badge's orbit redraws in the light shades");
                    island.Reveal(); await island.WaitForPresentationAsync(); await Pump();
                    PaleText(island, "The light panel");
                    island.CapturePreview(Path.Combine(output, "expanded-" + material + "-" + name + ".png"));
                    island.CollapseForAutomation(); await island.WaitForPresentationAsync();
                }
                Check(island.RimSides == "tblr" && island.Decoration.Shadow && island.Decoration.Shoulders.Length == 0,
                    "A floating bar draws its rim on every side and casts a shadow, with no shoulders");
                island.CapturePreview(Path.Combine(output, "collapsed-" + size + "-" + material + "-" + name + ".png"));
                await session.ChangeAsync(p => p with { Position = "topLeft", PositionChosen = true });
                await island.WaitForPresentationAsync();
                // Glass cannot be painted outside its window, so only an opaque strip has shoulders.
                Check(island.VisibleWidth == strip && island.RimSides == "tbr" && island.Decoration.Shoulders == (island.GlassVisible ? "" : "l") && !island.Decoration.Shadow,
                    $"The {size} strip is {strip} points wide, with shoulders against the screen unless it is glass, and no rim there");
                await session.ChangeAsync(p => p with { Position = "center" });
            }
            await session.ChangeAsync(p => p with { DisplayMode = "notch" }); await island.WaitForPresentationAsync();
            Check(island.VisibleHeight == 36 && island.RimSides == "blr" && island.Decoration.Shoulders == "t",
                "An attached bar without a camera housing takes the size's height and flares into the screen top");
            island.CapturePreview(Path.Combine(output, "collapsed-attached-" + name + ".png"));
        }
        finally
        {
            await engine.DisposeAsync(); window.AllowClose = true; window.Close(); island.AllowClose = true; island.Close();
            // The inks are shared; a failed case must not leave the next one light.
            PacerPalette.ApplyTone(false);
        }
    }
    private static void PaleText(DependencyObject root, string where)
    {
        var pale = SelfAndDescendants(root).OfType<TextBlock>().Where(text => text.IsVisible && !string.IsNullOrWhiteSpace(text.Text)
            && text.Foreground is SolidColorBrush { Color: { A: > 100, R: > 190, G: > 190, B: > 190 } }).Select(text => text.Text).ToArray();
        Check(pale.Length == 0, where + " keeps no white text: " + string.Join(" | ", pale));
    }
    private static Point Centre(FrameworkElement element, Visual relative) => element.TranslatePoint(new Point(element.ActualWidth / 2, element.ActualHeight / 2), (UIElement)relative);
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject
        => SelfAndDescendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
    private static void Select(RadioButton value) => ((ISelectionItemProvider)new RadioButtonAutomationPeer(value).GetPattern(PatternInterface.SelectionItem)).Select();
    private static void Select(ComboBox value, string selection)
    {
        value.SelectedItem = value.Items.Cast<ComboBoxItem>().Single(item => (string)item.Tag == selection);
    }
    private static bool PressKey(Window window, UIElement target, Key key)
    {
        var input = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, key) { RoutedEvent = Keyboard.KeyDownEvent };
        target.RaiseEvent(input); return input.Handled;
    }
    private static async Task Until(Func<bool> condition)
    {
        double end = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency + 5;
        while (!condition() && Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency < end) await Pump();
        Check(condition(), "The compact editor did not settle in time");
    }
    private static async Task Pump() { await Task.Delay(30); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
