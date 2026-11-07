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
            foreach (string id in state.Components.Where(value => value.Available && !value.Shown).Select(value => value.Id).ToArray())
            {
                await Until(() => editor.IsEnabled);
                var check = Find<CheckBox>(window, "compact.component." + id); Toggle(check);
                await Until(() => check.IsChecked == true && check.IsEnabled);
            }
            Select(Find<ComboBox>(window, "compact.singleTask"), "count"); await Until(() => session.Current.CompactSingleTask == "count");
            Select(Find<ComboBox>(window, "compact.metric.quota"), "pace"); await Until(() => session.Current.CompactMetric == "pace");
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
            Check(header.Any(value => value.Tag is true) && header.Any(value => value.Tag is false), "The live header must contain both dimmed and full-strength components");
            Check(header.All(value => Math.Abs(value.Opacity - (value.Tag is true ? .3 : 1)) < .001), "Expansion must quiet only the original quota family");
            PressKey(island, island, Key.Escape);
            if (animations)
            {
                // With idle clocks removed, the first timing tick may still
                // sample the starting value. Wait for actual clock progress,
                // rather than assuming a 30 ms dispatcher delay advanced it.
                await Pump();
                await Until(() => header.Where(value => value.Tag is true).All(value => value.Opacity > .3 && value.Opacity <= 1));
                Check(header.Where(value => value.Tag is true).All(value => value.Opacity > .3 && value.Opacity <= 1), "Collapsed values must ease from their displayed opacity");
                island.Reveal(); await island.WaitForPresentationAsync();
                Check(header.All(value => Math.Abs(value.Opacity - (value.Tag is true ? .3 : 1)) < .001), "A reversed dim must settle without changing other components");
            }
            else Check(header.All(value => Math.Abs(value.Opacity - 1) < .001), "Reduced motion must restore full strength immediately");
            var status = Find<CheckBox>(window, "compact.component.status"); bool original = status.IsChecked == true;
            reject = true; Toggle(status); await Until(() => !reject && status.IsEnabled);
            await island.WaitForPresentationAsync();
            Check((status.IsChecked == true) == original && SelfAndDescendants(island).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "compact.row.status") == original,
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
            var warning = Find<CheckBox>(window, "compact.component.warnings"); Toggle(warning);
            await Until(() => warning.IsChecked == false && warning.IsEnabled);
            await window.NavigateAsync("reminders"); await Pump();
            var fiveHour = Find<CheckBox>(window, "settings.reminders.fiveHour");
            await Until(() => fiveHour.IsEnabled);
            Check(!fiveHour.IsChecked.GetValueOrDefault(), "Removing the warnings slot must make its reminder switches read off");
            Toggle(fiveHour);
            await Until(() => session.Current.WarningKinds.SequenceEqual(new[] { "fiveHour" }));
            Check((await NativeCompactBar.Shared.ReadAsync(session.Current, language, ["codex", "claude", "deepseek"])).EditorTrailing.First() == "warnings",
                "Choosing one reminder must restore the slot at the start with only that kind");
            await window.NavigateAsync("collapsed"); await Pump();
            await session.ChangeAsync(p => p with { Position = "bottomLeft", DisplayMode = "floating" }); await island.WaitForPresentationAsync();
            Check(SelfAndDescendants(island).OfType<Button>().Where(value => AutomationProperties.GetAutomationId(value).StartsWith("compact.strip.", StringComparison.Ordinal)).All(value =>
                !AutomationProperties.GetAutomationId(value).EndsWith(".status", StringComparison.Ordinal) && !AutomationProperties.GetAutomationId(value).EndsWith(".quotaLabel", StringComparison.Ordinal)),
                "The side strip must retain its saved components while omitting the two word labels");
            island.CapturePreview(Path.Combine(output, "collapsed-strip-" + name + ".png"));
        }
        finally
        {
            await engine.DisposeAsync(); window.AllowClose = true; window.Close(); island.AllowClose = true; island.Close();
        }
    }
    private static Point Centre(FrameworkElement element, Visual relative) => element.TranslatePoint(new Point(element.ActualWidth / 2, element.ActualHeight / 2), (UIElement)relative);
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject
        => SelfAndDescendants(root).OfType<T>().First(value => AutomationProperties.GetAutomationId(value) == id);
    private static void Invoke(Button value) => ((IInvokeProvider)new ButtonAutomationPeer(value).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Toggle(CheckBox value) => ((IToggleProvider)new CheckBoxAutomationPeer(value).GetPattern(PatternInterface.Toggle)).Toggle();
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
