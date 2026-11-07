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
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace CodexPacer.Windows;

/// Pacer's main window, which grew out of Settings: a resizable window with the
/// Mac's sidebar and one centered column of cards per page, under Windows system window controls.
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
    private readonly Action openNotificationSettings;
    private readonly IslandWindow? surfaceWindow;
    private readonly ISystemAppearanceSource appearance;
    private readonly bool ownsAppearance;
    private readonly HighContrastScope semanticPaint;
    private readonly IDisplayTopologySource appearanceDisplays;
    private readonly bool ownsAppearanceDisplays;
    private readonly Func<Uri, bool>? guideLinkLauncher;
    private readonly Action<string>? guideCopyLink;
    private readonly Func<Uri, bool>? systemSettingsLauncher;
    private readonly Grid client = new() { Width = DefaultWidth, Height = DefaultHeight };
    private readonly StackPanel form = new() { Margin = new Thickness(32, 10, 32, 32), MaxWidth = ColumnWidth };
    private readonly TextBlock issue = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11, Visibility = Visibility.Collapsed, Margin = new Thickness(10, 0, 10, 10) };
    private readonly Button recoveryRestart = new() { Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(10, 0, 10, 10) };
    private readonly List<FrameworkElement> editors = [];
    private readonly Dictionary<string, RadioButton> navigation = new();
    private readonly TextBlock paneTitle, paneSubtitle;
    private readonly Grid headerColumn = new() { MaxWidth = ColumnWidth };
    private readonly StackPanel defaultHeader = new();
    private readonly ScrollViewer paneScroller;
    private string activePane = "general";
    /// The Help & Updates tab last chosen, kept while Pacer runs, as the Mac remembers it.
    private static string rememberedAboutTab = "whatsNew";
    private string aboutTab { get => rememberedAboutTab; set => rememberedAboutTab = value; }
    internal const double DefaultWidth = 980, DefaultHeight = 660, MinimumWidth = 860, MinimumHeight = 560, ColumnWidth = 640, SidebarWidth = 220;
    private CheckBox? login, hideProjects, appButtons, monitorSSH;
    private TextBlock? startupStatus;
    private Grid? startupRow;
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
        DeepSeekConnectionCoordinator? webConnection = null, ClaudeConnectionCoordinator? claudeConnection = null, Action? openNotificationSettings = null, IslandWindow? surfaceWindow = null, PreferencesStore? preferencesStore = null, IDisplayTopologySource? displayTopology = null, Func<Uri, bool>? guideLinkLauncher = null, Action<string>? guideCopyLink = null, ISystemAppearanceSource? appearanceSource = null, Func<Uri, bool>? systemSettingsLauncher = null, WindowsUpdateService? updater = null)
    {
        if (darkOverride != null && !demo) throw new ArgumentException("Theme fixtures require demo mode.");
        WindowRendering.Prepare(this);
        this.ui = ui; this.session = session; this.startup = startup; this.demo = demo; this.darkOverride = darkOverride;
        this.engine = engine;
        this.updater = updater;
        this.webConnection = webConnection;
        this.claudeConnection = claudeConnection;
        this.notifications = notifications;
        this.surfaceWindow = surfaceWindow;
        appearance = appearanceSource ?? surfaceWindow?.AppearanceSource ?? new SystemAppearanceSource(action => Dispatcher.BeginInvoke(action));
        ownsAppearance = appearanceSource == null && surfaceWindow == null; semanticPaint = new(this);
        DesktopAppearance.Apply(this, appearance.Current);
        appearanceDisplays = displayTopology ?? surfaceWindow?.DisplayTopology ?? new WindowsDisplayTopology(action => Dispatcher.BeginInvoke(action));
        ownsAppearanceDisplays = displayTopology == null && surfaceWindow == null;
        this.guideLinkLauncher = guideLinkLauncher;
        this.guideCopyLink = guideCopyLink;
        this.systemSettingsLauncher = systemSettingsLauncher;
        this.openNotificationSettings = openNotificationSettings ?? (() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:notifications") { UseShellExecute = true }));
        this.sourceReady = sourceReady ?? Task.CompletedTask;
        Title = ui.Text("menu.settings_title"); WindowStartupLocation = WindowStartupLocation.CenterScreen;
        // The first layout sizes the client exactly; then the window resizes freely down to the Mac's minimum.
        ResizeMode = ResizeMode.CanResize; SizeToContent = SizeToContent.WidthAndHeight;
        ContentRendered += (_, _) => ReleaseInitialSize();
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
        client.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(SidebarWidth) });
        client.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        client.ColumnDefinitions.Add(new ColumnDefinition());
        client.Children.Add(BuildSidebar());
        // Black 25%, as the Mac draws the seam beside its sidebar.
        var divider = new Border { Background = new SolidColorBrush(Color.FromArgb(64, 0, 0, 0)) };
        Grid.SetColumn(divider, 1); client.Children.Add(divider);
        var pane = new DockPanel(); Grid.SetColumn(pane, 2); client.Children.Add(pane);
        paneTitle = Label(ui.Text("settings.pane.general"), 22, FontWeights.Bold);
        AutomationProperties.SetHeadingLevel(paneTitle, AutomationHeadingLevel.Level1);
        paneSubtitle = Label("", 12.5); paneSubtitle.Margin = new Thickness(0, 3, 0, 0); paneSubtitle.TextWrapping = TextWrapping.Wrap;
        paneSubtitle.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); AutomationProperties.SetAutomationId(paneSubtitle, "settings.subtitle");
        defaultHeader.Children.Add(paneTitle); defaultHeader.Children.Add(paneSubtitle); headerColumn.Children.Add(defaultHeader);
        var paneHeader = new Border { Child = headerColumn, Padding = new Thickness(32, 22, 32, 12), BorderThickness = new Thickness(0, 0, 0, 1), BorderBrush = Brushes.Transparent };
        DockPanel.SetDock(paneHeader, Dock.Top); pane.Children.Add(paneHeader);
        InitializeStorageRecovery(pane, preferencesStore);
        paneScroller = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = form };
        // A hairline appears under the title once content scrolls beneath it, as under the Mac toolbar.
        paneScroller.ScrollChanged += (_, _) =>
        { if (paneScroller.VerticalOffset > 0) paneHeader.SetResourceReference(Border.BorderBrushProperty, "SettingsSeparator"); else paneHeader.BorderBrush = Brushes.Transparent; };
        Identify(paneScroller, "settings.content", ui.Text("common.settings"));
        pane.Children.Add(paneScroller); RebuildPane(session.Current.LastSettingsPane);
        RefreshValues(); RefreshTheme();
        ShellProjection.Changed += OnShellProjectionChanged;
        Loaded += (_, _) => OnShellProjectionChanged("");
        Closed += (_, _) => ShellProjection.Changed -= OnShellProjectionChanged;
        Activated += async (_, _) => { RefreshSystemState(); if (notifications != null) await notifications.RefreshAsync(); };
        Deactivated += (_, _) => RefreshTheme();
        appearance.Changed += OnAppearanceChanged;
        session.Changed += OnPreferencesChanged;
        if (notifications != null) notifications.Changed += OnNotificationsChanged;
        if (surfaceWindow != null) surfaceWindow.SurfaceChanged += RefreshSurfaceStatus;
        if (updater != null) updater.Changed += OnUpdateStatus;
        appearanceDisplays.Changed += OnAppearanceDisplaysChanged;
        if (engine != null) { engine.Snapshot += OnProviderSnapshot; engine.Status += OnProviderStatus; }
        Closing += (_, e) => { if (busy && !AllowClose) e.Cancel = true; };
        Closed += (_, _) =>
        {
            sourceClosed = true; inlineDownload?.Cancel(); IsEnabled = false; sourceInspectionRevision++; ClearProviderHome();
            appearance.Changed -= OnAppearanceChanged; semanticPaint.Dispose(); if (ownsAppearance) appearance.Dispose(); session.Changed -= OnPreferencesChanged;
            if (notifications != null) notifications.Changed -= OnNotificationsChanged;
            if (surfaceWindow != null) surfaceWindow.SurfaceChanged -= RefreshSurfaceStatus;
            if (updater != null) updater.Changed -= OnUpdateStatus;
            appearanceDisplays.Changed -= OnAppearanceDisplaysChanged;
            if (ownsAppearanceDisplays) appearanceDisplays.Dispose();
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
        var label = Label(text, 11.5); label.TextWrapping = TextWrapping.Wrap; label.Margin = new Thickness(0, 2, 0, 0);
        label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); return label;
    }
    private static void Identify(DependencyObject control, string id, string name)
    { AutomationProperties.SetAutomationId(control, id); AutomationProperties.SetName(control, name); }
    private Image AppIcon(double size)
        => new() { Width = size, Height = size, Source = BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))), Stretch = Stretch.Uniform };
    private void ReleaseInitialSize()
    {
        if (SizeToContent == SizeToContent.Manual) return;
        double chromeWidth = Math.Max(0, ActualWidth - client.ActualWidth), chromeHeight = Math.Max(0, ActualHeight - client.ActualHeight);
        MinWidth = MinimumWidth + chromeWidth; MinHeight = MinimumHeight + chromeHeight;
        double width = ActualWidth, height = ActualHeight;
        SizeToContent = SizeToContent.Manual; Width = width; Height = height;
        client.Width = client.Height = double.NaN;
    }
    private Border Card(params UIElement[] rows)
    {
        // 22 to whatever follows, as the Mac's page stack spaces its cards.
        var card = new Border { CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 0, 0, 22), BorderThickness = new Thickness(1) };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsCard"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        var content = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0)
            {
                // A hairline shows only between two visible rows, so a hidden row takes its line with it,
                // even when it is the first one.
                var line = new Border { Height = 1, Margin = new Thickness(14, 0, 14, 0) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
                var visible = new System.Windows.Data.MultiBinding { Converter = SeparatorVisibility.Instance };
                for (int j = 0; j <= i; j++) visible.Bindings.Add(new System.Windows.Data.Binding(nameof(Visibility)) { Source = rows[j] });
                line.SetBinding(VisibilityProperty, visible); content.Children.Add(line);
            }
            content.Children.Add(rows[i]);
        }
        card.Child = content; return card;
    }
    private Grid Row(UIElement label, UIElement trailing, double minHeight = 44)
    {
        var row = new Grid { MinHeight = minHeight, Margin = new Thickness(14, 0, 14, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (label is FrameworkElement left) left.Margin = new Thickness(0, 8, 8, 8);
        row.Children.Add(label); Grid.SetColumn(trailing, 1); row.Children.Add(trailing); return row;
    }
    /// A switch row; its explanation waits behind ⓘ, as on the Mac.
    private Grid Toggle(string key, string? infoKey, string id, out CheckBox check, string? title = null)
    {
        check = new CheckBox { Style = (Style)FindResource("SettingsSwitch"), HorizontalAlignment = HorizontalAlignment.Right };
        string name = title ?? ui.Text(key);
        Identify(check, id, name);
        return InfoRow(name, check, infoKey == null ? null : ui.Text(infoKey), id: id);
    }
    /// The installed version, where updates stand and its one action, then
    /// automatic checks, as on the Mac. Downloading and installing still run
    /// in the Windows update window.
    private void BuildUpdateCard()
    {
        var version = new Grid(); version.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); version.ColumnDefinitions.Add(new ColumnDefinition()); version.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = AppIcon(48); icon.Margin = new Thickness(0, 0, 14, 0); icon.VerticalAlignment = VerticalAlignment.Center; version.Children.Add(icon);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { FontSize = 18 };
        name.Inlines.Add(new System.Windows.Documents.Run("Codex Pacer") { FontWeight = FontWeights.Bold });
        var number = new System.Windows.Documents.Run("  " + (Version.Length > 0 ? Version : ui.Text("build.development"))); number.SetResourceReference(TextElement.ForegroundProperty, "SettingsSecondary"); name.Inlines.Add(number);
        AutomationProperties.SetName(name, "Codex Pacer " + Version); labels.Children.Add(name);
        updateStatus = Detail(""); updateStatus.FontSize = 12.5; updateStatus.Margin = new Thickness(0, 3, 0, 0); labels.Children.Add(updateStatus);
        // A failed update offers the download page, as on the Mac.
        updateDownloadPage = new Button { Content = ui.Text("main.update.download_page"), Style = (Style)FindResource("SettingsLink"), FontSize = 12.5, HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
        Identify(updateDownloadPage, "settings.update.download_page", ui.Text("main.update.download_page"));
        updateDownloadPage.Click += (_, _) => { if (!SettingsPagePolicy.OpenDownloadPage(guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); };
        labels.Children.Add(updateDownloadPage);
        Identify(updateStatus, "settings.update.status", ""); AutomationProperties.SetLiveSetting(updateStatus, AutomationLiveSetting.Polite);
        updateProgress = new ProgressBar { Style = (Style)FindResource("SettingsProgressBar"), Maximum = 1, MaxWidth = 240, Height = 4, Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
        Identify(updateProgress, "settings.update.progress", ui.Text("main.update.downloading")); labels.Children.Add(updateProgress);
        Grid.SetColumn(labels, 1); version.Children.Add(labels);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var update = new Button { Content = ui.Text("updates.check"), VerticalAlignment = VerticalAlignment.Center }; updateCheck = update;
        Identify(update, "settings.update.check", ui.Text("updates.check"));
        update.Click += async (_, _) => { if (updater != null) { inlineUpdateText = null; _ = await updater.CheckAsync(); } };
        updateInstall = new Button { Content = ui.Text("main.update.install"), Style = (Style)FindResource("SettingsProminentButton"), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        Identify(updateInstall, "settings.update.install", ui.Text("main.update.install"));
        updateInstall.Click += async (_, _) => await InstallInlineAsync();
        updateCancel = new Button { Content = ui.Text("common.cancel"), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        Identify(updateCancel, "settings.update.cancel", ui.Text("common.cancel")); updateCancel.Click += (_, _) => inlineDownload?.Cancel();
        updateNotesButton = new Button { Content = ui.Text("main.update.notes"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), Visibility = Visibility.Collapsed };
        Identify(updateNotesButton, "settings.update.notes", ui.Text("main.update.notes")); updateNotesButton.Click += ReadUpdateNotes;
        actions.Children.Add(updateNotesButton); actions.Children.Add(update); actions.Children.Add(updateInstall); actions.Children.Add(updateCancel);
        Grid.SetColumn(actions, 2); version.Children.Add(actions);
        var head = new Border { Child = version, Padding = new Thickness(14, 12, 14, 12) };
        var automatic = Toggle("updates.automatic", null, "settings.update.automatic", out var automaticSwitch); automaticUpdates = automaticSwitch;
        automaticSwitch.Checked += ChangeAutomaticUpdates; automaticSwitch.Unchecked += ChangeAutomaticUpdates;
        RefreshUpdates();
        form.Children.Add(Card(head, automatic));
    }
    /// Startup, language and privacy, as on the Mac. App buttons moved to
    /// Appearance and SSH to Remote; Windows has no Dock, so no icon choice.
    private void BuildGeneral()
    {
        var loginRow = Toggle("settings.open_at_login", "windows.settings.open_at_login_detail", "settings.startup", out var loginSwitch); login = loginSwitch;
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
        startupRow = Row(startupStatus, startupSettings);
        form.Children.Add(SectionTitle(ui.Text("main.section.startup"), 0)); form.Children.Add(Card(loginRow, startupRow));
        language = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 240, SelectedValuePath = "Tag" };
        foreach (var choice in new[] { ("system", ui.Text("windows.language.system")), ("en", "English"), ("zh-Hans", "简体中文") })
            language.Items.Add(new ComboBoxItem { Content = choice.Item2, Tag = choice.Item1 });
        Identify(language, "settings.language", ui.Text("language.label"));
        language.SelectionChanged += async (_, _) => { if (!synchronizing && language.SelectedValue is string value) await Change(p => p with { Language = value }); };
        editors.Add(language);
        // A row titled with the hint and the accent button, as on the Mac.
        var restartButton = new Button { Content = ui.Text("language.restart_now"), VerticalAlignment = VerticalAlignment.Center, Style = (Style)FindResource("SettingsProminentButton") };
        Identify(restartButton, "settings.restart", ui.Text("language.restart_now")); restartButton.Click += (_, _) => RestartRequested?.Invoke(); editors.Add(restartButton);
        restartHint = Label(ui.Text("language.restart_hint")); restartHint.TextWrapping = TextWrapping.Wrap;
        restart = new Border { Child = Row(restartHint, restartButton), Visibility = Visibility.Collapsed };
        form.Children.Add(SectionTitle(ui.Text("main.section.language"))); form.Children.Add(Card(Row(Label(ui.Text("language.label")), language), restart));
        var privacy = Toggle("settings.hide_projects", "settings.hide_projects_help", "settings.hide_projects", out var privacySwitch); hideProjects = privacySwitch;
        BindToggle(hideProjects, (p, value) => p with { HideProjects = value }); editors.Add(hideProjects);
        form.Children.Add(SectionTitle(ui.Text("main.privacy"))); form.Children.Add(Card(privacy));
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
            hideProjects = hideProjects?.IsChecked ?? session.Current.HideProjects, showAppButtons = appButtons?.IsChecked ?? session.Current.ShowAppButtons, languageChoice = language?.SelectedValue as string,
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
        RefreshUpdates();
        RefreshBanner();
        codexHistory?.SetInteractionEnabled(enabled);
        foreach (var item in navigation) item.Value.IsEnabled = enabled && PaneAvailable(item.Key);
        RefreshConnections();
    }
    private string appliedLook = "";
    private void OnPreferencesChanged(DesktopPreferences value)
    {
        string look = value.AppTheme + "/" + value.AccentColor;
        if (look != appliedLook) { appliedLook = look; PacerPalette.ApplyAccent(value.AccentColor); RefreshTheme(); overviewKey = historyKey = null; }
        if (!ReadOnlyGuidePane(activePane) && ResolvePane(value.LastSettingsPane) != activePane) RebuildPane(value.LastSettingsPane); RefreshValues();
    }
    private string ResolvePane(string value)
    {
        value = CanonicalPane(value);
        return value is "general" or "appearance" or "collapsed" or "about" or "support" || EnginePane(value) && engine != null ? value : "general";
    }
    /// Opens a page; What's New and Help open as tabs of Help & Updates.
    internal async System.Threading.Tasks.Task NavigateAsync(string pane)
    {
        string tab = pane is "help" or "whatsNew" ? pane : aboutTab;
        pane = CanonicalPane(pane);
        if (sourceClosed || ResolvePane(pane) != pane || PendingPane(pane)) return;
        bool switchesTab = pane == "about" && activePane == "about" && tab != aboutTab;
        aboutTab = tab;
        if (ReadOnlyGuidePane(pane)) RebuildPane(pane);
        else
        {
            bool wasReadOnly = ReadOnlyGuidePane(activePane); if (wasReadOnly || switchesTab) RebuildPane(pane);
            if (await Change(p => p with { LastSettingsPane = pane }) != PreferencesApplyResult.Applied && wasReadOnly) RebuildPane(session.Current.LastSettingsPane);
        }
    }
    private void RebuildPane(string value)
    {
        synchronizing = true;
        try
        {
            if (value is "help" or "whatsNew") aboutTab = value;
            activePane = ResolvePane(value);
            foreach (UIElement child in form.Children)
                if (child != issue && child != recoveryRestart) PageAccessibility.Retire(child);
            form.Children.Clear(); editors.Clear(); form.Children.Add(issue); form.Children.Add(recoveryRestart);
            login = hideProjects = appButtons = monitorSSH = null; startupStatus = null; startupRow = null;
            SetPaneHeader(defaultHeader); paneSubtitle.Text = ""; paneSubtitle.Visibility = Visibility.Collapsed;
            quotaRows.Clear(); ClearOverview(); form.MaxWidth = headerColumn.MaxWidth = ColumnWidth; language = null; restart = null; restartHint = null;
            automaticUpdates = null; updateCheck = updateNotesButton = updateInstall = updateCancel = updateDownloadPage = null; updateStatus = null; updateProgress = null;
            ClearAppearance();
            ClearCodex();
            ClearClaude();
            ClearProviderHome();
            ClearDeepSeek();
            ClearReminders();
            ClearCollapsed();
            ClearGuidePages();
            ClearConnections();
            paneTitle.Text = PaneTitle(activePane);
            AutomationProperties.SetName(paneScroller, paneTitle.Text);
            switch (activePane)
            {
                case "overview": BuildOverview(); break;
                case "history": BuildHistory(); break;
                case "about": BuildAbout(); break;
                case "support": BuildGuidePage("support"); break;
                case "appearance": BuildAppearance(); break;
                case "codex": BuildCodex(); break;
                case "claude": BuildClaude(); break;
                case "deepseek": BuildDeepSeek(); break;
                case "notifications": BuildReminders(); break;
                case "collapsed": BuildCollapsed(); break;
                case "remote": BuildConnections(); break;
                default: BuildGeneral(); break;
            }
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
                    if (startupRow != null) startupRow.Visibility = key == null ? Visibility.Collapsed : Visibility.Visible;
                    AutomationProperties.SetName(startupStatus, startupStatus.Text);
                }
            }
            if (hideProjects != null) hideProjects.IsChecked = session.Current.HideProjects;
            if (appButtons != null) appButtons.IsChecked = session.Current.ShowAppButtons;
            if (monitorSSH != null) monitorSSH.IsChecked = session.Current.MonitorSSH;
            RefreshUpdates();
            if (language != null) language.SelectedValue = session.Current.Language;
            string desired = session.Current.Language == "system" ? (CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh-Hans" : "en") : session.Current.Language;
            if (restart != null)
            {
                restart.Visibility = desired != ui.Language || session.RequiresRestart ? Visibility.Visible : Visibility.Collapsed;
                if (restartHint != null) restartHint.Text = ui.Text(session.RequiresRestart ? "windows.settings.recovery_required" : "language.restart_hint");
                if (session.RequiresRestart && restart.Child is Grid row) row.Children[1].IsEnabled = true;
            }
            RefreshAppearance();
            RefreshCodex();
            RefreshClaude();
            RefreshDeepSeek();
            RefreshProviderHome();
            RefreshReminders();
            RefreshCollapsed();
            RefreshConnections();
            RefreshSidebar();
            RefreshOverview();
            RefreshHistory();
            recoveryRestart.Visibility = session.RequiresRestart && activePane != "general" ? Visibility.Visible : Visibility.Collapsed;
            foreach (var item in navigation) item.Value.IsChecked = item.Key == activePane;
        }
        finally { synchronizing = false; }
    }
    internal void RefreshSystemState() { RefreshTheme(); RefreshValues(); }
    private void ShowIssue(string key) { issue.Text = ui.Text(key); AutomationProperties.SetName(issue, issue.Text); issue.Foreground = new SolidColorBrush(Color.FromRgb(204, 106, 32)); issue.Visibility = Visibility.Visible; AutomationProperties.SetLiveSetting(issue, AutomationLiveSetting.Assertive); }
    private void ClearIssue() { issue.Text = ""; issue.Visibility = Visibility.Collapsed; }
    private void OnAppearanceChanged() => Dispatcher.InvokeAsync(() => { if (!sourceClosed) RefreshTheme(); });
    private void RefreshTheme()
    {
        // The window theme overrides Windows' light or dark choice; the island stays dark.
        var system = appearance.Current; var state = system with { Dark = AccentPalette.Dark(session.Current.AppTheme, system.Dark) };
        DesktopAppearance.Apply(this, state);
        semanticPaint.Apply(state); bool dark = darkOverride ?? state.Dark;
        SettingsPalette.Apply(Resources, dark, IsActive, state, main: true, AccentPalette.Controls(session.Current.AccentColor, !demo));
        RefreshSurfaceStatus();
    }
    internal static bool IsSystemDark()
    {
        try { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"); return key?.GetValue("AppsUseLightTheme") is int value && value == 0; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return false; }
    }
}

/// Shows a card's hairline when its row (the last value) and any row above it are visible.
internal sealed class SeparatorVisibility : System.Windows.Data.IMultiValueConverter
{
    internal static readonly SeparatorVisibility Instance = new();
    public object Convert(object[] values, System.Type targetType, object parameter, System.Globalization.CultureInfo culture)
    {
        bool Visible(object value) => value is Visibility visibility && visibility == Visibility.Visible;
        return values.Length > 0 && Visible(values[^1]) && values.Take(values.Length - 1).Any(Visible) ? Visibility.Visible : Visibility.Collapsed;
    }
    public object[] ConvertBack(object value, System.Type[] targetTypes, object parameter, System.Globalization.CultureInfo culture) => throw new System.NotSupportedException();
}
