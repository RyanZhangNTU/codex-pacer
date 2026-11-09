using System;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private sealed class MoveGesture(Point start, Point grab, DisplayMonitor? monitor, FrameworkElement capture)
    {
        internal Point Start { get; } = start;
        internal Point Grab { get; } = grab;
        internal FrameworkElement Capture { get; } = capture;
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
        // Measure across the whole visible bar; the header band is inset by its margins.
        var across = e.GetPosition(Shell); var within = e.GetPosition(bar);
        var grab = new Point(Math.Clamp(across.X / Math.Max(1, Shell.ActualWidth), 0, 1),
            Math.Clamp(within.Y / Math.Max(1, bar.ActualHeight), 0, 1));
        move = new(PointerPixels(), grab, SelectedDisplay.Display, bar);
        if (!bar.CaptureMouse()) { move = null; return; }
        collapse.Stop();
        e.Handled = true;
    }

    private void OnMovePointerMotion(object sender, MouseEventArgs e)
    {
        if (move is not { } gesture) return;
        if (e.LeftButton != MouseButtonState.Pressed) { CancelMove(); return; }
        if (!CanMove) return;
        var cursor = PointerPixels();
        if (!gesture.Active)
        {
            var delta = (cursor - gesture.Start) / VisualTreeHelper.GetDpi(this).DpiScaleX;
            // Leaving the notch is a mode change, so a jittery click must not start it.
            double slack = (displayedPlacement ?? compactPreferences).DisplayMode == "notch" ? 3 : 1;
            if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance * slack &&
                Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance * slack) return;
            StartMove(gesture);
        }
        UpdateMove(gesture, cursor);
        e.Handled = true;
    }

    private void OnMovePointerUp(object sender, MouseButtonEventArgs e)
    {
        if (move is not { } gesture) return;
        e.Handled = true;
        if (gesture.Active)
        {
            UpdateMove(gesture, PointerPixels());
            if (move == gesture) _ = FinishMoveAsync(gesture);
            return;
        }
        EndMove(gesture);
        var point = e.GetPosition(gesture.Capture);
        if (new Rect(gesture.Capture.RenderSize).Contains(point)) { SetPinned(!pinned); SetExpanded(true); }
        else if (!pinned) collapse.Start();
    }

    // Esc drops a drag where it began, as on the Mac.
    private void OnMoveKey(object sender, KeyEventArgs e)
    {
        if (move == null || e.Key != Key.Escape) return;
        e.Handled = true;
        CancelMove();
    }

    private void StartMove(MoveGesture gesture)
    {
        collapse.Stop();
        if (expanded) SetExpanded(false, snap: true); else Relayout(snap: true);
        gesture.Size = new(destination.Width, destination.Height);
        gesture.Active = true;
        // The shoulders and shadow belong to a settled edge; they return when the island lands.
        decoration?.Conceal();
    }

    private void UpdateMove(MoveGesture gesture, Point cursor, bool retryDpi = true)
    {
        if (move != gesture || !CanMove) return;
        gesture.Cursor = cursor;
        var monitor = IslandPlacementGeometry.MonitorAt(displays.Current, cursor.X, cursor.Y, gesture.Monitor);
        bool crossed = monitor != gesture.Monitor;
        if (crossed) { gesture.Monitor = monitor; gesture.Edge = IslandEdge.Free; }
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
        if (gesture.Capture.IsMouseCaptured) gesture.Capture.ReleaseMouseCapture();
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
            // Moving within the display shown keeps the saved choice, including a
            // disconnected display it fell back from; dropping on another display selects it.
            var oldDisplay = DisplaySelection.Resolve(displays.Current, previous);
            if (gesture.Monitor is { } monitor && monitor != oldDisplay.Display)
                previous = monitor.Choose(previous);
            return previous with { IslandPlacement = placement, DisplayMode = "floating" };
        }
        displayedPlacement = Edit(compactPreferences);
        if (pinned) SetExpanded(true, snap: true); else Relayout(snap: true);
        PreferencesApplyResult result;
        try { result = await save(Edit); }
        // An unexpected failure still releases the shown placement, so the island can move again.
        catch (Exception error) when (error is not OutOfMemoryException) { result = PreferencesApplyResult.EngineFailed; }
        finally { displayedPlacement = null; }
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
        // Crossing a DPI boundary makes WPF apply its suggested size afterwards; restore the outline's pixels.
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(() => { if (IsVisible && pixels is { } target) NativeWindowBounds.ApplyPixels(this, target); },
            System.Windows.Threading.DispatcherPriority.Input);
    }
    private MotionBounds? pixels;

    internal void ShowAt(MotionBounds bounds, double scale, bool highContrast)
    {
        outline.BorderBrush = highContrast ? SystemColors.HighlightBrush : Brushes.DeepSkyBlue;
        if (!IsVisible)
        {
            Left = bounds.X; Top = bounds.Y; Width = bounds.Width; Height = bounds.Height;
            Show();
        }
        pixels = new(bounds.X * scale, bounds.Y * scale, bounds.Width * scale, bounds.Height * scale);
        NativeWindowBounds.ApplyPixels(this, pixels.Value);
    }
}
