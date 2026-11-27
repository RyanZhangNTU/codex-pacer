using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CodexPacer.Windows;

internal static class ProgressGuidePicture
{
    internal static DecorativeBorder? Draw(string? kind, AntigravityApprovalCard? card, string provider, UiText ui, bool light) => kind switch
    {
        "customConnector" => CustomConnectorPicture(ui),
        "trust" => TrustPicture(provider, ui, light),
        "antigravityApproval" when card != null => ApprovalPicture(card),
        _ => null
    };

    private static TextBlock Label(string text, double size, FontWeight? weight = null) =>
        new() { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center };

    /// The top of the app's connectors page, drawn: its tabs, and Custom
    /// Connector at the right inside a ring, the one button to click now.
    private static DecorativeBorder CustomConnectorPicture(UiText ui)
    {
        var bar = new DockPanel { LastChildFill = true };
        var button = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 5, 12, 6), Background = new SolidColorBrush(Color.FromRgb(29, 29, 31)) };
        button.Child = new TextBlock { Text = "\u270E " + ui.Text("progress_guide.trust_card.custom"), FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White };
        var ring = new Border { BorderThickness = new Thickness(2.5), CornerRadius = new CornerRadius(11), Padding = new Thickness(3), Child = button, VerticalAlignment = VerticalAlignment.Center };
        ring.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        DockPanel.SetDock(ring, Dock.Right); bar.Children.Add(ring);
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var (key, chosen) in new[] { ("progress_guide.trust_card.experts", false), ("progress_guide.trust_card.skills", false), ("progress_guide.trust_card.tab", true) })
        {
            var tab = Label(ui.Text(key), 14, chosen ? FontWeights.Bold : FontWeights.Normal); tab.Margin = new Thickness(0, 0, 18, 0);
            tab.SetResourceReference(TextBlock.ForegroundProperty, chosen ? "SettingsPrimary" : "SettingsDisabled");
            tabs.Children.Add(tab);
        }
        bar.Children.Add(tabs);
        return PictureFrame(bar);
    }

    /// Pacer's tool in the app's custom connectors, drawn, with Trust inside a ring.
    private static DecorativeBorder TrustPicture(string provider, UiText ui, bool settingsLight)
    {
        var item = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Padding = new Thickness(11, 9, 11, 10), MaxWidth = 380, HorizontalAlignment = HorizontalAlignment.Left };
        item.SetResourceReference(Border.BorderBrushProperty, "SettingsSeparator"); item.SetResourceReference(Border.BackgroundProperty, "SettingsCard");
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var lines = new StackPanel { Margin = new Thickness(0, 0, 12, 0) };
        var name = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 3) };
        name.Children.Add(new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Color.FromRgb(48, 176, 199)), Margin = new Thickness(0, 0, 7, 0) });
        name.Children.Add(Label("pacer_progress", 12.5, FontWeights.SemiBold));
        lines.Children.Add(name);
        var caption = Label(ui.Text("progress_guide.trust_card.caption"), 11); caption.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); lines.Children.Add(caption);
        var detail = Label(ui.Text("progress_guide.trust_card.detail"), 11.5); detail.TextWrapping = TextWrapping.Wrap; detail.Margin = new Thickness(0, 2, 0, 0); lines.Children.Add(detail);
        grid.Children.Add(lines);
        // As the Mac draws it: white on the brand's deeper shade on a light page, dark ink on its light shade on a dark one.
        var trust = new Border { CornerRadius = new CornerRadius(7), Padding = new Thickness(14, 4, 14, 5), Background = PacerPalette.BrandShade(provider, settingsLight) };
        trust.Child = new TextBlock { Text = ui.Text("progress_guide.trust_card.button"), FontSize = 12.5, FontWeight = FontWeights.SemiBold,
            Foreground = settingsLight ? Brushes.White : new SolidColorBrush(Color.FromArgb(204, 0, 0, 0)) };
        var ring = new Border { BorderThickness = new Thickness(2.5), CornerRadius = new CornerRadius(10), Padding = new Thickness(3), Child = trust, VerticalAlignment = VerticalAlignment.Center };
        ring.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        Grid.SetColumn(ring, 1); grid.Children.Add(ring);
        item.Child = grid;
        return PictureFrame(item);
    }

    // A picture only: the step's title and button carry the meaning.
    private static DecorativeBorder PictureFrame(UIElement content)
    {
        var frame = new DecorativeBorder { CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 12, 14, 12), Child = content, MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left };
        frame.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        return frame;
    }

    private static DecorativeBorder ApprovalPicture(AntigravityApprovalCard card)
    {
        var content = new StackPanel();
        var permission = new StackPanel { Orientation = Orientation.Horizontal };
        var shield = new Path
        {
            Data = Geometry.Parse("M8,1 L14,3.5 V8 Q14,12.5 8,15 Q2,12.5 2,8 V3.5 Z M6.5,7 V6 A1.5,1.5 0 0 1 9.5,6 V7 M5.5,7 H10.5 V11 H5.5 Z"),
            Width = 14, Height = 14, Stretch = Stretch.Uniform, StrokeThickness = 1.2, Margin = new Thickness(0, 0, 5, 0)
        };
        shield.SetResourceReference(Shape.StrokeProperty, "SettingsSecondary");
        permission.Children.Add(shield);
        var heading = Label(card.Permission, 11);
        heading.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        permission.Children.Add(heading);
        content.Children.Add(permission);
        var title = Label(card.Title, 14, FontWeights.Bold);
        title.Margin = new Thickness(0, 8, 0, 8);
        content.Children.Add(title);

        var mono = new FontFamily("Consolas");
        var resource = Label(card.Resource, 11);
        resource.FontFamily = mono;
        var field = new Border { Child = resource, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 6, 8, 6),
            BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 8) };
        field.SetResourceReference(Border.BorderBrushProperty, "SettingsPickerStroke");
        field.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        content.Children.Add(field);

        var rows = new StackPanel();
        string[] choices = [card.Once, card.Conversation, card.Always, card.Deny];
        for (int index = 0; index < choices.Length; index++)
        {
            if (index > 0)
            {
                var divider = new Border { Height = 1 };
                divider.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator");
                rows.Children.Add(divider);
            }
            var row = new Grid();
            AutomationProperties.SetAutomationId(row, "progress_approval.row" + (index + 1));
            var cells = new DockPanel { Margin = new Thickness(8, 5, 8, 5) };
            var number = Label((index + 1).ToString(CultureInfo.InvariantCulture), 11);
            number.FontFamily = mono;
            number.HorizontalAlignment = HorizontalAlignment.Center;
            number.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            var badge = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(5), Child = number, Margin = new Thickness(0, 0, 8, 0) };
            badge.SetResourceReference(Border.BackgroundProperty, "SettingsButton");
            cells.Children.Add(badge);
            var choice = Label(choices[index], 12);
            choice.TextWrapping = TextWrapping.Wrap;
            cells.Children.Add(choice);
            row.Children.Add(cells);
            if (index == 2)
            {
                var ring = new Border { CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(2), IsHitTestVisible = false };
                ring.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
                ring.SetResourceReference(FrameworkElement.StyleProperty, "ApprovalPictureRing");
                AutomationProperties.SetAutomationId(ring, "progress_approval.ring");
                row.Children.Add(ring);
            }
            rows.Children.Add(row);
        }
        var group = new Border { Child = rows, CornerRadius = new CornerRadius(9) };
        group.SetResourceReference(Border.BackgroundProperty, "SettingsFill");
        content.Children.Add(group);
        var frame = new DecorativeBorder { Child = content, CornerRadius = new CornerRadius(18), MaxWidth = 420,
            Padding = new Thickness(12), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(frame, "progress_approval.picture");
        frame.SetResourceReference(Border.BackgroundProperty, "SettingsTile");
        frame.SetResourceReference(Border.BorderBrushProperty, "SettingsPickerStroke");
        return frame;
    }
}
