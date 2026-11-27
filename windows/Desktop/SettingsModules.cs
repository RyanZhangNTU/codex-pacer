using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

internal sealed partial class SettingsWindow
{
    private const double ModuleTextInset = 28 + 10;
    private sealed record ModuleCard(string Provider, string Name, string Symbol, bool Detected, Uri? Website);
    private sealed record ModuleControls(ModulePageButton Body, Button Toggle, FrameworkElement Icon, TextBlock State);
    private StackPanel? moduleLibrary;
    private ModuleCard[]? moduleCards;
    private readonly Dictionary<string, ModuleControls> moduleControls = new();

    private void ClearModules()
    {
        moduleLibrary = null;
        moduleCards = null;
        moduleControls.Clear();
    }

    private void BuildModules()
    {
        moduleLibrary = new StackPanel();
        form.Children.Add(moduleLibrary);
        RefreshModules();
    }

    private ModuleCard DescribeModule(EngineModule module)
    {
        string title = "module." + module.Provider + ".title";
        string name = ui.Has(title) ? ui.Text(title) : module.DisplayName is { Length: > 0 and <= 64 } descriptorName
            ? descriptorName : PaneTitle(module.Provider);
        bool detected = module.Installed == true;
        Uri? website = !detected && Uri.TryCreate(module.Website, UriKind.Absolute, out var site) && site.Scheme == Uri.UriSchemeHttps
            ? site : null;
        return new(module.Provider, name, PaneSymbol(module.Provider), detected, website);
    }

    private void RefreshModules()
    {
        if (moduleLibrary == null) return;
        var modules = (engine?.LatestSnapshot?.Modules ?? []).Where(m => DesktopPreferences.ValidProviderId(m.Provider)).ToArray();
        var cards = modules.Select(DescribeModule).ToArray();
        // A state update keeps the same buttons, keyboard focus and open summaries.
        if (moduleCards == null || !cards.SequenceEqual(moduleCards))
        {
            foreach (var controls in moduleControls.Values)
            {
                editors.Remove(controls.Body);
                editors.Remove(controls.Toggle);
            }
            foreach (UIElement section in moduleLibrary.Children) PageAccessibility.Retire(section);
            moduleLibrary.Children.Clear();
            moduleControls.Clear();
            moduleCards = cards;
            var missing = cards.Where(card => !card.Detected).ToArray();
            moduleLibrary.Children.Add(ModuleSection("modules.on_this_computer", cards.Where(card => card.Detected).ToArray(), missing.Length == 0));
            if (missing.Length > 0) moduleLibrary.Children.Add(ModuleSection("modules.not_found", missing, last: true));
            // The scroller owns the automation children of these peerless layout panels.
            if (UIElementAutomationPeer.FromElement(paneScroller) is { } peer)
            {
                peer.ResetChildrenCache();
                peer.InvalidatePeer();
            }
        }

        bool editable = !busy && !session.RequiresRestart && !providerConnectionClosed && engine?.IsConnectionClosed == false;
        foreach (var module in modules)
        {
            var tile = moduleControls[module.Provider];
            bool detected = module.Installed == true;
            string state = ui.Text(module.Enabled ? "modules.state.on" : detected ? "modules.state.off" : "modules.state.not_found");
            tile.State.Text = state;
            tile.State.SetResourceReference(TextBlock.ForegroundProperty, module.Enabled ? "SettingsSuccess" : "SettingsSecondary");
            tile.Icon.Opacity = detected || module.Enabled ? 1 : 0.55;
            tile.Body.SetState(state);
            tile.Body.IsEnabled = editable || module.Enabled;
            PaintLibraryToggle(tile.Toggle, AutomationProperties.GetName(tile.Body), module.Enabled, false, "modules.turn_on", "modules.turn_off");
            tile.Toggle.IsEnabled = editable;
        }
    }

    private StackPanel ModuleSection(string key, ModuleCard[] cards, bool last)
    {
        var section = new StackPanel { Margin = new Thickness(0, 0, 0, last ? 0 : 22) };
        var title = SectionTitle(ui.Text(key));
        title.Margin = new Thickness(0, 0, 0, 8);
        section.Children.Add(title);
        if (cards.Length == 0)
        {
            var empty = Detail(ui.Text("modules.empty"));
            empty.FontSize = 13;
            empty.Margin = new Thickness(0, 0, 0, last ? 8 : 0);
            section.Children.Add(empty);
        }
        if (cards.Length > 0 || last)
        {
            var grid = new ModuleGrid();
            foreach (var card in cards) grid.Children.Add(ModuleTile(card));
            if (last) grid.Children.Add(MoreComingTile());
            section.Children.Add(grid);
        }
        return section;
    }

    private Grid ModuleTile(ModuleCard card)
    {
        string id = "settings.modules." + card.Provider;
        var tile = new Grid { MinHeight = 54 };
        var body = new ModulePageButton { Style = (Style)FindResource("SettingsModuleTile") };
        Identify(body, id, card.Name);
        editors.Add(body);
        body.Click += (_, _) => { if (!synchronizing && body.IsVisible && body.IsEnabled) _ = NavigateAsync(card.Provider); };
        tile.Children.Add(body);

        // Only the three action buttons intercept hits above the full-tile navigation button.
        var content = new StackPanel { Margin = new Thickness(12, 5, 5, 5), VerticalAlignment = VerticalAlignment.Center };
        tile.Children.Add(content);
        var row = new Grid { MinHeight = 32 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.Children.Add(row);
        var icon = ProviderIcon.Create(card.Provider, 28, card.Symbol);
        row.Children.Add(new DecorativeBorder { Child = icon, IsHitTestVisible = false, Margin = new Thickness(0, 0, 10, 0) });

        var heading = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        heading.ColumnDefinitions.Add(new ColumnDefinition());
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = Label(card.Name, 13, FontWeights.Medium);
        name.TextWrapping = TextWrapping.Wrap;
        heading.Children.Add(new DecorativeBorder { Child = name, IsHitTestVisible = false });
        Grid.SetColumn(heading, 1);
        row.Children.Add(heading);
        string summaryKey = "module." + card.Provider + ".summary";
        if (ui.Has(summaryKey))
        {
            // The summary and, for an app that isn't here, a quiet way to get it
            // live behind the ⓘ; the closed tile stays one line.
            var details = new StackPanel { Margin = new Thickness(ModuleTextInset, 2, 10, 0), Visibility = Visibility.Collapsed };
            var summary = Detail(ui.Text(summaryKey));
            summary.IsHitTestVisible = false;
            AutomationProperties.SetAutomationId(summary, id + ".summary");
            details.Children.Add(summary);
            if (card.Website is { } site)
            {
                string label = ui.Text("modules.get").Replace("%@", card.Name, StringComparison.Ordinal);
                var linkText = Label(label, 11.5);
                linkText.TextWrapping = TextWrapping.Wrap;
                linkText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
                var arrow = new IconGlyph { Symbol = "arrow.up.right", Width = 9, Height = 9, Margin = new Thickness(2, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                arrow.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
                var line = new StackPanel { Orientation = Orientation.Horizontal, Children = { linkText, arrow } };
                // The link template has a one-DIP focus border inside its hit target.
                var get = new Button { Content = line, ContentTemplate = null, Style = (Style)FindResource("SettingsLink"),
                    HorizontalAlignment = HorizontalAlignment.Left, MinHeight = 0, Margin = new Thickness(-1, 4, 0, 0), Padding = new Thickness(0) };
                Identify(get, id + ".get", label);
                get.Click += (_, _) => { if (get.IsVisible && !SettingsPagePolicy.OpenWebsite(site, guideLinkLauncher)) ShowIssue("windows.pages.open_failed"); };
                details.Children.Add(get);
            }
            content.Children.Add(details);
            var info = InfoButton(card.Name, details, id);
            info.Width = info.Height = 20;
            info.Margin = new Thickness(3, 0, 0, 0);
            Grid.SetColumn(info, 1);
            heading.Children.Add(info);
        }
        var state = Label("", 11.5);
        AutomationProperties.SetAutomationId(state, id + ".state");
        var stateBox = new DecorativeBorder { Child = state, IsHitTestVisible = false, Margin = new Thickness(4, 0, 0, 0) };
        Grid.SetColumn(stateBox, 2);
        row.Children.Add(stateBox);
        var toggle = LibraryToggle(id, card.Name, async () =>
        {
            if (HarnessModule(card.Provider) is not { } current || providerConnectionClosed || engine?.IsConnectionClosed != false) return;
            await Change(p => p with { ProviderModes = new(p.ProviderModes) { [card.Provider] = current.Enabled ? "disabled" : "enabled" } });
        });
        toggle.Height = 32;
        Grid.SetColumn(toggle, 3);
        row.Children.Add(toggle);
        moduleControls.Add(card.Provider, new(body, toggle, icon, state));
        return tile;
    }

    private Grid MoreComingTile()
    {
        var tile = new Grid { Height = 54, IsHitTestVisible = false };
        var outline = new Rectangle { RadiusX = 10, RadiusY = 10, StrokeDashArray = new DoubleCollection { 4, 4 }, StrokeThickness = 1 };
        outline.SetResourceReference(Shape.StrokeProperty, "SettingsTileRing");
        tile.Children.Add(outline);
        var row = new DockPanel { Margin = new Thickness(12, 0, 12, 0) };
        var glyph = new IconGlyph { Symbol = "sparkle", Width = 16, Height = 16 };
        glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        row.Children.Add(new Border { Width = 28, Child = glyph, Margin = new Thickness(0, 0, 10, 0) });
        var title = Label(ui.Text("modules.more_coming"), 13, FontWeights.Medium);
        title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetAutomationId(title, "settings.modules.more_coming");
        row.Children.Add(title);
        tile.Children.Add(row);
        return tile;
    }
}

internal sealed class ModulePageButton : Button
{
    internal void SetState(string state)
    {
        string previous = AutomationProperties.GetItemStatus(this);
        if (state == previous) return;
        AutomationProperties.SetItemStatus(this, state);
        UIElementAutomationPeer.FromElement(this)?.RaisePropertyChangedEvent(ValuePatternIdentifiers.ValueProperty, previous, state);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
    private sealed class Peer(ModulePageButton button) : ButtonAutomationPeer(button), IValueProvider
    {
        public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.Value ? this : base.GetPattern(pattern);
        public bool IsReadOnly => true;
        public string Value => AutomationProperties.GetItemStatus(button);
        public void SetValue(string value) => throw new InvalidOperationException();
    }
}

internal sealed class ModuleGrid : Panel
{
    private const double MinimumTileWidth = 280, Gap = 8;

    protected override Size MeasureOverride(Size available)
    {
        double width = double.IsFinite(available.Width) ? Math.Max(MinimumTileWidth, available.Width) : MinimumTileWidth;
        return new Size(width, Layout(width, arrange: false));
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        Layout(finalSize.Width, arrange: true);
        return finalSize;
    }

    private double Layout(double width, bool arrange)
    {
        int columns = Math.Max(1, (int)((width + Gap) / (MinimumTileWidth + Gap)));
        double tileWidth = (width - (columns - 1) * Gap) / columns;
        double y = 0, rowHeight = 0;
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            int column = i % columns;
            if (i > 0 && column == 0)
            {
                y += rowHeight + Gap;
                rowHeight = 0;
            }
            var child = InternalChildren[i];
            if (arrange) child.Arrange(new Rect(column * (tileWidth + Gap), y, tileWidth, child.DesiredSize.Height));
            else child.Measure(new Size(tileWidth, double.PositiveInfinity));
            rowHeight = Math.Max(rowHeight, child.DesiredSize.Height);
        }
        return y + rowHeight;
    }
}
