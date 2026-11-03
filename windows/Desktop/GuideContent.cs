using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
    private Border Card(params UIElement[] rows)
    {
        var group = new StackPanel(); foreach (var row in rows) group.Children.Add(row);
        var card = new Border { Child = group, CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 0, 0, 10) };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); return card;
    }
    private Grid Row(string title, string? detail, UIElement? control = null, string? id = null)
    {
        var row = new Grid { Margin = new Thickness(0, 4, 0, 4), MinHeight = 30 };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labels = new StackPanel { Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(Text(title)); if (!string.IsNullOrEmpty(detail)) labels.Children.Add(Text(detail, 11)); row.Children.Add(labels);
        if (control != null) { Grid.SetColumn(control, 1); row.Children.Add(control); }
        if (id != null) Identify(row, id, title); return row;
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
            _ => new(2, null, new Dictionary<string, int> { ["codex"] = 1, ["claude"] = 1 }, null, null, null, false, "2")
        }, false); return badge;
    }
    private static Border Swatch(params UIElement[] samples)
    {
        var marks = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var sample in samples) { if (sample is FrameworkElement item) item.Margin = new Thickness(5, 2, 5, 2); marks.Children.Add(sample); }
        return new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(9), Padding = new Thickness(5), Child = marks, VerticalAlignment = VerticalAlignment.Center };
    }
    private static CompactQuotaGlyph Rings(string provider = "codex")
    {
        var rings = new CompactQuotaGlyph { Width = 20, Height = 20 };
        rings.Update(new(1, "", [], [], [], [], [], [], [], [], [new(provider, provider == "claude" ? 81 : 58, false)], [], false, false, 0, 1), null); return rings;
    }
    private static WarningMark Warning(string kind, bool solid = false) => new(new(kind == "lowBalance" ? "balance" : "fiveHour", kind == "lowBalance" ? "deepseek" : "codex", solid,
        kind == "lowBalance" ? null : solid ? "0" : "12", kind == "lowBalance" ? "exclamationmark.circle" : null, ""));
    internal void WelcomeStep(int step)
    {
        Reset(); Heading(step == 0 ? "welcome.step.island" : "welcome.step.start");
        if (step == 0)
        {
            var rate = Text("42 t/s", 13); rate.Foreground = PacerPalette.Primary;
            var bar = Swatch(Badge(0), rate, Rings(), Warning("codex5hLow")); bar.HorizontalAlignment = HorizontalAlignment.Center; bar.Margin = new Thickness(0, 8, 0, 6);
            Identify(bar, "welcome.bar", ui.Text("welcome.step.island")); Children.Add(bar);
            var labels = new UniformGrid { Columns = 4, Margin = new Thickness(0, 4, 0, 12) };
            foreach (var part in new[] { ("task", ui.Text("welcome.part.task_detail")), ("rate", ui.Text("welcome.part.rate_detail")), ("quota", "Codex · Claude"), ("warning", ui.Text("welcome.part.warning_detail")) })
            { var label = new StackPanel { Margin = new Thickness(4) }; label.Children.Add(Text(ui.Text("welcome.part." + part.Item1), 12, true)); label.Children.Add(Text(part.Item2, 11)); labels.Children.Add(label); }
            Children.Add(labels);
            var legends = new Grid(); legends.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3, GridUnitType.Star) }); legends.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
            var badges = new StackPanel { Margin = new Thickness(0, 0, 10, 0) }; badges.Children.Add(Text(ui.Text("welcome.badges"), 12, true));
            badges.Children.Add(Card(Row(ui.Text("welcome.badge.running"), null, Swatch(Badge(0))), Row(ui.Text("welcome.badge.waiting"), null, Swatch(Badge(1))),
                Row(ui.Text("welcome.badge.ended"), ui.Text("welcome.badge.ended_hint"), Swatch(Badge(2))))); legends.Children.Add(badges);
            var gestures = new StackPanel(); gestures.Children.Add(Text(ui.Text("welcome.gestures"), 12, true));
            gestures.Children.Add(Card(Row(ui.Text("welcome.gesture.hover"), ui.Text("welcome.gesture.expand")), Row(ui.Text("welcome.gesture.leave"), ui.Text("welcome.gesture.collapse"))));
            Grid.SetColumn(gestures, 1); legends.Children.Add(gestures); Children.Add(legends);
        }
        else
        {
            var modules = new UniformGrid { Columns = 3 };
            foreach (string provider in new[] { "codex", "claude", "deepseek" }) modules.Children.Add(Module(provider)); Children.Add(modules);
            Children.Add(Text(ui.Text("welcome.modules_note"), 11)); Heading("welcome.section.personalize");
            var notification = Switch(ui.Text("settings.system_notifications"), "welcome.notifications", () => notifications?.DesiredEnabled == true,
                async value => notifications != null && await notifications.SetEnabledAsync(value) == NotificationChangeResult.Applied);
            refresh.Add(() => notification.IsEnabled = !changing && !session.RequiresRestart && notifications != null);
            var state = Text("", 11); Identify(state, "welcome.system.status", "");
            refresh.Add(() => state.Text = notifications?.Availability == NotificationAvailability.Denied
                ? ui.Text("settings.notification_denied") : StartupDetail());
            Children.Add(Card(Row(ui.Text("welcome.layout.title"), ui.Text("welcome.layout.detail"), Button(ui.Text("welcome.go"), "welcome.collapsed", () => settings("collapsed"))),
                Row(ui.Text("settings.system_notifications"), ui.Text("welcome.notifications_detail"), notification),
                Row(ui.Text("settings.open_at_login"), ui.Text("windows.settings.open_at_login_detail"), Login(ui.Text("settings.open_at_login"), "welcome.startup")), state));
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
        var stack = new StackPanel { Margin = new Thickness(4, 0, 4, 0) };
        string name = provider == "codex" ? "Codex" : provider == "claude" ? "Claude" : "DeepSeek";
        var title = Text(name, 13, true); title.Foreground = PacerPalette.Provider(provider); stack.Children.Add(title);
        var toggle = Switch(name, "welcome.module." + provider, () => session.Current.ProviderModes[provider] switch
        { "enabled" => true, "disabled" => false, _ => snapshot()?.Modules?.FirstOrDefault(value => value.Provider == provider)?.Enabled == true },
            value => Preference(p => p with { ProviderModes = new(p.ProviderModes) { [provider] = value ? "enabled" : "disabled" } }));
        toggle.HorizontalAlignment = HorizontalAlignment.Left; toggle.Margin = new Thickness(0, 8, 0, 8); stack.Children.Add(toggle);
        var status = Text("", 11); status.MinHeight = 42; Identify(status, "welcome.module." + provider + ".status", name); stack.Children.Add(status);
        var action = Button(ui.Text("welcome.module.settings"), "welcome.module." + provider + ".action", () => settings(provider)); stack.Children.Add(action);
        refresh.Add(() =>
        {
            var latest = snapshot(); var module = latest?.Modules?.FirstOrDefault(value => value.Provider == provider);
            bool enabled = toggle.IsChecked == true; string? titleKey = null;
            string text = catalog.ModuleOff[provider];
            if (enabled)
            {
                if (module?.Installed == false) { text = ui.Text("welcome.module." + provider + "_missing"); titleKey = "welcome.module.settings"; }
                else if (module == null || module.Installed == null) text = ui.Text("claude.account.checking");
                else if (provider == "claude" && latest?.ClaudeConnection?.State == "checking" || provider == "deepseek" && latest?.DeepseekConnection?.Refreshing == true && latest.Wallet?.Balance == null)
                    text = ui.Text("claude.account.checking");
                else if (provider == "claude" && latest?.ClaudeConnection is { State: not "signedIn" } claude)
                { text = ui.Text(claude.State == "workspaceNeeded" ? "claude.account.workspace_needed" : "welcome.module.sign_in_detail"); titleKey = claude.State == "workspaceNeeded" ? "claude.quota.choose_workspace" : "welcome.module.sign_in"; }
                else if (provider == "deepseek" && latest?.Wallet?.Balance == null)
                { bool key = latest?.DeepseekConnection?.Mode == "apiKey"; text = ui.Text(key ? "welcome.module.balance_detail" : "welcome.module.balance_sign_in_detail"); titleKey = key ? "deepseek.paste_key_short" : "welcome.module.sign_in"; }
                else text = ui.Text("welcome.module.ready") + (session.Current.ProviderModes[provider] == "automatic" ? " · " + ui.Text("welcome.module.automatic") : "");
            }
            status.Text = text; AutomationProperties.SetName(status, text); action.Visibility = titleKey == null ? Visibility.Collapsed : Visibility.Visible;
            if (titleKey != null) { action.Content = ui.Text(titleKey); AutomationProperties.SetName(action, ui.Text(titleKey)); }
        });
        return Card(stack);
    }
    internal void Releases(IEnumerable<GuideRelease> releases)
    {
        Reset();
        foreach (var release in releases)
        {
            Children.Add(Text(release.Title, 13, true));
            foreach (var item in release.Items)
            {
                UIElement? control = item.Control switch
                {
                    "openAtLogin" => Login(item.Title, "guide.control.openAtLogin"),
                    "showAppButtons" => Switch(item.Title, "guide.control.showAppButtons", () => session.Current.ShowAppButtons, value => Preference(p => p with { ShowAppButtons = value })),
                    "showEmbeddedSessions" => PendingEmbeddedControl(item.Title),
                    _ => null
                };
                string detail = item.Control == "openAtLogin" ? ui.Text("windows.settings.open_at_login_detail") : item.Detail;
                Children.Add(Card(Row(item.Title, detail, control)));
            }
        }
        Refresh();
    }
    private CheckBox PendingEmbeddedControl(string title)
    {
        var check = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), IsChecked = session.Current.ShowEmbeddedCodexSessions,
            IsEnabled = false, ToolTip = ui.Text("windows.claude.embedded_pending") };
        Identify(check, "guide.control.showEmbeddedSessions", title); AutomationProperties.SetHelpText(check, ui.Text("windows.claude.embedded_pending"));
        ToolTipService.SetShowOnDisabled(check, true); return check;
    }
    internal void Help()
    {
        Reset(); Heading("help.section.services"); Legend("help.enable", Swatch(Badge(0))); Legend("help.services", Swatch(Rings("codex"), Rings("claude"), Rings("deepseek")));
        Heading("help.section.collapsed"); Legend("help.tasks", Swatch(Badge(0))); Legend("help.attention", Swatch(Badge(1))); Legend("help.endings", Swatch(Badge(2)));
        Legend("help.quota", Swatch(Rings("codex"), Rings("claude"))); Legend("help.warnings", Swatch(Warning("codex5hLow"), Warning("lowBalance"))); Legend("help.customize", Swatch(new IconGlyph { Symbol = "slider.horizontal.3", Width = 20, Height = 20 }));
        Heading("help.section.expanded"); foreach (string key in new[] { "hover", "open", "app_buttons", "read", "pace" }) Legend("help." + key, Swatch(Badge(0)));
        Heading("help.section.modules");
        var tabs = new StackPanel { Orientation = Orientation.Horizontal }; var details = new StackPanel();
        foreach (string provider in new[] { "codex", "claude", "deepseek" })
        {
            var tab = new RadioButton { Content = provider == "codex" ? "Codex" : provider == "claude" ? "Claude" : "DeepSeek", GroupName = "help.providers", Margin = new Thickness(6) };
            Identify(tab, "help.module." + provider, tab.Content.ToString()!); tab.Checked += (_, _) => ModuleHelp(details, provider); tabs.Children.Add(tab);
        }
        Children.Add(tabs); Children.Add(details);
        string initial = SettingsPagePolicy.InitialHelpProvider(NativeCompactBar.Providers(session.Current, snapshot()));
        ((RadioButton)tabs.Children[Array.IndexOf(new[] { "codex", "claude", "deepseek" }, initial)]).IsChecked = true;
        Heading("help.section.more"); Children.Add(Button(ui.Text("help.show_welcome"), "help.welcome", welcome)); Children.Add(Link("help.link.guide", "manual")); Children.Add(Link("help.link.issues", "issues"));
    }
    private void Legend(string key, UIElement sample, Panel? parent = null)
    {
        var row = Row(ui.Text(key + ".title"), ui.Text(key + ".detail"), sample, key);
        (parent ?? this).Children.Add(Card(row));
    }
    private void ModuleHelp(Panel target, string provider)
    {
        target.Children.Clear();
        string[] keys = provider == "codex" ? ["quota", "windows", "remote", "apps"] : provider == "claude" ? ["quota", "windows", "cloud", "remote", "apps"] : ["balance", "mode", "cost", "peak", "clock", "alerts", "speed"];
        foreach (string key in keys)
        {
            UIElement sample = key is "windows" or "alerts" ? Swatch(Warning("codex5hLow"), Warning("codex5hExhausted", true)) : Swatch(Rings(provider));
            if (provider == "deepseek") sample = DeepSeekSample(key);
            Legend("help." + provider + "." + key, sample, target);
        }
    }
    private UIElement DeepSeekSample(string key)
    {
        var value = Text(key == "balance" ? "¥86" : key == "cost" ? "≈¥0.42" : "×2", 12, true); value.Foreground = key == "peak" ? PacerPalette.Attention : PacerPalette.DeepSeek;
        if (key == "mode") return Swatch(new IconGlyph { Symbol = "clock", Width = 20, Height = 20, Ink = PacerPalette.DeepSeek }, new IconGlyph { Symbol = "chart.pie", Width = 20, Height = 20, Ink = PacerPalette.DeepSeek });
        if (key == "alerts") return Swatch(Warning("lowBalance"), new WarningMark(new("spendSpike", "deepseek", true, null, "flame.fill", "")), new WarningMark(new("budget", "deepseek", false, "!", null, "")));
        if (key == "speed") return Swatch(new DeepSeekSpeedPlot(new("", new[] { .2, .45, .7, .35, .8 }, .6, "42 t/s", false, "", "")) { Width = 80, Height = 22 });
        if (key == "clock")
        {
            var clock = new DeepSeekPriceClock { Width = 28, Height = 28 };
            clock.Update(new("connected", 86.4, "86", ".40", "", null, Enumerable.Range(0, 24).Select(hour => hour is 9 or 10 or 14 or 15 ? .8 : 0).ToArray(),
                new[] { new WalletSpan(135, 180), new WalletSpan(210, 270) }, 236, true, 3.9, 0, null, null)); return Swatch(clock);
        }
        return Swatch(value);
    }
    internal void Support()
    {
        Reset(); Children.Add(Card(Row(ui.Text("support.thanks.title"), ui.Text("support.thanks.detail"))));
        Children.Add(Card(Row(ui.Text("support.star.title"), ui.Text("support.star.detail")), Link("support.star.action", "star"), Link("support.star.feature", "feature"), Link("support.star.bug", "bug")));
        Button? copy = null; copy = Button(ui.Text("support.share.copy"), "support.copy", () => _ = Copy(copy!));
        var send = Button(ui.Text("support.share.action"), "support.share", () =>
        {
            var window = Window.GetWindow(this);
            if (window == null || !(share ??= new()).Show(new WindowInteropHelper(window).Handle, catalog, ui)) issue.Text = ui.Text("windows.support.share_unavailable");
        });
        var actions = new StackPanel { Orientation = Orientation.Horizontal }; send.Margin = new Thickness(0, 3, 8, 3); actions.Children.Add(send); actions.Children.Add(copy);
        Children.Add(Card(Row(ui.Text("support.share.title"), ui.Text("support.share.detail")), actions));
        var coffee = Card(Row(ui.Text("support.coffee.title"), ui.Text("support.coffee.detail")), Link("support.coffee.title", "donate")); Children.Add(coffee);
        string? file = catalog.SupportCode;
        if (file != null && file == Path.GetFileName(file))
        {
            string imageFile = Path.Combine(AppContext.BaseDirectory, "CodexPacerPortable_PacerCore.resources", file);
            if (File.Exists(imageFile))
            {
                var button = Button(ui.Text("support.code.wechat"), "support.wechat", () => { if (code != null) code.IsOpen = !code.IsOpen; });
                var content = new StackPanel { Margin = new Thickness(12) };
                content.Children.Add(new Image { Source = BitmapFrame.Create(new Uri(imageFile)), Width = 220, Height = 220, Stretch = Stretch.Uniform });
                var hint = Text(ui.Text("support.code.wechat_hint"), 12); hint.Foreground = Brushes.Black; content.Children.Add(hint);
                var close = Button(ui.Text("whats_new.done"), "support.wechat.close", () => { if (code != null) code.IsOpen = false; button.Focus(); }); content.Children.Add(close);
                code = new Popup { PlacementTarget = button, Placement = PlacementMode.Bottom, StaysOpen = false,
                    Child = new Border { Background = Brushes.White, BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = content } };
                content.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { code.IsOpen = false; button.Focus(); args.Handled = true; } };
                code.Opened += (_, _) => close.Focus(); ((StackPanel)coffee.Child).Children.Add(button);
            }
        }
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
