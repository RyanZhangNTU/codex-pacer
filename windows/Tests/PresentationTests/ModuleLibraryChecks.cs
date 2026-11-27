using System;
using System.Collections.Generic;
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
using Rectangle = System.Windows.Shapes.Rectangle;
using PathShape = System.Windows.Shapes.Path;

internal static class ModuleLibraryChecks
{
    private const string Prefix = "settings.modules.";
    private static readonly EngineModule[] Catalog =
    [
        new("codex", "automatic", true, true),
        new("claude", "disabled", true, false),
        new("deepseek", "enabled", false, true, Website: "https://example.test/deepseek", Prominent: true, ApplicationInstalled: true),
        new("antigravity", "automatic", true, true, "Antigravity", Website: "https://example.test/antigravity", ApplicationInstalled: false),
        new("workbuddy", "automatic", false, false, "WorkBuddy", Prominent: false),
        new("workbuddy-ai", "automatic", false, false, "WorkBuddy AI", Website: "https://example.test/international", Prominent: false)
    ];

    internal static async Task Run(string language, bool dark, string output)
    {
        var ui = UiText.For(language == "zh-Hans");
        await using var engine = new EngineClient();
        await engine.StartAsync(Environment.ProcessPath!, true, "moduleLibrary", referenceFixture: true);
        Task Publish(params EngineModule[] modules) => PresentationWait.CommandSnapshotAsync(engine, "setModules", modules);
        var releaseEdit = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var prefs = new DesktopPreferences { LastSettingsPane = "modules",
            ProviderModes = new() { ["codex"] = "automatic", ["claude"] = "disabled", ["deepseek"] = "enabled" } };
        var session = new PreferencesSession(prefs, _ => releaseEdit.Task, _ => true);
        var sites = new List<Uri>();
        var window = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, dark, engine,
            appearanceSource: new AppearanceFixture(), guideLinkLauncher: site => { sites.Add(site); return true; })
        {
            ShowActivated = false, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = 0
        };
        try
        {
            window.Show();
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            var page = Find<ScrollViewer>(window, "settings.content");
            Check(Name(page) == ui.Text("main.pane.modules") && AutomationProperties.GetHelpText(page) == ""
                && Descendants(window).OfType<TextBlock>().Any(t => t.IsVisible && t.Text == Name(page)
                    && AutomationProperties.GetHeadingLevel(t) == AutomationHeadingLevel.Level1), "The library needs its page title");
            CheckSections(page, ui, [], []);
            await Publish(Catalog);
            window.UpdateLayout();
            var grids = CheckSections(page, ui, ["codex", "claude", "antigravity"], ["deepseek", "workbuddy", "workbuddy-ai"]);
            var sidebar = Find<RadioButton>(window, "settings.pane.modules");
            Check(Descendants(sidebar).OfType<TextBlock>().Any(t => t.IsVisible && t.Text == ui.Text("modules.sidebar_more").Replace("%ld", "2")),
                "The sidebar count excludes the manually enabled missing module");
            Check(Find<RadioButton>(window, "settings.pane.deepseek").IsVisible, "The manually enabled module stays in the sidebar");
            foreach (var grid in grids) CheckTwoColumns(grid);
            CheckColumnThresholds();
            foreach (var module in Catalog) CheckTile(page, module, ui);

            var missing = grids.Last();
            var card = (Grid)missing.Children[0];
            var neighbor = (Grid)missing.Children[1];
            var summary = Find<TextBlock>(card, Prefix + "deepseek.summary");
            var info = Find<Button>(card, Prefix + "deepseek.info");
            var get = Find<Button>(card, Prefix + "deepseek.get");
            // Get waits behind the closed Info, so its template isn't applied yet; read its own content.
            var linkText = ((StackPanel)get.Content).Children.OfType<TextBlock>().Single();
            var toggle = Find<Button>(card, Prefix + "deepseek.toggle");
            double closedHeight = card.ActualHeight, neighborHeight = neighbor.ActualHeight;
            double nameLeft = Bounds(card, NameLabel(card, "DeepSeek")).Left;
            void Capture(string suffix) => window.CapturePreview(Path.Combine(output, $"module-library-{language}-{(dark ? "dark" : "light")}{suffix}.png"));
            Capture("");
            Check(!get.IsVisible && Near(closedHeight, 54), "Get stays behind the closed Info, so the tile keeps one line");
            HitAndClick(card, info);
            window.UpdateLayout();
            Check(summary.IsVisible && summary.Text == ui.Text("module.deepseek.summary") && summary.TextWrapping == TextWrapping.Wrap
                && AccessibleText(page, summary.Text) == 1
                && Near(summary.FontSize, 11.5) && summary.Foreground == page.FindResource("SettingsSecondary")
                && Status(info) == ui.Text("main.info_shown") && info.ToolTip == null, "Info reveals the localized summary and announces its status");
            var detail = Bounds(card, summary);
            Check(Near(detail.Left, nameLeft) && detail.Top >= Bounds(card, info).Bottom && detail.Bottom <= Bounds(card, get).Top
                && Near(Bounds(card, linkText).Left, nameLeft) && card.ActualHeight > closedHeight && Near(neighbor.ActualHeight, neighborHeight),
                "The summary and Get link align with the name and only the expanded tile grows");
            // Like the summary, Get is quiet: secondary text with a small arrow, not an accent link.
            Check(get.IsVisible && linkText.Foreground == page.FindResource("SettingsSecondary") && Near(linkText.FontSize, 11.5)
                && Descendants(get).OfType<IconGlyph>().Any(g => g.Symbol == "arrow.up.right" && g.IsVisible), "Get uses the summary's color with an arrow");
            CheckTwoColumns(missing);
            Capture("-info");
            HitAndClick(card, get);
            PressEnter(get);
            PressEnter(info);
            window.UpdateLayout();
            Check(!summary.IsVisible && AccessibleText(page, summary.Text) == 0
                && Status(info) == ui.Text("main.info_hidden") && Near(card.ActualHeight, closedHeight),
                "Enter collapses the summary and restores the closed height");
            Check(!get.IsVisible, "Get hides again with the summary");
            Check(sites.Select(site => site.AbsoluteUri).SequenceEqual(Enumerable.Repeat(Catalog[2].Website!, 2)),
                "Both Get actions must open the descriptor URL through the fake launcher");
            HitAndClick(card, toggle);
            Check(Descendants(page).OfType<Button>().Where(b => Id(b).EndsWith(".toggle", StringComparison.Ordinal)).All(b => !b.IsEnabled),
                "A pending settings change disables every module toggle");
            releaseEdit.SetResult();
            await PresentationWait.UntilAsync(() => session.Current.ProviderModes["deepseek"] == "disabled" && toggle.IsEnabled,
                "The round button must turn off the missing module");
            Check(session.Current.LastSettingsPane == "modules", "Info, Get and toggle must leave the library open");
            AssertHit(card, NameLabel(card, "DeepSeek"), Find<Button>(card, Prefix + "deepseek"));

            // A new state for the same catalog keeps focusable controls and the open disclosure.
            PressEnter(info);
            var disabled = Catalog.Select(m => m.Provider == "deepseek" ? m with { Enabled = false, Mode = "disabled" } : m).ToArray();
            await Publish(disabled);
            Check(summary.IsVisible && Status(info) == ui.Text("main.info_shown") && ReferenceEquals(toggle, Find<Button>(page, Id(toggle))),
                "A state refresh must preserve the open summary and its controls");
            CheckTile(page, disabled[2], ui, expanded: true);
            PressEnter(toggle);
            await PresentationWait.UntilAsync(() => session.Current.ProviderModes["deepseek"] == "enabled" && toggle.IsEnabled,
                "The outlined plus must turn the module back on");
            Check(session.Current.LastSettingsPane == "modules", "Keyboard activation of the plus must stay on the library page");
            var workbuddy = Find<Button>(page, Prefix + "workbuddy");
            var workbuddyTile = (Grid)workbuddy.Parent;
            AssertHit(workbuddyTile, NameLabel(workbuddyTile, "WorkBuddy"), workbuddy);
            await Invoke(workbuddy);
            await PresentationWait.UntilAsync(() => session.Current.LastSettingsPane == DesktopPreferences.HarnessPanePrefix + "workbuddy",
                "The tile body must open the module's Settings page");
            await window.NavigateAsync("modules");
            await Publish(Catalog[0]);
            CheckSections(page, ui, ["codex"], []);
            await Publish(Catalog[4]);
            CheckSections(page, ui, [], ["workbuddy"]);
            await Publish();
            CheckSections(page, ui, [], []);
            await Publish(Catalog);
            await engine.SendAsync("shutdown");
            await PresentationWait.UntilAsync(() => engine.IsConnectionClosed && !Find<Button>(page, Prefix + "workbuddy.toggle").IsEnabled,
                "A disconnected engine must disable the module toggles");
            Console.WriteLine($"PASS Module Library ({language}, {(dark ? "dark" : "light")})");
        }
        finally { releaseEdit.TrySetResult(); window.AllowClose = true; window.Close(); }
    }

    private static ModuleGrid[] CheckSections(ScrollViewer page, UiText ui, string[] found, string[] missing)
    {
        page.UpdateLayout();
        var headings = Descendants(page).OfType<TextBlock>().Where(t => t.IsVisible && AutomationProperties.GetHeadingLevel(t) == AutomationHeadingLevel.Level2).ToArray();
        string[] keys = missing.Length == 0 ? ["modules.on_this_computer"] : ["modules.on_this_computer", "modules.not_found"];
        Check(headings.Select(t => t.Text).SequenceEqual(keys.Select(ui.Text)) && !Descendants(page).OfType<Expander>().Any(),
            "Only the detected and nonempty missing sections have headings");
        var placeholder = Find<TextBlock>(page, Prefix + "more_coming");
        var grids = Descendants(page).OfType<ModuleGrid>().ToArray();
        for (int i = 0; i < headings.Length; i++)
        {
            var section = (StackPanel)headings[i].Parent;
            string[] members = i == 0 ? found : missing;
            Check(section.Children[0] == headings[i] && !section.Children.OfType<Button>().Any()
                && !Descendants(section).OfType<Button>().Any(b => Name(b) == ui.Text("main.info").Replace("%@", headings[i].Text)),
                "Each section starts with a plain heading");
            var empty = section.Children.OfType<TextBlock>().SingleOrDefault(t => t.Text == ui.Text("modules.empty"));
            Check((empty != null) == (members.Length == 0) && (empty == null || empty.IsVisible && empty.Foreground == page.FindResource("SettingsSecondary")),
                "The empty detected group shows its secondary message");
            var grid = section.Children.OfType<ModuleGrid>().SingleOrDefault();
            var membersInGrid = grid == null ? [] : Descendants(grid).OfType<ModulePageButton>().Select(b => Id(b)[Prefix.Length..]).ToArray();
            Check(membersInGrid.SequenceEqual(members), "Each grid lists its modules in engine registry order");
            if (i + 1 == headings.Length)
                Check(grid != null && section.Children[^1] == grid && Descendants(grid.Children[^1]).Contains(placeholder),
                    "More coming occupies the last slot of the last section, after any empty message");
        }
        var tile = (FrameworkElement)grids.Last().Children[^1];
        var outline = Descendants(tile).OfType<Rectangle>().Single();
        var art = Descendants(tile).OfType<IconGlyph>().Single();
        var peer = Peer(placeholder);
        Check(peer.GetAutomationControlType() == AutomationControlType.Text && peer.GetName() == ui.Text("modules.more_coming")
            && AccessibleText(page, peer.GetName()) == 1
            && !peer.IsKeyboardFocusable() && peer.GetItemStatus() == "" && peer.GetPattern(PatternInterface.Invoke) == null
            && peer.GetPattern(PatternInterface.Value) == null && !tile.IsHitTestVisible && !SelfAndDescendants(tile).OfType<UIElement>().Any(e => e.Focusable)
            && !Descendants(tile).OfType<Button>().Any() && Near(tile.ActualHeight, 54), "More coming is a static, noninteractive text tile");
        Check(outline.StrokeDashArray.SequenceEqual(new[] { 4d, 4d }) && outline.Fill == null && Near(outline.StrokeThickness, 1)
            && Near(outline.RadiusX, 10) && Near(outline.RadiusY, 10) && art.Symbol == "sparkle" && art.Ink == page.FindResource("SettingsSecondary")
            && placeholder.Foreground == art.Ink, "The placeholder has neutral text and artwork inside an unfilled dashed outline");
        return grids;
    }

    private static void CheckTile(FrameworkElement page, EngineModule module, UiText ui, bool expanded = false)
    {
        string id = Prefix + module.Provider, titleKey = "module." + module.Provider + ".title";
        string name = ui.Has(titleKey) ? ui.Text(titleKey) : module.DisplayName ?? module.Provider switch
        { "codex" => "Codex", "claude" => "Claude", "deepseek" => "DeepSeek", _ => throw new InvalidOperationException() };
        var body = Find<Button>(page, id);
        var tile = (Grid)body.Parent;
        var surface = (Border)body.Template.FindName("Surface", body);
        var title = NameLabel(tile, name);
        var info = Find<Button>(tile, id + ".info");
        var state = Find<TextBlock>(tile, id + ".state");
        var toggle = Find<Button>(tile, id + ".toggle");
        var mark = (Grid)toggle.Template.FindName("Mark", toggle);
        var circle = (System.Windows.Shapes.Ellipse)toggle.Template.FindName("Circle", toggle);
        var icon = Descendants(tile).OfType<FrameworkElement>().Single(e => (e is Image or IconGlyph) && e.Width == 28 && e.Height == 28);
        string expected = ui.Text(module.Enabled ? "modules.state.on" : module.Installed == true ? "modules.state.off" : "modules.state.not_found");
        var value = (IValueProvider?)Peer(body).GetPattern(PatternInterface.Value);
        Check(Name(body) == name && value is { IsReadOnly: true } && value.Value == expected && Status(body) == expected
            && state.Text == expected && Near(state.FontSize, 11.5) && state.Foreground == page.FindResource(module.Enabled ? "SettingsSuccess" : "SettingsSecondary"),
            id + " needs its localized name, automation value and state color");
        Check(surface.Background == page.FindResource("SettingsTileIdle") && surface.BorderBrush == page.FindResource("SettingsTileStroke")
            && surface.CornerRadius == new CornerRadius(10) && surface.BorderThickness == new Thickness(1), id + " needs the neutral card surface");
        var image = Bounds(tile, icon);
        var label = Bounds(tile, title);
        Check(Near(image.Left, 12) && Near(image.Width, 28) && Near(image.Height, 28) && Near(label.Left - image.Right, 10)
            && Near(icon.Opacity, module.Installed == true || module.Enabled ? 1 : 0.55) && Near(title.FontSize, 13)
            && title.FontWeight == FontWeights.Medium && title.TextWrapping == TextWrapping.Wrap, id + " icon and title geometry");
        var infoBounds = Bounds(tile, info);
        Check(Near(infoBounds.Width, 20) && Near(infoBounds.Height, 20) && Near(infoBounds.Left - label.Right, 3)
            && infoBounds.Right + 3.9 <= Bounds(tile, state).Left && Bounds(tile, state).Right <= Bounds(tile, mark).Left
            && Near(mark.ActualWidth, 24) && Near(mark.ActualHeight, 24), id + " needs the inline Info and trailing state and round button");
        Check(Name(info) == ui.Text("main.info").Replace("%@", name) && Status(info) == ui.Text(expanded ? "main.info_shown" : "main.info_hidden")
            && Find<TextBlock>(tile, id + ".summary").IsVisible == expanded && info.ToolTip == null, id + " info state");
        Check(Name(toggle) == ui.Text(module.Enabled ? "modules.turn_off" : "modules.turn_on").Replace("%@", name)
            && ((PathShape)toggle.Template.FindName(module.Enabled ? "Check" : "Plus", toggle)).IsVisible
            && (module.Enabled ? circle.Fill == page.FindResource("SettingsAccent") : circle.Stroke == page.FindResource("SettingsTileRing")), id + " round button");
        var get = Descendants(tile).OfType<Button>().SingleOrDefault(b => Id(b) == id + ".get");
        Check((get != null) == (module.Installed != true && module.Website != null)
            && (get == null || get.IsVisible == expanded && Name(get) == ui.Text("modules.get").Replace("%@", name)), id + " Get availability");
        if (!expanded && title.ActualHeight < 28) Check(Near(tile.ActualHeight, 54), id + " closed tile height");
        foreach (var button in Descendants(tile).OfType<Button>())
            Check(button.Focusable && button.IsTabStop && Peer(button).GetPattern(PatternInterface.Invoke) != null, Id(button) + " keyboard and automation action");
    }

    private static void CheckTwoColumns(ModuleGrid grid)
    {
        var slots = grid.Children.Cast<FrameworkElement>().Select(child => Bounds(grid, child)).ToArray();
        double width = (grid.ActualWidth - 8) / 2;
        Check(width >= 280 && slots.All(r => Near(r.Width, width)), "Normal Settings width fits two equal columns");
        for (int i = 0; i < slots.Length; i++)
        {
            Check(Near(slots[i].Left, i % 2 * (width + 8)), "Columns start at the leading edge with an 8 DIP gap");
            if (i % 2 == 1) Check(Near(slots[i].Top, slots[i - 1].Top), "Tiles in each row are top-aligned");
            else if (i >= 2) Check(Near(slots[i].Top, Math.Max(slots[i - 2].Bottom, slots[i - 1].Bottom) + 8), "Rows have an 8 DIP gap");
        }
    }

    private static void CheckColumnThresholds()
    {
        var grid = new ModuleGrid();
        for (int i = 0; i < 3; i++) grid.Children.Add(new Border { Height = 54 });
        foreach (var (width, columns) in new[] { (260, 1), (567, 1), (568, 2), (855, 2), (856, 3) })
        {
            grid.Measure(new Size(width, double.PositiveInfinity));
            grid.Arrange(new Rect(0, 0, width, grid.DesiredSize.Height));
            var slots = grid.Children.Cast<FrameworkElement>().Select(child => Bounds(grid, child)).ToArray();
            Check(slots.Count(r => Near(r.Top, 0)) == columns && slots.All(r => r.Width >= 280), $"Adaptive columns at {width} DIP");
        }
    }

    private static void AssertHit(Grid tile, FrameworkElement target, Button expected)
    {
        var bounds = Bounds(tile, target);
        var hit = tile.InputHitTest(new Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2)) as DependencyObject;
        while (hit != null && hit is not Button) hit = VisualTreeHelper.GetParent(hit);
        Check(hit == expected, Id(expected) + " must own the pointer hit");
    }

    private static void HitAndClick(Grid tile, Button button)
    {
        AssertHit(tile, button, button);
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, button));
    }

    private static void PressEnter(Button button) => button.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,
        PresentationSource.FromVisual(button), Environment.TickCount, Key.Enter) { RoutedEvent = Keyboard.KeyDownEvent });
    private static async Task Invoke(Button button)
    {
        ((IInvokeProvider)Peer(button).GetPattern(PatternInterface.Invoke)!).Invoke();
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    private static Rect Bounds(FrameworkElement root, FrameworkElement child) => new(child.TranslatePoint(new Point(), root), child.RenderSize);
    private static AutomationPeer Peer(UIElement element) => UIElementAutomationPeer.CreatePeerForElement(element);
    private static int AccessibleText(UIElement root, string text)
    {
        int Count(AutomationPeer peer)
        {
            return (peer.IsControlElement() && peer.GetAutomationControlType() == AutomationControlType.Text && peer.GetName() == text ? 1 : 0)
                + (peer.GetChildren()?.Sum(Count) ?? 0);
        }
        return Count(Peer(root));
    }
    private static string Name(UIElement element) => Peer(element).GetName();
    private static string Status(UIElement element) => Peer(element).GetItemStatus();
    private static string Id(DependencyObject e) => AutomationProperties.GetAutomationId(e);
    private static TextBlock NameLabel(Grid tile, string name) => Descendants(tile).OfType<TextBlock>().Single(t => t.Text == name);
    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().Single(e => Id(e) == id);
    private static bool Near(double actual, double expected) => Math.Abs(actual - expected) < 0.05;
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
