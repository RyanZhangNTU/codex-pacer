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

/// The Collapsed Bar page's preview, as on the Mac: the bar on a desktop,
/// drawn with the island's own components and live values. Clicking a
/// component selects it for the settings beside the preview; dragging moves
/// it within its side or to the other side. A component with nothing to show
/// right now keeps its place as a faint label, so it can still be found and
/// moved. All edits return to the shared model through the preferences owner.
internal sealed class CompactLayoutEditorView : Grid
{
    private const double BarHeight = 34, MenuBarHeight = 24, DeskHeight = 122;
    private readonly UiText ui;
    private readonly Func<CompactEdit, Task> edit;
    private readonly ResourceDictionary resources;
    private readonly Border desk, bar;
    private readonly Grid barGrid = new();
    private readonly Border cameraGap = new() { Width = 18 };
    private readonly Dictionary<string, StackPanel> lanes = new();
    private readonly Dictionary<string, ChipHandle> chips = new();
    private readonly TextBlock stripHelp;
    private readonly Canvas overlay = new() { IsHitTestVisible = false };
    private CompactProjection? data;
    private string signature = "";
    private string? selected, hovered, pressed, dragged;
    private Point origin;
    private FrameworkElement? handle;
    private Border? ghost;
    private bool attached;
    /// A click (not a drag) or Return on a component selects it for the settings beside the preview.
    internal event Action<string>? ComponentSelected;

    internal CompactLayoutEditorView(UiText ui, ResourceDictionary resources, Func<CompactEdit, Task> edit)
    {
        this.ui = ui; this.resources = resources; this.edit = edit;
        var content = new StackPanel(); Children.Add(content);
        // A strip of desktop under a menu bar, with the bar where the island shows it.
        var scene = new Grid { Height = DeskHeight, Background = Wallpaper() };
        scene.Children.Add(new Border { Height = MenuBarHeight, VerticalAlignment = VerticalAlignment.Top, Background = new SolidColorBrush(Color.FromArgb(56, 0, 0, 0)) });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        foreach (string lane in new[] { "leading", "trailing" })
        {
            var stack = new StackPanel { Orientation = Orientation.Horizontal, MinWidth = 64, MinHeight = BarHeight, Background = Brushes.Transparent,
                HorizontalAlignment = lane == "leading" ? HorizontalAlignment.Left : HorizontalAlignment.Right };
            Identify(stack, "compact.lane." + lane, ui.Text("layout.lane." + lane)); lanes[lane] = stack;
            var host = new Grid { MinWidth = 64 }; host.Children.Add(stack);
            Grid.SetColumn(host, lane == "leading" ? 0 : 2); barGrid.Children.Add(host);
        }
        Grid.SetColumn(cameraGap, 1); barGrid.Children.Add(cameraGap);
        bar = new Border { Child = barGrid, Height = BarHeight, Padding = new Thickness(10, 0, 10, 0), Background = Brushes.Black, VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Center };
        // A wide bar shrinks to the page rather than overflowing it.
        scene.Children.Add(new Viewbox { Child = bar, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(10, 0, 10, 0) });
        desk = new Border { Child = scene, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), ClipToBounds = true };
        desk.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        desk.SizeChanged += (_, e) => scene.Clip = new RectangleGeometry(new Rect(e.NewSize), 11, 11);
        content.Children.Add(desk);
        stripHelp = new TextBlock { Text = ui.Text("layout.strip_help"), FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0), Visibility = Visibility.Collapsed };
        stripHelp.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary"); content.Children.Add(stripHelp);
        Children.Add(overlay);
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && (pressed != null || dragged != null)) { CancelGesture(); e.Handled = true; } };
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelGesture(); };
        Unloaded += (_, _) => CancelGesture();
    }
    private T Resource<T>(string name) => (T)resources[name];

    internal void SetSelected(string? id) { selected = id; Paint(); }

    /// The bar as the island shows it now: its components in their lanes with live values.
    internal void Update(CompactProjection value, bool docked, bool attached = false, EngineSnapshot? snapshot = null)
    {
        data = value; this.attached = attached;
        bar.CornerRadius = attached ? new CornerRadius(0, 0, 14, 14) : new CornerRadius(BarHeight / 2);
        bar.Margin = new Thickness(0, attached ? 0 : MenuBarHeight + 10, 0, 0);
        stripHelp.Visibility = docked ? Visibility.Visible : Visibility.Collapsed;
        foreach (string lane in lanes.Keys)
        {
            string title = ui.Text(docked ? lane == "trailing" ? "layout.lane.strip_bottom" : "layout.lane.strip_top" : "layout.lane." + lane);
            AutomationProperties.SetName(lanes[lane], title);
        }
        string next = string.Join(",", value.EditorLeading) + ":" + string.Join(",", value.EditorTrailing);
        if (next != signature)
        {
            string? focus = (Keyboard.FocusedElement as FrameworkElement)?.Tag as string;
            CancelGesture(); signature = next;
            foreach (var chip in chips.Values) PageAccessibility.Retire(chip);
            chips.Clear();
            foreach (var lane in lanes)
            {
                lane.Value.Children.Clear();
                var ids = lane.Key == "trailing" ? value.EditorTrailing : value.EditorLeading;
                if (ids.Length == 0) lane.Value.Children.Add(DropHere());
                foreach (string id in ids)
                {
                    var chip = Chip(value.Components.Single(item => item.Id == id));
                    chip.Margin = new Thickness(lane.Value.Children.Count == 0 ? 0 : attached ? 4 : 6, 0, 0, 0);
                    chips[id] = chip; lane.Value.Children.Add(chip);
                }
            }
            if (focus != null && chips.TryGetValue(focus, out var restore)) restore.Focus();
        }
        foreach (var chip in chips)
            if (value.Components.FirstOrDefault(item => item.Id == chip.Key) is { } component) Fill(chip.Value, component, value, snapshot);
        Paint();
    }

    /// A side with nothing on it: a dashed "Drop here", as on the Mac.
    private Border DropHere()
    {
        var label = new TextBlock { Text = ui.Text("layout.drop_here"), FontSize = 10.5, Foreground = new SolidColorBrush(Color.FromArgb(115, 255, 255, 255)), VerticalAlignment = VerticalAlignment.Center };
        var dashed = new System.Windows.Shapes.Rectangle { RadiusX = 7, RadiusY = 7, StrokeThickness = 1, StrokeDashArray = [3, 3], Stroke = new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)) };
        var grid = new Grid { Height = 24, VerticalAlignment = VerticalAlignment.Center }; grid.Children.Add(dashed);
        label.Margin = new Thickness(8, 0, 8, 0); grid.Children.Add(label);
        return new Border { Child = grid, VerticalAlignment = VerticalAlignment.Center };
    }

    private ChipHandle Chip(CompactComponent value)
    {
        var chip = new ChipHandle { Focusable = true, Tag = value.Id, Background = Brushes.Transparent, CornerRadius = new CornerRadius(7), Padding = new Thickness(5, 0, 5, 0),
            BorderThickness = new Thickness(1.5), BorderBrush = Brushes.Transparent, Height = 28, VerticalAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand };
        Identify(chip, "compact.chip." + value.Id, value.Label); AutomationProperties.SetHelpText(chip, value.Detail);
        chip.Invoked = () => { if (IsEnabled && chip.IsVisible) ComponentSelected?.Invoke(value.Id); };
        chip.GotKeyboardFocus += (_, _) => Paint(); chip.LostKeyboardFocus += (_, _) => Paint();
        chip.MouseEnter += (_, _) => { hovered = value.Id; Paint(); };
        chip.MouseLeave += (_, _) => { if (hovered == value.Id) hovered = null; Paint(); };
        chip.KeyDown += async (_, e) =>
        {
            if (!IsEnabled || !chip.IsVisible) return;
            if (e.Key is Key.Enter or Key.Space) { e.Handled = true; ComponentSelected?.Invoke(value.Id); return; }
            if (e.Key is Key.Left or Key.Right) { e.Handled = true; await Apply(new("shift", value.Id, Offset: e.Key == Key.Left ? -1 : 1), value.Id); return; }
            if (e.Key is Key.Delete or Key.Back) { e.Handled = true; await edit(new("hide", value.Id)); }
        };
        chip.MouseLeftButtonDown += (_, e) => { if (!BeginPointer(value.Id, e.GetPosition(this))) return; chip.Focus(); handle = chip; chip.CaptureMouse(); e.Handled = true; };
        chip.MouseMove += (_, e) => MovePointer(e.GetPosition(this), Mouse.LeftButton == MouseButtonState.Pressed);
        chip.MouseLeftButtonUp += async (_, e) =>
        {
            if (pressed != value.Id) return;
            e.Handled = true; await EndPointer(e.GetPosition(this));
        };
        chip.LostMouseCapture += (_, _) => CancelGesture();
        var menu = new ContextMenu();
        foreach (var (key, action) in new[] { ("layout.move_left", new CompactEdit("move", value.Id, "leading")), ("layout.move_right", new CompactEdit("move", value.Id, "trailing")),
            ("layout.earlier", new CompactEdit("shift", value.Id, Offset: -1)), ("layout.later", new CompactEdit("shift", value.Id, Offset: 1)), ("main.collapsed.remove", new CompactEdit("hide", value.Id)) })
        {
            if (key == "main.collapsed.remove") menu.Items.Add(new Separator());
            var item = new MenuItem { Header = ui.Text(key) };
            item.Click += async (_, _) => { if (IsEnabled && chip.IsVisible) await Apply(action, value.Id); }; menu.Items.Add(item);
        }
        chip.ContextMenu = menu; return chip;
    }

    /// The component as the island draws it, or its symbol and short name, faint, when it has nothing to show now.
    private void Fill(ChipHandle chip, CompactComponent value, CompactProjection projection, EngineSnapshot? snapshot)
    {
        UIElement? live = value.Visible ? LiveComponent(value, projection, snapshot) : null;
        if (live is FrameworkElement element) { element.IsHitTestVisible = false; element.VerticalAlignment = VerticalAlignment.Center; }
        chip.Child = live ?? FaintLabel(value);
        chip.ToolTip = live != null ? value.Label : ui.Has("main.collapsed.nothing_now") ? ui.Text("main.collapsed.nothing_now").Replace("%@", value.Label, StringComparison.Ordinal) : value.Label;
    }
    private static UIElement FaintLabel(CompactComponent value)
    {
        var faint = new SolidColorBrush(Color.FromArgb(128, 255, 255, 255));
        var label = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(new IconGlyph { Symbol = value.Symbol, Width = 9.5, Height = 9.5, Ink = faint, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center });
        label.Children.Add(new TextBlock { Text = value.ShortLabel, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = faint, VerticalAlignment = VerticalAlignment.Center });
        return label;
    }
    private static TextBlock BarText(string? text, double size, FontWeight weight, Brush ink)
    {
        var value = new TextBlock { Text = text ?? "", FontFamily = PacerFonts.Interface, FontSize = size, FontWeight = weight, Foreground = ink, VerticalAlignment = VerticalAlignment.Center };
        System.Windows.Documents.Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular); return value;
    }
    /// The island's own component for this slot, filled from the same projection and snapshot.
    private static UIElement? LiveComponent(CompactComponent value, CompactProjection projection, EngineSnapshot? snapshot)
    {
        switch (value.Id)
        {
            case "activity":
                if (snapshot?.Presentation?.Header is not EngineHeader header) return null;
                if (projection.SingleTaskCount && header.ActiveCount == 1) header = header with { CoreSymbol = null };
                var badge = new ActivityBadge(); badge.Update(header, false); return badge;
            case "status": return BarText(value.Text, 12, FontWeights.Medium, PacerPalette.Primary);
            case "tps":
                var rate = new StackPanel { Orientation = Orientation.Horizontal };
                rate.Children.Add(BarText(value.Text, 12, FontWeights.SemiBold, snapshot?.RateIsFresh == true ? PacerPalette.Primary : PacerPalette.Secondary));
                var unit = BarText("t/s", 9, FontWeights.Medium, new SolidColorBrush(Color.FromRgb(0x6B, 0x6B, 0x6B))); unit.Margin = new Thickness(2, 0, 0, 0); rate.Children.Add(unit);
                return rate;
            case "firstOutput": return BarText(value.Text, 11, FontWeights.Medium, PacerPalette.Secondary);
            case "warnings": var warnings = new CompactWarningsView(); warnings.Update(snapshot?.CompactWarnings); return warnings;
            case "quotaGauge": var gauge = new CompactQuotaGlyph { Width = 18, Height = 18 }; gauge.Update(projection, snapshot?.Wallet); return gauge;
            case "priceClock": var clock = new DeepSeekPriceClock { Width = 18, Height = 18 }; clock.Update(snapshot?.Wallet); return clock;
            case "quota":
                var quota = new AlternatingQuotaText { FontSize = 12 };
                quota.Update(value.Entries.Select(entry => (entry.Provider, entry.Text)).ToArray(), false, value.Entries.Select(entry => entry.Dimmed).ToArray()); return quota;
            case "timeRemaining":
                var time = new StackPanel { Orientation = Orientation.Horizontal };
                time.Children.Add(new IconGlyph { Symbol = "hourglass", Width = 9, Height = 9, Ink = PacerPalette.Tertiary, Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center });
                foreach (var entry in value.Entries)
                {
                    if (time.Children.Count > 1) time.Children.Add(new Border { Width = 1, Height = 10, Background = PacerPalette.Hairline, Margin = new Thickness(7, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center });
                    var text = BarText(entry.Text, 11, FontWeights.Medium, PacerPalette.Provider(entry.Provider)); text.Opacity = .85; time.Children.Add(text);
                }
                return time;
            default: return null;
        }
    }

    /// Selected in the accent at 30%, hovered in white at 10%, ringed in the accent while selected or focused, faded while dragged.
    private void Paint()
    {
        var accent = TryFindResource("SettingsAccent") as SolidColorBrush ?? new SolidColorBrush(Color.FromRgb(0, 122, 255));
        foreach (var chip in chips)
        {
            bool isSelected = chip.Key == selected;
            chip.Value.Background = isSelected ? new SolidColorBrush(Color.FromArgb(77, accent.Color.R, accent.Color.G, accent.Color.B))
                : chip.Key == hovered ? new SolidColorBrush(Color.FromArgb(26, 255, 255, 255)) : Brushes.Transparent;
            chip.Value.BorderBrush = isSelected || chip.Value.IsKeyboardFocused ? accent : Brushes.Transparent;
            chip.Value.Opacity = chip.Key == dragged ? .35 : 1;
        }
        if (dragged != null) { desk.BorderBrush = new SolidColorBrush(Color.FromArgb(153, accent.Color.R, accent.Color.G, accent.Color.B)); desk.BorderThickness = new Thickness(1.5); }
        else { desk.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder"); desk.BorderThickness = new Thickness(1); }
    }

    private async Task Apply(CompactEdit action, string focus)
    {
        await edit(action);
        if (IsVisible && IsEnabled && chips.TryGetValue(focus, out var chip)) chip.Focus();
    }
    internal bool BeginPointer(string component, Point point)
    {
        if (!IsEnabled || !IsVisible || !chips.ContainsKey(component) || !Finite(point)) return false;
        CancelGesture(); pressed = component; origin = point; return true;
    }
    internal async Task EndPointer(Point point)
    {
        string? id = dragged, clicked = pressed; CancelGesture();
        if (id == null && clicked != null) { ComponentSelected?.Invoke(clicked); return; }
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
            // Dragging selects the component too, as on the Mac.
            dragged = pressed; ComponentSelected?.Invoke(dragged);
            var item = data.Components.Single(value => value.Id == dragged);
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            label.Children.Add(new IconGlyph { Symbol = item.Symbol, Width = 10, Height = 10, Ink = Brushes.White, Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center });
            label.Children.Add(new TextBlock { Text = item.ShortLabel, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = Brushes.White });
            ghost = new Border { Child = label, CornerRadius = new CornerRadius(12), Padding = new Thickness(9, 5, 9, 5) }; ghost.SetResourceReference(Border.BackgroundProperty, "SettingsAccent"); overlay.Children.Add(ghost);
            Paint();
        }
        if (ghost != null) { ghost.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); Canvas.SetLeft(ghost, point.X - ghost.DesiredSize.Width / 2); Canvas.SetTop(ghost, point.Y - ghost.DesiredSize.Height / 2); }
    }
    private static bool Finite(Point point) => double.IsFinite(point.X) && double.IsFinite(point.Y);
    /// A drop lands in the side nearest the pointer, before the first component whose middle lies to its right, or at the end of that side.
    private (string? Lane, string? Before) DropAt(Point point)
    {
        static double Distance(Point point, Rect box)
        {
            double dx = Math.Max(Math.Max(box.Left - point.X, 0), point.X - box.Right), dy = Math.Max(Math.Max(box.Top - point.Y, 0), point.Y - box.Bottom);
            return dx * dx + dy * dy;
        }
        var lane = lanes.OrderBy(item => Distance(point, Bounds(item.Value))).FirstOrDefault();
        if (lane.Value == null) return (null, null);
        string? before = chips.Where(pair => lane.Value.Children.Contains(pair.Value)).Select(pair => (Id: pair.Key, Box: Bounds(pair.Value)))
            .OrderBy(item => item.Box.Left + item.Box.Width / 2).FirstOrDefault(item => point.X < item.Box.Left + item.Box.Width / 2).Id;
        return (lane.Key, before);
    }
    private Rect Bounds(FrameworkElement element) => element.TransformToAncestor(this).TransformBounds(new Rect(element.RenderSize));
    internal void CancelGesture()
    {
        pressed = dragged = null; overlay.Children.Clear(); ghost = null;
        var captured = handle; handle = null; if (captured?.IsMouseCaptured == true) captured.ReleaseMouseCapture();
        Paint();
    }

    /// The Mac's soft desktop: blue to violet to peach with two glows.
    private static Brush Wallpaper()
    {
        var group = new DrawingGroup(); var bounds = new RectangleGeometry(new Rect(0, 0, 1, 1));
        group.Children.Add(new GeometryDrawing(new LinearGradientBrush(new GradientStopCollection
        { new(Color.FromRgb(61, 77, 120), 0), new(Color.FromRgb(115, 97, 143), 0.5), new(Color.FromRgb(219, 148, 120), 1) }, new Point(0, 0), new Point(1, 1)), null, bounds));
        group.Children.Add(new GeometryDrawing(new RadialGradientBrush(Color.FromArgb(150, 250, 199, 140), Color.FromArgb(0, 250, 199, 140))
        { Center = new Point(0.72, 0.62), GradientOrigin = new Point(0.72, 0.62), RadiusX = 0.25, RadiusY = 0.7 }, null, bounds));
        group.Children.Add(new GeometryDrawing(new RadialGradientBrush(Color.FromArgb(150, 77, 140, 191), Color.FromArgb(0, 77, 140, 191))
        { Center = new Point(0.25, 0.55), GradientOrigin = new Point(0.25, 0.55), RadiusX = 0.25, RadiusY = 0.75 }, null, bounds));
        var brush = new DrawingBrush(group) { Stretch = Stretch.Fill }; brush.Freeze(); return brush;
    }
    private static void Identify(DependencyObject element, string id, string name) { AutomationProperties.SetAutomationId(element, id); AutomationProperties.SetName(element, name); }
    /// A component on the preview bar; invoking it selects it, as the Mac's accessibility action does.
    private sealed class ChipHandle : Border
    {
        internal Action? Invoked;
        protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
        private sealed class Peer(ChipHandle owner) : FrameworkElementAutomationPeer(owner), System.Windows.Automation.Provider.IInvokeProvider
        {
            protected override string GetClassNameCore() => "PacerCompactChip";
            protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;
            protected override List<AutomationPeer>? GetChildrenCore() => null;
            protected override bool IsKeyboardFocusableCore() => true;
            public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.Invoke ? this : base.GetPattern(pattern);
            public void Invoke()
            {
                if (!owner.IsEnabled) throw new ElementNotEnabledException();
                owner.Invoked?.Invoke();
            }
        }
    }
}
