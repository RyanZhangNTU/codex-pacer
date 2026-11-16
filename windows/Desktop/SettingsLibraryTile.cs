using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// A component in a page's library, as on the Mac: clicking the tile only
/// selects it, and the round button at its end adds or removes it without
/// changing the selection. Keyboards and screen readers reach two buttons.
internal sealed record LibraryTile(Grid Root, Button Body, Button? Toggle, FrameworkElement Icon, TextBlock Name, string Label);

internal sealed partial class SettingsWindow
{
    /// <param name="id">The tile's automation id; its round button adds ".toggle".</param>
    /// <param name="fixedNote">Shown instead of the round button for a component that is always there.</param>
    private LibraryTile BuildLibraryTile(string id, string label, string symbol, string help, Action select, Func<Task>? toggle, string? fixedNote = null,
        string? provider = null)
    {
        var root = new Grid();
        var body = new Button { Style = (Style)FindResource("SettingsLibraryTile") };
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = provider == null ? new IconGlyph { Symbol = symbol, Width = 12, Height = 12 } : ProviderIcon.Create(provider, 14, symbol);
        icon.Margin = new Thickness(0, 0, 8, 0);
        icon.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(icon);
        var name = Label(label, 12.5); name.TextTrimming = TextTrimming.CharacterEllipsis; Grid.SetColumn(name, 1); row.Children.Add(name);
        if (fixedNote != null)
        {
            var note = Label(fixedNote, 11); note.Margin = new Thickness(8, 0, 0, 0); note.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            Grid.SetColumn(note, 2); row.Children.Add(note); body.Padding = new Thickness(10, 0, 10, 0);
        }
        body.Content = row;
        Identify(body, id, label); AutomationProperties.SetHelpText(body, help); editors.Add(body);
        body.Click += (_, _) => { if (!synchronizing && body.IsVisible && body.IsEnabled) select(); };
        root.Children.Add(body);
        Button? button = null;
        if (toggle != null)
        {
            button = new Button { Style = (Style)FindResource("SettingsLibraryToggle") };
            Identify(button, id + ".toggle", label); editors.Add(button);
            button.Click += async (_, _) =>
            {
                if (synchronizing || busy || !button.IsVisible || !button.IsEnabled || Equals(button.Tag, "locked")) return;
                await toggle();
            };
            root.Children.Add(button);
        }
        return new LibraryTile(root, body, button, icon, name, label);
    }

    /// Paints a tile for its state. A tile that is not added stays plain and
    /// gray; its round button names the action it takes.
    /// <param name="tint">The resource key of the icon's ink while added; null uses the label's.</param>
    private void PaintLibraryTile(LibraryTile tile, bool added, bool selected, bool locked, bool available, string? tint, string addKey, string removeKey)
    {
        tile.Body.SetResourceReference(BackgroundProperty, added ? "SettingsTileAdded" : "SettingsTileIdle");
        tile.Body.SetResourceReference(BorderBrushProperty, added ? "SettingsCardBorder" : "SettingsTileStroke");
        tile.Body.Tag = selected ? "selected" : null;
        tile.Name.SetResourceReference(TextBlock.ForegroundProperty, added ? "SettingsPrimary" : "SettingsSecondary");
        if (tile.Icon is IconGlyph glyph)
            glyph.SetResourceReference(IconGlyph.InkProperty, !added ? "SettingsSecondary" : tint ?? "SettingsPrimary");
        // A service that is off keeps its tile, faded, so its settings stay reachable.
        tile.Root.Opacity = available ? 1 : 0.55;
        AutomationProperties.SetItemStatus(tile.Body, selected ? ui.Text("main.panel.selected") : "");
        if (tile.Toggle is not { } button) return;
        button.Tag = locked ? "locked" : added ? "added" : "add";
        string name = locked ? ui.Text("main.panel.last").TrimEnd('.', '。')
            : ui.Text(added ? removeKey : addKey).Replace("%@", tile.Label, StringComparison.Ordinal);
        AutomationProperties.SetName(button, name); button.ToolTip = name;
    }

    /// The inspector's note while the selected component is not added, or cannot be removed.
    private Border LibraryNotice(string id)
    {
        var text = Label("", 12); text.TextWrapping = TextWrapping.Wrap;
        var notice = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(14, 0, 14, 12), Child = text, Visibility = Visibility.Collapsed };
        Identify(text, id, "");
        return notice;
    }

    private void ShowLibraryNotice(Border notice, string? text, bool locked)
    {
        var label = (TextBlock)notice.Child;
        label.Text = text ?? ""; AutomationProperties.SetName(label, label.Text);
        notice.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
        notice.SetResourceReference(Border.BackgroundProperty, locked ? "SettingsInfoFill" : "SettingsNoticeFill");
        label.SetResourceReference(TextBlock.ForegroundProperty, locked ? "SettingsSecondary" : "SettingsNoticeText");
    }
}
