using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace CodexPacer.Windows;

public partial class IslandWindow : Window
{
    private readonly EngineClient engine;
    private readonly bool chinese, demo;
    private readonly UiText ui;
    private int position;
    private int displayMode;
    private string expandedQuotaStyle = "split";
    private string deepseekPanelStyle = "detailed";
    private readonly WindowsDesktopApplications? desktopApplications;
    private readonly Func<EngineNavigationPlan, EngineTaskRow, Task<bool>> openConversation;
    private readonly HashSet<string> openingActivityContexts = [];
    private readonly Func<bool>? canConnectDeepSeekWeb;
    private bool showAppButtons = true;
    private bool harnessAvailable;
    private string appButtonsSignature = "";
    private string appAvailabilitySignature = "";
    private double nextAppAvailabilityScan;
    private readonly bool? animationOverride;
    private bool AnimationsEnabled => animationOverride ?? appearance.Current.Animations;
    private readonly DispatcherTimer collapse = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private bool navigationErrorShown;
    private string? navigationFailureID;
    private readonly Queue<string> interactionTrace = new();
    private NativeMotion motion;
    private readonly NativeLayout geometry;
    private readonly Func<(MotionBounds Screen, MotionBounds WorkArea)>? screenGeometry;
    private bool pinned, expanded, rendering, presentationStopped;
    private bool updateInputSuspended;
    internal void SetUpdateInputSuspended(bool value)
    {
        updateInputSuspended = value;
        if (value) { CancelMove(); collapse.Stop(); MoreButton.ContextMenu.IsOpen = false; SetPinned(false); SetExpanded(false); }
        IsHitTestVisible = !value;
    }
    private bool renderCallback;
    private int motionRevision;
    private double transitionStarted, measuredRowsWidth;
    private int renderedFrames;
    private double lastRenderedAt;
    private double worstRenderMilliseconds, totalRenderMilliseconds, worstFrameIntervalMilliseconds;
    private double boundsMilliseconds, visualsMilliseconds, layoutMilliseconds;
    private MotionFrame lastFrame;
    internal string PresentationDiagnostics => $"rendering={rendering}, frames={renderedFrames}, sinceLast={Clock() - lastRenderedAt:0.000}, sinceStart={Clock() - transitionStarted:0.000}, renderMeanMs={totalRenderMilliseconds / Math.Max(1, renderedFrames):0.00}, renderWorstMs={worstRenderMilliseconds:0.00}, frameWorstIntervalMs={worstFrameIntervalMilliseconds:0.00}, boundsTotalMs={boundsMilliseconds:0.00}, visualsTotalMs={visualsMilliseconds:0.00}, layoutTotalMs={layoutMilliseconds:0.00}, renderTier={RenderCapability.Tier >> 16}, target={destination}, expanded={expanded}, requested={Width}x{Height}, actual={ActualWidth}x{ActualHeight}, shell={Shell.ActualWidth}x{Shell.ActualHeight}, callback={renderCallback}, last={lastFrame}, interactions=[{string.Join("; ", interactionTrace)}]";
    private EngineSnapshot? latest;
    private IslandLayout layout;
    private MotionBounds destination;
    private MotionBounds surfaceBounds;
    private (bool OpensUp, double Y)? expansionAnchor;
    private bool destinationExpanded;
    private int page;
    private RevealHost? currentPage;
    private readonly List<AnimationLease> pageClocks = [];
    private Point? pointerDown;
    private IReadOnlyList<EngineTaskRow> rows = [];
    internal bool AllowClose { get; set; }
    internal event Action? QuitRequested;
    internal event Action? SettingsRequested;
    internal event Action<string>? ProviderSettingsRequested;
    internal event Action<string>? DeepSeekWebSignInRequested;
    internal event Action<MotionFrame>? FrameApplied;

    internal IslandWindow(EngineClient engine, bool demo, bool chinese, int position = 0, bool? animationOverride = null, WindowsDesktopApplications? desktopApplications = null, int displayMode = 0, Func<bool>? canConnectDeepSeekWeb = null,
        Func<EngineNavigationPlan, EngineTaskRow, Task<bool>>? openConversation = null,
        Func<(MotionBounds Screen, MotionBounds WorkArea)>? screenGeometry = null,
        Func<IBackdropSystemSource>? backdropSystemFactory = null, Func<Window, ICompositionBackdrop>? backdropFactory = null,
        Func<IDisplayTopologySource>? displayTopologyFactory = null, ISystemAppearanceSource? appearanceSource = null,
        DisplayPresence? presence = null)
    {
        InitializeComponent();
        Icon = BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"), UriKind.Absolute));
        this.engine = engine; this.chinese = chinese; this.demo = demo; this.position = position;
        if (displayMode is < 0 or > 2) throw new ArgumentOutOfRangeException(nameof(displayMode));
        this.displayMode = displayMode;
        this.desktopApplications = desktopApplications;
        this.canConnectDeepSeekWeb = canConnectDeepSeekWeb;
        this.openConversation = openConversation ?? OpenConversationAsync;
        this.screenGeometry = screenGeometry;
        this.backdropSystemFactory = backdropSystemFactory; this.backdropFactory = backdropFactory;
        ui = UiText.For(chinese);
        Language = PacerFonts.RenderingLanguage(ui);
        if (animationOverride != null && !demo) throw new ArgumentException("Synthetic motion overrides require demo mode.");
        this.animationOverride = animationOverride;
        InitializeAppearance(appearanceSource);
        InitializePresence(presence);
        string directory = Path.Combine(AppContext.BaseDirectory, "Engine");
        geometry = new NativeLayout(directory);
        displays = displayTopologyFactory?.Invoke() ?? new WindowsDisplayTopology(action => Dispatcher.BeginInvoke(action, DispatcherPriority.ContextIdle));
        displays.Changed += DisplayTopologyChanged;
        layout = MeasureLayout(404, 402, 160, false);
        destination = layout.Target;
        surfaceBounds = destination;
        Left = destination.X; Top = destination.Y; Width = destination.Width; Height = destination.Height;
        Shell.Width = destination.Width; Shell.Height = destination.Height;
        motion = new NativeMotion(directory, destination, position: layout.MotionAnchor);
        DemoTag.Visibility = demo ? Visibility.Visible : Visibility.Collapsed;
        TasksTitle.Text = ui.Text("layout.group.tasks"); QuotaTitle.Text = ui.Text("layout.group.quota_balance"); DemoLabel.Text = ui.Text("demo.label");
        SetButtonName(MarkReadButton, ui.Text("activity.mark_all_read")); SetButtonName(PinButton, ui.Text("common.pin")); SetButtonName(MoreButton, ui.Text("common.more"));
        SetButtonName(PreviousPage, ui.Text("activity.previous_page")); SetButtonName(NextPage, ui.Text("activity.next_page"));
        SetButtonName(SettingsButton, ui.Text("common.settings"));
        AutomationProperties.SetName(ExpandedScroll, ui.Text("activity.task_list"));
        RefreshMenu.Header = ui.Text("common.refresh"); QuitMenu.Header = ui.Text("common.quit"); SettingsMenu.Header = ui.Text("common.settings");
        InitializeMove();
        // Hover and connection errors can expand the HWND before the first
        // engine snapshot. Give every measured lane a real initial value.
        InitializeCompactBar(); PaceBadges();
        TasksCount.Text = "0"; MarkReadButton.IsEnabled = false;
        // Closing under the pointer can still raise a leave that starts the timer.
        collapse.Tick += (_, _) => { collapse.Stop(); if (!presentationStopped && !pinned) SetExpanded(false); };
        // The open menu holds the pointer, so leaving the island meanwhile raised no leave event.
        MoreButton.ContextMenu.Closed += (_, _) => Dispatcher.BeginInvoke(() =>
        { if (!presentationStopped && move == null && IsVisible && !pinned && expanded && !IsMouseOver) collapse.Start(); }, DispatcherPriority.Input);
        engine.Snapshot += QueueSnapshot;
        engine.Status += value => Dispatcher.InvokeAsync(() => SetStatus(ui.Text(value == "engineStopped" ? "windows.connection.closed" : "windows.connection.refresh_failed")));
        ShellProjection.Changed += OnShellProjectionChanged;
        Loaded += (_, _) => OnShellProjectionChanged("");
        Closing += OnClosing;
        Closed += (_, _) => StopPresentation();
        IsVisibleChanged += (_, _) =>
        {
            Shell.IsEnabled = IsVisible;
            MoreButton.ContextMenu.IsEnabled = IsVisible;
            if (!IsVisible) MoreButton.ContextMenu.IsOpen = false;
            if (presentationStopped) return;
            if (!IsVisible) { CancelMove(); StopRendering(); FinishPageTransition(); UpdateCompactBar(); decoration?.Conceal(); }
            else { UpdateCompactBar(); StartRendering(); if (lastFrame.Window.Width > 0) UpdateDecoration(lastFrame); }
            RefreshRowMotion();
            SyncBackdrop();
        };
        ApplyPresentationLayout();
        InitializeBackdrop(); WindowRendering.KeepUnminimized(this);
        InitializeOcclusion();
        Loaded += (_, _) => QueueDisplayRefresh();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new IslandWindowAutomationPeer(this);
    internal Rect VisibleScreenBounds
        => IsVisible ? PresentationScreenBounds : Rect.Empty;
    private Rect PresentationScreenBounds
    {
        get
        {
            if (PresentationSource.FromVisual(this) == null) return Rect.Empty;
            var point = Shell.PointToScreen(new Point()); var dpi = VisualTreeHelper.GetDpi(this);
            return new(point.X, point.Y, Shell.ActualWidth * dpi.DpiScaleX, Shell.ActualHeight * dpi.DpiScaleY);
        }
    }
    internal double VisibleWidth => Shell.ActualWidth;
    internal double VisibleHeight => Shell.ActualHeight;
    // Only the first toolbar row shows hover tooltips; the rest of the island
    // keeps its descriptions for screen readers alone.
    private static void SetButtonName(Button button, string title, bool tooltip = true)
    { button.ToolTip = tooltip ? title : null; AutomationProperties.SetName(button, title); }
    private void OnShellProjectionChanged(string method)
    {
        if (method.Length > 0 && method != "projectCompactBar") return;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (presentationStopped || !UpdateCompactBar(projectionOnly: true)) return;
            // A new value can redraw inside the same footprint without measuring the panel again.
            var size = MeasureCompactBar();
            if (laidOutCompactSize != size) Relayout(compactSize: size);
        });
    }
    internal void SetStatus(string value)
    {
        if (presentationStopped) return;
        navigationErrorShown = false;
        StatusLabel.Text = value; StatusLabel.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
        Reveal(); Relayout();
    }
    private void ShowNavigationError(string value)
    {
        if (presentationStopped) return;
        _ = ReportNavigationFailureAsync(value);
    }
    private async Task ReportNavigationFailureAsync(string value, string? context = null)
    {
        try { await engine.SendAsync(context == null ? "showNavigationError" : "failActivityOpen", new { context, navigationMessage = value }); }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        { if (!presentationStopped && (context == null || latest?.ActivityLinks?.Any(link => link.Context == context) == true)) SetStatus(value); }
    }
    private void ApplyNavigationFailure(EngineNavigationFailure? failure)
    {
        if (failure == null) { navigationFailureID = null; ClearNavigationError(); return; }
        if (navigationFailureID == failure.Id) return;
        navigationFailureID = failure.Id; navigationErrorShown = true;
        StatusLabel.Text = failure.Message; StatusLabel.Visibility = Visibility.Visible;
        SetExpanded(true);
    }
    private void ClearNavigationError()
    {
        if (!navigationErrorShown || presentationStopped) return;
        navigationErrorShown = false; StatusLabel.Text = ""; StatusLabel.Visibility = Visibility.Collapsed; Relayout();
    }
    internal void CapturePreview(string path)
    {
        if (!demo) throw new InvalidOperationException("Only synthetic demo views can be exported.");
        if (rendering || renderCallback || !lastFrame.Finished) throw new InvalidOperationException("Wait for the actual window to settle before exporting it.");
        UpdateLayout();
        var visual = (FrameworkElement)Content;
        var viewport = new Rect(ShellOffset.X, ShellOffset.Y, Shell.ActualWidth, Shell.ActualHeight);
        var dpi = VisualTreeHelper.GetDpi(this);
        RenderTargetBitmap Bitmap(double resolution)
        {
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(viewport.Width * resolution / 96),
                (int)Math.Ceiling(viewport.Height * resolution / 96), resolution, resolution, PixelFormats.Pbgra32);
            var drawing = new DrawingVisual();
            using (var context = drawing.RenderOpen())
            {
                var brush = new VisualBrush(visual) { ViewboxUnits = BrushMappingMode.Absolute, Viewbox = viewport,
                    ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, viewport.Width, viewport.Height), Stretch = Stretch.Fill };
                context.DrawRectangle(brush, null, new Rect(0, 0, viewport.Width, viewport.Height));
            }
            bitmap.Render(drawing); return bitmap;
        }
        void Save(RenderTargetBitmap bitmap, string target)
        {
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = File.Create(target); encoder.Save(output);
        }
        // Export logical points for comparison, plus the actual window DPI.
        // A logical export does not claim a real 100% display-setting check.
        var image = Bitmap(96); Save(image, path);
        string nativePath = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + "-native-dpi.png");
        Save(Bitmap(dpi.PixelsPerInchX), nativePath);
        _ = new Typeface(QuotaLabel.FontFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal).TryGetGlyphTypeface(out var resolvedFont);
        File.WriteAllText(Path.ChangeExtension(path, ".json"), JsonSerializer.Serialize(new
        {
            schemaVersion = 1, syntheticOnly = true, acceptance = "pending", fixtureClock = latest?.CapturedAt,
            expandedQuotaStyle,
            deepseekPanelStyle,
            enabledProviders = latest?.QuotaDashboard?.Providers.Select(value => value.Provider).ToArray(),
            quotaLayout = expandedQuotaStyle == "classic" ? latest?.QuotaDashboard?.Classic.Kind : latest?.QuotaDashboard?.Split.Kind,
            language = chinese ? "zh-Hans" : "en", appearance = islandAppearance, captureIncludesNativeBackdrop = !GlassVisible, position, displayMode,
            expanded, windowVisible = IsVisible, page, logicalWidth = viewport.Width, logicalHeight = viewport.Height,
            hostWidth = ActualWidth, hostHeight = ActualHeight, surfaceBounds, viewport,
            pixelWidth = image.PixelWidth, pixelHeight = image.PixelHeight, renderDpi = 96, windowDpi = dpi.PixelsPerInchX,
            nativeDpiFile = Path.GetFileName(nativePath),
            leadingWidth = HeaderLeading.DesiredSize.Width, trailingWidth = HeaderTrailing.DesiredSize.Width, quotaWidth = QuotaLabel.Width,
            target = destination, appliedFrame = lastFrame, embeddedFont = QuotaLabel.FontFamily.Source,
            embeddedFontFace = resolvedFont?.FontUri.AbsoluteUri, embeddedFontWeight = resolvedFont?.Weight.ToOpenTypeWeight(),
            animations = AnimationsEnabled, quotaHeight = QuotaLabel.Height, quotaDesired = QuotaLabel.DesiredSize,
            renderingDiagnostics = new { frames = renderedFrames, meanMilliseconds = totalRenderMilliseconds / Math.Max(1, renderedFrames), worstMilliseconds = worstRenderMilliseconds, worstIntervalMilliseconds = worstFrameIntervalMilliseconds, boundsMilliseconds, visualsMilliseconds, layoutMilliseconds, renderTier = RenderCapability.Tier >> 16 },
            animationPhaseLocked = false, rows = rows.Skip(page * PageSize).Take(PageSize), header = latest?.Presentation?.Header
        }, new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    }
    internal async Task WaitForPresentationAsync()
    {
        await ShellProjection.WhenIdleAsync();
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        var timeout = Stopwatch.StartNew();
        while (displayRefreshPending || rendering || renderCallback || !lastFrame.Finished || !VisibleSizeMatches(destination.Width, destination.Height))
        {
            if (timeout.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException("The synthetic window did not settle.");
            await Task.Delay(25);
        }
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
    }
    internal bool VisibleSizeMatches(double width, double height)
    {
        return Math.Abs(Shell.ActualWidth - width) < 0.01 && Math.Abs(Shell.ActualHeight - height) < 0.01;
    }
    internal MotionBounds LogicalTarget => destination;
    internal bool IsExpandedForAutomation => expanded;
    internal void CollapseForAutomation() { SetPinned(false); SetExpanded(false); }
    private void RecordInteraction(string value)
    {
        if (interactionTrace.Count == 12) interactionTrace.Dequeue();
        interactionTrace.Enqueue($"{Clock():0.000} {value}");
    }
    internal void Reveal() { if (presentationStopped || updateInputSuspended) return; RecordInteraction("reveal"); RequestIslandVisibility(); SetPinned(true); SetExpanded(true); }
    internal Task SynchronizeExpansionAsync() => Send("setExpanded", new { expanded });
    private string paintedAccent = "multicolor";
    internal void ApplyPreferences(DesktopPreferences preferences)
    {
        bool screenChanged = compactPreferences.DisplaySelection != preferences.DisplaySelection || compactPreferences.DisplayID != preferences.DisplayID
            || compactPreferences.DisplayName != preferences.DisplayName || compactPreferences.DisplayX != preferences.DisplayX || compactPreferences.DisplayY != preferences.DisplayY;
        bool placementChanged = compactPreferences.IslandPlacement != preferences.IslandPlacement ||
            compactPreferences.Position != preferences.Position || compactPreferences.DisplayMode != preferences.DisplayMode;
        if (screenChanged || placementChanged) CancelMove();
        bool memoryTurnedOn = preferences.IslandPositionPerDisplay && !compactPreferences.IslandPositionPerDisplay;
        compactPreferences = preferences;
        RememberDisplayPlace(preferences);
        // Light Liquid Glass turns the whole island light before its surface changes.
        bool toneChanged = PacerPalette.ApplyTone(preferences.IslandAppearance == "liquidGlassLight");
        PreferSurface(preferences.IslandAppearance);
        // A new accent repaints the services' colors in the quota views and rows.
        PacerPalette.ApplyAccent(preferences.AccentColor);
        bool accentChanged = paintedAccent != PacerPalette.Accent; paintedAccent = PacerPalette.Accent;
        position = Array.IndexOf(new[] { "center", "topLeft", "bottomLeft", "topRight", "bottomRight" }, preferences.Position);
        displayMode = Array.IndexOf(new[] { "automatic", "notch", "floating" }, preferences.DisplayMode);
        showAppButtons = preferences.ShowAppButtons;
        if (accentChanged || toneChanged) InvalidatePanel(rebuildRows: true);
        if (toneChanged) RepaintTone();
        // The style draws from both of Core's layouts, so it needs no new snapshot.
        if (expandedQuotaStyle != preferences.ExpandedQuotaStyle || deepseekPanelStyle != preferences.DeepSeekPanelStyle)
        {
            expandedQuotaStyle = preferences.ExpandedQuotaStyle;
            deepseekPanelStyle = preferences.DeepSeekPanelStyle;
            InvalidatePanel(rebuildRows: false);
        }
        UpdateAppButtons(); UpdateCompactBar();
        if (!MoreButton.ContextMenu.IsOpen) BuildMoreMenu();
        // Turning the memory on records the current display's place.
        if ((screenChanged || memoryTurnedOn) && PresentationSource.FromVisual(this) != null && screenGeometry == null) QueueDisplayRefresh(force: true);
        else Relayout(snap: placementChanged);
        ApplyFullscreenVisibility(); occlusion?.Request();
    }
    private void UpdateAppButtons()
    {
        string availability = showAppButtons + ":" + string.Join(",", latest?.Modules?.Select(value => $"{value.Provider}:{value.Enabled}:{value.Installed}")
            ?? latest?.Sources.Select(value => value.Provider) ?? []);
        if (availability == appAvailabilitySignature && Clock() < nextAppAvailabilityScan) return;
        appAvailabilitySignature = availability; nextAppAvailabilityScan = Clock() + 60;
        var enabled = latest?.Modules?.Where(value => value.Enabled).Select(value => value.Provider).ToHashSet()
            ?? latest?.Sources.Select(value => value.Provider).ToHashSet() ?? [];
        var available = desktopApplications?.Available() ?? [];
        bool canOpenHarness = available.Any(value => value.Provider == "deepseek");
        if (harnessAvailable != canOpenHarness) { harnessAvailable = canOpenHarness; foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row); }
        availableApplications = available.Where(value => enabled.Contains(value.Provider)).Select(value => value.Provider).ToArray();
        var apps = showAppButtons ? available.Where(value => enabled.Contains(value.Provider)).ToArray() : [];
        string signature = string.Join(",", apps.Select(value => value.Provider));
        if (signature == appButtonsSignature) return;
        appButtonsSignature = signature; AppButtons.Children.Clear();
        foreach (var app in apps)
        {
            var button = new Button { Style = (Style)FindResource("IconButton") };
            var glyph = new IconGlyph { Symbol = app.Provider switch { "codex" => "chevron.left.forwardslash.chevron.right", "deepseek" => "water.waves", _ => "asterisk" }, Width = 14, Height = 14,
                Ink = new SolidColorBrush(app.Provider switch { "codex" => Color.FromRgb(102, 205, 187), "deepseek" => Color.FromRgb(126, 150, 255), _ => Color.FromRgb(255, 164, 119) }) };
            button.Content = glyph; SetButtonName(button, ui.Text("windows.open." + app.Provider));
            AutomationProperties.SetAutomationId(button, "island.open." + app.Provider);
            button.Click += (_, _) => OpenDesktopApplication(app.Provider, button);
            AppButtons.Children.Add(button);
        }
        AppButtons.Visibility = AppButtonsDivider.Visibility = apps.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void OpenDesktopApplication(string provider, Button button)
    {
        if (presentationStopped || !expanded || !Expanded.IsAccessible || !AppButtons.Children.Contains(button)) return;
        ClearNavigationError();
        if (desktopApplications?.Open(provider) == true) DismissForSettings();
        else ShowNavigationError(ui.Text("windows.app.open_failed"));
    }
    /// Enabled modules whose desktop app is installed, whether or not their buttons show.
    private string[] availableApplications = [];
    private IEnumerable<string> AvailableApplications() => availableApplications;
    /// An app the header leaves out opens from the More menu.
    private void OpenDesktopApplicationFromMenu(string provider)
    {
        if (presentationStopped || !expanded || showAppButtons || !availableApplications.Contains(provider)) return;
        ClearNavigationError();
        if (desktopApplications?.Open(provider) == true) DismissForSettings();
        else ShowNavigationError(ui.Text("windows.app.open_failed"));
    }
    private void OnMouseEnter(object sender, MouseEventArgs e) { if (move != null) return; RecordInteraction("hover-in"); collapse.Stop(); SetExpanded(true); }
    private void OnMouseLeave(object sender, MouseEventArgs e) { if (move != null) return; RecordInteraction("hover-out"); if (!pinned && !MoreButton.ContextMenu.IsOpen) collapse.Start(); }
    private void OnPin(object sender, RoutedEventArgs e) => SetPinned(!pinned);
    private void SetPinned(bool value)
    {
        value = value && !updateInputSuspended;
        pinned = value;
        PinButton.Background = value ? PacerPalette.Hover : Brushes.Transparent;
        PinButton.Foreground = value ? PacerPalette.Primary : PacerPalette.Secondary;
        ((IconGlyph)PinButton.Content).Symbol = value ? "pin.fill" : "pin";
        SetButtonName(PinButton, ui.Text(value ? "common.unpin" : "common.pin"));
        UpdateMainAction();
    }
    private async void OnMarkRead(object sender, RoutedEventArgs e) { if (latest != null) await Send("markAllRead", new { snapshotSequence = latest.Sequence }); }
    private async void OnRefresh(object sender, RoutedEventArgs e) => await Send("refresh", new { discover = true });
    private void OnQuit(object sender, RoutedEventArgs e) => QuitRequested?.Invoke();
    private void OnSettings(object sender, RoutedEventArgs e)
    { DismissForSettings(); SettingsRequested?.Invoke(); }
    internal void DismissForSettings()
    { CancelMove(); MoreButton.ContextMenu.IsOpen = false; SetPinned(false); SetExpanded(false); }
    private void OnMore(object sender, RoutedEventArgs e)
    {
        collapse.Stop(); BuildMoreMenu(); MoreButton.ContextMenu.PlacementTarget = MoreButton; MoreButton.ContextMenu.IsOpen = true;
    }
    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { RecordInteraction("escape"); SetPinned(false); SetExpanded(false); e.Handled = true; }
        if (IsPagingInput(e.Key, e.SystemKey, Keyboard.Modifiers, IsEditing(e.OriginalSource as DependencyObject)))
        { Key key = e.Key == Key.System ? e.SystemKey : e.Key; ChangePage(key == Key.Left ? -1 : 1); e.Handled = true; }
        if (demo && (Keyboard.Modifiers & ModifierKeys.Control) != 0 && e.Key >= Key.D1 && e.Key <= Key.D4)
            _ = Send("demoStage", new { demoStage = (int)e.Key - (int)Key.D1 });
    }
    private void OnPreviousPage(object sender, RoutedEventArgs e) => ChangePage(-1);
    private void OnNextPage(object sender, RoutedEventArgs e) => ChangePage(1);
    private void OnTaskWheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Shift) == 0) return;
        ChangePage(e.Delta < 0 ? 1 : -1); e.Handled = true;
    }
    private void OnTaskPointerDown(object sender, MouseButtonEventArgs e) => pointerDown = e.GetPosition(TaskPages);
    private void OnTaskPointerUp(object sender, MouseButtonEventArgs e)
    {
        if (pointerDown is Point start)
        {
            Vector movement = e.GetPosition(TaskPages) - start;
            if (Math.Abs(movement.X) > Math.Max(40, Math.Abs(movement.Y) * 1.5)) ChangePage(movement.X < 0 ? 1 : -1);
        }
        pointerDown = null;
    }
    private void OnClosing(object? sender, CancelEventArgs e) { if (!AllowClose) { e.Cancel = true; visibleRequested = false; ApplyFullscreenVisibility(); } else StopPresentation(); }
    private void SetExpanded(bool value, bool snap = false)
    {
        if (value && (updateInputSuspended || move?.Active == true)) return;
        collapse.Stop();
        if (value == expanded) return;
        if (!value) Keyboard.ClearFocus();
        expanded = value;
        // A collapsed island skipped the panel's snapshots; it is built once, before it is measured.
        // Rows kept from a hidden panel resume their loops once they show.
        if (value) { RefreshDirtyPanel(); RefreshRowMotion(); }
        PaceBadges();
        UIElementAutomationPeer.FromElement(this)?.RaisePropertyChangedEvent(ExpandCollapsePatternIdentifiers.ExpandCollapseStateProperty,
            value ? ExpandCollapseState.Collapsed : ExpandCollapseState.Expanded,
            value ? ExpandCollapseState.Expanded : ExpandCollapseState.Collapsed);
        Relayout(snap); _ = Send("setExpanded", new { expanded = value });
    }
    private IslandLayout MeasureLayout(double contentWidth, double contentHeight, double headerWidth, bool open,
        (bool OpensUp, double Y)? anchor = null)
    {
        var current = IslandScreen.Read(this, SelectedDisplay.Display);
        var bounds = screenGeometry?.Invoke() ?? (current.Screen, current.Work);
        var preferences = displayedPlacement ?? compactPreferences;
        if (preferences.DisplayMode != "notch" && preferences.IslandPlacement is { } placement)
            return MeasurePlacement(placement, bounds.Item1, bounds.Item2, contentWidth, contentHeight, headerWidth, open, anchor);
        return geometry.Measure(bounds.Item1, bounds.Item2, displayMode, 0, 0, position, open, contentWidth, contentHeight, headerWidth, measuredStripHeight, CompactSizeIndex);
    }
    private IslandLayout MeasurePlacement(IslandPlacement placement, MotionBounds screen, MotionBounds work,
        double contentWidth, double contentHeight, double headerWidth, bool open, (bool OpensUp, double Y)? anchor = null)
    {
        int side = placement.Edge == IslandEdge.Left ? 1 : placement.Edge == IslandEdge.Right ? 3 : 0;
        var measured = geometry.Measure(screen, work, 2, 0, 0, side, false, contentWidth, contentHeight, headerWidth, measuredStripHeight, CompactSizeIndex);
        return placement.Arrange(work, measured, measured.Target.Width, measured.Target.Height, contentHeight, open, anchor);
    }
    private void Relayout(bool snap = false, (double Header, double Strip)? compactSize = null)
    {
        if (move?.Active == true && !snap) return;
        // Never reuse a constrained lane's measured size as its natural width.
        var size = compactSize ?? MeasureCompactBar();
        laidOutCompactSize = size;
        double measuredHeader = size.Header;
        dragHeaderWidth = measuredHeader;
        double rowsHeight = RowsHeight(rows.Count);
        double contentWidth, contentHeight;
        // A collapsed island keeps the panel's last measured size: its
        // snapshots wait for the next opening, which measures it again.
        if (!expanded && latest != null && panelSize is { } kept)
            (contentWidth, contentHeight) = kept;
        else
        {
            // Every section header must fit, the one carrying the buttons above all.
            double headerWidth = 0;
            foreach (var header in sectionHeaders.Count > 0 ? sectionHeaders : [TaskToolbar])
            { header.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); headerWidth = Math.Max(headerWidth, header.DesiredSize.Width); }
            contentWidth = Math.Max((tasksShown ? measuredRowsWidth : 0) + 12, headerWidth + 12);
            var widthProbe = MeasureLayout(contentWidth, 0, measuredHeader, expanded);
            double availableContentWidth = Math.Max(1, widthProbe.CanvasWidth - 12 - (widthProbe.Position != 0 ? widthProbe.StripWidth : 0));
            // Before the first snapshot the panel reserves the original quota row.
            if (latest == null)
            {
                contentHeight = 4 + 24 + 4 + rowsHeight + 21 + 24 + 8 + 133 + 4 + 14;
                if (StatusLabel.Visibility == Visibility.Visible) { StatusLabel.Measure(new Size(availableContentWidth, double.PositiveInfinity)); contentHeight += StatusLabel.DesiredSize.Height; }
            }
            else
            {
                InvalidatePanelMeasure();
                PanelContent.Measure(new Size(availableContentWidth, double.PositiveInfinity));
                contentHeight = PanelContent.DesiredSize.Height;
                PanelMeasures++;
            }
            // IslandModel.updateMeasuredContentHeight also rounds upward. A
            // fractional text line must not create a scrollbar and narrow the
            // already measured content when geometry snaps the panel to points.
            contentHeight = Math.Ceiling(contentHeight);
            if (latest != null) panelSize = (contentWidth, contentHeight);
        }
        int previousAnchor = layout.MotionAnchor;
        layout = MeasureLayout(contentWidth, contentHeight, measuredHeader, expanded, snap ? null : expansionAnchor);
        // If the panel had to move to fit, hold that edge until it closes.
        if (expanded)
            expansionAnchor = (layout.OpensUp, layout.Target.Y + (layout.OpensUp ? layout.Target.Height : 0));
        snap |= previousAnchor != layout.MotionAnchor;
        ApplyPresentationLayout();
        bool blackHeader = layout.Attached && islandAppearance == "liquidGlass";
        if (snap)
        {
            StopRendering(); motion.Dispose();
            destination = layout.Target; destinationExpanded = expanded; destinationBlackHeader = blackHeader; surfaceBounds = destination;
            motionRevision++; transitionStarted = Clock();
            motion = new NativeMotion(Path.Combine(AppContext.BaseDirectory, "Engine"), destination, expanded, blackHeader, layout.MotionAnchor);
            NativeWindowBounds.Apply(this, surfaceBounds); ApplyMotion(motion.SettledAt(transitionStarted));
            return;
        }
        if (layout.Target == destination && destinationExpanded == expanded && destinationBlackHeader == blackHeader) return;
        destination = layout.Target;
        destinationExpanded = expanded;
        destinationBlackHeader = blackHeader;
        motionRevision++;
        Expanded.Visibility = Visibility.Visible;
        transitionStarted = Clock(); motion.RetargetTo(destination, expanded, transitionStarted, blackHeader, layout.MotionAnchor);
        if (!AnimationsEnabled)
        {
            // Nothing is displayed between here and the settled frame, so the
            // surface goes straight to its settled outline without growing first.
            StopRendering(); var settled = motion.SettledAt(transitionStarted);
            FitSurface(settled); ApplyMotion(settled);
            return;
        }
        PrepareSurface();
        // Allocation can wait on the system compositor. Start the displayed
        // transition after that work, retaining the same last displayed sample.
        transitionStarted = Clock(); motion.RetargetTo(destination, expanded, transitionStarted, blackHeader, layout.MotionAnchor);
        StartRendering();
    }
    private void PrepareSurface()
    {
        MotionBounds canvas = motion.CanvasAt(transitionStarted);
        var union = Rect.Union(new Rect(surfaceBounds.X, surfaceBounds.Y, surfaceBounds.Width, surfaceBounds.Height),
            new Rect(canvas.X, canvas.Y, canvas.Width, canvas.Height));
        surfaceBounds = new(union.X, union.Y, union.Width, union.Height);
        NativeWindowBounds.Apply(this, surfaceBounds);
        PlaceShell(lastFrame.Window.Width > 0 ? lastFrame.Window : layout.Target);
    }
    /// A finished transition trims the canvas grown for the spring. It is
    /// transparent, but a layered window still pushes all of it on every later
    /// frame of the bar's own motion. Only the right and bottom edges move: a
    /// new origin would show each layered window's previous bitmap at the new
    /// place until WPF draws again, so the shell, its glass and its shoulders
    /// or shadow would jump apart for a frame or two. A kept origin shows the
    /// same pixels, and the next transition grows the far edges back in place.
    private void FitSurface(MotionFrame frame)
    {
        var settled = destination;
        if (frame.Window.Width > 0 && frame.Window.Height > 0)
        {
            var union = Rect.Union(new Rect(settled.X, settled.Y, settled.Width, settled.Height),
                new Rect(frame.Window.X, frame.Window.Y, frame.Window.Width, frame.Window.Height));
            settled = new(union.X, union.Y, union.Width, union.Height);
        }
        var fitted = FittedSurface(surfaceBounds, settled);
        if (fitted == surfaceBounds) return;
        surfaceBounds = fitted;
        NativeWindowBounds.Apply(this, surfaceBounds);
    }
    /// The settled outline with the current origin, unless the outline starts
    /// above or left of it (only a transition without motion does that).
    internal static MotionBounds FittedSurface(MotionBounds current, MotionBounds settled)
    {
        double x = Math.Min(current.X, settled.X), y = Math.Min(current.Y, settled.Y);
        return new(x, y, settled.X + settled.Width - x, settled.Y + settled.Height - y);
    }
    /// The settled window surface, in logical points; read by the presentation checks.
    internal MotionBounds SurfaceBounds => surfaceBounds;
    private void PlaceShell(MotionBounds frame)
    {
        Shell.Width = frame.Width; Shell.Height = frame.Height;
        // Compensate for the whole-pixel native origin while retaining the
        // original logical geometry within the transparent drawing surface.
        ShellOffset.X = frame.X - Left; ShellOffset.Y = frame.Y - Top;
    }
    private void ApplyPresentationLayout()
    {
        int effective = layout.Position;
        bool side = effective != 0, left = effective is 1 or 2;
        Header.Height = layout.HeaderHeight;
        Header.VerticalAlignment = HeaderBand.VerticalAlignment = layout.OpensUp ? VerticalAlignment.Bottom : VerticalAlignment.Top;
        Header.Visibility = side ? Visibility.Collapsed : Visibility.Visible;
        Strip.Visibility = side ? Visibility.Visible : Visibility.Collapsed;
        Strip.HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        Strip.Width = layout.StripWidth;
        Expanded.Width = Math.Max(1, layout.CanvasWidth - 12 - (side ? layout.StripWidth : 0));
        Expanded.Height = Math.Max(1, layout.CanvasHeight - (side ? 0 : layout.HeaderHeight));
        Expanded.HorizontalAlignment = side ? left ? HorizontalAlignment.Left : HorizontalAlignment.Right : HorizontalAlignment.Center;
        // Content opening upward stays next to the header while the shell grows away from it.
        Expanded.VerticalAlignment = effective is 2 or 4 || (!side && layout.OpensUp) ? VerticalAlignment.Bottom : VerticalAlignment.Top;
        Expanded.Margin = side ? new Thickness(left ? layout.StripWidth + 6 : 6, 0, left ? 6 : layout.StripWidth + 6, 0)
            : layout.OpensUp ? new Thickness(6, 0, 6, layout.HeaderHeight) : new Thickness(6, layout.HeaderHeight, 6, 0);
    }
    private static double Clock() => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    private void StartRendering()
    {
        if (presentationStopped || rendering || !IsVisible) return;
        rendering = true; CompositionTarget.Rendering += OnRenderFrame;
    }
    private void StopRendering() { if (!rendering) return; rendering = false; CompositionTarget.Rendering -= OnRenderFrame; }
    private void OnRenderFrame(object? sender, EventArgs e)
    {
        // Resizing a layered HWND can pump the dispatcher and re-enter this
        // callback. Finish the displayed sample before taking another one.
        if (renderCallback || !rendering) return;
        renderCallback = true;
        double callbackStarted = Clock();
        try
        {
            int revision = motionRevision;
            if (lastRenderedAt >= transitionStarted && lastRenderedAt > 0) worstFrameIntervalMilliseconds = Math.Max(worstFrameIntervalMilliseconds, (callbackStarted - lastRenderedAt) * 1000);
            renderedFrames++; lastRenderedAt = Clock();
            MotionFrame frame = AnimationsEnabled ? motion.At(Clock()) : motion.SettledAt(Math.Max(Clock(), transitionStarted));
            if (frame.Finished && revision == motionRevision)
            {
                // Shrink before the last frame is applied, so the shell and its
                // decoration are placed in the final surface once.
                FitSurface(frame);
                if (revision != motionRevision) return;
            }
            ApplyMotion(frame);
            if (frame.Finished && revision == motionRevision) StopRendering();
        }
        finally
        {
            double duration = (Clock() - callbackStarted) * 1000;
            totalRenderMilliseconds += duration; worstRenderMilliseconds = Math.Max(worstRenderMilliseconds, duration);
            renderCallback = false;
        }
    }
    private void ApplyMotion(MotionFrame frame)
    {
        lastFrame = frame;
        if (frame.Finished && !expanded) expansionAnchor = null;
        double started = Clock();
        PlaceShell(frame.Window);
        boundsMilliseconds += (Clock() - started) * 1000; started = Clock();
        // The collapsed corners grow to the expanded panel's 27 as it opens.
        double collapsed = CollapsedRadius(), radius = collapsed + (27 - collapsed) * frame.Expansion;
        int effective = layout.Position;
        Shell.CornerRadius = effective is 1 or 2 ? new(0, radius, radius, 0) : effective is 3 or 4 ? new(radius, 0, 0, radius)
            : layout.Attached || layout.Dock == IslandEdge.Top ? new(0, 0, radius, radius)
            : layout.Dock == IslandEdge.Bottom ? new(radius, radius, 0, 0) : new(radius);
        Shell.Clip = ClipShape(frame.Window.Width, frame.Window.Height, Shell.CornerRadius);
        UpdateRim(frame.Window.Width, frame.Window.Height, Shell.CornerRadius);
        UpdateDecoration(frame);
        Expanded.Opacity = frame.Content;
        RevealOffset.X = effective == 0 ? 0 : (effective is 1 or 2 ? 1 : -1) * (1 - frame.Content) * 8;
        RevealOffset.Y = effective == 0 ? (layout.OpensUp ? -1 : 1) * (1 - frame.Content) * 8 : 0;
        bool interactive = expanded && frame.Content > 0.95;
        Expanded.IsHitTestVisible = interactive; Expanded.SetAccessible(interactive);
        KeyboardNavigation.SetTabNavigation(Expanded, interactive ? KeyboardNavigationMode.Continue : KeyboardNavigationMode.None);
        Expanded.Visibility = expanded || frame.Content > 0 ? Visibility.Visible : Visibility.Collapsed;
        visualsMilliseconds += (Clock() - started) * 1000; started = Clock();
        ((FrameworkElement)Content).UpdateLayout();
        UIElementAutomationPeer.FromElement(this)?.InvalidatePeer();
        layoutMilliseconds += (Clock() - started) * 1000;
        SyncBackdrop();
        FrameApplied?.Invoke(frame);
    }
    private static Geometry ClipShape(double width, double height, CornerRadius corners)
    {
        var path = new StreamGeometry();
        using (var geometry = path.Open())
        {
            geometry.BeginFigure(new Point(corners.TopLeft, 0), true, true);
            geometry.LineTo(new Point(width - corners.TopRight, 0), true, false);
            if (corners.TopRight > 0) geometry.ArcTo(new Point(width, corners.TopRight), new Size(corners.TopRight, corners.TopRight), 0, false, SweepDirection.Clockwise, true, false);
            geometry.LineTo(new Point(width, height - corners.BottomRight), true, false);
            if (corners.BottomRight > 0) geometry.ArcTo(new Point(width - corners.BottomRight, height), new Size(corners.BottomRight, corners.BottomRight), 0, false, SweepDirection.Clockwise, true, false);
            geometry.LineTo(new Point(corners.BottomLeft, height), true, false);
            if (corners.BottomLeft > 0) geometry.ArcTo(new Point(0, height - corners.BottomLeft), new Size(corners.BottomLeft, corners.BottomLeft), 0, false, SweepDirection.Clockwise, true, false);
            geometry.LineTo(new Point(0, corners.TopLeft), true, false);
            if (corners.TopLeft > 0) geometry.ArcTo(new Point(corners.TopLeft, 0), new Size(corners.TopLeft, corners.TopLeft), 0, false, SweepDirection.Clockwise, true, false);
        }
        path.Freeze(); return path;
    }
    internal void StopPresentation()
    {
        if (presentationStopped) return;
        ShellProjection.Changed -= OnShellProjectionChanged; engine.Snapshot -= QueueSnapshot;
        presentationStopped = true; CancelMove(); StopRendering(); DisposeOcclusion(); DisposeBackdrop(); motion.Dispose(); collapse.Stop(); QuotaLabel.Stop(); StripQuota.Stop();
        if (decoration != null) { decoration.Close(); decoration = null; }
        foreach (var clock in pageClocks) clock.Dispose(); pageClocks.Clear();
        DisposeAppearance(); DisposePresence();
        displays.Changed -= DisplayTopologyChanged; displays.Dispose();
    }
    private async Task Send(string method, object? parameters = null)
    {
        try { await engine.SendAsync(method, parameters); }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or InvalidOperationException) { }
    }
    internal void ReceiveSnapshot(EngineSnapshot snapshot) => Render(snapshot);
    private EngineSnapshot? queuedSnapshot;
    /// Snapshots rendered, the expanded panel's builds and measures; read by the presentation checks.
    internal int SnapshotRenders { get; private set; }
    internal int PanelBuilds { get; private set; }
    internal int PanelMeasures { get; private set; }
    internal bool PanelDirty => panelDirty;
    internal ulong RenderedSequence => latest?.Sequence ?? 0;
    /// A burst of snapshots renders once, with the newest. The engine still
    /// hands every snapshot to its other subscribers, so notices are unaffected.
    private void QueueSnapshot(EngineSnapshot value)
    {
        if (Interlocked.Exchange(ref queuedSnapshot, value) == null) Dispatcher.InvokeAsync(RenderQueuedSnapshot);
    }
    private void RenderQueuedSnapshot()
    {
        if (Interlocked.Exchange(ref queuedSnapshot, null) is { } value) Render(value);
    }
    /// Whether the panel follows each snapshot: while it is open or still
    /// fading, and until it has been measured once.
    private bool PanelLive => expanded || lastFrame.Content > 0 || panelSize == null;
    private bool panelDirty;
    private (double Width, double Height)? panelSize;

    private void Render(EngineSnapshot snapshot)
    {
        if (presentationStopped) return;
        SnapshotRenders++;
        bool linksChanged = !(latest?.ActivityLinks ?? []).SequenceEqual(snapshot.ActivityLinks ?? []);
        bool openingChanged = !(latest?.OpeningActivityIDs ?? []).SequenceEqual(snapshot.OpeningActivityIDs ?? []);
        bool first = latest == null;
        latest = snapshot;
        openingActivityContexts.IntersectWith((snapshot.ActivityLinks ?? []).Select(link => link.Context));
        ApplyNavigationFailure(snapshot.NavigationError);
        UpdateAppButtons();
        if (snapshot.Presentation is not EnginePresentation presentation) { SetStatus(ui.Text("windows.restart_required")); return; }
        MarkReadButton.IsEnabled = presentation.Rows.Any(row => row.Unread && row.Phase is "completed" or "interrupted");
        UpdateCompactBar();
        // New row choices redraw the page even when the rows are the same.
        bool choicesChanged = ApplyPanelChoices(snapshot);
        bool rowsChanged = !rows.SequenceEqual(presentation.Rows);
        if (rowsChanged || choicesChanged) { rows = presentation.Rows; page = Math.Clamp(page, 0, PageCount - 1); }
        string countShown = TasksCount.Text, pageShown = PageNumber.Text; var pagerShown = PageControls.Visibility;
        TasksCount.Text = presentation.TaskCountText ?? "—";
        UpdatePager();
        // A new count or page label can widen the task header.
        bool panelChanged = first || countShown != TasksCount.Text || pageShown != PageNumber.Text || pagerShown != PageControls.Visibility;
        if (!PanelLive)
        {
            // Nothing of the hidden panel is built or measured; opening builds it once.
            panelDirty = true;
        }
        else
        {
            if (panelDirty) { panelDirty = false; BuildPage(false, 0); panelChanged = true; }
            else if (choicesChanged) { BuildPage(false, 0); panelChanged = true; }
            else if (rowsChanged) { if (!UpdatePageInPlace()) BuildPage(false, 0); panelChanged = true; }
            else if (linksChanged || openingChanged) foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row);
            panelChanged |= RenderPanel(snapshot);
        }
        // Only a new size relays the island; values redraw within their footprint.
        var size = MeasureCompactBar();
        if (panelChanged || laidOutCompactSize != size) Relayout(compactSize: size);
    }
    /// Builds a panel that skipped snapshots while collapsed, from the latest one.
    private void RefreshDirtyPanel()
    {
        if (!panelDirty || latest?.Presentation is not EnginePresentation presentation) return;
        panelDirty = false;
        ApplyPanelChoices(latest);
        rows = presentation.Rows; page = Math.Clamp(page, 0, PageCount - 1);
        // Rows that changed meanwhile draw their final state, as rows built while hidden did.
        BuildPage(false, 0, settled: true); UpdatePager();
        RenderPanel(latest);
    }
    /// Rebuilds the panel now when it shows, or at its next opening.
    private void InvalidatePanel(bool rebuildRows)
    {
        if (latest == null) return;
        if (!PanelLive) { panelDirty = true; return; }
        if (rebuildRows) BuildPage(false, 0);
        RenderPanel(latest);
    }
    /// The page shows the same tasks in the same order: each row takes its new
    /// values in place, keeping its control and motion. Otherwise it is rebuilt.
    private bool UpdatePageInPlace()
    {
        if (currentPage is not { } shown || shown.Children.Count != 1 || shown.Children[0] is not StackPanel content) return false;
        var values = rows.Skip(page * PageSize).Take(PageSize).ToArray();
        var controls = content.Children.OfType<TaskRow>().ToArray();
        if (values.Length == 0 || controls.Length != content.Children.Count || controls.Length != values.Length) return false;
        for (int index = 0; index < values.Length; index++)
        {
            var current = ((TaskRowState)controls[index].DataContext).Value;
            if (current.Id != values[index].Id || current.Provider != values[index].Provider) return false;
        }
        AutomationProperties.SetName(shown, ui.Text(rows.Count > PageSize ? "activity.page_region" : "activity.task_list"));
        TaskPages.Height = RowsHeight(rows.Count);
        measuredRowsWidth = 0;
        for (int index = 0; index < values.Length; index++)
        {
            controls[index].Update(values[index], panelOptions); BindTaskAction(controls[index]);
            measuredRowsWidth = Math.Max(measuredRowsWidth, controls[index].IdealWidth());
        }
        return true;
    }
    private FrameworkElement? DeepSeekStatus(EngineSnapshot snapshot)
    {
        if (snapshot.DeepseekConnection is not { Status: not null } connection) return null;
        bool Current(string action) => !presentationStopped && !engine.IsConnectionClosed &&
            latest?.DeepseekConnection is { Status: not null } current && current.Context == connection.Context &&
            current.Status.Actions.Any(value => value.Kind == action && value.Enabled);
        return new DeepSeekBalanceStatusView(connection.Status, async () =>
        {
            if (!Current("retry")) return;
            try { await engine.SendAsync("retryDeepSeekBalance", new { balanceContext = connection.Context }); }
            catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
            { if (!presentationStopped) SetStatus(ui.Text("windows.connection.refresh_failed")); }
        }, () => { if (Current("settings")) { DismissForSettings(); ProviderSettingsRequested?.Invoke("deepseek"); } });
    }
    private Action? DeepSeekConnectAction(EngineSnapshot snapshot)
    {
        if (snapshot.DeepseekConnection is not DeepSeekConnection connection || snapshot.Wallet?.Dial?.ConnectTitle == null ||
            connection.Mode != "apiKey" && (!connection.WebAvailable || canConnectDeepSeekWeb?.Invoke() != true)) return null;
        return () =>
        {
            if (presentationStopped || engine.IsConnectionClosed || latest?.DeepseekConnection is not DeepSeekConnection current ||
                current.Context != connection.Context || latest.Wallet?.Dial?.ConnectTitle == null) return;
            if (current.Mode == "apiKey") { DismissForSettings(); ProviderSettingsRequested?.Invoke("deepseek"); }
            else if (current.WebAvailable && canConnectDeepSeekWeb?.Invoke() == true) DeepSeekWebSignInRequested?.Invoke(current.Context);
        };
    }
    private FrameworkElement? QuotaStatus(DashboardProvider? provider) => provider?.Status is QuotaConnectionStatus status
        ? new QuotaConnectionView(provider.Provider, status, ui, provider.Provider is "codex" or "claude" ? () => RetryProviderQuota(provider.Provider) : null,
            provider.Provider is "codex" or "claude" ? () => { DismissForSettings(); ProviderSettingsRequested?.Invoke(provider.Provider); } : null) : null;
    private async Task RetryProviderQuota(string provider)
    {
        try { await engine.SendAsync("retryQuota", new { provider }); }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        { SetStatus(ui.Text("windows.connection.refresh_failed")); }
    }
    private void UpdatePager()
    {
        int count = PageCount;
        PageControls.Visibility = count > 1 ? Visibility.Visible : Visibility.Collapsed;
        PageNumber.Text = $"{page + 1} / {count}";
        PreviousPage.IsEnabled = page > 0; NextPage.IsEnabled = page + 1 < count;
    }
    private void ChangePage(int delta)
    {
        int target = Math.Clamp(page + delta, 0, PageCount - 1);
        if (target == page) return;
        page = target; BuildPage(DecorationsAnimate, Math.Sign(delta)); UpdatePager(); Relayout();
    }
    private void BuildPage(bool animate, int direction, bool settled = false)
    {
        PanelBuilds++;
        foreach (var clock in pageClocks) clock.Dispose(); pageClocks.Clear();
        RevealHost? outgoing = currentPage;
        var content = new StackPanel { VerticalAlignment = VerticalAlignment.Top };
        var incoming = new RevealHost { VerticalAlignment = VerticalAlignment.Top, RenderTransform = new TranslateTransform() };
        incoming.Children.Add(content); incoming.SetAccessible(true);
        AutomationProperties.SetName(incoming, ui.Text(rows.Count > PageSize ? "activity.page_region" : "activity.task_list"));
        TaskPages.Height = RowsHeight(rows.Count);
        measuredRowsWidth = 0;
        int index = 0;
        foreach (var value in rows.Skip(page * PageSize).Take(PageSize))
        {
            var row = new TaskRow(value, panelOptions, settled) { Language = Language, Margin = new Thickness(0, index++ == 0 ? 0 : 2, 0, 0) };
            BindTaskAction(row);
            content.Children.Add(row); measuredRowsWidth = Math.Max(measuredRowsWidth, row.IdealWidth());
        }
        if (rows.Count == 0)
        {
            var empty = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(9, 8, 9, 8) };
            empty.Children.Add(new IconGlyph { Symbol = "moon", Ink = PacerPalette.Secondary, Width = 28, Height = 28 });
            empty.Children.Add(new TextBlock { Text = ui.Text("activity.no_tasks"), FontSize = 12, FontWeight = FontWeights.Medium,
                Foreground = PacerPalette.Secondary, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(empty);
        }
        if (outgoing != null)
        {
            outgoing.IsEnabled = false; outgoing.IsHitTestVisible = false; outgoing.SetAccessible(false);
            KeyboardNavigation.SetTabNavigation(outgoing, KeyboardNavigationMode.None);
            if (outgoing.IsKeyboardFocusWithin) Keyboard.ClearFocus();
        }
        TaskPages.Children.Clear(); currentPage = incoming;
        if (animate && outgoing != null)
        {
            TaskPages.Children.Add(outgoing);
            var fade = PageAnimation(outgoing.Opacity, 0);
            pageClocks.Add(new(fade, clock => outgoing.ApplyAnimationClock(OpacityProperty, clock), () => TaskPages.Children.Remove(outgoing)));
            var transform = (TranslateTransform)outgoing.RenderTransform;
            pageClocks.Add(new(PageAnimation(transform.X, -direction * 18), clock => transform.ApplyAnimationClock(TranslateTransform.XProperty, clock)));
            pageClocks.Add(new(PageAnimation(0, 1), clock => incoming.ApplyAnimationClock(OpacityProperty, clock)));
            pageClocks.Add(new(PageAnimation(direction * 18, 0), clock => ((TranslateTransform)incoming.RenderTransform).ApplyAnimationClock(TranslateTransform.XProperty, clock)));
        }
        TaskPages.Children.Add(incoming);
    }
    private static IEnumerable<TaskRow> TaskRowsIn(DependencyObject parent)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is TaskRow row) yield return row;
            else foreach (var nested in TaskRowsIn(child)) yield return nested;
        }
    }
    private void BindTaskAction(TaskRow row)
    {
        var state = (TaskRowState)row.DataContext;
        var link = latest?.ActivityLinks?.FirstOrDefault(value => value.ActivityID == state.Value.Id && value.Provider == state.Value.Provider);
        bool harness = state.Value.Provider == "deepseek" && harnessAvailable;
        bool available = link != null && (state.Value.Provider != "deepseek" || harness) &&
            !openingActivityContexts.Contains(link.Context) && latest?.OpeningActivityIDs?.Contains(state.Value.Id) != true;
        row.SetOpenAction(available ? () => _ = OpenConversationTaskAsync(row, link!) : null,
            available ? state.AccessibleName + "\n" + ui.Text("common.open_chat") : ui.Text("activity.no_link"), DecorationsAnimate);
    }
    /// The main window's Overview lists the same rows; a click there opens the
    /// task through the same prepared navigation as a row on the island.
    internal bool CanOpenFromWindow(EngineTaskRow value)
    {
        var link = latest?.ActivityLinks?.FirstOrDefault(item => item.ActivityID == value.Id && item.Provider == value.Provider);
        return !presentationStopped && link != null && (value.Provider != "deepseek" || harnessAvailable) &&
            !openingActivityContexts.Contains(link.Context) && latest?.OpeningActivityIDs?.Contains(value.Id) != true;
    }
    internal async Task OpenFromWindowAsync(EngineTaskRow value)
    {
        var link = latest?.ActivityLinks?.FirstOrDefault(item => item.ActivityID == value.Id && item.Provider == value.Provider);
        if (link == null || !CanOpenFromWindow(value) || !openingActivityContexts.Add(link.Context)) return;
        ClearNavigationError();
        try
        {
            var plan = await engine.QueryAsync<EngineNavigationPlan>("prepareActivityOpen", new { context = link.Context });
            if (!CurrentConversationLink(link) || plan.Context != link.Context || plan.Provider != link.Provider) return;
            bool opened = await openConversation(plan, value);
            if (!CurrentConversationLink(link)) return;
            if (!opened)
            {
                await ReportNavigationFailureAsync(ui.Text(link.Provider == "deepseek"
                    ? desktopApplications?.CanOpenHarness == true ? "windows.app.open_failed" : "deepseek.app_missing"
                    : "activity.open_failed"), link.Context);
                return;
            }
            try { await engine.SendAsync("completeActivityOpen", new { context = link.Context }); }
            catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException) { }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        {
            if (CurrentConversationLink(link)) await ReportNavigationFailureAsync(ui.Text(error is EngineCommandException command ? command.Code switch {
                "missingClaudeHost" => "activity.claude_host_missing", "missingCodexHost" => "activity.codex_host_missing", _ => "activity.open_failed"
            } : "activity.open_failed"), link.Context);
        }
        finally
        {
            await Send("cancelActivityOpen", new { context = link.Context });
            openingActivityContexts.Remove(link.Context);
        }
    }
    private bool CurrentConversationAction(TaskRow control, EngineActivityLink link) => !presentationStopped && expanded && Expanded.IsAccessible &&
        currentPage?.IsAccessible == true && currentPage.IsAncestorOf(control) && latest?.ActivityLinks?.Contains(link) == true;
    private bool CurrentConversationLink(EngineActivityLink link) => !presentationStopped && latest?.ActivityLinks?.Contains(link) == true;
    private bool CurrentConversationPanel(EngineActivityLink link) => CurrentConversationLink(link) && expanded && Expanded.IsAccessible &&
        currentPage?.IsAccessible == true && rows.Skip(page * PageSize).Take(PageSize).Any(row => row.Id == link.ActivityID);
    private async Task OpenConversationTaskAsync(TaskRow control, EngineActivityLink link)
    {
        if (!CurrentConversationAction(control, link) || !openingActivityContexts.Add(link.Context)) return;
        ClearNavigationError();
        foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row);
        try
        {
            var plan = await engine.QueryAsync<EngineNavigationPlan>("prepareActivityOpen", new { context = link.Context });
            if (!CurrentConversationPanel(link) || plan.Context != link.Context || plan.Provider != link.Provider) return;
            bool opened = await openConversation(plan, rows.First(row => row.Id == link.ActivityID));
            if (!CurrentConversationLink(link)) return;
            if (!opened) {
                await ReportNavigationFailureAsync(ui.Text(link.Provider == "deepseek"
                    ? desktopApplications?.CanOpenHarness == true ? "windows.app.open_failed" : "deepseek.app_missing"
                    : "activity.open_failed"), link.Context);
                return;
            }
            if (CurrentConversationPanel(link)) DismissForSettings();
            // A source/ending token survives unrelated rate ticks. The engine
            // rejects a newer turn or changed source rather than clearing it.
            try { await engine.SendAsync("completeActivityOpen", new { context = link.Context }); }
            catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException) { }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        {
            if (CurrentConversationLink(link)) await ReportNavigationFailureAsync(ui.Text(error is EngineCommandException command ? command.Code switch {
                "missingClaudeHost" => "activity.claude_host_missing", "missingCodexHost" => "activity.codex_host_missing", _ => "activity.open_failed"
            } : "activity.open_failed"), link.Context);
        }
        finally
        {
            await Send("cancelActivityOpen", new { context = link.Context });
            openingActivityContexts.Remove(link.Context);
            if (!presentationStopped) foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row);
        }
    }
    private Task<bool> OpenConversationAsync(EngineNavigationPlan plan, EngineTaskRow row)
    {
        if (row.Provider == "deepseek") return Task.FromResult(plan.Kind is "application" or "demo" &&
            plan.Url == null && plan.WebUrl == null && plan.Pid == null && plan.Started == null && desktopApplications?.Open("deepseek") == true);
        if (plan.Kind != "demo") return desktopApplications?.OpenConversationAsync(plan,
            context => engine.QueryAsync<bool>("activateActivityHost", new { context })) ?? Task.FromResult(false);
        if (!demo) return Task.FromResult(false);
        var content = new StackPanel { Margin = new Thickness(32) };
        content.Children.Add(new TextBlock { Text = ui.Text("demo.chat_heading"), Foreground = PacerPalette.Secondary });
        content.Children.Add(new TextBlock { Text = row.Title, FontSize = 26, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 22, 0, 14) });
        content.Children.Add(new TextBlock { Text = row.Status, Margin = new Thickness(0, 0, 0, 14) });
        content.Children.Add(new TextBlock { Text = ui.Text("demo.chat_detail"), TextWrapping = TextWrapping.Wrap, Foreground = PacerPalette.Secondary });
        var dialog = new Window { Title = ui.Text("demo.chat_title"), Width = 560, Height = 320, Content = content, Owner = this,
            FontFamily = FontFamily, Language = Language, Foreground = Brushes.White, Background = new SolidColorBrush(Color.FromRgb(25, 25, 27)), WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var back = new Button { Content = ui.Text("demo.return"), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 22, 0, 0), Padding = new Thickness(14, 6, 14, 6) };
        back.Click += (_, _) => { dialog.Close(); Reveal(); }; content.Children.Add(back); WindowRendering.Prepare(dialog); dialog.Show();
        return Task.FromResult(true);
    }
    private static DoubleAnimationUsingKeyFrames PageAnimation(double from, double to)
    {
        var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.18) };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        animation.KeyFrames.Add(new SplineDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.18)), new KeySpline(0.42, 0, 0.58, 1)));
        return animation;
    }
}
