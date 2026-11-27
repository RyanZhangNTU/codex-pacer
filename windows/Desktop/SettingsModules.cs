using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

/// The module library, as on the Mac: services found on this computer, or
/// turned on explicitly, come first; the others wait in a folded section.
/// Clicking a tile opens the service's page; its round button turns the
/// service on or off without opening it.
internal sealed partial class SettingsWindow
{
    private StackPanel? modulesFound, modulesMissing;
    private Expander? modulesMore;
    private TextBlock? modulesEmpty;
    private readonly Dictionary<string, (LibraryTile Tile, TextBlock State)> moduleTiles = new();
    private string moduleLibraryKey = "";

    private void ClearModules()
    {
        modulesFound = modulesMissing = null; modulesMore = null; modulesEmpty = null;
        moduleTiles.Clear(); moduleLibraryKey = "";
    }

    private void BuildModules()
    {
        form.Children.Add(SectionTitle(ui.Text("modules.on_this_computer"), 0));
        modulesFound = new StackPanel(); form.Children.Add(modulesFound);
        modulesEmpty = Detail(ui.Text("modules.empty")); modulesEmpty.Margin = new Thickness(4, 0, 4, 8); form.Children.Add(modulesEmpty);
        modulesMissing = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
        modulesMore = Disclosure(ui.Text("modules.not_found"), modulesMissing, false, "settings.modules.not_found");
        modulesMore.Margin = new Thickness(0, 14, 0, 0);
        form.Children.Add(modulesMore);
        RefreshModules();
    }

    private IReadOnlyList<EngineModule> LibraryModules() =>
        (engine?.LatestSnapshot?.Modules ?? []).Where(module => DesktopPreferences.ValidProviderId(module.Provider)).ToArray();

    private void RefreshModules()
    {
        if (modulesFound == null || modulesMissing == null) return;
        var modules = LibraryModules();
        // Rebuild only when a module moves between the sections; states repaint in place.
        string key = string.Join("|", modules.Select(module => module.Provider + ":" + module.IsProminent + ":" + module.HasApplication));
        if (key != moduleLibraryKey)
        {
            moduleLibraryKey = key;
            foreach (var entry in moduleTiles.Values) PageAccessibility.Retire(entry.Tile.Root);
            moduleTiles.Clear(); modulesFound.Children.Clear(); modulesMissing.Children.Clear();
            foreach (var module in modules) (module.IsProminent ? modulesFound : modulesMissing).Children.Add(ModuleTile(module));
        }
        int hidden = modules.Count(module => !module.IsProminent);
        modulesMore!.Visibility = hidden > 0 ? Visibility.Visible : Visibility.Collapsed;
        modulesMore.Tag = hidden > 0 ? hidden.ToString(System.Globalization.CultureInfo.InvariantCulture) : null;
        modulesEmpty!.Visibility = modules.Any(module => module.IsProminent) ? Visibility.Collapsed : Visibility.Visible;
        bool editable = !busy && !session.RequiresRestart && !providerConnectionClosed && engine?.IsConnectionClosed == false;
        foreach (var module in modules)
        {
            if (!moduleTiles.TryGetValue(module.Provider, out var entry)) continue;
            string state = module.Enabled ? "on" : module.Installed == true ? "off" : "not_found";
            entry.State.Text = ui.Text("modules.state." + state);
            entry.State.SetResourceReference(TextBlock.ForegroundProperty, module.Enabled ? "SettingsSuccess" : "SettingsSecondary");
            PaintLibraryTile(entry.Tile, module.Enabled, module.Provider == activePane, locked: false, available: true, tint: null,
                "modules.turn_on", "modules.turn_off");
            entry.Tile.Body.IsEnabled = editable || module.Enabled;
            if (entry.Tile.Toggle is { } toggle) toggle.IsEnabled = editable;
            AutomationProperties.SetItemStatus(entry.Tile.Body, entry.State.Text);
        }
    }

    private FrameworkElement ModuleTile(EngineModule module)
    {
        string provider = module.Provider, name = PaneTitle(provider);
        string summary = ui.Has("module." + provider + ".summary") ? ui.Text("module." + provider + ".summary") : "";
        var tile = BuildLibraryTile("settings.modules." + provider, name, PaneSymbol(provider), summary,
            () => _ = NavigateAsync(provider),
            async () =>
            {
                if (HarnessModule(provider) is not { } current) return;
                await Change(p => p with { ProviderModes = new(p.ProviderModes) { [provider] = current.Enabled ? "disabled" : "enabled" } });
            }, provider: provider);
        // Two lines: the name, then what the service brings, with its state at the end.
        tile.Body.Height = 54; if (tile.Toggle != null) tile.Toggle.Height = 54;
        var row = (Grid)tile.Body.Content;
        tile.Name.FontSize = 13; tile.Name.FontWeight = FontWeights.Medium;
        row.Children.Remove(tile.Name);
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(tile.Name);
        if (summary.Length > 0)
        {
            var detail = Label(summary, 11.5); detail.TextTrimming = TextTrimming.CharacterEllipsis;
            detail.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); names.Children.Add(detail);
        }
        Grid.SetColumn(names, 1); row.Children.Add(names);
        if (tile.Icon is FrameworkElement icon) { icon.Width = icon.Height = 22; icon.Margin = new Thickness(0, 0, 10, 0); }
        var state = Label("", 11.5); state.Margin = new Thickness(8, 0, 0, 0); state.VerticalAlignment = VerticalAlignment.Center;
        Identify(state, "settings.modules." + provider + ".state", "");
        Grid.SetColumn(state, 2); row.Children.Add(state);
        moduleTiles[provider] = (tile, state);
        var cell = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        cell.Children.Add(tile.Root);
        // A service that isn't here links to where to get it.
        if (module.HasApplication == false && Uri.TryCreate(module.Website, UriKind.Absolute, out var site) && site.Scheme == Uri.UriSchemeHttps)
        {
            string label = ui.Text("modules.get").Replace("%@", name, StringComparison.Ordinal);
            var get = new Button { Content = label, Style = (Style)FindResource("SettingsLink"), HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(44, 3, 0, 0), FontSize = 12 };
            Identify(get, "settings.modules." + provider + ".get", label);
            get.Click += (_, _) => { if (!SettingsPagePolicy.OpenWebsite(site, guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); };
            cell.Children.Add(get);
        }
        return cell;
    }
}
