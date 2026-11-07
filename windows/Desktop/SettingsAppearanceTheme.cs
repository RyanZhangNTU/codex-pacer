using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

/// Appearance's Theme and Accent sections, as on the Mac: the window theme as
/// three pictures, and Multicolor plus eight accent swatches like Apple's.
/// They appear once the shared catalog has their strings.
internal sealed partial class SettingsWindow
{
    private readonly Dictionary<string, RadioButton> themeChoices = new(), accentChoices = new();
    private TextBlock? accentName;

    private bool ThemeSectionsAvailable => ui.Has("appearance.theme") && ui.Has("appearance.accent");
    private void ClearAppearanceTheme() { themeChoices.Clear(); accentChoices.Clear(); accentName = null; }

    private void BuildThemeSection()
    {
        if (!ThemeSectionsAvailable) return;
        form.Children.Add(SectionHeader("appearance.theme"));
        var tiles = new Grid { Margin = new Thickness(14, 12, 14, 12) };
        string[] themes = ["auto", "light", "dark"];
        for (int index = 0; index < themes.Length; index++)
        {
            string theme = themes[index];
            if (index > 0) tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            tiles.ColumnDefinitions.Add(new ColumnDefinition());
            var choice = ArtChoice("appearance.theme." + theme, ui.Text("appearance.theme." + theme), "appearance.themes", ThemeArt(theme));
            choice.Checked += async (_, _) => { if (!synchronizing && session.Current.AppTheme != theme) await Change(p => p with { AppTheme = theme }); };
            themeChoices[theme] = choice; editors.Add(choice); Grid.SetColumn(choice, index * 2); tiles.Children.Add(choice);
        }
        form.Children.Add(Card(tiles));
    }

    private void BuildAccentSection()
    {
        if (!ThemeSectionsAvailable) return;
        var swatches = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (string accent in AccentPalette.Choices)
        {
            var swatch = new RadioButton { Style = (Style)FindResource("SettingsAccentSwatch"), GroupName = "appearance.accents", Margin = new Thickness(5, 0, 0, 0), Background = AccentFill(accent) };
            Identify(swatch, "appearance.accent." + accent, ui.Text("appearance.accent." + accent));
            swatch.Checked += async (_, _) => { if (!synchronizing && session.Current.AccentColor != accent) await Change(p => p with { AccentColor = accent }); };
            accentChoices[accent] = swatch; editors.Add(swatch); row.Children.Add(swatch);
        }
        swatches.Children.Add(row);
        // The chosen color's name sits under the swatches, as in System Settings.
        accentName = Label("", 11); accentName.HorizontalAlignment = HorizontalAlignment.Right; accentName.Margin = new Thickness(0, 4, 0, 0);
        accentName.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); swatches.Children.Add(accentName);
        form.Children.Add(SectionHeader("appearance.accent", 20));
        form.Children.Add(Card(InfoRow(ui.Text("appearance.accent"), swatches, ui.Has("appearance.accent_info") ? ui.Text("appearance.accent_info") : null, id: "appearance.accent", minHeight: 56)));
    }

    private void RefreshAppearanceTheme()
    {
        foreach (var item in themeChoices) item.Value.IsChecked = item.Key == session.Current.AppTheme;
        foreach (var item in accentChoices) item.Value.IsChecked = item.Key == session.Current.AccentColor;
        if (accentName != null) { accentName.Text = ui.Text("appearance.accent." + session.Current.AccentColor); AutomationProperties.SetName(accentName, accentName.Text); }
    }

    /// Multicolor is a rainbow; the others are their own color.
    private static Brush AccentFill(string accent)
    {
        if (AccentPalette.Fixed(accent) is { } color) return new SolidColorBrush(color);
        var rainbow = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        string[] order = ["blue", "purple", "pink", "red", "orange", "yellow", "green"];
        for (int index = 0; index < order.Length; index++) rainbow.GradientStops.Add(new GradientStop(AccentPalette.Fixed(order[index])!.Value, index / (double)(order.Length - 1)));
        return rainbow;
    }

    /// A small window in the theme's colors; Auto shows light and dark halves.
    private static UIElement ThemeArt(string theme)
    {
        Border Window(bool dark) => new()
        {
            Width = 92, Height = 38, CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Color.FromArgb(40, 128, 128, 128)), Background = new SolidColorBrush(dark ? Color.FromRgb(27, 27, 30) : Color.FromRgb(244, 244, 246)),
            Child = new Grid
            {
                ColumnDefinitions = { new ColumnDefinition { Width = new GridLength(24) }, new ColumnDefinition() },
                Children =
                {
                    new Border { Background = new SolidColorBrush(dark ? Color.FromRgb(37, 37, 40) : Color.FromRgb(234, 234, 237)), CornerRadius = new CornerRadius(4, 0, 0, 4) },
                    Column(new Border { Margin = new Thickness(6, 7, 8, 7), CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(dark ? Color.FromRgb(36, 36, 40) : Colors.White) }, 1)
                }
            }
        };
        static UIElement Column(UIElement element, int column) { Grid.SetColumn(element, column); return element; }
        if (theme != "auto") return Window(theme == "dark");
        var light = Window(false); var dark = Window(true);
        dark.Clip = new RectangleGeometry(new Rect(46, 0, 46, 38));
        var both = new Grid { Width = 92, Height = 38 }; both.Children.Add(light); both.Children.Add(dark); return both;
    }
}
