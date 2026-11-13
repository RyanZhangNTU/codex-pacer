using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// The main window's sidebar, as on the Mac: search, then Overview and History,
/// the services and the preferences, with Help & Updates and Support & Feedback
/// in the footer. Selection is a neutral fill; color only marks a service.
internal sealed partial class SettingsWindow
{
    /// Every page in the Mac's order; search lists matches in this order.
    internal static readonly string[] Panes = ["overview", "history", "codex", "claude", "deepseek", "remote", "appearance", "collapsed", "expandedPanel", "notifications", "general", "about", "support"];
    private static readonly string[][] PaneGroups = [["overview", "history"], ["codex", "claude", "deepseek", "remote"], ["appearance", "collapsed", "expandedPanel", "notifications", "general"]];
    private readonly Dictionary<string, TextBlock> moduleOff = new();
    private readonly Dictionary<string, Ellipse> attentionDots = new();
    private readonly StackPanel paneGroups = new(), searchResults = new() { Visibility = Visibility.Collapsed };
    private readonly StackPanel harnessRows = new();
    private (string Provider, string Title, string Symbol)[] harnessPages = [];
    private TextBox? search;
    private TextBlock? searchPlaceholder, aboutDetail;
    private Button? searchClear;
    private Ellipse? updateDot;

    /// Earlier stored pages open where their content moved.
    internal static string CanonicalPane(string value) => value switch
    {
        "reminders" => "notifications",
        "connections" => "remote",
        "whatsNew" or "help" => "about",
        "collapsedBar" => "collapsed",
        _ => value
    };
    /// Nothing waits for a later step any more; kept so a page can be held back again.
    private static bool PendingPane(string pane) => false;
    private static bool EnginePane(string pane) => pane is "overview" or "history" or "codex" or "claude" or "deepseek" or "notifications" or "remote";
    private bool PaneAvailable(string pane) => !PendingPane(pane) && ResolvePane(pane) == pane;
    /// The Mac's raw value, which names the shared search words.
    private static string MacPane(string pane) => pane == "collapsed" ? "collapsedBar" : pane;
    private bool ProviderPane(string pane) => DesktopPreferences.IsLegacyProvider(pane) || HarnessPane(pane);
    private bool HarnessPane(string pane) => Array.Exists(harnessPages, page => page.Provider == pane);
    private EngineModule? HarnessModule(string provider) => engine?.LatestSnapshot?.Modules?.FirstOrDefault(module => module.Provider == provider);

    private bool SyncHarnessNavigation()
    {
        var pages = (engine?.LatestSnapshot?.Modules ?? [])
            .Where(module => module.DisplayName is { Length: > 0 and <= 64 } && DesktopPreferences.ValidProviderId(module.Provider)
                && !Panes.Contains(module.Provider) && CanonicalPane(module.Provider) == module.Provider)
            .Select(module => (module.Provider, module.DisplayName!, GuideArt.Symbol(module.Symbol ?? "circle.circle")))
            .DistinctBy(page => page.Provider).ToArray();
        if (harnessPages.SequenceEqual(pages)) return false;
        foreach (var page in harnessPages)
        {
            PageAccessibility.Retire(navigation[page.Provider]);
            navigation.Remove(page.Provider);
            moduleOff.Remove(page.Provider);
        }
        harnessRows.Children.Clear();
        harnessPages = pages;
        foreach (var page in pages) harnessRows.Children.Add(SidebarRow(page.Provider));
        return true;
    }

    private string PaneTitle(string pane) => pane switch
    {
        "codex" => "Codex",
        "claude" => "Claude",
        "deepseek" => "DeepSeek",
        "overview" or "history" or "remote" or "notifications" or "about" or "support" => ui.Text("main.pane." + pane),
        "expandedPanel" => ui.Text("settings.pane.expanded_panel"),
        _ => harnessPages.FirstOrDefault(page => page.Provider == pane).Title ?? ui.Text("settings.pane." + pane)
    };
    private string PaneSymbol(string pane) => pane switch
    {
        "overview" => "square.grid.2x2",
        "history" => "chart.xyaxis.line",
        "codex" or "claude" or "deepseek" => GuideArt.ProviderSymbol(pane),
        "remote" => "server.rack",
        "appearance" => "circle.lefthalf.filled",
        "collapsed" => "rectangle.topthird.inset.filled",
        "expandedPanel" => "text.alignleft",
        "notifications" => "bell",
        "general" => "gearshape",
        "support" => "heart",
        _ => harnessPages.FirstOrDefault(page => page.Provider == pane).Symbol ?? "info.circle"
    };

    private UIElement BuildSidebar()
    {
        var surface = new Border(); surface.SetResourceReference(Border.BackgroundProperty, "SettingsSidebar");
        var dock = new DockPanel { Margin = new Thickness(10, 12, 10, 10), LastChildFill = true }; surface.Child = dock;
        var field = BuildSearchField(); DockPanel.SetDock(field, Dock.Top); dock.Children.Add(field);
        var footer = BuildSidebarFooter(); DockPanel.SetDock(footer, Dock.Bottom); dock.Children.Add(footer);
        for (int index = 0; index < PaneGroups.Length; index++)
        {
            if (index > 0)
            {
                var title = Label(ui.Text(index == 1 ? "main.group.services" : "main.group.preferences"), 11, FontWeights.SemiBold);
                title.Margin = new Thickness(8, 12, 8, 3); title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2);
                paneGroups.Children.Add(title);
            }
            foreach (string pane in PaneGroups[index])
            {
                if (pane == "remote") paneGroups.Children.Add(harnessRows);
                paneGroups.Children.Add(SidebarRow(pane));
            }
        }
        SyncHarnessNavigation();
        var lists = new StackPanel(); lists.Children.Add(paneGroups); lists.Children.Add(searchResults);
        var scroller = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = lists, Focusable = false };
        Identify(scroller, "settings.sidebar", ui.Text("common.settings"));
        dock.Children.Add(scroller);
        return surface;
    }

    private UIElement BuildSearchField()
    {
        var box = new Border { CornerRadius = new CornerRadius(7), Height = 28, Padding = new Thickness(8, 0, 2, 0), Margin = new Thickness(0, 0, 0, 12) };
        box.SetResourceReference(Border.BackgroundProperty, "SettingsSearchFill");
        var grid = new Grid(); box.Child = grid;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glyph = new IconGlyph { Symbol = "magnifyingglass", Width = 13, Height = 13, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
        glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); grid.Children.Add(glyph);
        searchPlaceholder = Label(ui.Text("main.search")); searchPlaceholder.IsHitTestVisible = false; searchPlaceholder.Margin = new Thickness(2, 0, 0, 0);
        searchPlaceholder.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); Grid.SetColumn(searchPlaceholder, 1); grid.Children.Add(searchPlaceholder);
        search = new TextBox { Style = (Style)FindResource("SettingsSearchInput"), VerticalAlignment = VerticalAlignment.Stretch };
        Identify(search, "settings.search", ui.Text("main.search")); Grid.SetColumn(search, 1); grid.Children.Add(search);
        searchClear = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 22, Height = 22, Padding = new Thickness(0), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        var clearGlyph = new IconGlyph { Symbol = "xmark.circle.fill", Width = 13, Height = 13 }; clearGlyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        searchClear.Content = clearGlyph; Identify(searchClear, "settings.search.clear", ui.Text("main.search_clear"));
        searchClear.Click += (_, _) => { if (search != null) { search.Clear(); search.Focus(); } };
        Grid.SetColumn(searchClear, 2); grid.Children.Add(searchClear);
        search.TextChanged += (_, _) => ApplySearch();
        // Return opens the first match; Escape clears a query before it can close the window.
        search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && SearchMatches().FirstOrDefault() is { } first) { ChooseFromSearch(first); e.Handled = true; }
            else if (e.Key == Key.Escape && search.Text.Length > 0) { search.Clear(); e.Handled = true; }
        };
        return box;
    }

    /// Pages whose title or search words contain the query, among those that can open now.
    internal IReadOnlyList<string> SearchMatches()
    {
        string needle = search?.Text.Trim().ToLower(CultureInfo.CurrentCulture) ?? "";
        if (needle.Length == 0) return [];
        return Panes.TakeWhile(pane => pane != "remote").Concat(harnessPages.Select(page => page.Provider))
            .Concat(Panes.SkipWhile(pane => pane != "remote"))
            .Where(pane => PaneAvailable(pane)
                && (PaneTitle(pane) + " " + ui.Text(HarnessPane(pane) ? "main.search.local_harness" : "main.search." + MacPane(pane)))
                    .ToLower(CultureInfo.CurrentCulture).Contains(needle, StringComparison.Ordinal)).ToArray();
    }

    private void ApplySearch()
    {
        if (search == null) return;
        bool empty = search.Text.Length == 0;
        if (searchPlaceholder != null) searchPlaceholder.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (searchClear != null) searchClear.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        foreach (UIElement child in searchResults.Children) PageAccessibility.Retire(child);
        searchResults.Children.Clear();
        bool searching = search.Text.Trim().Length > 0;
        paneGroups.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
        searchResults.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
        if (!searching) return;
        var matches = SearchMatches();
        if (matches.Count == 0)
        {
            var none = Label(ui.Text("main.search_empty"), 12); none.Margin = new Thickness(8, 6, 8, 6);
            none.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            Identify(none, "settings.search.empty", none.Text); AutomationProperties.SetLiveSetting(none, AutomationLiveSetting.Polite);
            searchResults.Children.Add(none); return;
        }
        foreach (string pane in matches)
        {
            var result = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Margin = new Thickness(0, 0, 0, 2) };
            result.SetResourceReference(ForegroundProperty, "SettingsPrimary");
            // A result is the row it leads to: its Off label, its attention dot and, for the open page, the selection.
            var end = new StackPanel { Orientation = Orientation.Horizontal };
            if (moduleOff.TryGetValue(pane, out var off) && off.Visibility == Visibility.Visible)
            { var copy = Label(off.Text, 11); copy.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); end.Children.Add(copy); }
            if (attentionDots.TryGetValue(pane, out var dot) && dot.Visibility == Visibility.Visible)
                end.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = PacerPalette.Attention, VerticalAlignment = VerticalAlignment.Center });
            if (pane == activePane) result.SetResourceReference(BackgroundProperty, "SettingsSidebarSelection");
            result.Content = RowContent(pane, result, end);
            Identify(result, "settings.search.result." + pane, PaneTitle(pane));
            result.Click += (_, _) => ChooseFromSearch(pane);
            searchResults.Children.Add(result);
        }
    }

    private void ChooseFromSearch(string pane)
    {
        search?.Clear();
        if (pane == activePane) navigation[pane].Focus();
        else _ = NavigateAsync(pane);
    }

    private RadioButton SidebarRow(string pane)
    {
        string title = PaneTitle(pane);
        var button = new RadioButton { Style = (Style)FindResource("SettingsSidebarChoice"), GroupName = "settings.panes", Margin = new Thickness(0, 0, 0, 2), IsEnabled = PaneAvailable(pane) };
        var end = new StackPanel { Orientation = Orientation.Horizontal };
        if (ProviderPane(pane))
        {
            var off = Label(ui.Text("settings.module_off"), 11); off.Visibility = Visibility.Collapsed;
            off.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); moduleOff[pane] = off; end.Children.Add(off);
        }
        if (pane is "claude" or "codex" or "remote")
        {
            // Amber only says that something needs the user.
            var dot = new Ellipse { Width = 7, Height = 7, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
            dot.Fill = PacerPalette.Attention; AutomationProperties.SetName(dot, ui.Text("main.needs_attention"));
            AutomationProperties.SetAutomationId(dot, "settings.pane." + pane + ".attention"); attentionDots[pane] = dot; end.Children.Add(dot);
        }
        button.Content = RowContent(pane, button, end);
        Identify(button, "settings.pane." + pane, title);
        string? tip = PendingPane(pane) ? "windows.main.pane_later" : EnginePane(pane) && engine == null ? "windows.settings.pane_pending" : null;
        if (tip != null) { button.ToolTip = ui.Text(tip); ToolTipService.SetShowOnDisabled(button, true); }
        button.Checked += async (_, _) => { if (!synchronizing && button.IsChecked == true) await NavigateAsync(pane); };
        navigation[pane] = button; return button;
    }

    /// Icon, title and an optional trailing note; the title follows the row's text color.
    private Grid RowContent(string pane, Control row, UIElement? trailing)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        FrameworkElement icon;
        if (ProviderPane(pane))
        {
            // Service tiles keep their tinted gradient, so color in the sidebar only says which service a row is.
            icon = ProviderIcon.Tile(pane, 22, PaneSymbol(pane));
        }
        else
        {
            var glyph = new IconGlyph { Symbol = PaneSymbol(pane), Width = 15, Height = 15 };
            if (pane == "support") glyph.Ink = new SolidColorBrush(Color.FromRgb(245, 92, 107));
            else glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
            icon = new Border { Width = 22, Height = 22, Child = glyph };
        }
        icon.Margin = new Thickness(0, 0, 9, 0); icon.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(icon);
        var label = Label(PaneTitle(pane)); label.TextTrimming = TextTrimming.CharacterEllipsis;
        label.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = row });
        Grid.SetColumn(label, 1); grid.Children.Add(label);
        if (trailing is FrameworkElement end) { end.Margin = new Thickness(4, 0, 0, 0); end.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(end, 2); grid.Children.Add(end); }
        return grid;
    }

    /// Help & Updates shows the installed version, or a found one in the accent color;
    /// Support follows; Quit stays here because Windows has no app menu.
    private UIElement BuildSidebarFooter()
    {
        var footer = new StackPanel();
        var line = new Border { Height = 1, Margin = new Thickness(0, 8, 0, 8) }; line.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); footer.Children.Add(line);
        var about = new RadioButton { Style = (Style)FindResource("SettingsSidebarChoice"), GroupName = "settings.panes", Margin = new Thickness(0, 0, 0, 2), Height = double.NaN, MinHeight = 40, Padding = new Thickness(8, 4, 8, 4) };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = AppIcon(22); icon.Margin = new Thickness(0, 0, 9, 0); icon.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(icon);
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = Label(PaneTitle("about")); title.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = about });
        names.Children.Add(title);
        aboutDetail = Label("", 11); AutomationProperties.SetAutomationId(aboutDetail, "settings.about.version"); names.Children.Add(aboutDetail);
        Grid.SetColumn(names, 1); grid.Children.Add(names);
        updateDot = new Ellipse { Width = 7, Height = 7, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
        updateDot.SetResourceReference(Shape.FillProperty, "SettingsAccent"); Grid.SetColumn(updateDot, 2); grid.Children.Add(updateDot);
        about.Content = grid; Identify(about, "settings.pane.about", PaneTitle("about"));
        about.Checked += async (_, _) => { if (!synchronizing && about.IsChecked == true) await NavigateAsync("about"); };
        navigation["about"] = about; footer.Children.Add(about);
        footer.Children.Add(SidebarRow("support"));
        var quit = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Height = 26, Margin = new Thickness(0, 4, 0, 0) };
        var quitLabel = new StackPanel { Orientation = Orientation.Horizontal };
        var power = new IconGlyph { Symbol = "power", Width = 14, Height = 14, Margin = new Thickness(0, 0, 8, 0) };
        power.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); quitLabel.Children.Add(power);
        var quitText = Label(ui.Text("common.quit"), 12); quitText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); quitLabel.Children.Add(quitText);
        quit.Content = quitLabel; Identify(quit, "settings.quit", ui.Text("common.quit")); quit.Click += (_, _) => QuitRequested?.Invoke(); footer.Children.Add(quit);
        RefreshSidebar();
        return footer;
    }

    private void RefreshProviderPages()
    {
        bool changed = SyncHarnessNavigation();
        if (changed && !ReadOnlyGuidePane(activePane))
        {
            string stored = session.Current.LastSettingsPane;
            if (ResolvePane(stored) != activePane || HarnessPane(activePane)) RebuildPane(stored);
        }
        RefreshHarnessPage();
        RefreshSidebar();
        if (changed) ApplySearch();
    }

    /// Off services say so, and a found update replaces the installed version.
    private void RefreshSidebar()
    {
        EnsureCodexCheck();
        var needs = AttentionItems().Select(value => value.Id).ToHashSet();
        foreach (var item in attentionDots)
        {
            item.Value.Visibility = needs.Contains(item.Key) ? Visibility.Visible : Visibility.Collapsed;
            if (navigation.TryGetValue(item.Key, out var row))
                AutomationProperties.SetItemStatus(row, needs.Contains(item.Key) ? ui.Text("main.needs_attention") : "");
        }
        var modules = engine?.LatestSnapshot?.Modules;
        foreach (var item in moduleOff)
        {
            bool off = engine != null && (modules?.FirstOrDefault(value => value.Provider == item.Key) is { } module
                ? !module.Enabled : session.Current.ProviderModes.TryGetValue(item.Key, out string? mode) && mode == "disabled");
            item.Value.Visibility = off ? Visibility.Visible : Visibility.Collapsed;
        }
        if (aboutDetail == null) return;
        string? found = updater?.CurrentOffer?.Version;
        if (found != null)
        {
            aboutDetail.Text = ui.Text("main.update.sidebar").Replace("%@", found, StringComparison.Ordinal);
            aboutDetail.FontWeight = FontWeights.Medium; aboutDetail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsLinkText");
        }
        else
        {
            aboutDetail.Text = Version.Length > 0 ? Version : ui.Text("build.development");
            aboutDetail.FontWeight = FontWeights.Normal; aboutDetail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        }
        AutomationProperties.SetName(aboutDetail, aboutDetail.Text);
        if (updateDot != null) updateDot.Visibility = found != null ? Visibility.Visible : Visibility.Collapsed;
    }
}
