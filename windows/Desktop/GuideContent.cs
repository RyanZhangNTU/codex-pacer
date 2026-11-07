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
        Loaded += (_, _) => { session.Changed += PreferencesChanged; if (engine != null) engine.Snapshot += SnapshotChanged; if (notifications != null) notifications.Changed += Refresh; Refresh(); };
        Unloaded += (_, _) => { copyRevision++; session.Changed -= PreferencesChanged; if (engine != null) engine.Snapshot -= SnapshotChanged; if (notifications != null) notifications.Changed -= Refresh; if (code != null) code.IsOpen = false; share?.Dispose(); share = null; };
        PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape && code?.IsOpen == true) { code.IsOpen = false; args.Handled = true; } };
    }
    private void PreferencesChanged(DesktopPreferences _) => Refresh();
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
        share?.Dispose(); share = null;
        foreach (UIElement child in Children) if (child != issue) PageAccessibility.Retire(child);
        Children.Clear(); refresh.Clear(); editors.Clear(); Children.Add(issue); issue.Text = "";
    }
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
            if (i > 0) { var line = new Border { Height = 1, Margin = new Thickness(inset, 0, 0, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); content.Children.Add(line); }
            content.Children.Add(rows[i]);
        }
        var group = new Border { Child = content, CornerRadius = new CornerRadius(10) };
        group.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); return group;
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
        return new Border { Width = 84, Height = 32, Background = Brushes.Black, CornerRadius = new CornerRadius(9), Child = marks, VerticalAlignment = VerticalAlignment.Center, ClipToBounds = true };
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
        Add(new Border { Width = 20, Height = 8, CornerRadius = new CornerRadius(4), Background = PacerPalette.Ink(255, 255, 255, 64),
            BorderBrush = PacerPalette.Ink(255, 255, 255, 140), BorderThickness = new Thickness(1) }, 0, 5);
        Add(new System.Windows.Shapes.Path { Data = Geometry.Parse("M 0 4 L 18 4 M 14 0 L 18 4 L 14 8"), Stroke = Brushes.White, StrokeThickness = 1.4 }, 25, 5);
        Add(new Border { Width = 3, Height = 18, CornerRadius = new CornerRadius(1.5), Background = PacerPalette.Codex }, 50, 0);
        return sample;
    }
    /// A quota bar with the white reference tick.
    private static Grid PaceSample()
    {
        var bar = new Grid { Width = 48, Height = 10 };
        bar.Children.Add(new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = PacerPalette.Ink(255, 255, 255, 46) });
        bar.Children.Add(new Border { Width = 28, Height = 4, CornerRadius = new CornerRadius(2), Background = PacerPalette.Codex, HorizontalAlignment = HorizontalAlignment.Left });
        bar.Children.Add(new Border { Width = 2, Height = 10, CornerRadius = new CornerRadius(1), Background = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(21, 0, 0, 0) });
        return bar;
    }
    private static CompactQuotaGlyph Rings(params (string Provider, double Remaining)[] values)
    {
        var rings = new CompactQuotaGlyph { Width = 20, Height = 20 };
        rings.Update(new(1, "", [], [], [], [], [], [], [], [], values.Select(value => new CompactRing(value.Provider, value.Remaining, false)).ToArray(), [], false, false, 0, 1), null); return rings;
    }
    /// Badges sit on a bar-colored swatch, as they appear on the island.
    private Grid BadgeRow(int state, string title, string? hint = null, Brush? tint = null)
    {
        var row = new Grid { Height = 38, Margin = new Thickness(12, 0, 12, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
        var badge = Badge(state); badge.HorizontalAlignment = HorizontalAlignment.Center; badge.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(new Border { Width = 30, Height = 26, CornerRadius = new CornerRadius(7), Background = Brushes.Black, Child = badge, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center });
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
    internal void WelcomeStep(int step)
    {
        Reset(); Heading(step == 0 ? "welcome.step.island" : "welcome.step.start");
        if (step == 0)
        {
            var map = new WelcomeIslandMap(ui, Badge, Rings(("codex", 58), ("claude", 81)), Warning("codex5hLow"));
            Identify(map, "welcome.bar", ui.Text("welcome.step.island")); Children.Add(map);
            var legends = new Grid { Margin = new Thickness(0, 14, 0, 0) };
            legends.ColumnDefinitions.Add(new ColumnDefinition()); legends.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) }); legends.ColumnDefinitions.Add(new ColumnDefinition());
            legends.Children.Add(Column("welcome.badges", Group(52, BadgeRow(0, ui.Text("welcome.badge.running")),
                BadgeRow(1, ui.Text("welcome.badge.waiting"), tint: PacerPalette.Attention), BadgeRow(2, ui.Text("welcome.badge.ended"), ui.Text("welcome.badge.ended_hint")))));
            var gestures = Column("welcome.gestures", Gestures()); Grid.SetColumn(gestures, 2); legends.Children.Add(gestures); Children.Add(legends);
        }
        else
        {
            var modules = new Grid();
            string[] providers = ["codex", "claude", "deepseek"];
            for (int i = 0; i < providers.Length; i++)
            {
                if (i > 0) modules.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
                modules.ColumnDefinitions.Add(new ColumnDefinition());
                var card = Module(providers[i]); Grid.SetColumn(card, i * 2); modules.Children.Add(card);
            }
            Children.Add(modules);
            var note = Text(ui.Text("welcome.modules_note"), 11); note.Margin = new Thickness(10, 8, 10, 0); Children.Add(note);
            Heading("welcome.section.personalize");
            var notification = Switch(ui.Text("settings.system_notifications"), "welcome.notifications", () => notifications?.DesiredEnabled == true,
                async value => notifications != null && await notifications.SetEnabledAsync(value) == NotificationChangeResult.Applied);
            refresh.Add(() => notification.IsEnabled = !changing && !session.RequiresRestart && notifications != null);
            var notificationDetail = Text("", 11);
            refresh.Add(() =>
            {
                bool denied = notifications?.Availability == NotificationAvailability.Denied;
                notificationDetail.Text = ui.Text(denied ? "windows.settings.notification_denied" : "welcome.notifications_detail");
                notificationDetail.SetResourceReference(TextBlock.ForegroundProperty, denied ? "SettingsWarning" : "SettingsSecondary");
            });
            var loginDetail = Text("", 11); Identify(loginDetail, "welcome.system.status", "");
            refresh.Add(() =>
            {
                string blocked = StartupDetail();
                loginDetail.Text = blocked.Length > 0 ? blocked : ui.Text("windows.settings.open_at_login_detail"); AutomationProperties.SetName(loginDetail, loginDetail.Text);
                loginDetail.SetResourceReference(TextBlock.ForegroundProperty, blocked.Length > 0 ? "SettingsWarning" : "SettingsSecondary");
            });
            var layout = Button(ui.Text("welcome.go"), "welcome.collapsed", () => settings("collapsed"));
            Children.Add(Group(50,
                TileRow(GuideArt.Tile("rectangle.topthird.inset.filled", Color.FromRgb(51, 56, 69), 26), ui.Text("welcome.layout.title"), Text(ui.Text("welcome.layout.detail"), 11), layout),
                TileRow(GuideArt.Tile("bell.badge", Color.FromRgb(255, 77, 74), 26), ui.Text("settings.system_notifications"), notificationDetail, notification),
                TileRow(GuideArt.Tile("gearshape", Color.FromRgb(133, 133, 133), 26), ui.Text("settings.open_at_login"), loginDetail, Login(ui.Text("settings.open_at_login"), "welcome.startup"))));
        }
        Refresh();
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
        var tile = GuideArt.Tile(GuideArt.ProviderSymbol(provider), GuideArt.ProviderTile(provider), 34, darkGlyph: true); tile.HorizontalAlignment = HorizontalAlignment.Left; top.Children.Add(tile);
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
                UIElement? control = item.Control switch
                {
                    "openAtLogin" => Login(item.Title, "guide.control.openAtLogin"),
                    "showAppButtons" => Switch(item.Title, "guide.control.showAppButtons", () => session.Current.ShowAppButtons, value => Preference(p => p with { ShowAppButtons = value })),
                    "showEmbeddedSessions" => EmbeddedControl(item.Title, item.Detail),
                    _ => null
                };
                string detail = item.Control == "openAtLogin" ? ui.Text("windows.settings.open_at_login_detail") : item.Detail;
                if (large) { Children.Add(FeatureRow(item.Symbol, item.Title, detail, control)); continue; }
                rows.Add(TileRow(FeatureSymbol(item.Symbol, 28), item.Title, Text(detail, 11.5), control));
            }
            if (!large) Children.Add(Group(50, rows.ToArray()));
        }
        Refresh();
    }
    private Grid FeatureRow(string symbol, string title, string detail, UIElement? control)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = FeatureSymbol(symbol, 40); tile.Margin = new Thickness(0, 0, 14, 0); tile.VerticalAlignment = VerticalAlignment.Top; row.Children.Add(tile);
        var labels = new StackPanel { Margin = new Thickness(0, 1, 8, 0) };
        labels.Children.Add(Text(title, 13.5, true));
        var text = Text(detail, 12.5); text.Margin = new Thickness(0, 3, 0, 0); text.LineHeight = 18; text.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); labels.Children.Add(text);
        Grid.SetColumn(labels, 1); row.Children.Add(labels);
        if (control is FrameworkElement end) { end.Margin = new Thickness(0, 9, 0, 0); end.VerticalAlignment = VerticalAlignment.Top; Grid.SetColumn(end, 2); row.Children.Add(end); }
        return row;
    }
    private CheckBox EmbeddedControl(string title, string detail)
    {
        var check = Switch(title, "guide.control.showEmbeddedSessions", () => GuideControls.ShowsEmbedded(session.Current),
            value => Preference(p => GuideControls.SetEmbedded(p, value)));
        AutomationProperties.SetHelpText(check, detail); return check;
    }
    internal void Help()
    {
        Reset(); string[] providers = ["codex", "claude", "deepseek"];
        HelpSection("help.section.services", HelpRow("help.enable", Mark("switch.2")),
            HelpRow("help.services", providers.Select(provider => (UIElement)GuideArt.Tile(GuideArt.ProviderSymbol(provider), GuideArt.ProviderTile(provider), 18, true)).ToArray()));
        HelpSection("help.section.collapsed",
            HelpRow("help.tasks", Tasks(1, "codex"), Tasks(2, "codex", "claude"), Tasks(3, providers)),
            HelpRow("help.attention", Badge(1)),
            HelpRow("help.endings", Badge(2), Badge(3)),
            HelpRow("help.quota", Rings(("codex", 58), ("claude", 81)), Figure("58%", PacerPalette.Codex)),
            HelpRow("help.warnings", Warning("codex5hLow"), Warning("lowBalance"), Mark("clock.arrow.circlepath", PacerPalette.Attention, 11)),
            HelpRow("help.customize", Mark("slider.horizontal.3")),
            HelpRow("help.move", MoveSample()));
        HelpSection("help.section.expanded",
            HelpRow("help.hover", Mark("cursorarrow.rays")), HelpRow("help.open", Mark("arrow.up.forward.app")),
            HelpRow("help.app_buttons", providers.Select(provider => (UIElement)Mark(GuideArt.ProviderSymbol(provider), PacerPalette.Provider(provider), 12)).ToArray()),
            HelpRow("help.read", Mark("checkmark.rectangle.stack")), HelpRow("help.pace", PaceSample()));
        // One segmented choice heads the chosen module's rows; its template paints the label with the theme text color.
        var tabs = new Grid(); var details = new StackPanel();
        foreach (string provider in providers)
        {
            string name = provider == "codex" ? "Codex" : provider == "claude" ? "Claude" : "DeepSeek";
            var tab = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), Content = name, GroupName = "help.providers" };
            tabs.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(tab, tabs.Children.Count);
            Identify(tab, "help.module." + provider, name); tab.Checked += (_, _) => ModuleHelp(details, provider); tabs.Children.Add(tab);
        }
        var segments = new Border { Child = tabs, Padding = new Thickness(2), CornerRadius = new CornerRadius(7), Margin = new Thickness(12, 10, 12, 10) };
        segments.SetResourceReference(Border.BackgroundProperty, "SettingsButton");
        HelpSection("help.section.modules", segments, details);
        string initial = SettingsPagePolicy.InitialHelpProvider(NativeCompactBar.Providers(session.Current, snapshot()));
        ((RadioButton)tabs.Children[Array.IndexOf(providers, initial)]).IsChecked = true;
        Heading("help.section.more");
        Children.Add(Group(12, HelpLink(Button(ui.Text("help.show_welcome"), "help.welcome", welcome), "hand.wave"),
            HelpLink(Link("help.link.guide", "manual"), "book"), HelpLink(Link("help.link.issues", "issues"), "exclamationmark.bubble")));
    }
    private void HelpSection(string key, params UIElement[] rows) { Heading(key); Children.Add(Group(HelpInset, rows)); }
    /// Separators start under the text, past the 84-point swatch.
    private const double HelpInset = 110;
    /// The real marks on a bar-colored swatch, then what they mean.
    private Grid HelpRow(string key, params UIElement[] samples)
    {
        string title = ui.Text(key + ".title");
        var row = new Grid { Margin = new Thickness(12, 8, 12, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
        var swatch = Swatch(samples); swatch.Margin = new Thickness(0, 0, 14, 0); row.Children.Add(swatch);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(Text(title)); var detail = Text(ui.Text(key + ".detail"), 11); detail.Margin = new Thickness(0, 2, 0, 0); labels.Children.Add(detail);
        Grid.SetColumn(labels, 1); row.Children.Add(labels); Identify(row, key, title); return row;
    }
    private Button HelpLink(Button button, string symbol)
    {
        button.Style = (Style)FindResource("SettingsLink"); button.HorizontalAlignment = HorizontalAlignment.Left; button.Margin = new Thickness(12, 6, 12, 6);
        WithGlyph(button, GuideArt.Symbol(symbol), AutomationProperties.GetName(button)); return button;
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
            if (target.Children.Count > 0) { var line = new Border { Height = 1, Margin = new Thickness(HelpInset, 0, 0, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); target.Children.Add(line); }
            target.Children.Add(HelpRow("help." + provider + "." + key, samples));
        }
    }
    private static UIElement[] DeepSeekSample(string key)
    {
        switch (key)
        {
            case "balance": return [GuideArt.Tile(GuideArt.ProviderSymbol("deepseek"), GuideArt.ProviderTile("deepseek"), 18, true), Figure("¥86", PacerPalette.DeepSeek)];
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
            Source = BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) });
        var thanksText = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        thanksText.Children.Add(Text(ui.Text("support.thanks.title"), 17, true)); var thanksDetail = Text(ui.Text("support.thanks.detail"), 12.5); thanksDetail.Margin = new Thickness(0, 5, 0, 0); thanksDetail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); thanksText.Children.Add(thanksDetail);
        thanks.Children.Add(thanksText); Identify(thanks, "support.thanks", ui.Text("support.thanks.title"));
        var wash = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        wash.GradientStops.Add(new GradientStop(Color.FromArgb(41, 102, 205, 187), 0)); wash.GradientStops.Add(new GradientStop(Color.FromArgb(31, 255, 164, 119), .5)); wash.GradientStops.Add(new GradientStop(Color.FromArgb(41, 126, 150, 255), 1));
        var hero = new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 12), Child = new Border { CornerRadius = new CornerRadius(13), Background = wash, Child = thanks } };
        hero.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); hero.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        Children.Add(hero);
        var star = Link("support.star.action", "star"); Prominent(star, "star.fill");
        Button? copy = null; copy = Button(ui.Text("support.share.copy"), "support.copy", () => _ = Copy(copy!));
        var send = Button(ui.Text("support.share.action"), "support.share", () =>
        {
            var window = Window.GetWindow(this);
            if (window == null || !(share ??= new()).Show(new WindowInteropHelper(window).Handle, catalog, ui)) issue.Text = ui.Text("windows.support.share_unavailable");
        });
        var donate = Link("support.coffee.title", "donate"); WithGlyph(donate, "cup.and.saucer", ui.Text("support.coffee.title"));
        var coffeeActions = new List<Button> { donate };
        string? file = catalog.SupportCode;
        if (file != null && file == Path.GetFileName(file))
        {
            string imageFile = Path.Combine(AppContext.BaseDirectory, "CodexPacerPortable_PacerCore.resources", file);
            if (File.Exists(imageFile))
            {
                var button = Button(ui.Text("support.code.wechat"), "support.wechat", () => { if (code != null) code.IsOpen = !code.IsOpen; });
                WithGlyph(button, "qrcode", ui.Text("support.code.wechat")); coffeeActions.Insert(0, button);
                var content = new StackPanel { Margin = new Thickness(12) };
                content.Children.Add(new Image { Source = BitmapFrame.Create(new Uri(imageFile)), Width = 220, Height = 220, Stretch = Stretch.Uniform });
                var hint = Text(ui.Text("support.code.wechat_hint"), 12); hint.Foreground = Brushes.Black; content.Children.Add(hint);
                var close = Button(ui.Text("whats_new.done"), "support.wechat.close", () => { if (code != null) code.IsOpen = false; button.Focus(); }); content.Children.Add(close);
                code = new Popup { PlacementTarget = button, Placement = PlacementMode.Bottom, StaysOpen = false,
                    Child = new Border { Background = Brushes.White, BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = content } };
                content.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { code.IsOpen = false; button.Focus(); args.Handled = true; } };
                WindowRendering.Prepare(code); code.Opened += (_, _) => close.Focus();
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
        Children.Add(Group(0, FeedbackRow(Link("support.star.feature", "feature"), "lightbulb", Color.FromRgb(250, 194, 51)),
            FeedbackRow(Link("support.star.bug", "bug"), "ladybug", Color.FromRgb(240, 92, 84))));
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
        foreach (var action in actions) { action.Margin = new Thickness(0, 6, 0, 0); action.HorizontalAlignment = HorizontalAlignment.Stretch; action.MinHeight = 28; buttons.Children.Add(action); }
        layout.Children.Add(buttons);
        var card = new Border { CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1), Padding = new Thickness(14), Child = layout };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        AutomationProperties.SetName(card, ui.Text(key + ".title")); return card;
    }
    /// A feedback form opened in the browser: tile, title and a chevron.
    private Grid FeedbackRow(Button link, string symbol, Color tint)
    {
        var row = new Grid { Margin = new Thickness(12, 8, 12, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition());
        var tile = GuideArt.Tile(symbol, tint, 22); tile.Margin = new Thickness(0, 0, 10, 0); tile.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(tile);
        link.HorizontalAlignment = HorizontalAlignment.Left; link.VerticalAlignment = VerticalAlignment.Center; link.Style = (Style)FindResource("SettingsLink");
        Grid.SetColumn(link, 1); row.Children.Add(link); return row;
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
    private async Task Copy(Button button)
    {
        try
        {
            copyLink(catalog.Links["repository"]); int revision = ++copyRevision;
            button.Content = ui.Text("support.share.copied"); AutomationProperties.SetName(button, button.Content.ToString());
            await Task.Delay(TimeSpan.FromSeconds(2));
            if (IsLoaded && revision == copyRevision) { button.Content = ui.Text("support.share.copy"); AutomationProperties.SetName(button, button.Content.ToString()); }
        }
        catch (System.Runtime.InteropServices.COMException) { issue.Text = ui.Text("windows.pages.copy_failed"); }
    }
    internal Popup? SupportCodePopup => code;
}
