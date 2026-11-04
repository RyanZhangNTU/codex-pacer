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
    private Border? positionSeparator;
    private readonly Dictionary<string, RadioButton> quotaStyleChoices = new();
    private readonly Dictionary<string, RadioButton> surfaceChoices = new();
    private TextBlock? surfaceStatus;
    private FrameworkElement? transparencyRow, expandedQuotaRow;
    private ComboBox? displayChoice;
    private CheckBox? fullscreenChoice;
    private TextBlock? displayStatus;
    private IReadOnlyList<DisplayMonitor>? displayItemsSource;
    private sealed record DisplayOption(string Mode, DisplayMonitor? Monitor);

    private void ClearAppearance()
    { notchChoice = freeChoice = null; positionRow = null; positionSeparator = null; quotaStyleChoices.Clear(); surfaceChoices.Clear(); surfaceStatus = null;
        displayChoice = null; fullscreenChoice = null; displayStatus = null; displayItemsSource = null; transparencyRow = expandedQuotaRow = null; }
    private TextBlock SectionHeader(string key, double top = 2)
    {
        var text = Label(ui.Text(key), 13, FontWeights.SemiBold); text.Margin = new Thickness(10, top, 0, 8); return text;
    }
    private RadioButton ArtChoice(string id, string name, string group, UIElement art, bool enabled = true)
    {
        var choice = new RadioButton { Style = (Style)FindResource("SettingsArtChoice"), GroupName = group, IsEnabled = enabled };
        var content = new StackPanel();
        var artHost = new Grid { Height = 44 }; artHost.Children.Add(art); content.Children.Add(artHost);
        var title = Label(name, 12); title.HorizontalAlignment = HorizontalAlignment.Center; title.Margin = new Thickness(0, 7, 0, 0);
        title.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = choice });
        title.SetBinding(TextBlock.FontWeightProperty, new System.Windows.Data.Binding(nameof(FontWeight)) { Source = choice });
        content.Children.Add(title); choice.Content = content; Identify(choice, id, name); return choice;
    }
    private static Grid Pair(UIElement left, UIElement right)
    {
        var grid = new Grid { Margin = new Thickness(10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(left); Grid.SetColumn(right, 2); grid.Children.Add(right); return grid;
    }
    private void Pending(FrameworkElement element, string key)
    { element.IsEnabled = false; element.ToolTip = ui.Text(key); ToolTipService.SetShowOnDisabled(element, true); }
    private void BuildAppearance()
    {
        form.Children.Add(SectionHeader("appearance.style"));
        var solid = ArtChoice("appearance.style.classic", ui.Text("settings.classic"), "appearance.styles", StyleSwatch(false));
        var glass = ArtChoice("appearance.style.liquidGlass", ui.Text("settings.liquid_glass"), "appearance.styles", StyleSwatch(true));
        foreach (var choice in new[] { (Name: "classic", Button: solid), (Name: "liquidGlass", Button: glass) })
        {
            surfaceChoices[choice.Name] = choice.Button; editors.Add(choice.Button);
            choice.Button.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { IslandAppearance = choice.Name }); };
        }
        surfaceStatus = Detail(""); surfaceStatus.Margin = new Thickness(10, 0, 10, 10);
        Identify(surfaceStatus, "appearance.status", ui.Text("appearance.style"));
        var adjust = new Button { Content = ui.Text("appearance.glass_adjust"), Style = (Style)FindResource("SettingsLink") };
        Identify(adjust, "appearance.transparency.settings", ui.Text("appearance.glass_adjust"));
        adjust.Click += (_, _) => { if (!SettingsPagePolicy.OpenTransparency(systemSettingsLauncher)) ShowIssue("windows.settings.open_system_failed"); };
        transparencyRow = Row(Label(ui.Text("appearance.glass_transparency")), adjust, 36);
        form.Children.Add(Card(Pair(solid, glass), surfaceStatus, transparencyRow));

        var quotaChoices = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (string style in new[] { "split", "classic" })
        {
            var choice = new RadioButton { Style = (Style)FindResource("SettingsSegmentChoice"), Content = ui.Text("appearance.quota_" + style), GroupName = "appearance.quota", VerticalAlignment = VerticalAlignment.Center };
            Identify(choice, "appearance.quota." + style, ui.Text("appearance.quota_" + style));
            choice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { ExpandedQuotaStyle = style }); };
            quotaStyleChoices[style] = choice; editors.Add(choice); quotaChoices.Children.Add(choice);
        }
        var segments = new Border { Child = quotaChoices, Padding = new Thickness(2), CornerRadius = new CornerRadius(7), VerticalAlignment = VerticalAlignment.Center };
        segments.SetResourceReference(Border.BackgroundProperty, "SettingsButton");
        expandedQuotaRow = Card(Row(Label(ui.Text("appearance.expanded_quota")), segments, 40)); form.Children.Add(expandedQuotaRow);
        form.Children.Add(SectionHeader("appearance.position", 20));
        notchChoice = ArtChoice("appearance.mode.notch", ui.Text("settings.notch"), "appearance.modes", PositionSwatch(true));
        freeChoice = ArtChoice("appearance.mode.free", ui.Text("appearance.free_move"), "appearance.modes", PositionSwatch(false));
        notchChoice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { DisplayMode = "notch" }); };
        freeChoice.Checked += async (_, _) => { if (!synchronizing) await Change(p => p with { DisplayMode = "floating" }); };
        editors.Add(notchChoice); editors.Add(freeChoice);
        var caption = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 8, 12, 8) };
        caption.Children.Add(Label(ui.Text("appearance.screen_position")));
        caption.Children.Add(Detail(ui.Text("appearance.free_move_detail")));
        var reset = new Button { Content = ui.Text("appearance.position_reset"), Style = (Style)FindResource("SettingsLink"), VerticalAlignment = VerticalAlignment.Center };
        Identify(reset, "appearance.position.reset", ui.Text("appearance.position_reset"));
        reset.Click += async (_, _) => await Change(p => p with { IslandPlacement = null, Position = "center", PositionChosen = false, DisplayMode = "floating" });
        editors.Add(reset);
        positionRow = Row(caption, reset, 56);
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
        var positionCard = Card(Pair(notchChoice, freeChoice), positionRow, Row(displayCaption, displayChoice, 40), fullscreen);
        positionSeparator = (Border)((Panel)positionCard.Child).Children[1]; form.Children.Add(positionCard);
    }
    private void RefreshAppearance()
    {
        RefreshDisplayChoices();
        if (fullscreenChoice != null) fullscreenChoice.IsChecked = session.Current.ShowInFullscreen;
        foreach (var item in surfaceChoices) item.Value.IsChecked = item.Key == session.Current.IslandAppearance;
        RefreshSurfaceStatus();
        if (expandedQuotaRow != null) expandedQuotaRow.Visibility = SettingsPagePolicy.ShowExpandedQuotaStyle(CompactProviders()) ? Visibility.Visible : Visibility.Collapsed;
        foreach (var item in quotaStyleChoices) item.Value.IsChecked = item.Key == session.Current.ExpandedQuotaStyle;
        if (notchChoice == null || freeChoice == null || positionRow == null) return;
        bool attached = session.Current.DisplayMode == "notch";
        notchChoice.IsChecked = attached; freeChoice.IsChecked = !attached;
        positionRow.Visibility = positionSeparator!.Visibility = attached ? Visibility.Collapsed : Visibility.Visible;
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
        if (transparencyRow != null) transparencyRow.Visibility = session.Current.IslandAppearance == "liquidGlass" && state.Build >= 22621 ? Visibility.Visible : Visibility.Collapsed;
        string key = decision.Reason switch
        {
            BackdropReason.Classic => "classic", BackdropReason.Available => "available", BackdropReason.OldSystem => "old_system",
            BackdropReason.TransparencyOff => "transparency_off", BackdropReason.HighContrast => "high_contrast",
            BackdropReason.DeviceLost => "device_lost", _ => "unavailable"
        };
        surfaceStatus.Text = ui.Text("windows.appearance.surface_" + key);
        if (surfaceChoices.TryGetValue("liquidGlass", out var choice))
        {
            choice.IsEnabled = !busy && !session.RequiresRestart && state.Build >= 22621;
            choice.ToolTip = decision.Glass ? null : surfaceStatus.Text;
            ToolTipService.SetShowOnDisabled(choice, true);
        }
    }
    private static Canvas Wallpaper(double width, double height, double radius = 6)
    {
        var screen = new Canvas { Width = width, Height = height, Clip = new RectangleGeometry(new Rect(0, 0, width, height), radius, radius), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var background = new SolidColorBrush(Color.FromRgb(48, 54, 64)); background.Freeze();
        screen.Background = background; return screen;
    }
    private static UIElement StyleSwatch(bool glass)
    {
        var art = Wallpaper(112, 40);
        var capsule = new Border { Width = 64, Height = 16, CornerRadius = new CornerRadius(8), Background = glass ? new SolidColorBrush(Color.FromArgb(77, 0, 0, 0)) : new SolidColorBrush(Color.FromRgb(11, 12, 14)), BorderThickness = new Thickness(0.5), BorderBrush = new SolidColorBrush(Color.FromArgb(glass ? (byte)102 : (byte)15, 255, 255, 255)) };
        Canvas.SetLeft(capsule, 24); Canvas.SetTop(capsule, 12); art.Children.Add(capsule); return art;
    }
    private static UIElement PositionSwatch(bool attached)
    {
        var art = Wallpaper(112, 40); art.Children.Add(new Border { Width = 112, Height = 9, Background = new SolidColorBrush(Color.FromArgb(56, 0, 0, 0)) });
        var island = new Border { Width = 52, Height = attached ? 12 : 11, Background = Brushes.Black,
            CornerRadius = attached ? new CornerRadius(0, 0, 6, 6) : new CornerRadius(5.5) };
        Canvas.SetLeft(island, 30); Canvas.SetTop(island, attached ? 0 : 18); art.Children.Add(island); return art;
    }
}
