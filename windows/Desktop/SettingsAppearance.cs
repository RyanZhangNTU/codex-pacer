using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private RadioButton? notchChoice, freeChoice;
    private FrameworkElement? positionRow;
    private Button? positionReset;
    private readonly Dictionary<string, RadioButton> quotaStyleChoices = new();
    private readonly Dictionary<string, RadioButton> surfaceChoices = new(), barSizeChoices = new();
    private TextBlock? surfaceStatus, transparencyMode;
    private FrameworkElement? transparencyRow, expandedQuotaRow, deepseekPanelRow;
    private ComboBox? displayChoice;
    private CheckBox? fullscreenChoice;
    private TextBlock? displayStatus;
    private IReadOnlyList<DisplayMonitor>? displayItemsSource;
    private sealed record DisplayOption(string Mode, DisplayMonitor? Monitor);

    private void ClearAppearance()
    { ClearAppearanceTheme(); notchChoice = freeChoice = null; positionRow = null; quotaStyleChoices.Clear(); surfaceChoices.Clear(); barSizeChoices.Clear(); surfaceStatus = transparencyMode = null;
        displayChoice = null; fullscreenChoice = null; displayStatus = null; displayItemsSource = null; transparencyRow = expandedQuotaRow = deepseekPanelRow = null; }
    private TextBlock SectionHeader(string key) => SectionTitle(ui.Text(key));
    /// A picture choice, as on the Mac: the art (64 tall, or its own height when NaN), then its name 7 below.
    private RadioButton ArtChoice(string id, string name, string group, UIElement art, bool enabled = true, double artHeight = 64)
    {
        var choice = new RadioButton { Style = (Style)FindResource("SettingsArtChoice"), GroupName = group, IsEnabled = enabled };
        var content = new StackPanel();
        var artHost = new Grid { Height = artHeight }; artHost.Children.Add(art); content.Children.Add(artHost);
        var title = Label(name, 12); title.HorizontalAlignment = HorizontalAlignment.Center; title.Margin = new Thickness(0, 7, 0, 0);
        title.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = choice });
        title.SetBinding(TextBlock.FontWeightProperty, new System.Windows.Data.Binding(nameof(FontWeight)) { Source = choice });
        content.Children.Add(title); choice.Content = content; Identify(choice, id, name); return choice;
    }
    private static Grid Pair(UIElement left, UIElement right)
    {
        var grid = new Grid { Margin = new Thickness(14, 14, 14, 14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(left); Grid.SetColumn(right, 2); grid.Children.Add(right); return grid;
    }
    private void Pending(FrameworkElement element, string key)
    { element.IsEnabled = false; element.ToolTip = ui.Text(key); ToolTipService.SetShowOnDisabled(element, true); }
    private void BuildAppearance()
    {
        // Theme, then Material (the island's surface), then Accent, then Position, as on the Mac.
        BuildThemeSection();
        form.Children.Add(ThemeSectionsAvailable && ui.Has("appearance.material") ? SectionTitle(ui.Text("appearance.material")) : SectionHeader("appearance.style"));
        var solid = ArtChoice("appearance.style.classic", ui.Text("settings.classic"), "appearance.styles", StyleSwatch("classic"));
        var glass = ArtChoice("appearance.style.liquidGlass", ui.Text("settings.liquid_glass"), "appearance.styles", StyleSwatch("liquidGlass"));
        var lightGlass = ArtChoice("appearance.style.liquidGlassLight", ui.Text("settings.liquid_glass_light"), "appearance.styles", StyleSwatch("liquidGlassLight"));
        var graphite = ArtChoice("appearance.style.graphite", ui.Text("settings.graphite"), "appearance.styles", StyleSwatch("graphite"));
        foreach (var choice in new[] { (Name: "classic", Button: solid), (Name: "liquidGlass", Button: glass), (Name: "liquidGlassLight", Button: lightGlass), (Name: "graphite", Button: graphite) })
        {
            surfaceChoices[choice.Name] = choice.Button; editors.Add(choice.Button);
            if (ui.Has("appearance.material_info." + choice.Name)) choice.Button.ToolTip = ui.Text("appearance.material_info." + choice.Name);
            choice.Button.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { IslandAppearance = choice.Name }); };
        }
        surfaceStatus = Detail(""); surfaceStatus.Margin = new Thickness(14, 8, 14, 12);
        Identify(surfaceStatus, "appearance.status", ui.Text("appearance.style"));
        var adjust = new Button { Content = ui.Text("appearance.glass_adjust"), VerticalAlignment = VerticalAlignment.Center };
        Identify(adjust, "appearance.transparency.settings", ui.Text("appearance.glass_adjust"));
        adjust.Click += (_, _) => { if (!SettingsPagePolicy.OpenTransparency(systemSettingsLauncher)) ShowIssue("windows.settings.open_system_failed"); };
        var transparencyEnd = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        transparencyMode = Label(ui.Text("appearance.glass_system"), 12.5); transparencyMode.Margin = new Thickness(0, 0, 8, 0); transparencyMode.VerticalAlignment = VerticalAlignment.Center;
        transparencyMode.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        transparencyEnd.Children.Add(transparencyMode); transparencyEnd.Children.Add(adjust);
        transparencyRow = InfoRow(ui.Text("appearance.glass_transparency"), transparencyEnd, ui.Text("windows.appearance.surface_available"), id: "appearance.transparency");
        form.Children.Add(Card(Pair(solid, graphite), Pair(glass, lightGlass), surfaceStatus, transparencyRow));
        // The collapsed bar's size: every length and type size scales together.
        var sizeChoices = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (string size in DesktopPreferences.BarSizes)
        {
            string text = ui.Text("appearance.bar_size." + size);
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), Content = text, GroupName = "appearance.barSize", VerticalAlignment = VerticalAlignment.Center };
            Identify(choice, "appearance.bar_size." + size, text);
            choice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { CompactBarSize = size }); };
            barSizeChoices[size] = choice; editors.Add(choice); sizeChoices.Children.Add(choice);
        }
        var sizeTrack = new Border { Child = sizeChoices, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        sizeTrack.SetResourceReference(Border.BackgroundProperty, "SettingsFill"); Identify(sizeTrack, "appearance.bar_size", ui.Text("appearance.bar_size"));
        form.Children.Add(Card(InfoRow(ui.Text("appearance.bar_size"), sizeTrack, ui.Text("appearance.bar_size_info"), id: "appearance.bar_size.row")));

        var quotaChoices = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (string style in new[] { "split", "classic" })
        {
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), Content = ui.Text("appearance.quota_" + style), GroupName = "appearance.quota", VerticalAlignment = VerticalAlignment.Center };
            Identify(choice, "appearance.quota." + style, ui.Text("appearance.quota_" + style));
            choice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { ExpandedQuotaStyle = style }); };
            quotaStyleChoices[style] = choice; editors.Add(choice); quotaChoices.Children.Add(choice);
        }
        var segments = new Border { Child = quotaChoices, Padding = new Thickness(2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        segments.SetResourceReference(Border.BackgroundProperty, "SettingsFill");
        // The expanded panel's choices follow Position, as on the Mac.
        expandedQuotaRow = Row(Label(ui.Text("main.appearance.quota_style")), segments);
        BuildAccentSection();
        form.Children.Add(SectionHeader("appearance.position"));
        // Both positions are shown moving, with the welcome guide's scenes, as on the Mac.
        notchChoice = ArtChoice("appearance.mode.notch", ui.Text("settings.notch"), "appearance.modes", ModeScene(new WelcomeGestureScene()), artHeight: double.NaN);
        freeChoice = ArtChoice("appearance.mode.free", ui.Text("appearance.free_move"), "appearance.modes", ModeScene(new WelcomeMoveScene(true)), artHeight: double.NaN);
        notchChoice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { DisplayMode = "notch" }); };
        freeChoice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { DisplayMode = "floating" }); };
        editors.Add(notchChoice); editors.Add(freeChoice);
        var reset = positionReset = new Button { Content = ui.Text("appearance.position_reset"), VerticalAlignment = VerticalAlignment.Center };
        Identify(reset, "appearance.position.reset", ui.Text("appearance.position_reset"));
        reset.Click += async (_, _) => await Change(p => p with { IslandPlacement = null, Position = "center", PositionChosen = false, DisplayMode = "floating" });
        editors.Add(reset);
        positionRow = InfoRow(ui.Text("appearance.free_move_detail"), reset);
        displayChoice = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = 150, MaxWidth = 270 };
        Identify(displayChoice, "appearance.display", ui.Text("settings.display_picker")); editors.Add(displayChoice);
        displayChoice.DropDownOpened += (_, _) => appearanceDisplays.Refresh();
        displayChoice.SelectionChanged += async (_, _) =>
        {
            if (synchronizing || displayChoice.SelectedItem is not ComboBoxItem { Tag: DisplayOption option, IsEnabled: true }) return;
            await Change(p => option.Monitor?.Choose(p) ?? p with { DisplaySelection = option.Mode, DisplayID = "", DisplayName = "", DisplayX = 0, DisplayY = 0 });
        };
        var displayCaption = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; displayCaption.Children.Add(Label(ui.Text("settings.display_picker")));
        displayStatus = Detail(""); displayStatus.MaxWidth = 230; Identify(displayStatus, "appearance.display.status", ui.Text("settings.display_picker")); displayCaption.Children.Add(displayStatus);
        var fullscreen = Toggle("windows.appearance.fullscreen", null, "appearance.fullscreen", out var full); fullscreenChoice = full;
        BindToggle(full, (p, value) => p with { ShowInFullscreen = value }); editors.Add(full);
        var positionCard = Card(Pair(notchChoice, freeChoice), positionRow, Row(displayCaption, displayChoice), fullscreen);
        form.Children.Add(positionCard);
        deepseekPanelRow = Row(Label(ui.Text("main.appearance.deepseek_panel")), DeepSeekSegments("panel", new[] { ("simple", "deepseek.panel_style.simple"), ("detailed", "deepseek.panel_style.detailed") }, value => ChangeDeepSeek(p => p with { DeepSeekPanelStyle = value })));
        var apps = Toggle("settings.app_buttons", "main.info.app_buttons", "settings.app_buttons", out var appsSwitch); appButtons = appsSwitch;
        BindToggle(appsSwitch, (p, value) => p with { ShowAppButtons = value }); editors.Add(appsSwitch);
        form.Children.Add(SectionTitle(ui.Text("main.appearance.panel"))); form.Children.Add(Card(expandedQuotaRow, deepseekPanelRow, apps));
    }
    private void RefreshAppearance()
    {
        RefreshAppearanceTheme();
        RefreshDisplayChoices();
        if (fullscreenChoice != null) fullscreenChoice.IsChecked = session.Current.ShowInFullscreen;
        foreach (var item in surfaceChoices) item.Value.IsChecked = item.Key == session.Current.IslandAppearance;
        // Windows has no camera housing to match, so every size is available.
        foreach (var item in barSizeChoices) item.Value.IsChecked = item.Key == session.Current.CompactBarSize;
        RefreshSurfaceStatus();
        if (expandedQuotaRow != null) expandedQuotaRow.Visibility = SettingsPagePolicy.ShowExpandedQuotaStyle(CompactProviders()) ? Visibility.Visible : Visibility.Collapsed;
        // DeepSeek alone has its own dashboard, so the panel offers Simple or Detailed instead.
        if (deepseekPanelRow != null) deepseekPanelRow.Visibility = CompactProviders() is ["deepseek"] ? Visibility.Visible : Visibility.Collapsed;
        if (appButtons != null) appButtons.IsChecked = session.Current.ShowAppButtons;
        foreach (var choice in deepseekChoices.Where(value => value.Key.StartsWith("panel.", StringComparison.Ordinal)))
            choice.Value.IsChecked = choice.Key == "panel." + session.Current.DeepSeekPanelStyle;
        foreach (var item in quotaStyleChoices) item.Value.IsChecked = item.Key == session.Current.ExpandedQuotaStyle;
        if (notchChoice == null || freeChoice == null || positionRow == null) return;
        bool attached = session.Current.DisplayMode == "notch";
        notchChoice.IsChecked = attached; freeChoice.IsChecked = !attached;
        positionRow.Visibility = attached ? Visibility.Collapsed : Visibility.Visible;
        // Nothing to return when the island already sits at the top center, as on the Mac.
        if (positionReset != null) positionReset.IsEnabled = !busy && (session.Current.IslandPlacement != null || session.Current.Position != "center");
    }
    private void OnAppearanceDisplaysChanged()
    {
        if (sourceClosed) return;
        bool previous = synchronizing; synchronizing = true;
        try { RefreshDisplayChoices(); }
        finally { synchronizing = previous; }
    }
    private void RefreshDisplayChoices()
    {
        if (displayChoice == null) return;
        var topology = appearanceDisplays.Current;
        if (!ReferenceEquals(displayItemsSource, topology))
        {
            displayChoice.Items.Clear(); displayItemsSource = topology;
            Add(ui.Text("settings.main_display"), new("primary", null));
            foreach (var monitor in topology) Add(monitor.Name + " (" + (monitor.Bounds.Right - monitor.Bounds.Left) + " × " + (monitor.Bounds.Bottom - monitor.Bounds.Top) + ")", new("specified", monitor));
        }
        var resolved = DisplaySelection.Resolve(topology, session.Current);
        var missing = displayChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(value => value.Tag is DisplayOption { Mode: "missing" });
        if (missing != null) displayChoice.Items.Remove(missing);
        ComboBoxItem? selected;
        if (session.Current.DisplaySelection == "specified" && resolved.FellBack)
        {
            selected = Add(session.Current.DisplayName + " (" + ui.Text("windows.appearance.display_disconnected") + ")", new("missing", null));
            selected.IsEnabled = false;
        }
        else
        {
            string mode = session.Current.DisplaySelection == "automatic" ? "primary" : session.Current.DisplaySelection;
            selected = displayChoice.Items.Cast<ComboBoxItem>().FirstOrDefault(value => value.Tag is DisplayOption option
                && option.Mode == mode && (option.Mode != "specified" || option.Monitor == resolved.Display));
        }
        displayChoice.SelectedItem = selected;
        if (displayStatus != null)
        {
            displayStatus.Text = topology.Count == 0 ? ui.Text("windows.appearance.display_unavailable")
                : resolved.FellBack ? ui.Text("windows.appearance.display_fallback") : "";
            displayStatus.Visibility = displayStatus.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        ComboBoxItem Add(string text, DisplayOption option)
        {
            var item = new ComboBoxItem { Content = text, ContentTemplate = (DataTemplate)FindResource("SettingsChoiceText"), Tag = option, ToolTip = text };
            System.Windows.Automation.AutomationProperties.SetName(item, text); displayChoice.Items.Add(item); return item;
        }
    }
    private void RefreshSurfaceStatus()
    {
        if (surfaceStatus == null) return;
        var state = appearance.Current;
        var decision = surfaceWindow?.SurfaceDecision ?? BackdropPolicy.Resolve(session.Current.IslandAppearance,
            new(state.Build, state.Transparency, state.HighContrast, state.Available));
        bool glassChosen = session.Current.IslandAppearance is "liquidGlass" or "liquidGlassLight";
        if (transparencyRow != null) transparencyRow.Visibility = glassChosen && state.Build >= 22621 ? Visibility.Visible : Visibility.Collapsed;
        string key = decision.Reason switch
        {
            BackdropReason.Classic => "classic", BackdropReason.Available => "available", BackdropReason.OldSystem => "old_system",
            BackdropReason.TransparencyOff => "transparency_off", BackdropReason.HighContrast => "high_contrast",
            BackdropReason.DeviceLost => "device_lost", _ => "unavailable"
        };
        surfaceStatus.Text = ui.Text("windows.appearance.surface_" + key);
        // Classic and working glass need no note; a fallback explains itself under the pictures.
        surfaceStatus.Visibility = key is "classic" or "available" ? Visibility.Collapsed : Visibility.Visible;
        if (transparencyMode != null) transparencyMode.Text = ui.Text(key == "transparency_off" ? "appearance.glass_reduced" : "appearance.glass_system");
        foreach (string name in new[] { "liquidGlass", "liquidGlassLight" })
        {
            if (!surfaceChoices.TryGetValue(name, out var choice)) continue;
            choice.IsEnabled = !busy && !session.RequiresRestart && state.Build >= 22621;
            choice.ToolTip = decision.Glass ? null : surfaceStatus.Text;
            ToolTipService.SetShowOnDisabled(choice, true);
        }
    }
    private static UIElement StyleSwatch(string material)
    {
        var art = new Grid { Width = 132, Height = 58, Background = MaterialWallpaper(), Clip = new RectangleGeometry(new Rect(0, 0, 132, 58), 7, 7), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var capsule = new Grid { Width = 86, Height = 22 };
        (Brush Fill, Brush Edge, double Width) look = material switch
        {
            "liquidGlass" => (new SolidColorBrush(Color.FromArgb(77, 0, 0, 0)), new SolidColorBrush(Color.FromArgb(102, 255, 255, 255)), 0.5),
            "liquidGlassLight" => (new SolidColorBrush(Color.FromArgb(214, 248, 248, 250)), new SolidColorBrush(Color.FromArgb(31, 0, 0, 0)), 0.75),
            "graphite" => (new SolidColorBrush(Color.FromRgb(0x16, 0x17, 0x1B)), new SolidColorBrush(Color.FromRgb(0x30, 0x33, 0x3A)), 1),
            _ => (Brushes.Black, new SolidColorBrush(Color.FromArgb(38, 255, 255, 255)), 0.75)
        };
        capsule.Children.Add(new Border { CornerRadius = new CornerRadius(11), Background = look.Fill, BorderThickness = new Thickness(look.Width), BorderBrush = look.Edge });
        var mark = material == "liquidGlassLight" ? Color.FromArgb(191, 29, 29, 31) : Color.FromArgb(191, 255, 255, 255);
        capsule.Children.Add(new Border { Width = 20, Height = 4, CornerRadius = new CornerRadius(2), Background = new SolidColorBrush(mark), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(9, 0, 0, 0) });
        // The ring takes Codex's color, which follows the accent, in the swatch's own tone.
        var ring = new System.Windows.Shapes.Ellipse { Width = 10, Height = 10, StrokeThickness = 2, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 9, 0) };
        ring.Stroke = PacerPalette.CodexShade(material == "liquidGlassLight"); capsule.Children.Add(ring);
        art.Children.Add(capsule); return art;
    }
    /// A soft desktop so translucency has something to show through, as on the Mac.
    private static Brush MaterialWallpaper()
    {
        var group = new DrawingGroup(); var bounds = new RectangleGeometry(new Rect(0, 0, 1, 1));
        group.Children.Add(new GeometryDrawing(new LinearGradientBrush(new GradientStopCollection
        { new(Color.FromRgb(61, 77, 120), 0), new(Color.FromRgb(115, 97, 143), 0.5), new(Color.FromRgb(219, 148, 120), 1) }, new Point(0, 0), new Point(1, 1)), null, bounds));
        group.Children.Add(new GeometryDrawing(new RadialGradientBrush(Color.FromArgb(150, 250, 199, 140), Color.FromArgb(0, 250, 199, 140))
        { Center = new Point(1.25, 0.95), GradientOrigin = new Point(1.25, 0.95), RadiusX = 0.75, RadiusY = 1.6 }, null, bounds));
        group.Children.Add(new GeometryDrawing(new RadialGradientBrush(Color.FromArgb(150, 77, 140, 191), Color.FromArgb(0, 77, 140, 191))
        { Center = new Point(-0.4, 0.6), GradientOrigin = new Point(-0.4, 0.6), RadiusX = 0.85, RadiusY = 1.8 }, null, bounds));
        var brush = new DrawingBrush(group) { Stretch = Stretch.Fill }; brush.Freeze(); return brush;
    }
    /// The welcome guide's scene, scaled to the tile up to 240 wide, as on the Mac.
    private static Viewbox ModeScene(FrameworkElement scene) => new() { Child = scene, Stretch = Stretch.Uniform, MaxWidth = 240, HorizontalAlignment = HorizontalAlignment.Center };
}
