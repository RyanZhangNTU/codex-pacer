using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CodexPacer.Windows;

/// Page-local choices and samples never touch collection or the saved profile.
internal sealed class GuideContent : StackPanel
{
    private readonly UiText ui;
    private readonly PreferencesSession session;
    private readonly IStartupRegistration startup;
    private readonly NotificationSession? notifications;
    private readonly EngineClient? engine;
    private readonly Func<EngineSnapshot?> snapshot;
    private readonly GuideCatalog catalog;
    private readonly Action<string> settings;
    private readonly Action welcome;
    private readonly Func<Uri, bool>? launch;
    private readonly Action<string> copyLink;
    private readonly List<Action> refresh = [];
    private readonly List<FrameworkElement> editors = [];
    private readonly TextBlock issue;
    private bool syncing, changing;
    private Popup? code;
    private int copyRevision;
    private SupportShareSession? share;
    internal GuideContent(UiText ui, PreferencesSession session, IStartupRegistration startup, GuideCatalog catalog,
        Action<string> settings, Action welcome, EngineClient? engine = null, NotificationSession? notifications = null, Func<Uri, bool>? launch = null, Func<EngineSnapshot?>? snapshot = null, Action<string>? copyLink = null)
    {
        this.ui = ui; this.session = session; this.startup = startup; this.catalog = catalog;
        this.settings = settings; this.welcome = welcome; this.engine = engine; this.notifications = notifications; this.launch = launch;
        this.snapshot = snapshot ?? (() => engine?.LatestSnapshot);
        this.copyLink = copyLink ?? Clipboard.SetText;
        issue = Text("", 11); Identify(issue, "guide.issue", ""); AutomationProperties.SetLiveSetting(issue, AutomationLiveSetting.Assertive);
        issue.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
        issue.SetBinding(VisibilityProperty, new System.Windows.Data.Binding(nameof(TextBlock.Text)) { Source = issue, Converter = EmptyCollapses.Instance });
        Loaded += (_, _) => { session.Changed += PreferencesChanged; if (engine != null) engine.Snapshot += SnapshotChanged; if (notifications != null) notifications.Changed += Refresh; Refresh(); };
        Unloaded += (_, _) => { copyRevision++; session.Changed -= PreferencesChanged; if (engine != null) engine.Snapshot -= SnapshotChanged; if (notifications != null) notifications.Changed -= Refresh; if (code != null) code.IsOpen = false; share?.Dispose(); share = null; };
        PreviewKeyDown += (_, args) =>
        {
            if (args.Key != Key.Escape) return;
            if (code?.IsOpen == true) { code.IsOpen = false; args.Handled = true; }
            else if (qqCode?.IsOpen == true) { qqCode.IsOpen = false; args.Handled = true; }
        };
    }
    private void PreferencesChanged(DesktopPreferences value)
    {
        string next = value.AppTheme + "/" + value.AccentColor;
        if (next != look) { look = next; LookChanged?.Invoke(); }
        Refresh();
    }
    private void SnapshotChanged(EngineSnapshot _) => Dispatcher.InvokeAsync(Refresh);
    internal void Refresh()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.InvokeAsync(Refresh); return; }
        syncing = true;
        try { foreach (var editor in editors) editor.IsEnabled = !changing && !session.RequiresRestart; foreach (var action in refresh) action(); }
        finally { syncing = false; }
    }
    private void Reset()
    {
        if (code != null) code.IsOpen = false;
        if (qqCode != null) qqCode.IsOpen = false; qqCode = null;
        share?.Dispose(); share = null;
        foreach (UIElement child in Children) if (child != issue) PageAccessibility.Retire(child);
        Children.Clear(); refresh.Clear(); editors.Clear(); Children.Add(issue); issue.Text = "";
    }
    internal DesktopPreferences Preferences => session.Current;
    internal event Action? LookChanged;
    private string look = "";
    internal static void Identify(DependencyObject value, string id, string name)
    { AutomationProperties.SetAutomationId(value, id); AutomationProperties.SetName(value, name); }
    private TextBlock Text(string text, double size = 13, bool bold = false)
    {
        var value = new TextBlock { Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        value.SetResourceReference(TextBlock.ForegroundProperty, size < 12 ? "SettingsSecondary" : "SettingsPrimary"); return value;
    }
    private void Heading(string key) { var label = Text(ui.Text(key), 13, true); label.Margin = new Thickness(10, 12, 0, 8); Children.Add(label); }
    /// Rows in one grouped box, separated by inset hairlines as on the Mac guide.
    private static Border Group(double inset, params UIElement[] rows)
    {
        var content = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) { var line = new Border { Height = 1, Margin = new Thickness(14, 0, 14, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); content.Children.Add(line); }
            content.Children.Add(rows[i]);
        }
        var group = new Border { Child = content, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1) };
        group.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); group.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder"); return group;
    }
    private StackPanel Column(string key, UIElement content)
    {
        var column = new StackPanel(); var title = Text(ui.Text(key), 12); title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        title.Margin = new Thickness(10, 0, 0, 6); column.Children.Add(title); column.Children.Add(content); return column;
    }
    /// An icon tile, a title over its detail, and an optional trailing control.
    private Grid TileRow(Border tile, string title, TextBlock detail, UIElement? control = null)
    {
        var row = new Grid { Margin = new Thickness(12, 10, 12, 10) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tile.Margin = new Thickness(0, 0, 12, 0); row.Children.Add(tile);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        labels.Children.Add(Text(title)); detail.Margin = new Thickness(0, 2, 0, 0); labels.Children.Add(detail);
        Grid.SetColumn(labels, 1); row.Children.Add(labels);
        if (control != null) { Grid.SetColumn(control, 2); row.Children.Add(control); }
        return row;
    }
    private Button Button(string title, string id, Action action)
    {
        var button = new Button { Content = title, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 3, 0, 3) };
        Identify(button, id, title); button.Click += (_, _) => action(); return button;
    }
    private Button Link(string key, string action) => Button(ui.Text(key), "guide.link." + action, () =>
    { if (!GuideLinks.Open(catalog, action, launch)) issue.Text = ui.Text("windows.pages.open_failed"); });
    internal void OpenHelp() => settings("help");
    internal void OpenReleaseNotes() { if (!GuideLinks.Open(catalog, "releaseNotes", launch)) issue.Text = ui.Text("windows.pages.open_failed"); }
    private async Task Edit(Func<Task<bool>> change)
    {
        if (syncing || changing || session.RequiresRestart) return;
        changing = true; issue.Text = ""; Refresh();
        try { if (!await change()) issue.Text = ui.Text("windows.settings.save_failed"); }
        catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException) { issue.Text = ui.Text("windows.settings.apply_failed"); }
        finally { changing = false; if (IsLoaded) Refresh(); }
    }
    private CheckBox Switch(string title, string id, Func<bool> read, Func<bool, Task<bool>> write)
    {
        var check = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), VerticalAlignment = VerticalAlignment.Center };
        Identify(check, id, title); editors.Add(check); refresh.Add(() => check.IsChecked = read());
        RoutedEventHandler changed = async (_, _) => { if (!syncing) { bool value = check.IsChecked == true; await Edit(() => write(value)); } };
        check.Checked += changed; check.Unchecked += changed; return check;
    }
    private async Task<bool> Preference(Func<DesktopPreferences, DesktopPreferences> edit) => await session.ChangeAsync(edit) == PreferencesApplyResult.Applied;
    private CheckBox Login(string title, string id)
    {
        var check = Switch(title, id, () => startup.Read().Registered, value => Task.FromResult(startup.Set(value)));
        refresh.Add(() => check.IsEnabled = !changing && !session.RequiresRestart && startup.Read().Available); return check;
    }
    internal static ActivityBadge Badge(int state)
    {
        var badge = new ActivityBadge(); badge.Update(state switch
        {
            1 => new(1, null, new Dictionary<string, int>(), "input", null, null, false, "1"),
            2 => new(0, "checkmark.circle", new Dictionary<string, int>(), null, "checkmark.circle", "codex", true),
            // Some ended: the count stays and a small dot marks the ending.
            3 => new(1, null, new Dictionary<string, int> { ["claude"] = 1 }, null, "checkmark.circle", "codex", false, "1"),
            _ => new(2, null, new Dictionary<string, int> { ["codex"] = 1, ["claude"] = 1 }, null, null, null, false, "2")
        }, false); return badge;
    }
    /// A black swatch shaped like the bar, so island marks read as on screen in both themes.
    private static Border Swatch(params UIElement[] samples)
    {
        var marks = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var sample in samples) { if (sample is FrameworkElement item) { item.Margin = new Thickness(3, 0, 3, 0); item.VerticalAlignment = VerticalAlignment.Center; } marks.Children.Add(sample); }
        return new Border { Width = 84, Height = 32, Background = PacerPalette.Surface, CornerRadius = new CornerRadius(9), Child = marks, VerticalAlignment = VerticalAlignment.Center, ClipToBounds = true };
    }
    private static IconGlyph Mark(string symbol, Brush? ink = null, double size = 14) => new() { Symbol = GuideArt.Symbol(symbol), Ink = ink ?? PacerPalette.Primary, Width = size, Height = size };
    private static TextBlock Figure(string text, Brush ink, double size = 12) => new() { Text = text, FontSize = size, FontWeight = FontWeights.SemiBold, Foreground = ink };
    private static ActivityBadge Tasks(int count, params string[] providers)
    {
        var badge = new ActivityBadge(); badge.Update(new(count, null, providers.ToDictionary(provider => provider, _ => 1), null, null, null, false, count.ToString()), false); return badge;
    }
    /// A small bar carried toward a screen edge, on the same black swatch as the other marks.
    private static Canvas MoveSample()
    {
        var sample = new Canvas { Width = 56, Height = 18 };
        void Add(UIElement element, double x, double y) { Canvas.SetLeft(element, x); Canvas.SetTop(element, y); sample.Children.Add(element); }
        Add(new Border { Width = 20, Height = 8, CornerRadius = new CornerRadius(4), Background = PacerPalette.Overlay(64),
            BorderBrush = PacerPalette.Overlay(140), BorderThickness = new Thickness(1) }, 0, 5);
        Add(new System.Windows.Shapes.Path { Data = Geometry.Parse("M 0 4 L 18 4 M 14 0 L 18 4 L 14 8"), Stroke = PacerPalette.Tick, StrokeThickness = 1.4 }, 25, 5);
        Add(new Border { Width = 3, Height = 18, CornerRadius = new CornerRadius(1.5), Background = PacerPalette.Codex }, 50, 0);
        return sample;
    }
    /// A quota bar with the white reference tick.
    private static Grid PaceSample()
    {
        var bar = new Grid { Width = 48, Height = 10 };
        bar.Children.Add(new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = PacerPalette.Overlay(46) });
        bar.Children.Add(new Border { Width = 28, Height = 4, CornerRadius = new CornerRadius(2), Background = PacerPalette.Codex, HorizontalAlignment = HorizontalAlignment.Left });
        bar.Children.Add(new Border { Width = 2, Height = 10, CornerRadius = new CornerRadius(1), Background = PacerPalette.Tick, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(21, 0, 0, 0) });
        return bar;
    }
    private static CompactQuotaGlyph Rings(params (string Provider, double Remaining)[] values)
    {
        var rings = new CompactQuotaGlyph { Width = 20, Height = 20 };
        rings.Update(new(1, "", [], [], [], [], [], [], [], [], values.Select(value => new CompactRing(value.Provider, value.Remaining, false)).ToArray(), [], false, false), null); return rings;
    }
    /// Badges sit on a bar-colored swatch, as they appear on the island.
    private Grid BadgeRow(int state, string title, string? hint = null, Brush? tint = null)
    {
        var row = new Grid { Height = 38, Margin = new Thickness(12, 0, 12, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
        var badge = Badge(state); badge.HorizontalAlignment = HorizontalAlignment.Center; badge.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(new Border { Width = 30, Height = 26, CornerRadius = new CornerRadius(7), Background = PacerPalette.Surface, Child = badge, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center });
        var label = new TextBlock { FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        var name = new System.Windows.Documents.Run(title); if (tint != null) name.Foreground = tint; else name.SetResourceReference(TextElement.ForegroundProperty, "SettingsPrimary");
        label.Inlines.Add(name);
        if (hint != null) { var extra = new System.Windows.Documents.Run("  ·  " + hint); extra.SetResourceReference(TextElement.ForegroundProperty, "SettingsSecondary"); label.Inlines.Add(extra); }
        Grid.SetColumn(label, 1); row.Children.Add(label); Identify(row, "welcome.badge." + state, title + (hint == null ? "" : " · " + hint)); return row;
    }
    private Border Gestures()
    {
        var content = new Grid { Margin = new Thickness(10) };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); content.ColumnDefinitions.Add(new ColumnDefinition());
        var scene = new Viewbox { Width = 92, Height = 60, Child = new WelcomeGestureScene(), Margin = new Thickness(0, 0, 10, 0) };
        content.Children.Add(scene);
        // Three gestures in one style, each beside its illustration: hover, leave, drag.
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        lines.Children.Add(Gesture("welcome.gesture.hover", "welcome.gesture.expand"));
        lines.Children.Add(GestureDivider());
        lines.Children.Add(Gesture("welcome.gesture.leave", "welcome.gesture.collapse"));
        Grid.SetColumn(lines, 1); content.Children.Add(lines);
        var move = new Viewbox { Width = 92, Height = 32, Child = new WelcomeMoveScene(), Margin = new Thickness(0, 8, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetRow(move, 1); content.Children.Add(move);
        var drag = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        drag.Children.Add(GestureDivider());
        drag.Children.Add(Gesture("welcome.gesture.drag", "welcome.gesture.move", ui.Text("welcome.gesture.snap")));
        Grid.SetColumn(drag, 1); Grid.SetRow(drag, 1); content.Children.Add(drag);
        var group = new Border { Child = content, CornerRadius = new CornerRadius(10) }; group.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); return group;
    }
    private static Border GestureDivider()
    {
        var divider = new Border { Height = 1 }; divider.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); return divider;
    }
    private StackPanel Gesture(string verb, string result, string? note = null)
    {
        string action = ui.Text(verb), detail = ui.Text(result);
        var line = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 4, 0, 4) };
        line.Children.Add(Text(action + " → " + detail));
        if (note != null)
        {
            var hint = Text(note, 12); hint.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); hint.Margin = new Thickness(0, 2, 0, 0);
            line.Children.Add(hint);
        }
        Identify(line, verb, action + " " + detail + (note == null ? "" : " " + note)); return line;
    }
    private static WarningMark Warning(string kind, bool solid = false, string provider = "codex") => new(new(kind == "lowBalance" ? "balance" : "fiveHour", kind == "lowBalance" ? "deepseek" : provider, solid,
        kind == "lowBalance" ? null : solid ? "0" : "12", kind == "lowBalance" ? "exclamationmark.circle" : null, ""));
    /// The four welcome pages, as on the Mac: what the island shows, how it
    /// appears, which services it watches, and a last few choices.
    internal static readonly string[] WelcomePages = ["main.welcome.title", "main.welcome.mode_title", "main.welcome.services_title", "main.welcome.finish_title"];
    private StackPanel PageHeader(string title, string subtitle)
    {
        var header = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch };
        var heading = Text(title, 24, true); heading.FontWeight = FontWeights.Bold; heading.TextAlignment = TextAlignment.Center; heading.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level1); header.Children.Add(heading);
        var detail = Text(subtitle, 13); detail.TextAlignment = TextAlignment.Center; detail.TextWrapping = TextWrapping.Wrap; detail.Margin = new Thickness(0, 6, 0, 0);
        detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); header.Children.Add(detail);
        return header;
    }
    internal void WelcomeStep(int step)
    {
        Reset();
        switch (step)
        {
            case 0:
                var icon = new DecorativeImage { Width = 84, Height = 84, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center,
                    Source = BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) };
                Children.Add(icon);
                var intro = PageHeader(ui.Text("main.welcome.title"), ui.Text("welcome.subtitle")); intro.Margin = new Thickness(0, 8, 0, 26); Children.Add(intro);
                var map = new WelcomeIslandMap(ui, Badge, Rings(("codex", 58), ("claude", 81)), Warning("codex5hLow"));
                Identify(map, "welcome.bar", ui.Text("welcome.step.island")); Children.Add(map);
                break;
            case 1:
                var mode = PageHeader(ui.Text("main.welcome.mode_title"), ui.Text("main.welcome.mode_subtitle")); mode.Margin = new Thickness(0, 4, 0, 24); Children.Add(mode);
                var cards = new Grid();
                cards.ColumnDefinitions.Add(new ColumnDefinition()); cards.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) }); cards.ColumnDefinitions.Add(new ColumnDefinition());
                var island = ModeCard(true, ui.Text("main.welcome.mode_island"), ui.Text("main.welcome.mode_island_detail"), new WelcomeGestureScene());
                var free = ModeCard(false, ui.Text("main.welcome.mode_free"), ui.Text("appearance.free_move_detail"), new WelcomeMoveScene());
                cards.Children.Add(island); Grid.SetColumn(free, 2); cards.Children.Add(free); Children.Add(cards);
                break;
            case 2:
                var services = PageHeader(ui.Text("main.welcome.services_title"), ui.Text("welcome.modules_note")); services.Margin = new Thickness(0, 4, 0, 24); Children.Add(services);
                var modules = new Grid();
                string[] providers = ["codex", "claude", "deepseek"];
                for (int i = 0; i < providers.Length; i++)
                {
                    if (i > 0) modules.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
                    modules.ColumnDefinitions.Add(new ColumnDefinition());
                    var card = Module(providers[i]); Grid.SetColumn(card, i * 2); modules.Children.Add(card);
                }
                Children.Add(modules);
                break;
            default:
                var finish = PageHeader(ui.Text("main.welcome.finish_title"), ui.Text("main.welcome.finish_subtitle")); finish.Margin = new Thickness(24, 4, 24, 24); Children.Add(finish);
                // One switch for every service's ring; Settings keeps one per service.
                var rings = Switch(ui.Text("main.claude.ring"), "welcome.rings", () => session.Current.ClaudeProgressRing || session.Current.CodexProgressRing || session.Current.DeepSeekProgressRing,
                    value => Preference(p => p with { ClaudeProgressRing = value, CodexProgressRing = value, DeepSeekProgressRing = value }));
                var notification = Switch(ui.Text("settings.system_notifications"), "welcome.notifications", () => notifications?.DesiredEnabled == true,
                    async value => notifications != null && await notifications.SetEnabledAsync(value) == NotificationChangeResult.Applied);
                refresh.Add(() => notification.IsEnabled = !changing && !session.RequiresRestart && notifications != null);
                var notificationProblem = Text("", 11.5); notificationProblem.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
                refresh.Add(() =>
                {
                    bool denied = notifications?.Availability == NotificationAvailability.Denied;
                    notificationProblem.Text = denied ? ui.Text("windows.settings.notification_denied") : "";
                    notificationProblem.Visibility = denied ? Visibility.Visible : Visibility.Collapsed;
                });
                var loginProblem = Text("", 11.5); Identify(loginProblem, "welcome.system.status", ""); loginProblem.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
                refresh.Add(() =>
                {
                    string blocked = StartupDetail();
                    loginProblem.Text = blocked; AutomationProperties.SetName(loginProblem, blocked);
                    loginProblem.Visibility = blocked.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                });
                var layout = Button(ui.Text("welcome.go"), "welcome.collapsed", () => settings("collapsed"));
                var choices = Group(54,
                    ChoiceRow(GuideArt.Tile("circle.circle", Color.FromRgb(48, 176, 199), 28), ui.Text("main.claude.ring"), ui.Text("main.welcome.ring_info"), null, rings),
                    ChoiceRow(GuideArt.Tile("bell.badge", Color.FromRgb(255, 77, 74), 28), ui.Text("settings.system_notifications"), ui.Text("main.welcome.notifications_info"), notificationProblem, notification),
                    ChoiceRow(GuideArt.Tile("power", Color.FromRgb(51, 189, 102), 28), ui.Text("settings.open_at_login"), ui.Text("main.welcome.login_info"), loginProblem, Login(ui.Text("settings.open_at_login"), "welcome.startup")),
                    ChoiceRow(GuideArt.Tile("rectangle.topthird.inset.filled", Color.FromRgb(51, 56, 69), 28), ui.Text("welcome.layout.title"), ui.Text("main.welcome.layout_info"), null, layout));
                choices.Margin = new Thickness(24, 0, 24, 0); Children.Add(choices);
                break;
        }
        Refresh();
    }
    /// One way the island appears, shown moving. Choosing it moves the real island
    /// at once, the same choice as Appearance > Position.
    private RadioButton ModeCard(bool attached, string title, string detail, FrameworkElement art)
    {
        var card = new RadioButton { Style = (Style)FindResource("SettingsArtChoice"), GroupName = "welcome.mode", Height = double.NaN, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var content = new StackPanel { Margin = new Thickness(12, 12, 12, 14) };
        var frame = new Border { Height = 118, CornerRadius = new CornerRadius(8), ClipToBounds = true, Background = new SolidColorBrush(Color.FromRgb(40, 44, 58)),
            Child = new Viewbox { Child = art, Stretch = Stretch.Uniform, Margin = new Thickness(10) } };
        content.Children.Add(frame);
        var heading = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        var mark = new IconGlyph { Width = 17, Height = 17, VerticalAlignment = VerticalAlignment.Center }; DockPanel.SetDock(mark, Dock.Right); heading.Children.Add(mark);
        heading.Children.Add(Text(title, 14, true)); content.Children.Add(heading);
        var text = Text(detail, 11.5); text.Margin = new Thickness(0, 3, 0, 0); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); content.Children.Add(text);
        card.Content = content; Identify(card, attached ? "welcome.mode.notch" : "welcome.mode.free", title);
        refresh.Add(() =>
        {
            bool selected = (session.Current.DisplayMode == "notch") == attached;
            card.IsChecked = selected;
            mark.Symbol = selected ? "checkmark.circle" : "empty.circle";
            mark.SetResourceReference(IconGlyph.InkProperty, selected ? "SettingsAccent" : "SettingsSecondary");
        });
        editors.Add(card);
        card.Checked += async (_, _) => { if (!syncing && (session.Current.DisplayMode == "notch") != attached) await Edit(() => Preference(p => p with { DisplayMode = attached ? "notch" : "floating" })); };
        return card;
    }
    /// A row of the last page: a tile, the title with an info button, then its control.
    /// A problem shows under the title in amber; the explanation opens under the row.
    private StackPanel ChoiceRow(Border tile, string title, string info, TextBlock? problem, UIElement control)
    {
        var row = new Grid { Margin = new Thickness(12, 10, 12, 10) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tile.Margin = new Thickness(0, 0, 12, 0); row.Children.Add(tile);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        var heading = new StackPanel { Orientation = Orientation.Horizontal }; heading.Children.Add(Text(title));
        var box = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(11, 9, 11, 9), Margin = new Thickness(52, 0, 12, 10), Visibility = Visibility.Collapsed };
        box.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        var body = Text(info, 12); body.LineHeight = 17; body.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); box.Child = body;
        var glyph = new IconGlyph { Symbol = "info.circle", Width = 14, Height = 14 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var button = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 22, Height = 22, Padding = new Thickness(0), Margin = new Thickness(3, -2, 0, -2), Content = glyph, VerticalAlignment = VerticalAlignment.Center };
        Identify(button, "welcome.info." + (AutomationProperties.GetAutomationId(control) is { Length: > 0 } id ? id : title), ui.Text("main.info").Replace("%@", title, StringComparison.Ordinal));
        button.Click += (_, _) =>
        {
            bool show = box.Visibility != Visibility.Visible; box.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            glyph.SetResourceReference(IconGlyph.InkProperty, show ? "SettingsPrimary" : "SettingsSecondary");
            AutomationProperties.SetItemStatus(button, ui.Text(show ? "main.info_shown" : "main.info_hidden"));
        };
        AutomationProperties.SetItemStatus(button, ui.Text("main.info_hidden"));
        heading.Children.Add(button); labels.Children.Add(heading);
        if (problem != null) { problem.Margin = new Thickness(0, 2, 0, 0); labels.Children.Add(problem); }
        Grid.SetColumn(labels, 1); row.Children.Add(labels);
        if (control is FrameworkElement end) end.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 2); row.Children.Add(control);
        AutomationProperties.SetHelpText(control, info);
        var host = new StackPanel(); host.Children.Add(row); host.Children.Add(box); return host;
    }
    private string StartupDetail()
    {
        var state = startup.Read();
        return state.BlockReason switch { StartupBlockReason.Disabled => ui.Text("windows.settings.startup_disabled"), StartupBlockReason.Policy => ui.Text("windows.settings.startup_policy"),
            StartupBlockReason.OtherInstallation => ui.Text("windows.settings.startup_other"), StartupBlockReason.Unknown => ui.Text("windows.settings.startup_unknown"), _ => "" };
    }
    private Border Module(string provider)
    {
        string name = provider == "codex" ? "Codex" : provider == "claude" ? "Claude" : "DeepSeek";
        var layout = new Grid { Margin = new Thickness(12) };
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto }) layout.RowDefinitions.Add(new RowDefinition { Height = height });
        var top = new Grid();
        var tile = ProviderIcon.Tile(provider, 34); tile.HorizontalAlignment = HorizontalAlignment.Left; top.Children.Add(tile);
        var toggle = Switch(name, "welcome.module." + provider, () => session.Current.ProviderModes[provider] switch
        { "enabled" => true, "disabled" => false, _ => snapshot()?.Modules?.FirstOrDefault(value => value.Provider == provider)?.Enabled == true },
            value => Preference(p => p with { ProviderModes = new(p.ProviderModes) { [provider] = value ? "enabled" : "disabled" } }));
        toggle.HorizontalAlignment = HorizontalAlignment.Right; toggle.VerticalAlignment = VerticalAlignment.Top; top.Children.Add(toggle); layout.Children.Add(top);
        var title = Text(name, 15, true); title.Margin = new Thickness(0, 9, 0, 0); Grid.SetRow(title, 1); layout.Children.Add(title);
        var statusLine = new Grid { Margin = new Thickness(0, 3, 0, 8), VerticalAlignment = VerticalAlignment.Top };
        statusLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); statusLine.ColumnDefinitions.Add(new ColumnDefinition());
        var ready = new IconGlyph { Symbol = "checkmark.circle", Width = 13, Height = 13, Margin = new Thickness(0, 1, 5, 0), VerticalAlignment = VerticalAlignment.Top };
        ready.SetResourceReference(IconGlyph.InkProperty, "SettingsSuccess"); statusLine.Children.Add(ready);
        var status = Text("", 11); status.MaxHeight = 32; status.TextTrimming = TextTrimming.CharacterEllipsis; status.VerticalAlignment = VerticalAlignment.Top;
        Identify(status, "welcome.module." + provider + ".status", name); Grid.SetColumn(status, 1); statusLine.Children.Add(status);
        Grid.SetRow(statusLine, 2); layout.Children.Add(statusLine);
        var action = Button(ui.Text("welcome.module.settings"), "welcome.module." + provider + ".action", () => settings(provider));
        action.HorizontalAlignment = HorizontalAlignment.Left; action.FontSize = 12; action.Padding = new Thickness(9, 2, 9, 2); action.Margin = new Thickness(0);
        Grid.SetRow(action, 3); layout.Children.Add(action);
        refresh.Add(() =>
        {
            var latest = snapshot(); var module = latest?.Modules?.FirstOrDefault(value => value.Provider == provider);
            bool enabled = toggle.IsChecked == true, isReady = false, connects = false; string? titleKey = null;
            string text = catalog.ModuleOff[provider];
            if (enabled)
            {
                if (module?.Installed == false) { text = ui.Text("welcome.module." + provider + "_missing"); titleKey = "welcome.module.settings"; }
                else if (module == null || module.Installed == null) text = ui.Text("claude.account.checking");
                else if (provider == "claude" && latest?.ClaudeConnection?.State == "checking" || provider == "deepseek" && latest?.DeepseekConnection?.Refreshing == true && latest.Wallet?.Balance == null)
                    text = ui.Text("claude.account.checking");
                else if (provider == "claude" && latest?.ClaudeConnection is { State: not "signedIn" } claude)
                { text = ui.Text(claude.State == "workspaceNeeded" ? "claude.account.workspace_needed" : "welcome.module.sign_in_detail"); titleKey = claude.State == "workspaceNeeded" ? "claude.quota.choose_workspace" : "welcome.module.sign_in"; connects = true; }
                else if (provider == "deepseek" && latest?.Wallet?.Balance == null)
                { bool key = latest?.DeepseekConnection?.Mode == "apiKey"; text = ui.Text(key ? "welcome.module.balance_detail" : "welcome.module.balance_sign_in_detail"); titleKey = key ? "deepseek.paste_key_short" : "welcome.module.sign_in"; connects = true; }
                else { text = ui.Text("welcome.module.ready") + (session.Current.ProviderModes[provider] == "automatic" ? " · " + ui.Text("welcome.module.automatic") : ""); isReady = true; }
            }
            status.Text = text; status.ToolTip = text; AutomationProperties.SetName(status, text); ready.Visibility = isReady ? Visibility.Visible : Visibility.Collapsed;
            title.SetResourceReference(TextBlock.ForegroundProperty, enabled ? "SettingsPrimary" : "SettingsSecondary"); tile.Opacity = enabled ? 1 : 0.45;
            action.Visibility = titleKey == null ? Visibility.Collapsed : Visibility.Visible;
            if (titleKey != null) { action.Content = ui.Text(titleKey); AutomationProperties.SetName(action, ui.Text(titleKey)); }
            // Connecting is what the card waits for, so it takes the provider's color.
            if (connects) { action.Background = new SolidColorBrush(GuideArt.ProviderTile(provider)); action.Foreground = new SolidColorBrush(Color.FromArgb(222, 0, 0, 0)); }
            else { action.ClearValue(Control.BackgroundProperty); action.ClearValue(Control.ForegroundProperty); }
        });
        var card = new Border { Child = layout, CornerRadius = new CornerRadius(10) }; card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); return card;
    }
    /// A highlight's symbol in the accent color on a soft tile of the same hue, as on the Mac.
    private static Border FeatureSymbol(string symbol, double size)
    {
        var glyph = new IconGlyph { Symbol = GuideArt.Symbol(symbol), Width = size * 0.52, Height = size * 0.52 };
        glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsAccent");
        var tile = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.26), Child = glyph };
        tile.SetResourceReference(Border.BackgroundProperty, "SettingsAccentSoft"); return tile;
    }
    /// The update note draws each highlight larger, as a feature list without cards.
    internal void Releases(IEnumerable<GuideRelease> releases, bool large = false)
    {
        Reset(); var list = releases.ToList();
        foreach (var release in list)
        {
            // Skipped updates keep their own headings, newest first.
            if (list.Count > 1)
            {
                var heading = Text(release.Title, 12); heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                heading.Margin = new Thickness(large ? 0 : 10, release == list[0] ? 0 : large ? 22 : 14, 0, large ? 16 : 6); if (large) heading.FontWeight = FontWeights.SemiBold; Children.Add(heading);
            }
            var rows = new List<UIElement>();
            foreach (var item in release.Items)
            {
                // The update note keeps each explanation behind ⓘ, as Help & Updates does.
                if (large) { var feature = InfoFeatureRow(item, true, unique: false); feature.Margin = new Thickness(0, 0, 0, 14); Children.Add(feature); continue; }
                UIElement? control = item.Control switch
                {
                    "openAtLogin" => Login(item.Title, "guide.control.openAtLogin"),
                    "showAppButtons" => Switch(item.Title, "guide.control.showAppButtons", () => session.Current.ShowAppButtons, value => Preference(p => p with { ShowAppButtons = value })),
                    "showEmbeddedSessions" => EmbeddedControl(item.Title, item.Detail),
                    _ => PaneLink(item)
                };
                string detail = item.Control == "openAtLogin" ? ui.Text("windows.settings.open_at_login_detail") : item.Detail;
                rows.Add(TileRow(FeatureSymbol(item.Symbol, 28), item.Title, Text(detail, 11.5), control));
            }
            if (!large) Children.Add(Group(50, rows.ToArray()));
        }
        Refresh();
    }
    /// Help & Updates' What's New, as on the Mac: the newest note as a feature
    /// list with the release notes one click away, then every earlier version
    /// folded to one line of its highlights. Explanations wait behind info buttons.
    internal void SettingsReleases(IEnumerable<GuideRelease> history)
    {
        Reset(); var list = history.ToList();
        if (list.Count == 0) { Refresh(); return; }
        var latest = new StackPanel();
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
        var notes = new Button { Content = ui.Text("whats_new.release_notes") + " ↗", Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
        Identify(notes, "guide.releaseNotes", ui.Text("whats_new.release_notes")); notes.Click += (_, _) => OpenReleaseNotes();
        DockPanel.SetDock(notes, Dock.Right); header.Children.Add(notes);
        var title = Text(VersionTitle(list[0]), 15, true); AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2); header.Children.Add(title);
        latest.Children.Add(header);
        foreach (var item in list[0].Items) { var row = InfoFeatureRow(item, true); row.Margin = new Thickness(0, latest.Children.Count > 1 ? 16 : 0, 0, 0); latest.Children.Add(row); }
        Children.Add(Card(latest, new Thickness(18)));
        if (list.Count > 1)
        {
            var heading = Text(ui.Text("whats_new.earlier"), 12, true); heading.Margin = new Thickness(4, 0, 0, 8); heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            Children.Add(heading);
            var earlier = new StackPanel();
            foreach (var release in list.Skip(1))
            {
                var rows = new StackPanel { Margin = new Thickness(34, 0, 14, 12) };
                foreach (var item in release.Items) { var row = InfoFeatureRow(item, false); row.Margin = new Thickness(0, rows.Children.Count > 0 ? 12 : 0, 0, 0); rows.Children.Add(row); }
                var fold = new Expander { Header = release.Version, Tag = string.Join(" · ", release.Items.Select(item => item.Title)), Content = rows, Style = (Style)FindResource("SettingsReleaseFold") };
                Identify(fold, "whats_new.release." + release.Version, VersionTitle(release));
                if (earlier.Children.Count > 0) { var line = new Border { Height = 1, Margin = new Thickness(14, 0, 14, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); earlier.Children.Add(line); }
                earlier.Children.Add(fold);
            }
            Children.Add(Card(earlier, new Thickness(0)));
        }
        Refresh();
    }
    private string VersionTitle(GuideRelease release) =>
        ui.Has("whats_new.version") ? ui.Text("whats_new.version").Replace("%@", release.Version, StringComparison.Ordinal) : release.Title;
    private Border Card(UIElement child, Thickness padding)
    {
        var card = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = padding, Child = child, Margin = new Thickness(0, 0, 0, 22) };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        return card;
    }
    /// A highlight with only its title; the explanation opens under it from the info button.
    /// A blocked sign-in item still says so in place, and the item's own switch stays.
    /// <param name="unique">Help & Updates lists every version, so its controls carry the title in their ids; the update note keeps plain ids.</param>
    private StackPanel InfoFeatureRow(GuideItem item, bool large, bool unique = true)
    {
        string suffix = unique ? "." + item.Title.GetHashCode().ToString("x") : "";
        UIElement? control = item.Control switch
        {
            "openAtLogin" => Login(item.Title, "guide.control.openAtLogin" + suffix),
            "showAppButtons" => Switch(item.Title, "guide.control.showAppButtons" + suffix, () => session.Current.ShowAppButtons, value => Preference(p => p with { ShowAppButtons = value })),
            "showEmbeddedSessions" => EmbeddedControl(item.Title, item.Detail),
            _ => PaneLink(item)
        };
        double size = large ? 40 : 28;
        var host = new StackPanel();
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = FeatureSymbol(item.Symbol, size); tile.Margin = new Thickness(0, 0, large ? 14 : 12, 0); row.Children.Add(tile);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var heading = new WrapPanel();
        var title = Text(item.Title, large ? 13.5 : 13, large); heading.Children.Add(title);
        var box = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(11, 9, 11, 9), Margin = new Thickness(size + (large ? 14 : 12), 8, 0, 0), Visibility = Visibility.Collapsed };
        box.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        string detail = item.Control == "openAtLogin" ? ui.Text("windows.settings.open_at_login_detail") : item.Detail;
        var body = Text(detail, 12); body.LineHeight = 17; body.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); box.Child = body;
        heading.Children.Add(InfoToggle(item.Title, box));
        labels.Children.Add(heading);
        if (item.Control == "openAtLogin")
        {
            var problem = Text("", 11.5); problem.SetResourceReference(TextBlock.ForegroundProperty, "SettingsWarning");
            refresh.Add(() => { string blocked = StartupDetail(); problem.Text = blocked; problem.Visibility = blocked.Length > 0 ? Visibility.Visible : Visibility.Collapsed; });
            labels.Children.Add(problem);
        }
        Grid.SetColumn(labels, 1); row.Children.Add(labels);
        if (control is FrameworkElement end) { end.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(end, 2); row.Children.Add(end); }
        host.Children.Add(row); host.Children.Add(box); return host;
    }
    /// "Settings ›" at the end of a highlight whose setting lives on a page.
    private Button? PaneLink(GuideItem item)
    {
        string? pane = item.Control switch { "openExpandedPanel" => "expandedPanel", "openCollapsedBar" => "collapsed", "openAppearance" => "appearance", _ => null };
        if (pane == null) return null;
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var text = Text(ui.Text("whats_new.open_settings"), 12.5); text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsLinkText"); content.Children.Add(text);
        var chevron = new IconGlyph { Symbol = "chevron.right", Width = 9, Height = 9, Margin = new Thickness(3, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        chevron.SetResourceReference(IconGlyph.InkProperty, "SettingsLinkText"); content.Children.Add(chevron);
        var button = new Button { Style = (Style)FindResource("SettingsLink"), ContentTemplate = null, Content = content, Cursor = System.Windows.Input.Cursors.Hand, Margin = new Thickness(8, 0, 0, 0) };
        Identify(button, "guide.control." + item.Control, ui.Text("whats_new.open_settings_label").Replace("%@", item.Title, StringComparison.Ordinal));
        button.Click += (_, _) => settings(pane);
        return button;
    }
    private Button InfoToggle(string title, Border box)
    {
        var glyph = new IconGlyph { Symbol = "info.circle", Width = 14, Height = 14 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var button = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 22, Height = 22, Padding = new Thickness(0), Margin = new Thickness(3, -2, 0, -2), Content = glyph, VerticalAlignment = VerticalAlignment.Center };
        Identify(button, "guide.info." + title.GetHashCode().ToString("x"), ui.Text("main.info").Replace("%@", title, StringComparison.Ordinal));
        AutomationProperties.SetItemStatus(button, ui.Text("main.info_hidden"));
        button.Click += (_, _) =>
        {
            bool show = box.Visibility != Visibility.Visible; box.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            glyph.SetResourceReference(IconGlyph.InkProperty, show ? "SettingsPrimary" : "SettingsSecondary");
            AutomationProperties.SetItemStatus(button, ui.Text(show ? "main.info_shown" : "main.info_hidden"));
        };
        return button;
    }
    private CheckBox EmbeddedControl(string title, string detail)
    {
        var check = Switch(title, "guide.control.showEmbeddedSessions", () => GuideControls.ShowsEmbedded(session.Current),
            value => Preference(p => GuideControls.SetEmbedded(p, value)));
        AutomationProperties.SetHelpText(check, detail); return check;
    }
    /// Help, as on the Mac: three ways in (the welcome guide, the user guide,
    /// an issue), then what each mark means, one topic at a time.
    internal void Help()
    {
        Reset(); string[] providers = ["codex", "claude", "deepseek"];
        var quick = new Grid { Margin = new Thickness(0, 0, 0, 22) };
        var tiles = new[] {
            QuickTile(Button(ui.Text("help.quick.welcome"), "help.welcome", welcome), "hand.wave", ui.Text("help.quick.welcome"), ui.Text("help.quick.welcome_detail"), false),
            QuickTile(Link("help.link.guide", "manual"), "book", ui.Text("help.link.guide"), ui.Text("help.quick.guide_detail"), true),
            QuickTile(Link("help.link.issues", "issues"), "exclamationmark.bubble", ui.Text("help.link.issues"), ui.Text("help.quick.issues_detail"), true) };
        for (int index = 0; index < tiles.Length; index++)
        {
            if (index > 0) quick.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            quick.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(tiles[index], index * 2); quick.Children.Add(tiles[index]);
        }
        Children.Add(quick);
        var chips = new WrapPanel { Margin = new Thickness(0, 0, 0, 4) }; var topic = new StackPanel(); var footer = Text(ui.Text("help.enable.detail"), 11.5);
        footer.Margin = new Thickness(4, 8, 4, 0); footer.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetName(chips, ui.Text("settings.pane.help"));
        foreach (string id in new[] { "collapsed", "expanded" }.Concat(providers))
        {
            bool module = providers.Contains(id);
            string name = id switch { "codex" => "Codex", "claude" => "Claude", "deepseek" => "DeepSeek", _ => ui.Text("help.section." + id) };
            var chip = new RadioButton { Style = (Style)FindResource("SettingsTopicChip"), GroupName = "help.topics", Margin = new Thickness(0, 0, 6, 6) };
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            if (module) label.Children.Add(ProviderIcon.Caption(id));
            var text = new TextBlock { Text = name, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            text.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Control.Foreground)) { Source = chip }); label.Children.Add(text);
            chip.Content = label; Identify(chip, module ? "help.module." + id : "help.topic." + id, name);
            chip.Checked += (_, _) => { HelpTopic(topic, id, providers); footer.Visibility = module ? Visibility.Visible : Visibility.Collapsed; };
            chips.Children.Add(chip);
        }
        Children.Add(chips); Children.Add(topic); Children.Add(footer);
        ((RadioButton)chips.Children[0]).IsChecked = true;
    }
    /// The chosen topic's marks, each beside what it means, in one card.
    private void HelpTopic(Panel target, string id, string[] providers)
    {
        foreach (UIElement child in target.Children) PageAccessibility.Retire(child);
        target.Children.Clear();
        if (id == "collapsed")
        {
            // Under one accent the services are its shades, as the tiles draw them.
            bool shades = PacerPalette.Accent != "multicolor";
            var services = HelpRow("help.services", providers.Select(provider => (UIElement)ProviderIcon.Tile(provider, 18)).ToArray());
            if (shades && services.Children.OfType<StackPanel>().FirstOrDefault(child => Grid.GetColumn(child) == 1)?.Children[1] is TextBlock detail) detail.Text = ui.Text("help.services.shades");
            target.Children.Add(Group(HelpInset, services,
                HelpRow("help.tasks", Tasks(1, "codex"), Tasks(2, "codex", "claude"), Tasks(3, providers)),
                HelpRow("help.attention", Badge(1)),
                HelpRow("help.endings", Badge(2), Badge(3)),
                HelpRow("help.quota", Rings(("codex", 58), ("claude", 81)), Figure("58%", PacerPalette.Codex)),
                HelpRow("help.warnings", Warning("codex5hLow"), Warning("lowBalance"), Mark("clock.arrow.circlepath", PacerPalette.Attention, 11)),
                HelpRow("help.customize", Mark("slider.horizontal.3")),
                HelpRow("help.move", MoveSample())));
        }
        else if (id == "expanded")
            target.Children.Add(Group(HelpInset,
                HelpRow("help.hover", Mark("cursorarrow.rays")), HelpRow("help.open", Mark("arrow.up.forward.app")),
                HelpRow("help.app_buttons", providers.Select(provider => (UIElement)ProviderIcon.CreateLaunch(provider, 14)).ToArray()),
                HelpRow("help.read", Mark("checkmark.rectangle.stack")), HelpRow("help.pace", PaceSample())));
        else
        {
            var details = new StackPanel(); ModuleHelp(details, id);
            target.Children.Add(Group(HelpInset, details.Children.Cast<UIElement>().ToArray().Select(child => { details.Children.Remove(child); return child; }).ToArray()));
        }
        Refresh();
    }
    /// One way in: its symbol on a soft tile, a title and a sentence, with an arrow when it leaves Pacer.
    private Button QuickTile(Button button, string symbol, string title, string detail, bool external)
    {
        var content = new StackPanel();
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        if (external)
        {
            var arrow = new IconGlyph { Symbol = "arrow.up.right", Width = 11, Height = 11, VerticalAlignment = VerticalAlignment.Top, Opacity = 0.7 };
            arrow.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); DockPanel.SetDock(arrow, Dock.Right); top.Children.Add(arrow);
        }
        var tile = FeatureSymbol(symbol, 30); tile.HorizontalAlignment = HorizontalAlignment.Left; top.Children.Add(tile);
        content.Children.Add(top);
        content.Children.Add(Text(title, 13, true));
        var line = Text(detail, 11.5); line.Margin = new Thickness(0, 2, 0, 0); line.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); content.Children.Add(line);
        button.Style = (Style)FindResource("SettingsQuickTile"); button.ContentTemplate = null; button.Content = content;
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.VerticalAlignment = VerticalAlignment.Stretch; button.Margin = new Thickness(0);
        AutomationProperties.SetName(button, title); AutomationProperties.SetHelpText(button, detail);
        return button;
    }
    /// Separators start under the text, past the 84-point swatch.
    private const double HelpInset = 110;
    /// The real marks on a bar-colored swatch, then what they mean.
    private Grid HelpRow(string key, params UIElement[] samples)
    {
        string title = ui.Text(key + ".title");
        var row = new Grid { Margin = new Thickness(14, 8, 14, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
        var swatch = Swatch(samples); swatch.Margin = new Thickness(0, 0, 14, 0); row.Children.Add(swatch);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(Text(title)); var detail = Text(ui.Text(key + ".detail"), 11.5); detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); detail.Margin = new Thickness(0, 2, 0, 0); labels.Children.Add(detail);
        Grid.SetColumn(labels, 1); row.Children.Add(labels); Identify(row, key, title); return row;
    }
    private void ModuleHelp(Panel target, string provider)
    {
        target.Children.Clear(); Brush tint = PacerPalette.Provider(provider); double remaining = provider == "claude" ? 81 : 58;
        string[] keys = provider == "codex" ? ["quota", "windows", "remote", "apps"] : provider == "claude" ? ["quota", "windows", "cloud", "remote", "apps"] : ["balance", "mode", "cost", "peak", "clock", "alerts", "speed"];
        foreach (string key in keys)
        {
            UIElement[] samples = provider == "deepseek" ? DeepSeekSample(key) : key switch
            {
                "quota" => [Rings((provider, remaining)), Figure(remaining + "%", tint)],
                "windows" => [Warning("codex5hLow", false, provider), Warning("codex5hExhausted", true, provider)],
                "cloud" => [Mark("cloud", tint)], "remote" => [Mark("network", tint)], _ => [Mark("square.on.square", tint)]
            };
            if (target.Children.Count > 0) { var line = new Border { Height = 1, Margin = new Thickness(14, 0, 14, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); target.Children.Add(line); }
            target.Children.Add(HelpRow("help." + provider + "." + key, samples));
        }
    }
    private static UIElement[] DeepSeekSample(string key)
    {
        switch (key)
        {
            case "balance": return [ProviderIcon.Tile("deepseek", 18), Figure("¥86", PacerPalette.DeepSeek)];
            case "mode": return [Mark("clock", PacerPalette.DeepSeek), Mark("chart.pie", PacerPalette.DeepSeek)];
            case "cost": return [Figure("≈¥0.42", PacerPalette.DeepSeek, 11)];
            case "peak": return [Figure("×2", PacerPalette.Attention)];
            case "alerts": return [Warning("lowBalance"), new WarningMark(new("spendSpike", "deepseek", true, null, "flame.fill", "")), new WarningMark(new("budget", "deepseek", false, "!", null, ""))];
            case "speed": return [new DeepSeekSpeedPlot(new("", new[] { .2, .45, .7, .35, .8 }, .6, "42 t/s", false, "", "")) { Width = 70, Height = 20 }];
        }
        var clock = new DeepSeekPriceClock { Width = 26, Height = 26 };
        clock.Update(new("connected", 86.4, "86", ".40", "", null, Enumerable.Range(0, 24).Select(hour => hour is 9 or 10 or 14 or 15 ? .8 : 0).ToArray(),
            new[] { new WalletSpan(135, 180), new WalletSpan(210, 270) }, 236, true, 3.9, 0, null, null)); return [clock];
    }
    internal void Support()
    {
        Reset();
        // The icon and thanks over a faint wash of the three services' colors, as on the Mac.
        var thanks = new DockPanel { Margin = new Thickness(20, 18, 20, 18) };
        thanks.Children.Add(new DecorativeImage { Width = 60, Height = 60, Margin = new Thickness(0, 0, 16, 0), Stretch = Stretch.Uniform,
            Source = BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 2, Direction = 270, Opacity = 0.25 } });
        var thanksText = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        thanksText.Children.Add(Text(ui.Text("support.thanks.title"), 17, true)); var thanksDetail = Text(ui.Text("support.thanks.detail"), 12.5); thanksDetail.Margin = new Thickness(0, 5, 0, 0); thanksDetail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); thanksText.Children.Add(thanksDetail);
        thanks.Children.Add(thanksText); Identify(thanks, "support.thanks", ui.Text("support.thanks.title"));
        var wash = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        wash.GradientStops.Add(new GradientStop(Color.FromArgb(41, 102, 205, 187), 0)); wash.GradientStops.Add(new GradientStop(Color.FromArgb(31, 255, 164, 119), .5)); wash.GradientStops.Add(new GradientStop(Color.FromArgb(41, 126, 150, 255), 1));
        var hero = new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 12), Child = new Border { CornerRadius = new CornerRadius(13), Background = wash, Child = thanks } };
        hero.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); hero.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        Children.Add(hero);
        var star = Link("support.star.action", "star"); Prominent(star, "star");
        Button? copy = null; copy = Button(ui.Text("support.share.copy"), "support.copy", () => _ = Copy(copy!, catalog.Links["repository"], "support.share.copy", "link"));
        WithGlyph(copy, "link", ui.Text("support.share.copy"));
        var send = Button(ui.Text("support.share.action"), "support.share", () =>
        {
            var window = Window.GetWindow(this);
            if (window == null || !(share ??= new()).Show(new WindowInteropHelper(window).Handle, catalog, ui)) issue.Text = ui.Text("windows.support.share_unavailable");
        });
        // The donation platform by its own name, as on the Mac.
        WithGlyph(send, "square.and.arrow.up", ui.Text("support.share.action"));
        var donate = Link("support.coffee.title", "donate"); WithGlyph(donate, "cup.and.saucer", "Buy Me a Coffee"); AutomationProperties.SetName(donate, "Buy Me a Coffee");
        var coffeeActions = new List<Button> { donate };
        string? file = catalog.SupportCode;
        if (file != null && file == Path.GetFileName(file))
        {
            string imageFile = Path.Combine(AppContext.BaseDirectory, "CodexPacerPortable_PacerCore.resources", file);
            if (File.Exists(imageFile))
            {
                var button = Button(ui.Text("support.code.wechat"), "support.wechat", () => { if (code != null) code.IsOpen = !code.IsOpen; });
                WithGlyph(button, "qrcode", ui.Text("support.code.wechat")); coffeeActions.Insert(0, button);
                var content = CodeCard(imageFile, ui.Text("support.code.wechat_hint"), "support.wechat.panel");
                code = new Popup { PlacementTarget = button, Placement = PlacementMode.Bottom, StaysOpen = false, Child = content };
                content.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { code.IsOpen = false; button.Focus(); args.Handled = true; } };
                WindowRendering.Prepare(code); code.Opened += (_, _) => content.Focus();
            }
        }
        // Three ways to help back side by side, their buttons pinned to the bottom so the cards line up.
        var cards = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        foreach (var (card, column) in new[] {
            (SupportCard("support.star", "star.fill", Color.FromRgb(245, 173, 28), star), 0),
            (SupportCard("support.share", "square.and.arrow.up", Color.FromRgb(51, 168, 115), send, copy), 2),
            (SupportCard("support.coffee", "cup.and.saucer", Color.FromRgb(158, 107, 69), coffeeActions.ToArray()), 4) })
        {
            if (column > 0) cards.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            cards.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(card, column); cards.Children.Add(card);
        }
        Children.Add(cards);
        var feedbackTitle = Text(ui.Text("main.support.feedback"), 12, true); feedbackTitle.Margin = new Thickness(4, 10, 0, 8); feedbackTitle.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        Children.Add(feedbackTitle);
        var rows = new List<UIElement> { FeedbackRow(Link("support.star.feature", "feature"), "lightbulb", Color.FromRgb(250, 194, 51)),
            FeedbackRow(Link("support.star.bug", "bug"), "ladybug", Color.FromRgb(240, 92, 84)) };
        if (catalog.QqGroup is { Length: > 0 } group && ui.Has("support.qq.title")) rows.Add(QqGroupRow(group, catalog.QqCode));
        Children.Add(Group(0, rows.ToArray()));
    }
    /// One way to help: its tile, name and a sentence, then full-width buttons at the bottom.
    private Border SupportCard(string key, string symbol, Color tint, params Button[] actions)
    {
        var layout = new DockPanel { LastChildFill = false };
        var top = new StackPanel(); DockPanel.SetDock(top, Dock.Top);
        var tile = GuideArt.Tile(symbol, tint, 30); tile.HorizontalAlignment = HorizontalAlignment.Left; top.Children.Add(tile);
        var title = Text(ui.Text(key + ".title"), 13.5, true); title.Margin = new Thickness(0, 12, 0, 0); top.Children.Add(title);
        var detail = Text(ui.Text(key + ".detail"), 12); detail.Margin = new Thickness(0, 4, 0, 14); detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); top.Children.Add(detail);
        layout.Children.Add(top);
        var buttons = new StackPanel(); DockPanel.SetDock(buttons, Dock.Bottom);
        foreach (var action in actions) { action.Margin = new Thickness(0, 6, 0, 0); action.HorizontalAlignment = HorizontalAlignment.Stretch; action.MinHeight = 28; action.FontSize = 12.5; buttons.Children.Add(action); }
        layout.Children.Add(buttons);
        var card = new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Padding = new Thickness(14), Child = layout };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        AutomationProperties.SetName(card, ui.Text(key + ".title")); return card;
    }
    /// The QQ group: its number, a copy button and its code on request, as on the Mac.
    private Grid QqGroupRow(string number, string? file)
    {
        var row = new Grid { Margin = new Thickness(14, 8, 14, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = GuideArt.Tile("person.2", Color.FromRgb(0x12, 0xB7, 0xF5), 22); tile.Margin = new Thickness(0, 0, 10, 0); row.Children.Add(tile);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(Text(ui.Text("support.qq.title")));
        var detail = Text(ui.Text("support.qq.number").Replace("%@", number, StringComparison.Ordinal), 11.5); detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); labels.Children.Add(detail);
        Grid.SetColumn(labels, 1); row.Children.Add(labels);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        Button? copy = null; copy = Button(ui.Text("support.qq.copy"), "support.qq.copy", () => _ = Copy(copy!, number, "support.qq.copy"));
        actions.Children.Add(copy);
        string? image = file != null && file == Path.GetFileName(file) ? Path.Combine(AppContext.BaseDirectory, "CodexPacerPortable_PacerCore.resources", file) : null;
        if (image != null && File.Exists(image))
        {
            Popup? popup = null;
            var show = Button(ui.Text("support.qq.code"), "support.qq.code", () => { if (popup != null) popup.IsOpen = !popup.IsOpen; }); show.Margin = new Thickness(6, 3, 0, 3);
            WithGlyph(show, "qrcode", ui.Text("support.qq.code"));
            var content = CodeCard(image, ui.Text("support.qq.hint"), "support.qq.panel");
            popup = new Popup { PlacementTarget = show, Placement = PlacementMode.Bottom, StaysOpen = false, Child = content };
            content.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { popup.IsOpen = false; show.Focus(); args.Handled = true; } };
            WindowRendering.Prepare(popup); popup.Opened += (_, _) => content.Focus();
            qqCode = popup; actions.Children.Add(show);
        }
        Grid.SetColumn(actions, 2); row.Children.Add(actions);
        AutomationProperties.SetName(row, ui.Text("support.qq.title") + " " + detail.Text);
        return row;
    }
    /// A QR code on white with its hint under it; the card itself takes focus so Escape closes it.
    private Border CodeCard(string image, string hint, string id)
    {
        var content = new StackPanel { Margin = new Thickness(12) };
        content.Children.Add(new Image { Source = BitmapFrame.Create(new Uri(image)), Width = 220, Height = 220, Stretch = Stretch.Uniform });
        var line = Text(hint, 12); line.Foreground = Brushes.Black; line.HorizontalAlignment = HorizontalAlignment.Center; line.Margin = new Thickness(0, 6, 0, 0); content.Children.Add(line);
        var card = new Border { Background = Brushes.White, CornerRadius = new CornerRadius(10), Child = content, Focusable = true, FocusVisualStyle = null };
        Identify(card, id, hint); return card;
    }
    /// A feedback form opened in the browser: tile, title and a chevron.
    private Grid FeedbackRow(Button link, string symbol, Color tint)
    {
        var line = new Grid();
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); line.ColumnDefinitions.Add(new ColumnDefinition()); line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = GuideArt.Tile(symbol, tint, 22); tile.Margin = new Thickness(0, 0, 10, 0); tile.VerticalAlignment = VerticalAlignment.Center; line.Children.Add(tile);
        var title = Text(AutomationProperties.GetName(link), 13); Grid.SetColumn(title, 1); line.Children.Add(title);
        var arrow = new IconGlyph { Symbol = "arrow.up.right", Width = 11, Height = 11, VerticalAlignment = VerticalAlignment.Center }; arrow.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        Grid.SetColumn(arrow, 2); line.Children.Add(arrow);
        link.Style = (Style)FindResource("SettingsRowButton"); link.ContentTemplate = null; link.Content = line;
        var row = new Grid(); row.Children.Add(link); return row;
    }
    /// A tile, the title over its detail, then the row's actions in one line.
    private Grid SupportRow(string key, string symbol, Color tint, params Button[] actions)
    {
        var row = new Grid { Margin = new Thickness(12, 10, 12, 12) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
        var tile = GuideArt.Tile(symbol, tint, 26); tile.Margin = new Thickness(0, 0, 12, 0); tile.VerticalAlignment = VerticalAlignment.Top; row.Children.Add(tile);
        var content = new StackPanel(); content.Children.Add(Text(ui.Text(key + ".title")));
        var detail = Text(ui.Text(key + ".detail"), 11); detail.Margin = new Thickness(0, 2, 0, 8); content.Children.Add(detail);
        var line = new WrapPanel();
        foreach (var action in actions) { action.Margin = new Thickness(0, 0, 8, 4); line.Children.Add(action); }
        content.Children.Add(line); Grid.SetColumn(content, 1); row.Children.Add(content); return row;
    }
    private static void WithGlyph(Button button, string symbol, string title)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var glyph = new IconGlyph { Symbol = symbol, Width = 13, Height = 13, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
        glyph.SetBinding(IconGlyph.InkProperty, new System.Windows.Data.Binding(nameof(Control.Foreground)) { Source = button });
        var label = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center };
        label.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Control.Foreground)) { Source = button });
        // The shared button template renders text content; this content is the glyph and its label.
        content.Children.Add(glyph); content.Children.Add(label); button.ContentTemplate = null; button.Content = content;
    }
    /// The page's one invitation is the prominent button, as on the Mac pane.
    private void Prominent(Button button, string symbol)
    {
        button.Style = (Style)FindResource("SettingsProminentButton"); WithGlyph(button, symbol, AutomationProperties.GetName(button));
    }
    /// Copies, then says so for two seconds; a button with a symbol shows a check meanwhile, as on the Mac.
    private async Task Copy(Button button, string value, string idleKey, string? symbol = null)
    {
        void Show(string text, string? glyph)
        {
            if (glyph != null) WithGlyph(button, glyph, text); else button.Content = text;
            AutomationProperties.SetName(button, text);
        }
        try
        {
            copyLink(value); int revision = ++copyRevision;
            Show(ui.Text("support.share.copied"), symbol == null ? null : "checkmark");
            await Task.Delay(TimeSpan.FromSeconds(2));
            if (IsLoaded && revision == copyRevision) Show(ui.Text(idleKey), symbol);
        }
        catch (System.Runtime.InteropServices.COMException) { issue.Text = ui.Text("windows.pages.copy_failed"); }
    }
    internal Popup? SupportCodePopup => code;
    /// Collapses a text that has nothing to say.
    private sealed class EmptyCollapses : System.Windows.Data.IValueConverter
    {
        internal static readonly EmptyCollapses Instance = new();
        public object Convert(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => value is string { Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        public object ConvertBack(object value, Type targetType, object parameter, System.Globalization.CultureInfo culture) => throw new NotSupportedException();
    }
    private Popup? qqCode;
    internal Popup? QqCodePopup => qqCode;
}
