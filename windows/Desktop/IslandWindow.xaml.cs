using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
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
    private string? openingActivityContext;
    private readonly Func<bool>? canConnectDeepSeekWeb;
    private bool showAppButtons = true;
    private bool harnessAvailable;
    private string appButtonsSignature = "";
    private string appAvailabilitySignature = "";
    private double nextAppAvailabilityScan;
    private readonly bool? animationOverride;
    private bool AnimationsEnabled => animationOverride ?? SystemParameters.ClientAreaAnimation;
    private readonly DispatcherTimer collapse = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly DispatcherTimer navigationErrorDismiss = new();
    private bool navigationErrorShown;
    private readonly Queue<string> interactionTrace = new();
    private NativeMotion motion;
    private readonly NativeLayout geometry;
    private readonly Func<(MotionBounds Screen, MotionBounds WorkArea)>? screenGeometry;
    private bool pinned, expanded, rendering, presentationStopped;
    private bool renderCallback;
    private int motionRevision;
    private double transitionStarted, measuredRowsWidth;
    private int renderedFrames;
    private double lastRenderedAt;
    private double worstRenderMilliseconds, totalRenderMilliseconds, worstFrameIntervalMilliseconds;
    private double boundsMilliseconds, visualsMilliseconds, layoutMilliseconds;
    private MotionFrame lastFrame;
    internal string PresentationDiagnostics => $"rendering={rendering}, frames={renderedFrames}, sinceLast={Clock() - lastRenderedAt:0.000}, sinceStart={Clock() - transitionStarted:0.000}, renderMeanMs={totalRenderMilliseconds / Math.Max(1, renderedFrames):0.00}, renderWorstMs={worstRenderMilliseconds:0.00}, frameWorstIntervalMs={worstFrameIntervalMilliseconds:0.00}, boundsTotalMs={boundsMilliseconds:0.00}, visualsTotalMs={visualsMilliseconds:0.00}, layoutTotalMs={layoutMilliseconds:0.00}, renderTier={RenderCapability.Tier >> 16}, target={destination}, expanded={expanded}, requested={Width}x{Height}, actual={ActualWidth}x{ActualHeight}, last={lastFrame}, interactions=[{string.Join("; ", interactionTrace)}]";
    private EngineSnapshot? latest;
    private IslandLayout layout;
    private MotionBounds destination;
    private MotionBounds surfaceBounds;
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
        Func<IBackdropSystemSource>? backdropSystemFactory = null, Func<Window, ICompositionBackdrop>? backdropFactory = null)
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
        string directory = Path.Combine(AppContext.BaseDirectory, "Engine");
        geometry = new NativeLayout(directory);
        layout = MeasureLayout(404, 402, 160, false);
        destination = layout.Target;
        surfaceBounds = destination;
        Left = destination.X; Top = destination.Y; Width = destination.Width; Height = destination.Height;
        Shell.Width = destination.Width; Shell.Height = destination.Height;
        motion = new NativeMotion(directory, destination, position: layout.Position);
        DemoTag.Visibility = demo ? Visibility.Visible : Visibility.Collapsed;
        TasksTitle.Text = ui.Text("layout.group.tasks"); QuotaTitle.Text = ui.Text("layout.group.quota_balance"); DemoLabel.Text = ui.Text("demo.label");
        SetButtonName(MarkReadButton, ui.Text("activity.mark_all_read")); SetButtonName(PinButton, ui.Text("common.pin")); SetButtonName(MoreButton, ui.Text("common.more"));
        SetButtonName(PreviousPage, ui.Text("activity.previous_page")); SetButtonName(NextPage, ui.Text("activity.next_page"));
        SetButtonName(SettingsButton, ui.Text("common.settings"));
        RefreshMenu.Header = ui.Text("common.refresh"); QuitMenu.Header = ui.Text("common.quit"); SettingsMenu.Header = ui.Text("common.settings");
        // Hover and connection errors can expand the HWND before the first
        // engine snapshot. Give every measured lane a real initial value.
        RatePanel.Visibility = StripRatePanel.Visibility = Visibility.Collapsed;
        InitializeCompactBar();
        TasksCount.Text = "0"; MarkReadButton.IsEnabled = false;
        collapse.Tick += (_, _) => { collapse.Stop(); if (!pinned) SetExpanded(false); };
        navigationErrorDismiss.Tick += (_, _) => ClearNavigationError();
        engine.Snapshot += value => Dispatcher.InvokeAsync(() => Render(value));
        engine.Status += value => Dispatcher.InvokeAsync(() => SetStatus(ui.Text(value == "engineStopped" ? "windows.connection.closed" : "windows.connection.refresh_failed")));
        ShellProjection.Changed += OnShellProjectionChanged;
        Loaded += (_, _) => OnShellProjectionChanged("");
        Closing += OnClosing;
        Closed += (_, _) => StopPresentation();
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
        IsVisibleChanged += (_, _) =>
        {
            if (presentationStopped) return;
            if (!IsVisible) StopRendering();
            else StartRendering();
            SyncBackdrop();
        };
        ApplyPresentationLayout();
        InitializeBackdrop();
        InitializeOcclusion();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new IslandWindowAutomationPeer(this);
    internal Rect VisibleScreenBounds
    {
        get
        {
            if (!IsVisible || PresentationSource.FromVisual(this) == null) return Rect.Empty;
            var point = Shell.PointToScreen(new Point()); var dpi = VisualTreeHelper.GetDpi(this);
            return new(point.X, point.Y, Shell.ActualWidth * dpi.DpiScaleX, Shell.ActualHeight * dpi.DpiScaleY);
        }
    }
    internal double VisibleWidth => Shell.ActualWidth;
    internal double VisibleHeight => Shell.ActualHeight;
    private static void SetButtonName(Button button, string title) { button.ToolTip = title; AutomationProperties.SetName(button, title); }
    private void OnSystemParametersChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName != null && args.PropertyName != nameof(SystemParameters.ClientAreaAnimation)) return;
        Dispatcher.InvokeAsync(() =>
        {
            if (presentationStopped) return;
            UpdateCompactBar();
            foreach (var row in TaskRowsIn(TaskPages)) row.SetAnimations(AnimationsEnabled);
            if (rendering) OnRenderFrame(this, EventArgs.Empty);
        });
    }
    private void OnShellProjectionChanged(string method)
    {
        if (method.Length > 0 && method != "projectCompactBar") return;
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (presentationStopped) return;
            UpdateCompactBar(); Relayout();
        });
    }
    internal void SetStatus(string value)
    {
        if (presentationStopped) return;
        navigationErrorDismiss.Stop(); navigationErrorShown = false;
        StatusLabel.Text = value; StatusLabel.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
        Reveal(); Relayout();
    }
    private void ShowNavigationError(string value)
    {
        if (presentationStopped) return;
        navigationErrorDismiss.Stop(); navigationErrorShown = true;
        StatusLabel.Text = value; StatusLabel.Visibility = Visibility.Visible;
        SetExpanded(true); Relayout();
        navigationErrorDismiss.Interval = TimeSpan.FromSeconds(NativeTaskRowTiming.Shared.NavigationErrorDuration);
        navigationErrorDismiss.Start();
    }
    private void ClearNavigationError()
    {
        navigationErrorDismiss.Stop();
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
            animationPhaseLocked = false, rows = rows.Skip(page * 3).Take(3), header = latest?.Presentation?.Header
        }, new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    }
    internal async Task WaitForPresentationAsync()
    {
        await ShellProjection.WhenIdleAsync();
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        var timeout = Stopwatch.StartNew();
        while (rendering || renderCallback || !lastFrame.Finished || !VisibleSizeMatches(destination.Width, destination.Height) || !CompactDimStateMatches())
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
    internal void Reveal() { if (presentationStopped) return; RecordInteraction("reveal"); Show(); SetPinned(true); SetExpanded(true); }
    internal Task SynchronizeExpansionAsync() => Send("setExpanded", new { expanded });
    internal void ApplyPreferences(DesktopPreferences preferences)
    {
        compactPreferences = preferences;
        PreferSurface(preferences.IslandAppearance);
        position = Array.IndexOf(new[] { "center", "topLeft", "bottomLeft", "topRight", "bottomRight" }, preferences.Position);
        displayMode = Array.IndexOf(new[] { "automatic", "notch", "floating" }, preferences.DisplayMode);
        showAppButtons = preferences.ShowAppButtons;
        if (expandedQuotaStyle != preferences.ExpandedQuotaStyle || deepseekPanelStyle != preferences.DeepSeekPanelStyle)
        {
            expandedQuotaStyle = preferences.ExpandedQuotaStyle;
            deepseekPanelStyle = preferences.DeepSeekPanelStyle;
            if (latest != null) RenderQuota(latest);
        }
        UpdateAppButtons(); UpdateCompactBar(); Relayout();
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
    private void OnMouseEnter(object sender, MouseEventArgs e) { RecordInteraction("hover-in"); collapse.Stop(); SetExpanded(true); }
    private void OnMouseLeave(object sender, MouseEventArgs e) { RecordInteraction("hover-out"); if (!pinned && !MoreButton.ContextMenu.IsOpen) collapse.Start(); }
    private void OnHeaderClick(object sender, MouseButtonEventArgs e) { SetPinned(!pinned); SetExpanded(true); }
    private void OnPin(object sender, RoutedEventArgs e) => SetPinned(!pinned);
    private void SetPinned(bool value)
    {
        pinned = value;
        PinButton.Background = value ? PacerPalette.Hover : Brushes.Transparent;
        PinButton.Foreground = value ? PacerPalette.Primary : PacerPalette.Secondary;
        ((IconGlyph)PinButton.Content).Symbol = value ? "pin.fill" : "pin";
        SetButtonName(PinButton, ui.Text(value ? "common.unpin" : "common.pin"));
    }
    private async void OnMarkRead(object sender, RoutedEventArgs e) { if (latest != null) await Send("markAllRead", new { snapshotSequence = latest.Sequence }); }
    private async void OnRefresh(object sender, RoutedEventArgs e) => await Send("refresh", new { discover = true });
    private void OnQuit(object sender, RoutedEventArgs e) => QuitRequested?.Invoke();
    private void OnSettings(object sender, RoutedEventArgs e)
    { DismissForSettings(); SettingsRequested?.Invoke(); }
    internal void DismissForSettings()
    { MoreButton.ContextMenu.IsOpen = false; SetPinned(false); SetExpanded(false); }
    private void OnMore(object sender, RoutedEventArgs e)
    {
        collapse.Stop(); MoreButton.ContextMenu.PlacementTarget = MoreButton; MoreButton.ContextMenu.IsOpen = true;
    }
    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { RecordInteraction("escape"); SetPinned(false); SetExpanded(false); e.Handled = true; }
        if ((Keyboard.Modifiers & ModifierKeys.Alt) != 0 && e.Key is Key.Left or Key.Right) { ChangePage(e.Key == Key.Left ? -1 : 1); e.Handled = true; }
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
    private void OnClosing(object? sender, CancelEventArgs e) { if (!AllowClose) { e.Cancel = true; Hide(); } }
    private void SetExpanded(bool value)
    {
        collapse.Stop();
        if (value == expanded) return;
        if (!value) Keyboard.ClearFocus();
        expanded = value;
        UIElementAutomationPeer.FromElement(this)?.RaisePropertyChangedEvent(ExpandCollapsePatternIdentifiers.ExpandCollapseStateProperty,
            value ? ExpandCollapseState.Collapsed : ExpandCollapseState.Expanded,
            value ? ExpandCollapseState.Expanded : ExpandCollapseState.Collapsed);
        SetCompactDimState(value, true); Relayout(); _ = Send("setExpanded", new { expanded = value });
    }
    private IslandLayout MeasureLayout(double contentWidth, double contentHeight, double headerWidth, bool open)
    {
        var current = IslandScreen.Read(this);
        var bounds = screenGeometry?.Invoke() ?? (current.Screen, current.Work);
        return geometry.Measure(bounds.Item1, bounds.Item2, displayMode, 0, 0, position, open, contentWidth, contentHeight, headerWidth, measuredStripHeight);
    }
    private void Relayout()
    {
        double Probe(string text, double size, FontWeight weight)
        {
            var label = new TextBlock { Text = text, FontFamily = RateLabel.FontFamily, FontSize = size, FontWeight = weight };
            System.Windows.Documents.Typography.SetNumeralAlignment(label, FontNumeralAlignment.Tabular);
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return label.DesiredSize.Width;
        }
        // Never reuse a constrained lane's measured size as its natural width.
        // The native header also measures a separate, unconstrained copy.
        RateUnit.Width = Math.Max(NativeTypography.RateUnitWidth, Probe("t/s", 9, FontWeights.Medium));
        double measuredHeader = MeasureCompactBar().Header;
        double rowsHeight = rows.Count == 0 ? 44 : Math.Min(3, rows.Count) * 54 + (Math.Min(3, rows.Count) - 1) * 2;
        TaskToolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double contentWidth = Math.Max(measuredRowsWidth + 12, TaskToolbar.DesiredSize.Width + 12);
        var widthProbe = MeasureLayout(contentWidth, 0, measuredHeader, expanded);
        double availableContentWidth = Math.Max(1, widthProbe.CanvasWidth - 12 - (widthProbe.Position != 0 ? 32 : 0));
        QuotaSlots.Measure(new Size(availableContentWidth, double.PositiveInfinity));
        double quotaHeight = latest == null ? 133 : Math.Max(0, QuotaSlots.DesiredSize.Height - QuotaSlots.Margin.Top - QuotaSlots.Margin.Bottom);
        double contentHeight = 4 + 24 + 4 + rowsHeight + 21 + 24 + 8 + quotaHeight + 4 + 14;
        if (StatusLabel.Visibility == Visibility.Visible) { StatusLabel.Measure(new Size(availableContentWidth, double.PositiveInfinity)); contentHeight += StatusLabel.DesiredSize.Height; }
        // IslandModel.updateMeasuredContentHeight also rounds upward. A
        // fractional text line must not create a scrollbar and narrow the
        // already measured content when geometry snaps the panel to points.
        contentHeight = Math.Ceiling(contentHeight);
        layout = MeasureLayout(contentWidth, contentHeight, measuredHeader, expanded);
        ApplyPresentationLayout();
        bool blackHeader = layout.Attached && islandAppearance == "liquidGlass";
        if (layout.Target == destination && destinationExpanded == expanded && destinationBlackHeader == blackHeader) return;
        destination = layout.Target;
        destinationExpanded = expanded;
        destinationBlackHeader = blackHeader;
        motionRevision++;
        Expanded.Visibility = Visibility.Visible;
        transitionStarted = Clock(); motion.RetargetTo(destination, expanded, transitionStarted, blackHeader, layout.Position);
        PrepareSurface();
        // Allocation can wait on the system compositor. Start the displayed
        // transition after that work, retaining the same last displayed sample.
        transitionStarted = Clock(); motion.RetargetTo(destination, expanded, transitionStarted, blackHeader, layout.Position);
        if (!AnimationsEnabled) { StopRendering(); ApplyMotion(motion.SettledAt(transitionStarted)); }
        else StartRendering();
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
        Header.Visibility = side ? Visibility.Collapsed : Visibility.Visible;
        Strip.Visibility = side ? Visibility.Visible : Visibility.Collapsed;
        Strip.HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        Expanded.Width = Math.Max(1, layout.CanvasWidth - 12 - (side ? 32 : 0));
        Expanded.Height = Math.Max(1, layout.CanvasHeight - (side ? 0 : layout.HeaderHeight));
        Expanded.HorizontalAlignment = side ? left ? HorizontalAlignment.Left : HorizontalAlignment.Right : HorizontalAlignment.Center;
        Expanded.VerticalAlignment = effective is 2 or 4 ? VerticalAlignment.Bottom : VerticalAlignment.Top;
        Expanded.Margin = side ? new Thickness(left ? 38 : 6, 0, left ? 6 : 38, 0) : new Thickness(6, layout.HeaderHeight, 6, 0);
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
            MotionFrame frame = AnimationsEnabled ? motion.At(Clock()) : motion.SettledAt(Math.Max(Clock(), transitionStarted)); ApplyMotion(frame);
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
        double started = Clock();
        PlaceShell(frame.Window);
        boundsMilliseconds += (Clock() - started) * 1000; started = Clock();
        double radius = 19 + 8 * frame.Expansion;
        int effective = layout.Position;
        Shell.CornerRadius = effective is 1 or 2 ? new(0, radius, radius, 0) : effective is 3 or 4 ? new(radius, 0, 0, radius)
            : layout.Attached ? new(0, 0, radius, radius) : new(radius);
        Shell.Clip = ClipShape(frame.Window.Width, frame.Window.Height, Shell.CornerRadius);
        Expanded.Opacity = frame.Content;
        RevealOffset.X = effective == 0 ? 0 : (effective is 1 or 2 ? 1 : -1) * (1 - frame.Content) * 8;
        RevealOffset.Y = effective == 0 ? (1 - frame.Content) * 8 : 0;
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
        ShellProjection.Changed -= OnShellProjectionChanged;
        presentationStopped = true; StopRendering(); DisposeOcclusion(); DisposeBackdrop(); motion.Dispose(); collapse.Stop(); navigationErrorDismiss.Stop(); QuotaLabel.Stop(); StripQuota.Stop();
        foreach (var clock in pageClocks) clock.Dispose(); pageClocks.Clear();
        foreach (var clock in dimClocks.Values) clock.Dispose(); dimClocks.Clear();
        SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
    }
    private async Task Send(string method, object? parameters = null)
    {
        try { await engine.SendAsync(method, parameters); }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or InvalidOperationException) { }
    }
    internal void ReceiveSnapshot(EngineSnapshot snapshot) => Render(snapshot);

    private void Render(EngineSnapshot snapshot)
    {
        if (presentationStopped) return;
        bool linksChanged = !(latest?.ActivityLinks ?? []).SequenceEqual(snapshot.ActivityLinks ?? []);
        latest = snapshot;
        if (openingActivityContext != null && snapshot.ActivityLinks?.Any(link => link.Context == openingActivityContext) != true) openingActivityContext = null;
        UpdateAppButtons();
        if (snapshot.Presentation is not EnginePresentation presentation) { SetStatus(ui.Text("windows.restart_required")); return; }
        MarkReadButton.IsEnabled = presentation.Rows.Any(row => row.Unread && row.Phase is "completed" or "interrupted");
        UpdateCompactBar(); HeaderTrailing.InvalidateMeasure();
        if (!rows.SequenceEqual(presentation.Rows))
        {
            rows = presentation.Rows; page = Math.Clamp(page, 0, presentation.PageCount - 1); BuildPage(false, 0);
        }
        else if (linksChanged) foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row);
        TasksCount.Text = presentation.TaskCountText ?? "—";
        UpdatePager();
        RenderQuota(snapshot);
        Relayout();
    }
    private void RenderQuota(EngineSnapshot snapshot)
    {
        QuotaSlots.Children.Clear(); QuotaSlots.ColumnDefinitions.Clear();
        string connectUnavailable = ui.Text(demo ? "windows.deepseek.demo_web_help" : "windows.deepseek.runtime_required");
        var layout = snapshot.QuotaDashboard is { SchemaVersion: 1 } data ? expandedQuotaStyle == "classic" ? data.Classic : data.Split : null;
        if (layout?.Kind == "legacyCodex" && snapshot.QuotaDashboard is { LegacyCodex: not null } legacy)
            QuotaSlots.Children.Add(new LegacyQuotaView(legacy.LegacyCodex, ui,
                snapshot.Sources.FirstOrDefault(source => source.Provider == "codex" && source.Transport == "app-server")?.Reason,
                QuotaStatus(legacy.Providers.FirstOrDefault(value => value.Provider == "codex"))));
        else if (layout?.Kind == "classicRings" && snapshot.QuotaDashboard is { SchemaVersion: 1 } classic)
            QuotaSlots.Children.Add(new ClassicQuotaView(classic, snapshot.Quota, snapshot.Wallet, ui, QuotaStatus, DeepSeekConnectAction(snapshot), connectUnavailable, DeepSeekStatus(snapshot)));
        else if (layout?.Kind == "splitSingle" && snapshot.QuotaDashboard is { Providers.Count: 1 } single)
        {
            var provider = single.Providers[0];
            var help = snapshot.Sources.FirstOrDefault(source => source.Provider == provider.Provider && source.Transport == "app-server")?.Reason;
            QuotaSlots.Children.Add(new SingleQuotaView(provider, snapshot.Quota.FirstOrDefault(value => value.Provider == provider.Provider), ui, help, QuotaStatus(provider)));
        }
        else if (layout?.Kind == "deepseekSolo") QuotaSlots.Children.Add(new DeepSeekSoloView(snapshot.Wallet, ui, deepseekPanelStyle == "detailed", connectAction: DeepSeekConnectAction(snapshot), connectUnavailable: connectUnavailable, balanceStatus: DeepSeekStatus(snapshot)));
        else
        {
            string[] providers = layout?.Slots.Select(value => value.Provider).ToArray()
                ?? snapshot.Sources.Select(source => source.Provider).Distinct().OrderBy(provider => provider == "codex" ? 0 : provider == "claude" ? 1 : 2).ToArray();
            for (int index = 0; index < providers.Length; index++)
            {
                if (index > 0) QuotaSlots.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
                int column = QuotaSlots.ColumnDefinitions.Count;
                QuotaSlots.ColumnDefinitions.Add(new ColumnDefinition());
                var help = snapshot.Sources.FirstOrDefault(source => source.Provider == providers[index] && source.Transport == "app-server")?.Reason;
                var dashboard = snapshot.QuotaDashboard is { SchemaVersion: 1 } projected ? projected.Providers.FirstOrDefault(value => value.Provider == providers[index]) : null;
                FrameworkElement cell = providers[index] == "deepseek" ? new DeepSeekQuotaCell(snapshot.Wallet, ui, connectAction: DeepSeekConnectAction(snapshot), connectUnavailable: connectUnavailable, balanceStatus: DeepSeekStatus(snapshot))
                    : new QuotaCell(providers[index], snapshot.Quota.FirstOrDefault(q => q.Provider == providers[index]), snapshot.Wallet, help, dashboard, QuotaStatus(dashboard));
                Grid.SetColumn(cell, column); QuotaSlots.Children.Add(cell);
            }
        }
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
        int count = Math.Max(1, (rows.Count + 2) / 3);
        PageControls.Visibility = count > 1 ? Visibility.Visible : Visibility.Collapsed;
        PageNumber.Text = $"{page + 1} / {count}";
        PreviousPage.IsEnabled = page > 0; NextPage.IsEnabled = page + 1 < count;
    }
    private void ChangePage(int delta)
    {
        int target = Math.Clamp(page + delta, 0, Math.Max(0, (rows.Count - 1) / 3));
        if (target == page) return;
        page = target; BuildPage(AnimationsEnabled, Math.Sign(delta)); UpdatePager(); Relayout();
    }
    private void BuildPage(bool animate, int direction)
    {
        foreach (var clock in pageClocks) clock.Dispose(); pageClocks.Clear();
        RevealHost? outgoing = currentPage;
        var content = new StackPanel { VerticalAlignment = VerticalAlignment.Top };
        var incoming = new RevealHost { VerticalAlignment = VerticalAlignment.Top, RenderTransform = new TranslateTransform() };
        incoming.Children.Add(content); incoming.SetAccessible(true);
        AutomationProperties.SetName(incoming, ui.Text(rows.Count > 3 ? "activity.page_region" : "activity.task_list"));
        TaskPages.Height = rows.Count == 0 ? 44 : Math.Min(rows.Count, 3) * 54 + (Math.Min(rows.Count, 3) - 1) * 2;
        measuredRowsWidth = 0;
        int index = 0;
        foreach (var value in rows.Skip(page * 3).Take(3))
        {
            var row = new TaskRow(value) { Language = Language, Margin = new Thickness(0, index++ == 0 ? 0 : 2, 0, 0) };
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
            outgoing.IsHitTestVisible = false; outgoing.SetAccessible(false);
            KeyboardNavigation.SetTabNavigation(outgoing, KeyboardNavigationMode.None);
            if (outgoing.IsKeyboardFocusWithin) Keyboard.ClearFocus();
        }
        TaskPages.Children.Clear(); currentPage = incoming;
        if (animate && outgoing != null)
        {
            TaskPages.Children.Add(outgoing);
            var fade = new DoubleAnimation(outgoing.Opacity, 0, TimeSpan.FromSeconds(0.18));
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
        bool available = harness || (link != null && openingActivityContext == null);
        row.SetOpenAction(available ? harness ? () => _ = OpenHarnessTaskAsync(row) : () => _ = OpenConversationTaskAsync(row, link!) : null,
            available ? state.AccessibleName + "\n" + ui.Text("common.open_chat") : ui.Text("activity.no_link"), AnimationsEnabled);
    }
    private bool CurrentConversationAction(TaskRow control, EngineActivityLink link) => !presentationStopped && expanded && Expanded.IsAccessible &&
        currentPage?.IsAccessible == true && currentPage.IsAncestorOf(control) && latest?.ActivityLinks?.Contains(link) == true;
    private bool CurrentConversationLink(EngineActivityLink link) => !presentationStopped && latest?.ActivityLinks?.Contains(link) == true;
    private bool CurrentConversationPanel(EngineActivityLink link) => CurrentConversationLink(link) && expanded && Expanded.IsAccessible &&
        currentPage?.IsAccessible == true && rows.Skip(page * 3).Take(3).Any(row => row.Id == link.ActivityID);
    private async Task OpenConversationTaskAsync(TaskRow control, EngineActivityLink link)
    {
        if (openingActivityContext != null || !CurrentConversationAction(control, link)) return;
        openingActivityContext = link.Context; ClearNavigationError();
        foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row);
        try
        {
            var plan = await engine.QueryAsync<EngineNavigationPlan>("prepareActivityOpen", new { context = link.Context });
            if (!CurrentConversationPanel(link) || plan.Context != link.Context || plan.Provider != link.Provider) return;
            bool opened = await openConversation(plan, rows.First(row => row.Id == link.ActivityID));
            if (!CurrentConversationLink(link)) return;
            if (!opened) { ShowNavigationError(ui.Text("activity.open_failed")); return; }
            if (CurrentConversationPanel(link)) DismissForSettings();
            // A source/ending token survives unrelated rate ticks. The engine
            // rejects a newer turn or changed source rather than clearing it.
            try { await engine.SendAsync("completeActivityOpen", new { context = link.Context }); }
            catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException) { }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException)
        {
            if (CurrentConversationLink(link)) ShowNavigationError(ui.Text(error is EngineCommandException command ? command.Code switch {
                "missingClaudeHost" => "activity.claude_host_missing", "missingCodexHost" => "activity.codex_host_missing", _ => "activity.open_failed"
            } : "activity.open_failed"));
        }
        finally
        {
            if (openingActivityContext == link.Context) openingActivityContext = null;
            if (!presentationStopped) foreach (var row in TaskRowsIn(TaskPages)) BindTaskAction(row);
        }
    }
    private Task<bool> OpenConversationAsync(EngineNavigationPlan plan, EngineTaskRow row)
    {
        if (plan.Kind != "demo") return desktopApplications?.OpenConversationAsync(plan) ?? Task.FromResult(false);
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
    private async Task OpenHarnessTaskAsync(TaskRow control)
    {
        if (presentationStopped || !expanded || !Expanded.IsAccessible || currentPage?.IsAccessible != true || !currentPage.IsAncestorOf(control)) return;
        var row = ((TaskRowState)control.DataContext).Value;
        ClearNavigationError();
        ulong? sequence = latest?.Sequence;
        if (desktopApplications?.Open("deepseek") != true)
        { ShowNavigationError(ui.Text(desktopApplications?.CanOpenHarness == true ? "windows.app.open_failed" : "deepseek.app_missing")); return; }
        if (row.Unread && row.Phase is "completed" or "interrupted" && sequence != null)
        {
            try { await engine.SendAsync("markRead", new { activityID = row.Id, snapshotSequence = sequence.Value }); }
            catch (Exception error) when (error is IOException or OperationCanceledException or EngineCommandException) { }
        }
        if (!presentationStopped) DismissForSettings();
    }
    private static DoubleAnimationUsingKeyFrames PageAnimation(double from, double to)
    {
        var animation = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(0.18) };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        animation.KeyFrames.Add(new SplineDoubleKeyFrame(to, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.18)), new KeySpline(0.42, 0, 0.58, 1)));
        return animation;
    }
}
