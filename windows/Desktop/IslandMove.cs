using System;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private sealed class MoveGesture(Point start, Point grab, DisplayMonitor? monitor, FrameworkElement? capture)
    {
        internal Point Start { get; } = start;
        internal Point Grab { get; } = grab;
        internal FrameworkElement? Capture { get; } = capture;
        internal Point Cursor = start;
        internal DisplayMonitor? Monitor = monitor;
        internal bool Active;
        internal IslandPlacement? Placement;
        internal IslandEdge Edge;
        internal Size Size;
    }

    private MoveGesture? move;
    private IslandSnapPreview? snapPreview;
    private DesktopPreferences? displayedPlacement;
    private double dragHeaderWidth;
    internal Func<Func<DesktopPreferences, DesktopPreferences>, Task<PreferencesApplyResult>>? SaveIslandPlacement { get; set; }

    private void InitializeMove()
    {
        foreach (var bar in new[] { Header, Strip })
        {
            bar.PreviewMouseLeftButtonDown += OnMovePointerDown;
            bar.PreviewMouseLeftButtonUp += OnMovePointerUp;
            bar.PreviewMouseMove += OnMovePointerMotion;
            bar.LostMouseCapture += (_, _) => { if (move?.Capture == bar) CancelMove(); };
        }
        MoveMenu.Header = ui.Text("windows.position.move");
        MoveMenu.ToolTip = ui.Text("windows.position.keyboard");
        AutomationProperties.SetHelpText(MoveMenu, ui.Text("windows.position.keyboard"));
        Deactivated += (_, _) => { if (move is { Capture: null }) CancelMove(); };
        PreviewKeyDown += OnMoveKey;
    }

    private bool CanMove => IsVisible && !presentationStopped && !updateInputSuspended &&
        displayedPlacement == null && SaveIslandPlacement != null;

    private static Point PointerPixels()
    {
        var pointer = System.Windows.Forms.Cursor.Position;
        return new(pointer.X, pointer.Y);
    }

    private void OnMovePointerDown(object sender, MouseButtonEventArgs e)
    {
        if (presentationStopped || updateInputSuspended || move != null || sender is not FrameworkElement bar) return;
        var pointer = e.GetPosition(bar);
        var grab = new Point(Math.Clamp(pointer.X / Math.Max(1, bar.ActualWidth), 0, 1),
            Math.Clamp(pointer.Y / Math.Max(1, bar.ActualHeight), 0, 1));
        move = new(PointerPixels(), grab, SelectedDisplay.Display, bar);
        if (!bar.CaptureMouse()) { move = null; return; }
        collapse.Stop();
        e.Handled = true;
    }

    private void OnMovePointerMotion(object sender, MouseEventArgs e)
    {
        if (move is not { Capture: not null } gesture) return;
        if (e.LeftButton != MouseButtonState.Pressed) { CancelMove(); return; }
        if (!CanMove) return;
        var cursor = PointerPixels();
        if (!gesture.Active)
        {
            var delta = (cursor - gesture.Start) / VisualTreeHelper.GetDpi(this).DpiScaleX;
            if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance &&
                Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            StartMove(gesture);
        }
        UpdateMove(gesture, cursor);
        e.Handled = true;
    }

    private void OnMovePointerUp(object sender, MouseButtonEventArgs e)
    {
        if (move is not { Capture: { } bar } gesture) return;
        e.Handled = true;
        if (gesture.Active)
        {
            UpdateMove(gesture, PointerPixels());
            if (move == gesture) _ = FinishMoveAsync(gesture);
            return;
        }
        EndMove(gesture);
        var point = e.GetPosition(bar);
        if (new Rect(bar.RenderSize).Contains(point)) { SetPinned(!pinned); SetExpanded(true); }
        else if (!pinned) collapse.Start();
    }

    private void OnMoveIsland(object sender, RoutedEventArgs e)
    {
        MoreButton.ContextMenu.IsOpen = false;
        if (!CanMove || move != null) return;
        if (VisibleScreenBounds.IsEmpty) return;
        var gesture = new MoveGesture(default, new Point(.5, .5), SelectedDisplay.Display, null);
        move = gesture;
        StartMove(gesture);
        var bar = layout.Position == 0 ? Header : Strip;
        gesture.Cursor = bar.PointToScreen(new Point(bar.ActualWidth / 2, bar.ActualHeight / 2));
        Activate();
        Keyboard.Focus(layout.Position == 0 ? HeaderAction : StripAction);
    }

    private void OnMoveKey(object sender, KeyEventArgs e)
    {
        if (move is not { } gesture) return;
        if (e.Key == Key.Escape) { e.Handled = true; CancelMove(); return; }
        if (gesture.Capture != null) return;
        if (e.Key == Key.Enter) { e.Handled = true; _ = FinishMoveAsync(gesture); return; }
        Vector delta = e.Key switch
        {
            Key.Left => new(-1, 0), Key.Right => new(1, 0), Key.Up => new(0, -1), Key.Down => new(0, 1), _ => new()
        };
        if (delta.LengthSquared == 0) return;
        e.Handled = true;
        UpdateMove(gesture, gesture.Cursor + delta * (12 * VisualTreeHelper.GetDpi(this).DpiScaleX));
    }

    private void StartMove(MoveGesture gesture)
    {
        collapse.Stop();
        if (expanded) SetExpanded(false, snap: true); else Relayout(snap: true);
        gesture.Size = new(destination.Width, destination.Height);
        gesture.Active = true;
    }

    private void UpdateMove(MoveGesture gesture, Point cursor, bool retryDpi = true)
    {
        if (move != gesture || !CanMove) return;
        gesture.Cursor = cursor;
        var monitor = IslandPlacementGeometry.MonitorAt(displays.Current, cursor.X, cursor.Y, gesture.Monitor);
        if (monitor != gesture.Monitor) { gesture.Monitor = monitor; gesture.Edge = IslandEdge.Free; }
        var screen = IslandScreen.Read(this, monitor);
        var bounds = screenGeometry?.Invoke() ?? (screen.Screen, screen.Work);
        var raw = new MotionBounds(cursor.X / screen.Scale - gesture.Grab.X * gesture.Size.Width,
            cursor.Y / screen.Scale - gesture.Grab.Y * gesture.Size.Height, gesture.Size.Width, gesture.Size.Height);
        gesture.Edge = IslandPlacementGeometry.SnapEdge(bounds.Item2, raw, gesture.Edge);
        gesture.Placement = IslandPlacementGeometry.FromFrame(gesture.Edge, bounds.Item2, raw);
        var moving = IslandPlacementGeometry.Clamp(bounds.Item2, raw);
        try
        {
            surfaceBounds = moving;
            NativeWindowBounds.Apply(this, moving);
            if (move != gesture) return;
            // WPF can change the HWND's scale synchronously when it crosses a display.
            // Recompute from the original screen pointer in the new coordinate system.
            if (VisualTreeHelper.GetDpi(this).DpiScaleX != screen.Scale)
            {
                if (retryDpi) UpdateMove(gesture, cursor, retryDpi: false); else QueueMoveDpiRefresh();
                return;
            }
            lastFrame = lastFrame with { Bounds = moving, Window = moving };
            PlaceShell(moving); SyncBackdrop();
            if (gesture.Edge == IslandEdge.Free) snapPreview?.Hide();
            else
            {
                var target = MeasurePlacement(gesture.Placement, bounds.Item1, bounds.Item2, 0, 0, dragHeaderWidth, false).Target;
                (snapPreview ??= new IslandSnapPreview()).ShowAt(target, screen.Scale, appearance.Current.HighContrast);
            }
        }
        catch (Win32Exception) { CancelMove(); }
    }

    private bool moveDpiPending;
    private void QueueMoveDpiRefresh()
    {
        if (move?.Active != true || moveDpiPending) return;
        moveDpiPending = true;
        Dispatcher.BeginInvoke(() =>
        {
            moveDpiPending = false;
            if (move is { Active: true } gesture) UpdateMove(gesture, gesture.Cursor);
        }, DispatcherPriority.Input);
    }

    private void EndMove(MoveGesture gesture)
    {
        move = null;
        if (gesture.Capture?.IsMouseCaptured == true) gesture.Capture.ReleaseMouseCapture();
        snapPreview?.Close(); snapPreview = null;
    }

    private void CancelMove()
    {
        if (move is not { } gesture) return;
        EndMove(gesture);
        if (gesture.Active && IsVisible && !presentationStopped)
        {
            if (pinned && !updateInputSuspended) SetExpanded(true, snap: true); else Relayout(snap: true);
            QueueDisplayRefresh(force: true);
        }
    }

    private async Task FinishMoveAsync(MoveGesture gesture)
    {
        if (move != gesture) return;
        if (gesture.Placement is not { } placement || SaveIslandPlacement is not { } save) { CancelMove(); return; }
        EndMove(gesture);
        DesktopPreferences Edit(DesktopPreferences previous)
        {
            var oldDisplay = DisplaySelection.Resolve(displays.Current, previous);
            if (gesture.Monitor is { } monitor && (oldDisplay.FellBack || monitor != oldDisplay.Display))
                previous = monitor.Choose(previous);
            return previous with { IslandPlacement = placement, DisplayMode = "floating" };
        }
        displayedPlacement = Edit(compactPreferences);
        if (pinned) SetExpanded(true, snap: true); else Relayout(snap: true);
        var result = await save(Edit);
        displayedPlacement = null;
        if (presentationStopped) return;
        Relayout(snap: true); QueueDisplayRefresh(force: true);
        if (result != PreferencesApplyResult.Applied)
            SetStatus(ui.Text(result == PreferencesApplyResult.SaveFailed ? "windows.settings.save_failed" : "windows.settings.apply_failed"));
    }
}

// Only the outline is visible. The layered tool window never takes focus or input.
internal sealed class IslandSnapPreview : Window
{
    private readonly Border outline = new() { BorderThickness = new Thickness(2) };
    internal IslandSnapPreview()
    {
        AllowsTransparency = true; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        Background = Brushes.Transparent; Content = outline; IsHitTestVisible = false;
        SourceInitialized += (_, _) => NativeWindowBounds.MakeInputTransparent(this);
    }

    internal void ShowAt(MotionBounds bounds, double scale, bool highContrast)
    {
        outline.BorderBrush = highContrast ? SystemColors.HighlightBrush : Brushes.DeepSkyBlue;
        if (!IsVisible)
        {
            Left = bounds.X; Top = bounds.Y; Width = bounds.Width; Height = bounds.Height;
            Show();
        }
        NativeWindowBounds.ApplyPixels(this, new(bounds.X * scale, bounds.Y * scale, bounds.Width * scale, bounds.Height * scale));
    }
}
