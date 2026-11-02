using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

/// Two wrapping lanes with the original chip gesture, keyboard and menu edits.
/// All mutations are returned to the shared model through the preferences owner.
internal sealed class CompactLayoutEditorView : Grid
{
    private readonly UiText ui;
    private readonly Func<CompactEdit, Task> edit;
    private readonly ResourceDictionary resources;
    private readonly Grid laneStrip = new();
    private readonly Dictionary<string, StackPanel> lanes = new();
    private readonly Dictionary<string, Border> chips = new();
    private readonly Canvas overlay = new() { IsHitTestVisible = false };
    private readonly Border outline = new() { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), IsHitTestVisible = false, Opacity = 0 };
    private CompactProjection? data;
    private string signature = "";
    private string? pressed, dragged;
    private Point origin;
    private FrameworkElement? handle;
    private Border? ghost;

    internal CompactLayoutEditorView(UiText ui, ResourceDictionary resources, Func<CompactEdit, Task> edit)
    {
        this.ui = ui; this.resources = resources; this.edit = edit; Margin = new Thickness(10, 14, 10, 14);
        var content = new StackPanel(); Children.Add(content);
        var title = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var restoreText = new TextBlock { Text = ui.Text("common.restore_defaults"), FontSize = 12 }; restoreText.SetResourceReference(TextBlock.ForegroundProperty, "SettingsAccent");
        var restore = new Button { Content = restoreText, ContentTemplate = null, Padding = new Thickness(0), Style = Resource<Style>("SettingsLink"), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Right };
        Identify(restore, "compact.restore", ui.Text("common.restore_defaults"));
        restore.Click += async (_, _) => { if (IsEnabled && IsVisible) await edit(new("restore")); };
        DockPanel.SetDock(restore, Dock.Right); title.Children.Add(restore);
        title.Children.Add(new TextBlock { Text = ui.Text("layout.arrangement"), FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center }); content.Children.Add(title);
        laneStrip.ColumnDefinitions.Add(new ColumnDefinition()); laneStrip.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) }); laneStrip.ColumnDefinitions.Add(new ColumnDefinition());
        foreach (string lane in new[] { "leading", "trailing" })
        {
            var stack = new StackPanel { MinHeight = 58, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top };
            Identify(stack, "compact.lane." + lane, ui.Text("layout.lane." + lane)); lanes[lane] = stack;
            Grid.SetColumn(stack, lane == "leading" ? 0 : 2); laneStrip.Children.Add(stack);
        }
        var divider = new Border { Width = 1, Margin = new Thickness(0, 2, 0, 2) }; divider.SetResourceReference(Border.BackgroundProperty, "SettingsSeparator"); Grid.SetColumn(divider, 1); laneStrip.Children.Add(divider);
        var surface = new Grid(); surface.Children.Add(laneStrip); surface.Children.Add(outline); outline.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        var border = new Border { Child = surface, Padding = new Thickness(10), CornerRadius = new CornerRadius(10) }; border.SetResourceReference(Border.BackgroundProperty, "SettingsTile");
        content.Children.Add(border);
        content.Children.Add(Note("layout.help", 12));
        var stripHelp = Note("layout.strip_help", 12); stripHelp.Name = "StripHelp"; content.Children.Add(stripHelp);
        Children.Add(overlay);
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && (pressed != null || dragged != null)) { CancelGesture(); e.Handled = true; } };
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelGesture(); };
        Unloaded += (_, _) => CancelGesture();
    }
    private T Resource<T>(string name) => (T)resources[name];
    private TextBlock Note(string key, double top)
    {
        var value = new TextBlock { Text = ui.Text(key), FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, top, 0, 0) };
        value.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); return value;
    }
    internal void Update(CompactProjection value, bool docked)
    {
        data = value;
        string next = docked + ":" + string.Join(",", value.EditorLeading) + ":" + string.Join(",", value.EditorTrailing);
        if (next == signature) return;
        var focused = Keyboard.FocusedElement as FrameworkElement;
        string? focus = focused?.Tag as string;
        CancelGesture(); signature = next; chips.Clear();
        foreach (string lane in new[] { "leading", "trailing" })
        {
            var stack = lanes[lane]; stack.Children.Clear(); bool right = lane == "trailing";
            string title = ui.Text(docked ? right ? "layout.lane.strip_bottom" : "layout.lane.strip_top" : "layout.lane." + lane);
            AutomationProperties.SetName(stack, title);
            var caption = new TextBlock { Text = title, FontSize = 11, FontWeight = FontWeights.Medium, HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 8) };
            caption.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); stack.Children.Add(caption);
            var ids = right ? value.EditorTrailing : value.EditorLeading;
            if (ids.Length == 0) { var empty = Note("layout.drop_here", 0); empty.Padding = new Thickness(0, 5, 0, 5); empty.HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left; stack.Children.Add(empty); }
            else
            {
                var flow = new ChipFlow { Trailing = right };
                foreach (string id in ids) { var chip = Chip(value.Components.Single(item => item.Id == id)); chips[id] = chip; flow.Children.Add(chip); }
                stack.Children.Add(flow);
            }
        }
        var body = (StackPanel)Children[0]; body.Children.OfType<TextBlock>().Single(item => item.Name == "StripHelp").Visibility = docked ? Visibility.Visible : Visibility.Collapsed;
        if (focus != null && chips.TryGetValue(focus, out var restore)) ((Grid)restore.Child).Children[0].Focus();
    }
    private Border Chip(CompactComponent value)
    {
        var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = new IconGlyph { Symbol = value.Symbol, Width = 9, Height = 9, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center }; icon.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary"); label.Children.Add(icon);
        label.Children.Add(new TextBlock { Text = value.ShortLabel, FontSize = 11, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center });
        var grip = new ChipHandle { Child = label, Focusable = true, Tag = value.Id, Background = Brushes.Transparent, Cursor = Cursors.SizeAll };
        Identify(grip, "compact.chip." + value.Id, value.Label); AutomationProperties.SetHelpText(grip, value.Detail);
        var hideIcon = new IconGlyph { Symbol = "xmark", Width = 8, Height = 8 }; hideIcon.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        var hide = new Button { Style = Resource<Style>("SettingsLink"), ContentTemplate = null, Padding = new Thickness(0), Width = 14, Height = 18, Margin = new Thickness(4, 0, 0, 0), Content = hideIcon, VerticalAlignment = VerticalAlignment.Center };
        Identify(hide, "compact.hide." + value.Id, value.HideLabel);
        hide.ToolTip = AutomationProperties.GetName(hide);
        hide.Click += async (_, _) => { if (IsEnabled && hide.IsVisible) await edit(new("hide", value.Id)); };
        Grid.SetColumn(hide, 1); row.Children.Add(grip); row.Children.Add(hide);
        var chip = new Border { Child = row, CornerRadius = new CornerRadius(13), Padding = new Thickness(8, 4, 4, 4) };
        var stroke = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13), Margin = new Thickness(-8, -4, -4, -4), IsHitTestVisible = false };
        Grid.SetColumnSpan(stroke, 2); row.Children.Add(stroke);
        chip.SetResourceReference(Border.BackgroundProperty, "SettingsCompactChip"); stroke.SetResourceReference(Border.BorderBrushProperty, "SettingsSeparator");
        grip.GotKeyboardFocus += (_, _) => stroke.SetResourceReference(Border.BorderBrushProperty, "SettingsAccent");
        grip.LostKeyboardFocus += (_, _) => stroke.SetResourceReference(Border.BorderBrushProperty, "SettingsSeparator");
        grip.KeyDown += async (_, e) => { if (IsEnabled && grip.IsVisible && e.Key is Key.Left or Key.Right) { e.Handled = true; await Apply(new("shift", value.Id, Offset: e.Key == Key.Left ? -1 : 1), value.Id); } };
        grip.MouseLeftButtonDown += (_, e) => { if (!BeginPointer(value.Id, e.GetPosition(this))) return; grip.Focus(); handle = grip; grip.CaptureMouse(); e.Handled = true; };
        grip.MouseMove += (_, e) => MovePointer(e.GetPosition(this), Mouse.LeftButton == MouseButtonState.Pressed);
        grip.MouseLeftButtonUp += async (_, e) =>
        {
            if (pressed != value.Id) return;
            e.Handled = true; await EndPointer(e.GetPosition(this));
        };
        grip.LostMouseCapture += (_, _) => CancelGesture();
        var menu = new ContextMenu();
        foreach (var command in new[] { ("layout.move_left", new CompactEdit("move", value.Id, "leading")), ("layout.move_right", new CompactEdit("move", value.Id, "trailing")),
            ("layout.earlier", new CompactEdit("shift", value.Id, Offset: -1)), ("layout.later", new CompactEdit("shift", value.Id, Offset: 1)) })
        {
            var item = new MenuItem { Header = ui.Text(command.Item1) }; var action = command.Item2;
            item.Click += async (_, _) => { if (IsEnabled && grip.IsVisible) await Apply(action, value.Id); }; menu.Items.Add(item);
        }
        grip.ContextMenu = menu; return chip;
    }
    private async Task Apply(CompactEdit action, string focus)
    {
        await edit(action);
        if (IsVisible && IsEnabled && chips.TryGetValue(focus, out var chip)) ((Grid)chip.Child).Children[0].Focus();
    }
    internal bool BeginPointer(string component, Point point)
    {
        if (!IsEnabled || !IsVisible || !chips.ContainsKey(component) || !Finite(point)) return false;
        CancelGesture(); pressed = component; origin = point; return true;
    }
    internal async Task EndPointer(Point point)
    {
        string? id = dragged; CancelGesture();
        if (id != null && IsEnabled && IsVisible && Finite(point) && DropAt(point) is var drop && drop.Lane != null)
            await Apply(new("move", id, drop.Lane, drop.Before), id);
    }
    internal void MovePointer(Point point, bool leftPressed)
    {
        if (pressed == null || !leftPressed) return;
        if (!Finite(point)) { CancelGesture(); return; }
        if (dragged == null && (point - origin).Length < 5) return;
        if (dragged == null && data != null)
        {
            dragged = pressed; chips[dragged].Opacity = .4; outline.Opacity = .55;
            var item = data.Components.Single(value => value.Id == dragged);
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            label.Children.Add(new IconGlyph { Symbol = item.Symbol, Width = 9, Height = 9, Ink = Brushes.Black, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center });
            label.Children.Add(new TextBlock { Text = item.ShortLabel, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = Brushes.Black });
            ghost = new Border { Child = label, CornerRadius = new CornerRadius(16), Padding = new Thickness(8) }; ghost.SetResourceReference(Border.BackgroundProperty, "SettingsAccent"); overlay.Children.Add(ghost);
        }
        if (ghost != null) { ghost.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); Canvas.SetLeft(ghost, point.X - ghost.DesiredSize.Width / 2); Canvas.SetTop(ghost, point.Y - ghost.DesiredSize.Height / 2); }
    }
    private static bool Finite(Point point) => double.IsFinite(point.X) && double.IsFinite(point.Y);
    private (string? Lane, string? Before) DropAt(Point point)
    {
        foreach (var lane in lanes)
        {
            if (!Bounds(lane.Value).Contains(point)) continue;
            var candidates = chips.Where(pair => lane.Value.IsAncestorOf(pair.Value)).Select(pair => (Id: pair.Key, Box: Bounds(pair.Value))).ToArray();
            string? before = candidates.Where(item => Math.Abs(item.Box.Top + item.Box.Height / 2 - point.Y) <= item.Box.Height / 2 + 3)
                .OrderBy(item => item.Box.Left + item.Box.Width / 2).FirstOrDefault(item => point.X < item.Box.Left + item.Box.Width / 2).Id;
            before ??= candidates.Where(item => item.Box.Top > point.Y).OrderBy(item => item.Box.Top).ThenBy(item => item.Box.Left).FirstOrDefault().Id;
            return (lane.Key, before);
        }
        return (null, null);
    }
    private Rect Bounds(FrameworkElement element) => new(element.TranslatePoint(new Point(), this), element.RenderSize);
    internal void CancelGesture()
    {
        pressed = dragged = null; overlay.Children.Clear(); ghost = null; outline.Opacity = 0;
        foreach (var value in chips.Values) value.Opacity = 1;
        var captured = handle; handle = null; if (captured?.IsMouseCaptured == true) captured.ReleaseMouseCapture();
    }
    private static void Identify(DependencyObject element, string id, string name) { AutomationProperties.SetAutomationId(element, id); AutomationProperties.SetName(element, name); }
    private sealed class ChipHandle : Border
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
        private sealed class Peer(ChipHandle owner) : FrameworkElementAutomationPeer(owner)
        {
            protected override string GetClassNameCore() => "PacerCompactChip";
            protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Custom;
            protected override List<AutomationPeer>? GetChildrenCore() => null;
        }
    }
    private sealed class ChipFlow : Panel
    {
        internal bool Trailing;
        private IEnumerable<(List<(UIElement Element, Size Size)> Items, double Width, double Height)> Rows(double width)
        {
            var row = new List<(UIElement, Size)>(); double x = 0, height = 0;
            foreach (UIElement child in Children)
            {
                Size size = child.DesiredSize;
                if (row.Count > 0 && x + 6 + size.Width > width) { yield return (row, x, height); row = []; x = height = 0; }
                if (row.Count > 0) x += 6; x += size.Width; height = Math.Max(height, size.Height); row.Add((child, size));
            }
            if (row.Count > 0) yield return (row, x, height);
        }
        protected override Size MeasureOverride(Size available)
        {
            foreach (UIElement child in Children) child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var rows = Rows(available.Width).ToArray(); return new(Math.Min(available.Width, rows.Select(row => row.Width).DefaultIfEmpty().Max()), rows.Sum(row => row.Height) + Math.Max(0, rows.Length - 1) * 6);
        }
        protected override Size ArrangeOverride(Size final)
        {
            double y = 0;
            foreach (var row in Rows(final.Width))
            {
                double x = Trailing ? final.Width - row.Width : 0;
                foreach (var item in row.Items) { item.Element.Arrange(new Rect(new Point(x, y + (row.Height - item.Size.Height) / 2), item.Size)); x += item.Size.Width + 6; }
                y += row.Height + 6;
            }
            return final;
        }
    }
}
