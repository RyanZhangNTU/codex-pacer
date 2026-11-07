using System;
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
        var tiles = new Grid { Margin = new Thickness(14, 14, 14, 14) };
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
        var swatches = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 6, 0, 6) };
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (string accent in AccentPalette.Choices)
        {
            var swatch = new RadioButton { Style = (Style)FindResource("SettingsAccentSwatch"), GroupName = "appearance.accents", Margin = new Thickness(row.Children.Count == 0 ? 0 : 2, 0, 0, 0), Background = AccentFill(accent) };
            // The chosen dot is ringed in its own color; Multicolor in gray.
            if (AccentPalette.Fixed(accent) is { } own) swatch.BorderBrush = new SolidColorBrush(own); else swatch.SetResourceReference(Control.BorderBrushProperty, "SettingsSecondary");
            Identify(swatch, "appearance.accent." + accent, ui.Text("appearance.accent." + accent));
            swatch.Checked += async (_, _) => { if (!synchronizing && session.Current.AccentColor != accent) await Change(p => p with { AccentColor = accent }); };
            accentChoices[accent] = swatch; editors.Add(swatch); row.Children.Add(swatch);
        }
        swatches.Children.Add(row);
        // The chosen color's name sits under the swatches, as in System Settings.
        accentName = Label("", 11); accentName.HorizontalAlignment = HorizontalAlignment.Center; accentName.Margin = new Thickness(0, 2, 0, 0);
        accentName.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); swatches.Children.Add(accentName);
        // Accent is one row in its own card, with no section title, as on the Mac.
        var card = Card(InfoRow(ui.Text("appearance.accent"), swatches, ui.Has("appearance.accent_info") ? ui.Text("appearance.accent_info") : null, id: "appearance.accent"));
        form.Children.Add(card);
    }

    private void RefreshAppearanceTheme()
    {
        foreach (var item in themeChoices) item.Value.IsChecked = item.Key == session.Current.AppTheme;
        foreach (var item in accentChoices) item.Value.IsChecked = item.Key == session.Current.AccentColor;
        if (accentName != null) { accentName.Text = ui.Text("appearance.accent." + session.Current.AccentColor); AutomationProperties.SetName(accentName, accentName.Text); }
    }

    /// Multicolor shows the three services' own colors in thirds from the top, as on the Mac; the others are their own color.
    private static Brush AccentFill(string accent)
    {
        if (AccentPalette.Fixed(accent) is { } color) return new SolidColorBrush(color);
        var group = new DrawingGroup();
        Brush[] brands = [PacerPalette.BrandCodex, PacerPalette.BrandClaude, PacerPalette.BrandDeepSeek];
        for (int index = 0; index < brands.Length; index++)
        {
            double start = -90 + index * 120, end = start + 120;
            Point At(double degrees) => new(0.5 + 0.5 * Math.Cos(degrees * Math.PI / 180), 0.5 + 0.5 * Math.Sin(degrees * Math.PI / 180));
            var figure = new PathFigure { StartPoint = new Point(0.5, 0.5), IsClosed = true };
            figure.Segments.Add(new LineSegment(At(start), false)); figure.Segments.Add(new ArcSegment(At(end), new Size(0.5, 0.5), 0, false, SweepDirection.Clockwise, false));
            group.Children.Add(new GeometryDrawing(brands[index], null, new PathGeometry([figure])));
        }
        var brush = new DrawingBrush(group) { Stretch = Stretch.Fill, Viewbox = new Rect(0, 0, 1, 1), ViewboxUnits = BrushMappingMode.Absolute }; brush.Freeze(); return brush;
    }

    /// A window in each theme, as the Mac draws its appearance choices: a sidebar, two gray bars and an
    /// accent pill. Auto splits it light and dark along the diagonal.
    private UIElement ThemeArt(string theme)
    {
        Grid Window(bool dark)
        {
            Brush Gray(double white) { byte value = (byte)Math.Round(white * 255); return new SolidColorBrush(Color.FromRgb(value, value, value)); }
            var window = new Grid { Width = 100, Height = 62, Background = Gray(dark ? 0.12 : 0.97) };
            window.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) }); window.ColumnDefinitions.Add(new ColumnDefinition());
            window.Children.Add(new Border { Background = Gray(dark ? 0.18 : 0.88) });
            var lines = new StackPanel { Margin = new Thickness(10), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            lines.Children.Add(new Border { Width = 40, Height = 5, CornerRadius = new CornerRadius(2.5), Background = Gray(dark ? 0.36 : 0.76) });
            lines.Children.Add(new Border { Width = 52, Height = 5, CornerRadius = new CornerRadius(2.5), Background = Gray(dark ? 0.27 : 0.85), Margin = new Thickness(0, 6, 0, 0) });
            var pill = new Border { Width = 22, Height = 8, CornerRadius = new CornerRadius(4), Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
            pill.SetResourceReference(Border.BackgroundProperty, "SettingsAccent"); lines.Children.Add(pill);
            Grid.SetColumn(lines, 1); window.Children.Add(lines); return window;
        }
        var art = new Grid { Width = 100, Height = 62, Clip = new RectangleGeometry(new Rect(0, 0, 100, 62), 7, 7), HorizontalAlignment = HorizontalAlignment.Center };
        if (theme == "auto")
        {
            art.Children.Add(Window(false));
            var dark = Window(true); dark.Clip = new PathGeometry([new PathFigure(new Point(100, 0), [new LineSegment(new Point(100, 62), false), new LineSegment(new Point(0, 62), false)], true)]);
            art.Children.Add(dark);
        }
        else art.Children.Add(Window(theme == "dark"));
        var outline = new Border { CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1) };
        outline.SetResourceReference(Border.BorderBrushProperty, "SettingsTileStroke"); art.Children.Add(outline);
        return art;
    }
}
