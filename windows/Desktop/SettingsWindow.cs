using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// The native settings content geometry, with Windows system window controls.
internal sealed partial class SettingsWindow : Window
{
    private readonly UiText ui;
    private readonly PreferencesSession session;
    private readonly IStartupRegistration startup;
    private readonly bool demo;
    private readonly bool? darkOverride;
    private readonly EngineClient? engine;
    private readonly Task sourceReady;
    private readonly DeepSeekConnectionCoordinator? webConnection;
    private readonly ClaudeConnectionCoordinator? claudeConnection;
    private readonly NotificationSession? notifications;
    private readonly Grid client = new() { Width = 780, Height = 600 };
    private readonly StackPanel form = new() { Margin = new Thickness(20, 20, 20, 16) };
    private readonly TextBlock issue = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11, Visibility = Visibility.Collapsed, Margin = new Thickness(10, 0, 10, 10) };
    private readonly Button recoveryRestart = new() { Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(10, 0, 10, 10) };
    private readonly List<FrameworkElement> editors = [];
    private readonly Dictionary<string, RadioButton> navigation = new();
    private readonly TextBlock paneTitle;
    private readonly ScrollViewer paneScroller;
    private string activePane = "general";
    private CheckBox? login, hideProjects, appButtons;
    private TextBlock? startupStatus;
    private ComboBox? language;
    private Border? restart;
    private TextBlock? restartHint;
    private bool synchronizing, busy, composing;
    private int pendingChanges;
    internal bool AllowClose { get; set; }
    internal event Action? QuitRequested;
    internal event Action? RestartRequested;
    internal FrameworkElement ClientContent => client;

    internal SettingsWindow(UiText ui, PreferencesSession session, IStartupRegistration startup, bool demo, bool? darkOverride = null, EngineClient? engine = null, Task? sourceReady = null, NotificationSession? notifications = null,
        DeepSeekConnectionCoordinator? webConnection = null, ClaudeConnectionCoordinator? claudeConnection = null)
    {
        if (darkOverride != null && !demo) throw new ArgumentException("Theme fixtures require demo mode.");
        WindowRendering.Prepare(this);
        this.ui = ui; this.session = session; this.startup = startup; this.demo = demo; this.darkOverride = darkOverride;
        this.engine = engine;
        this.webConnection = webConnection;
        this.claudeConnection = claudeConnection;
        this.notifications = notifications;
        this.sourceReady = sourceReady ?? Task.CompletedTask;
        Title = ui.Text("menu.settings_title"); WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.WidthAndHeight;
        FontFamily = PacerFonts.Interface;
        Language = PacerFonts.RenderingLanguage(ui);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        recoveryRestart.Content = ui.Text("language.restart_now"); Identify(recoveryRestart, "settings.recovery_restart", ui.Text("language.restart_now"));
        recoveryRestart.Click += (_, _) => RestartRequested?.Invoke();
        AutomationProperties.SetAutomationId(issue, "settings.issue");
        SetResourceReference(BackgroundProperty, "SettingsBackground");
        Content = client;
        client.SetResourceReference(Panel.BackgroundProperty, "SettingsBackground");
        client.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        client.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        client.ColumnDefinitions.Add(new ColumnDefinition());
        client.Children.Add(BuildSidebar());
        var divider = new Border(); divider.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
        Grid.SetColumn(divider, 1); client.Children.Add(divider);
        var pane = new DockPanel(); Grid.SetColumn(pane, 2); client.Children.Add(pane);
        paneTitle = Label(ui.Text("settings.pane.general"), 20, FontWeights.SemiBold); paneTitle.Margin = new Thickness(28, 20, 28, 0);
        DockPanel.SetDock(paneTitle, Dock.Top); pane.Children.Add(paneTitle);
        paneScroller = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = form };
        Identify(paneScroller, "settings.content", ui.Text("common.settings"));
        pane.Children.Add(paneScroller); RebuildPane(session.Current.LastSettingsPane);
        RefreshValues(); RefreshTheme();
        ShellProjection.Changed += OnShellProjectionChanged;
        Loaded += (_, _) => OnShellProjectionChanged("");
        Closed += (_, _) => ShellProjection.Changed -= OnShellProjectionChanged;
        Activated += async (_, _) => { RefreshSystemState(); if (notifications != null) await notifications.RefreshAsync(); };
        Deactivated += (_, _) => RefreshTheme();
        SystemEvents.UserPreferenceChanged += OnSystemPreferenceChanged;
        session.Changed += OnPreferencesChanged;
        if (notifications != null) notifications.Changed += OnNotificationsChanged;
        if (engine != null) { engine.Snapshot += OnProviderSnapshot; engine.Status += OnProviderStatus; }
        Closing += (_, e) => { if (busy && !AllowClose) e.Cancel = true; };
        Closed += (_, _) =>
        {
            sourceClosed = true; sourceInspectionRevision++; ClearProviderHome();
            SystemEvents.UserPreferenceChanged -= OnSystemPreferenceChanged; session.Changed -= OnPreferencesChanged;
            if (notifications != null) notifications.Changed -= OnNotificationsChanged;
            if (engine != null) { engine.Snapshot -= OnProviderSnapshot; engine.Status -= OnProviderStatus; }
        };
        // PreviewKeyDown yields to ComboBox's Escape handling while its menu is open.
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None && !composing && !editors.OfType<ComboBox>().Any(value => value.IsDropDownOpen))
            { Close(); e.Handled = true; }
        };
        TextCompositionManager.AddPreviewTextInputStartHandler(this, (_, _) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(this, (_, _) => composing = false);
    }

    private static string Version => typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3) ?? "";
    private TextBlock Label(string text, double size = 13, FontWeight? weight = null)
        => new() { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center };
    private TextBlock Detail(string text)
    {
        var label = Label(text, 11); label.TextWrapping = TextWrapping.Wrap; label.Margin = new Thickness(0, 2, 0, 0);
        label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); return label;
    }
    private static void Identify(DependencyObject control, string id, string name)
    { AutomationProperties.SetAutomationId(control, id); AutomationProperties.SetName(control, name); }
    private Image AppIcon(double size)
        => new() { Width = size, Height = size, Source = BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))), Stretch = Stretch.Uniform };
    private UIElement BuildSidebar()
    {
        var surface = new Border(); surface.SetResourceReference(Border.BackgroundProperty, "SettingsSidebar");
        var stack = new DockPanel { Margin = new Thickness(10, 0, 10, 0), LastChildFill = true }; surface.Child = stack;
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 16, 8, 16) };
        brand.Children.Add(AppIcon(32)); var names = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(Label("Codex Pacer", 13, FontWeights.SemiBold)); names.Children.Add(Detail(Version)); brand.Children.Add(names);
        DockPanel.SetDock(brand, Dock.Top); stack.Children.Add(brand);
        var bottom = new StackPanel(); DockPanel.SetDock(bottom, Dock.Bottom); stack.Children.Add(bottom);
        bottom.Children.Add(Navigation("whatsNew", "whats_new.window_title", "sparkle", Color.FromRgb(237, 74, 153)));
        bottom.Children.Add(Navigation("help", "settings.pane.help", "questionmark", Color.FromRgb(133, 133, 133)));
        bottom.Children.Add(Navigation("support", "settings.pane.support", "heart", Color.FromRgb(245, 92, 107)));
        var quit = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Height = 26, Margin = new Thickness(0, 0, 0, 10) };
        var quitLabel = new StackPanel { Orientation = Orientation.Horizontal };
        var power = new IconGlyph { Symbol = "power", Width = 14, Height = 14, Margin = new Thickness(0, 0, 8, 0) };
        power.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); quitLabel.Children.Add(power);
        var quitText = Label(ui.Text("common.quit"), 12); quitText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); quitLabel.Children.Add(quitText);
        quit.Content = quitLabel; Identify(quit, "settings.quit", ui.Text("common.quit")); quit.Click += (_, _) => QuitRequested?.Invoke(); bottom.Children.Add(quit);
        var top = new StackPanel(); stack.Children.Add(top);
        top.Children.Add(Navigation("general", "settings.pane.general", "gearshape", Color.FromRgb(133, 133, 133), enabled: true));
        top.Children.Add(Navigation("appearance", "settings.pane.appearance", "paintpalette", Color.FromRgb(112, 102, 245), enabled: true));
        top.Children.Add(Navigation("collapsed", "settings.pane.collapsed", "rectangle.topthird.inset.filled", Color.FromRgb(51, 56, 69), enabled: true));
        top.Children.Add(Navigation("reminders", "settings.reminders", "bell.badge", Color.FromRgb(255, 77, 74), enabled: engine != null));
        var modules = Detail(ui.Text("provider.modules")); modules.FontWeight = FontWeights.SemiBold; modules.Margin = new Thickness(8, 14, 8, 6); top.Children.Add(modules);
        top.Children.Add(Navigation("codex", null, "chevron.left.forwardslash.chevron.right", Color.FromRgb(102, 205, 187), "Codex", enabled: engine != null, darkGlyph: true));
        top.Children.Add(Navigation("claude", null, "asterisk", Color.FromRgb(255, 164, 119), "Claude", enabled: engine != null, darkGlyph: true));
        top.Children.Add(Navigation("deepseek", null, "water.waves", Color.FromRgb(126, 150, 255), "DeepSeek", enabled: engine != null, darkGlyph: true));
        top.Children.Add(Navigation("connections", "settings.pane.connections", "point.3.connected.trianglepath.dotted", Color.FromRgb(41, 128, 255)));
        return surface;
    }
    private RadioButton Navigation(string id, string? key, string symbol, Color color, string? literal = null, bool enabled = false, bool darkGlyph = false)
    {
        string name = literal ?? ui.Text(key!);
        var button = new RadioButton { Style = (Style)FindResource("SettingsSidebarChoice"), GroupName = "settings.panes", Margin = new Thickness(0, 0, 0, 2), IsEnabled = enabled };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        // Native sidebar tiles use a tinted gradient; this is limited to the tile, not a glass substitute.
        Color lighter = Color.FromRgb((byte)Math.Min(255, color.R + 10), (byte)Math.Min(255, color.G + 10), (byte)Math.Min(255, color.B + 10));
        var tile = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(5.72), Background = new LinearGradientBrush(lighter, color, 90), Margin = new Thickness(0, 0, 9, 0) };
        tile.Child = new IconGlyph { Symbol = symbol, Width = 16, Height = 16, Ink = darkGlyph ? new SolidColorBrush(Color.FromArgb(194, 0, 0, 0)) : Brushes.White }; row.Children.Add(tile);
        var label = Label(name); label.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = button }); row.Children.Add(label); button.Content = row;
        Identify(button, "settings.pane." + id, name);
        if (!enabled) { button.ToolTip = ui.Text("windows.settings.pane_pending"); ToolTipService.SetShowOnDisabled(button, true); }
        button.Checked += async (_, _) => { if (!synchronizing && button.IsChecked == true) await Change(p => p with { LastSettingsPane = id }); };
        navigation[id] = button; return button;
    }
    private Border Card(params UIElement[] rows)
    {
        var card = new Border { CornerRadius = new CornerRadius(13), Margin = new Thickness(0, 0, 0, 10) };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard");
        var content = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) { var line = new Border { Height = 1, Margin = new Thickness(10, 0, 10, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); content.Children.Add(line); }
            content.Children.Add(rows[i]);
        }
        card.Child = content; return card;
    }
    private Grid Row(UIElement label, UIElement trailing, double minHeight = 36)
    {
        var row = new Grid { MinHeight = minHeight, Margin = new Thickness(10, 0, 10, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (label is FrameworkElement left) left.Margin = new Thickness(0, 8, 8, 8);
        row.Children.Add(label); Grid.SetColumn(trailing, 1); row.Children.Add(trailing); return row;
    }
    private Grid Toggle(string key, string? detailKey, string id, out CheckBox check)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; text.Children.Add(Label(ui.Text(key)));
        if (detailKey != null) text.Children.Add(Detail(ui.Text(detailKey)));
        check = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), HorizontalAlignment = HorizontalAlignment.Right };
        Identify(check, id, ui.Text(key)); if (detailKey != null) AutomationProperties.SetHelpText(check, ui.Text(detailKey));
        return Row(text, check);
    }
    private void BuildGeneral()
    {
        var version = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        version.Children.Add(AppIcon(34)); var labels = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(Label("Codex Pacer " + Version)); labels.Children.Add(Detail(ui.Text(demo ? "updates.demo_disabled" : "windows.updates.pending"))); version.Children.Add(labels);
        var update = new Button { Content = ui.Text("updates.check"), IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
        Identify(update, "settings.update.check", ui.Text("updates.check"));
        var automatic = Toggle("updates.automatic", null, "settings.update.automatic", out var automaticSwitch); automaticSwitch.IsEnabled = false;
        automaticSwitch.ToolTip = ui.Text(demo ? "updates.demo_disabled" : "windows.updates.pending");
        form.Children.Add(Card(Row(version, update, 54), automatic));
        var loginRow = Toggle("settings.open_at_login", "windows.settings.open_at_login_detail", "settings.startup", out var loginSwitch); login = loginSwitch;
        loginRow.MinHeight = 52;
        RoutedEventHandler changeStartup = (_, _) =>
        {
            if (synchronizing) return;
            if (!startup.Set(login.IsChecked == true)) ShowIssue("windows.settings.startup_failed");
            else ClearIssue(); RefreshValues();
        };
        login.Checked += changeStartup; login.Unchecked += changeStartup;
        editors.Add(login);
        startupStatus = Detail(""); startupStatus.TextWrapping = TextWrapping.Wrap;
        Identify(startupStatus, "settings.startup.status", "");
        AutomationProperties.SetLiveSetting(startupStatus, AutomationLiveSetting.Polite);
        var startupSettings = new Button { Content = ui.Text("windows.settings.startup_settings"), VerticalAlignment = VerticalAlignment.Center };
        Identify(startupSettings, "settings.startup.settings", ui.Text("windows.settings.startup_settings"));
        startupSettings.Click += (_, _) => { if (!startup.OpenSettings()) ShowIssue("windows.settings.startup_settings_failed"); else ClearIssue(); };
        editors.Add(startupSettings);
        form.Children.Add(Card(loginRow, Row(startupStatus, startupSettings, 34)));
        language = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = 140, MaxWidth = 240, SelectedValuePath = "Tag" };
        foreach (var choice in new[] { ("system", ui.Text("windows.language.system")), ("en", "English"), ("zh-Hans", "简体中文") })
            language.Items.Add(new ComboBoxItem { Content = choice.Item2, Tag = choice.Item1 });
        Identify(language, "settings.language", ui.Text("language.label"));
        language.SelectionChanged += async (_, _) => { if (!synchronizing && language.SelectedValue is string value) await Change(p => p with { Language = value }); };
        editors.Add(language);
        var restartButton = new Button { Content = ui.Text("language.restart_now"), VerticalAlignment = VerticalAlignment.Center };
        Identify(restartButton, "settings.restart", ui.Text("language.restart_now")); restartButton.Click += (_, _) => RestartRequested?.Invoke(); editors.Add(restartButton);
        restartHint = Detail(ui.Text("language.restart_hint"));
        restart = new Border { Child = Row(restartHint, restartButton), Visibility = Visibility.Collapsed };
        form.Children.Add(Card(Row(Label(ui.Text("language.label")), language, 38), restart));
        // A collapsed optional row must not leave its separator visible.
        restart.IsVisibleChanged += (_, _) =>
        {
            if (restart.Parent is Panel rows && rows.Children.Count == 3) rows.Children[1].Visibility = restart.Visibility;
        };
        var privacy = Toggle("settings.hide_projects", "settings.hide_projects_help", "settings.hide_projects", out var privacySwitch); hideProjects = privacySwitch;
        BindToggle(hideProjects, (p, value) => p with { HideProjects = value }); editors.Add(hideProjects);
        var apps = Toggle("settings.app_buttons", "settings.app_buttons_help", "settings.app_buttons", out var appsSwitch); appButtons = appsSwitch;
        ((FrameworkElement)privacy.Children[0]).Margin = new Thickness(0, 11, 8, 11);
        ((FrameworkElement)apps.Children[0]).Margin = new Thickness(0, 11, 8, 11);
        BindToggle(appButtons, (p, value) => p with { ShowAppButtons = value }); editors.Add(appButtons);
        form.Children.Add(Card(privacy, apps));
    }
    private void BindToggle(CheckBox check, Func<DesktopPreferences, bool, DesktopPreferences> edit)
        => BindToggle(check, (value, enabled) => System.Threading.Tasks.Task.FromResult(edit(value, enabled)));
    private void BindToggle(CheckBox check, Func<DesktopPreferences, bool, System.Threading.Tasks.Task<DesktopPreferences>> edit)
    {
        RoutedEventHandler changed = async (_, _) =>
        {
            if (synchronizing) return;
            bool value = check.IsChecked == true;
            await Change(p => edit(p, value));
        };
        check.Checked += changed; check.Unchecked += changed;
    }

    internal void CapturePreview(string path)
    {
        if (!demo || busy) throw new InvalidOperationException("Only settled synthetic settings can be exported.");
        client.UpdateLayout();
        var dpi = VisualTreeHelper.GetDpi(this);
        void Save(double resolution, string target)
        {
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(client.ActualWidth * resolution / 96),
                (int)Math.Ceiling(client.ActualHeight * resolution / 96), resolution, resolution, PixelFormats.Pbgra32);
            bitmap.Render(client); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = File.Create(target); encoder.Save(output);
        }
        Save(96, path);
        string nativePath = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + "-native-dpi.png");
        Save(dpi.PixelsPerInchX, nativePath);
        _ = new Typeface(FontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal).TryGetGlyphTypeface(out var resolvedFont);
        File.WriteAllText(Path.ChangeExtension(path, ".json"), JsonSerializer.Serialize(new
        {
            schemaVersion = 1, syntheticOnly = true, acceptance = "pending", pane = activePane, language = ui.Language,
            dark = darkOverride ?? IsSystemDark(), active = IsActive, renderMode = WindowRendering.Mode(this), clientWidth = client.ActualWidth, clientHeight = client.ActualHeight,
            expandedQuotaStyle = session.Current.ExpandedQuotaStyle,
            deepseekMode = activePane == "deepseek" ? session.Current.DeepSeekMode : null,
            deepseekPanelStyle = activePane == "deepseek" ? session.Current.DeepSeekPanelStyle : null,
            deepseekBudgetPeriods = activePane == "deepseek" ? engine?.LatestSnapshot?.Wallet?.Solo?.Budgets.Select(value => value.Kind).ToArray() : null,
            renderDpi = 96, windowDpi = dpi.PixelsPerInchX, nativeDpiFile = Path.GetFileName(nativePath), version = Version,
            font = FontFamily.Source, fontFace = resolvedFont?.FontUri.AbsoluteUri, fontWeight = resolvedFont?.Weight.ToOpenTypeWeight(),
            sourceInspectionPending = activePane == "codex" ? !sourceInspection.IsCompleted : activePane is "claude" or "deepseek" && !homeInspection.IsCompleted,
            sourceState = activePane == "codex" ? cliState?.Text : activePane == "claude" ? claudeLocalState?.Text : activePane == "deepseek" ? deepseekLocalState?.Text : null,
            moduleDetected = activePane == "codex" ? engine?.LatestSnapshot?.Modules?.FirstOrDefault(value => value.Provider == "codex")?.Installed : null,
            historySamples = activePane == "codex" ? engine?.LatestSnapshot?.QuotaDashboard?.Providers.FirstOrDefault(value => value.Provider == "codex")?.History?.Chart?.Points.Count : null,
            historyChartWidth = activePane == "codex" ? codexHistory?.Chart?.ActualWidth : null,
            switchAnimationAcceptance = "pending", disabledPanes = navigation.Where(pair => !pair.Value.IsEnabled).Select(pair => pair.Key).ToArray()
        }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private System.Threading.Tasks.Task<PreferencesApplyResult> Change(Func<DesktopPreferences, DesktopPreferences> edit)
        => Change(value => System.Threading.Tasks.Task.FromResult(edit(value)));
    private async System.Threading.Tasks.Task<PreferencesApplyResult> Change(Func<DesktopPreferences, System.Threading.Tasks.Task<DesktopPreferences>> edit)
    {
        pendingChanges++; busy = true; SetEditors(false); ClearIssue();
        try
        {
            PreferencesApplyResult result = await session.ChangeAsync(edit);
            if (result != PreferencesApplyResult.Applied) ShowIssue(result switch
            {
                PreferencesApplyResult.EngineFailed => "windows.settings.apply_failed",
                PreferencesApplyResult.RecoveryRequired => "windows.settings.recovery_required",
                _ => "windows.settings.save_failed"
            });
            return result;
        }
        finally { busy = --pendingChanges > 0; SetEditors(!busy && !session.RequiresRestart); RefreshValues(); }
    }
    private void SetEditors(bool enabled)
    {
        foreach (var editor in editors) editor.IsEnabled = enabled;
        codexHistory?.SetInteractionEnabled(enabled);
        foreach (var item in navigation) item.Value.IsEnabled = enabled && (item.Key is "general" or "appearance" or "collapsed" || (item.Key is "codex" or "claude" or "deepseek" or "reminders") && engine != null);
    }
    private void OnPreferencesChanged(DesktopPreferences value)
    { if (ResolvePane(value.LastSettingsPane) != activePane) RebuildPane(value.LastSettingsPane); RefreshValues(); }
    private string ResolvePane(string value) => value is "appearance" or "collapsed" || (value is "codex" or "claude" or "deepseek" or "reminders") && engine != null ? value : "general";
    internal async System.Threading.Tasks.Task NavigateAsync(string pane)
    { if (!sourceClosed && ResolvePane(pane) == pane) await Change(p => p with { LastSettingsPane = pane }); }
    private void RebuildPane(string value)
    {
        synchronizing = true;
        try
        {
            activePane = ResolvePane(value);
            form.Children.Clear(); editors.Clear(); form.Children.Add(issue); form.Children.Add(recoveryRestart);
            login = hideProjects = appButtons = null; startupStatus = null; language = null; restart = null; restartHint = null;
            ClearAppearance();
            ClearCodex();
            ClearClaude();
            ClearProviderHome();
            ClearDeepSeek();
            ClearReminders();
            ClearCollapsed();
            paneTitle.Text = activePane == "codex" ? "Codex" : activePane == "claude" ? "Claude" : activePane == "deepseek" ? "DeepSeek" : ui.Text(activePane == "reminders" ? "settings.reminders" : "settings.pane." + activePane);
            if (activePane == "general") BuildGeneral(); else if (activePane == "appearance") BuildAppearance(); else if (activePane == "codex") BuildCodex(); else if (activePane == "claude") BuildClaude(); else if (activePane == "reminders") BuildReminders(); else if (activePane == "collapsed") BuildCollapsed(); else BuildDeepSeek();
            foreach (var item in navigation) item.Value.IsChecked = item.Key == activePane;
            paneScroller.ScrollToTop(); SetEditors(!busy && !session.RequiresRestart);
        }
        finally { synchronizing = false; }
    }
    private void RefreshValues()
    {
        synchronizing = true;
        try
        {
            if (login != null)
            {
                var state = startup.Read(); login.IsChecked = state.Registered; login.IsEnabled = !busy && !session.RequiresRestart && state.Available;
                string? key = state.BlockReason switch
                {
                    StartupBlockReason.Disabled => "windows.settings.startup_disabled",
                    StartupBlockReason.Policy => "windows.settings.startup_policy",
                    StartupBlockReason.Unknown => "windows.settings.startup_unknown",
                    StartupBlockReason.OtherInstallation => "windows.settings.startup_other",
                    _ => null
                };
                if (startupStatus != null)
                {
                    startupStatus.Text = key == null ? "" : ui.Text(key);
                    AutomationProperties.SetName(startupStatus, startupStatus.Text);
                }
            }
            if (hideProjects != null) hideProjects.IsChecked = session.Current.HideProjects;
            if (appButtons != null) appButtons.IsChecked = session.Current.ShowAppButtons;
            if (language != null) language.SelectedValue = session.Current.Language;
            string desired = session.Current.Language == "system" ? (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh-Hans" : "en") : session.Current.Language;
            if (restart != null)
            {
                restart.Visibility = desired != ui.Language || session.RequiresRestart ? Visibility.Visible : Visibility.Collapsed;
                if (restartHint != null) restartHint.Text = ui.Text(session.RequiresRestart ? "windows.settings.recovery_required" : "language.restart_hint");
                if (session.RequiresRestart && restart.Child is Grid row) row.Children[1].IsEnabled = true;
                if (restart.Parent is Panel rows && rows.Children.Count == 3) rows.Children[1].Visibility = restart.Visibility;
            }
            RefreshAppearance();
            RefreshCodex();
            RefreshClaude();
            RefreshDeepSeek();
            RefreshProviderHome();
            RefreshReminders();
            RefreshCollapsed();
            recoveryRestart.Visibility = session.RequiresRestart && activePane != "general" ? Visibility.Visible : Visibility.Collapsed;
            foreach (var item in navigation) item.Value.IsChecked = item.Key == activePane;
        }
        finally { synchronizing = false; }
    }
    internal void RefreshSystemState() { RefreshTheme(); RefreshValues(); }
    private void ShowIssue(string key) { issue.Text = ui.Text(key); AutomationProperties.SetName(issue, issue.Text); issue.Foreground = new SolidColorBrush(Color.FromRgb(204, 106, 32)); issue.Visibility = Visibility.Visible; AutomationProperties.SetLiveSetting(issue, AutomationLiveSetting.Assertive); }
    private void ClearIssue() { issue.Text = ""; issue.Visibility = Visibility.Collapsed; }
    private void OnSystemPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatcher.InvokeAsync(RefreshTheme);
    private void RefreshTheme()
    {
        bool dark = darkOverride ?? IsSystemDark(); SettingsPalette.Apply(Resources, dark, IsActive);
    }
    internal static bool IsSystemDark()
    {
        try { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"); return key?.GetValue("AppsUseLightTheme") is int value && value == 0; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return false; }
    }
}
