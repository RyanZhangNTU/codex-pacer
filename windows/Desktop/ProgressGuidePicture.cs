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
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        var padlock = new Path
        {
            Data = Geometry.Parse("M3,6 V4 A4,4 0 0 1 11,4 V6 Q13,6 13,8 V13 Q13,15 11,15 H3 Q1,15 1,13 V8 Q1,6 3,6 Z M5,6 H9 V4 A2,2 0 0 0 5,4 Z"),
            Width = 12, Height = 14, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0)
        };
        padlock.SetResourceReference(Shape.FillProperty, "SettingsPrimary");
        heading.Children.Add(padlock);
        heading.Children.Add(Label(card.Title, 14, FontWeights.Bold));
        content.Children.Add(heading);

        var mono = new FontFamily("Consolas");
        var resource = Label(card.Resource, 11);
        resource.FontFamily = mono;
        resource.TextTrimming = TextTrimming.CharacterEllipsis;
        var field = new Border { Child = resource, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 6, 8, 6),
            BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 8) };
        field.SetResourceReference(Border.BorderBrushProperty, "SettingsPickerStroke");
        field.SetResourceReference(Border.BackgroundProperty, "SettingsInfoFill");
        content.Children.Add(field);

        var rows = new StackPanel();
        string[] choices = [card.Once, card.Conversation, card.Always, card.No];
        for (int index = 0; index < choices.Length; index++)
        {
            bool selected = index == 2;
            var row = new Grid { Margin = new Thickness(0, index == 0 ? 0 : 2, 0, 0) };
            AutomationProperties.SetAutomationId(row, "progress_approval.row" + (index + 1));
            var cells = new DockPanel { Margin = new Thickness(8, 5, 8, 5) };
            var number = Label((index + 1).ToString(CultureInfo.InvariantCulture), 11);
            number.FontFamily = mono;
            number.Margin = new Thickness(0, 0, 10, 0);
            number.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
            cells.Children.Add(number);
            var choice = Label(choices[index], 12);
            choice.TextTrimming = TextTrimming.CharacterEllipsis;
            choice.SetResourceReference(TextBlock.ForegroundProperty, selected ? "SettingsPrimary" : "SettingsSecondary");
            cells.Children.Add(choice);
            if (index == 3) cells.Children.Add(ApprovalFooter(card));
            if (selected)
            {
                var fill = new Border { CornerRadius = new CornerRadius(7), Child = cells };
                fill.SetResourceReference(Border.BackgroundProperty, "SettingsTileStroke");
                row.Children.Add(fill);
                row.Children.Add(ApprovalRing("progress_approval.ring", 7));
            }
            else row.Children.Add(cells);
            rows.Children.Add(row);
        }
        content.Children.Add(rows);
        var frame = new DecorativeBorder { Child = content, CornerRadius = new CornerRadius(18), MaxWidth = 420,
            Padding = new Thickness(12), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Stretch, IsHitTestVisible = false };
        AutomationProperties.SetAutomationId(frame, "progress_approval.picture");
        frame.SetResourceReference(Border.BackgroundProperty, "SettingsTile");
        frame.SetResourceReference(Border.BorderBrushProperty, "SettingsPickerStroke");
        return frame;
    }

    private static Grid ApprovalFooter(AntigravityApprovalCard card)
    {
        var footer = new Grid { Margin = new Thickness(10, 0, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var hint = Label(card.NoHint, 12);
        hint.Margin = new Thickness(0, 0, 8, 0);
        hint.TextTrimming = TextTrimming.CharacterEllipsis;
        hint.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        hint.Opacity = 0.85;
        footer.Children.Add(hint);

        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var microphone = new Path
        {
            Data = Geometry.Parse("M5,7 V4 A2,2 0 0 1 9,4 V7 A2,2 0 0 1 5,7 Z M3,7 A4,4 0 0 0 11,7 M7,11 V14 M5,14 H9"),
            Width = 11, Height = 13, Stretch = Stretch.Uniform, StrokeThickness = 1.3, StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, VerticalAlignment = VerticalAlignment.Center
        };
        microphone.SetResourceReference(Shape.StrokeProperty, "SettingsSecondary");
        actions.Children.Add(microphone);
        var skip = Label(card.Skip, 12);
        skip.Margin = new Thickness(10, 0, 10, 0);
        skip.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        actions.Children.Add(skip);

        var label = Label(card.Submit + " ↵", 12, FontWeights.SemiBold);
        label.Foreground = Brushes.White;
        var capsule = new Border { Child = label, Background = new SolidColorBrush(Color.FromRgb(33, 92, 194)),
            CornerRadius = new CornerRadius(14), Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(2) };
        AutomationProperties.SetAutomationId(capsule, "progress_approval.submit");
        var submit = new Grid();
        submit.Children.Add(capsule);
        submit.Children.Add(ApprovalRing("progress_approval.submit_ring", 14));
        actions.Children.Add(submit);
        Grid.SetColumn(actions, 1);
        footer.Children.Add(actions);
        return footer;
    }

    private static Border ApprovalRing(string id, double radius)
    {
        var ring = new Border { CornerRadius = new CornerRadius(radius), BorderThickness = new Thickness(2), IsHitTestVisible = false };
        ring.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        ring.SetResourceReference(FrameworkElement.StyleProperty, "ApprovalPictureRing");
        AutomationProperties.SetAutomationId(ring, id);
        return ring;
    }
}
