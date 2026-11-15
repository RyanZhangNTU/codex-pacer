using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Condition = System.Windows.Automation.Condition;

namespace CodexPacer.Windows;

/// Reads where an app's buttons are through UI Automation, for the progress
/// ring's guide. Reads only element names, types and positions in the app's
/// own window; never clicks, types or reads other content.
internal static class AppAutomation
{
    internal const string Tool = "pacer_progress";
    // WorkBuddy's own labels, in the languages it ships.
    internal static readonly string[] CustomConnector = ["自定义连接器", "自定義聯結器", "Custom Connector"];
    internal static readonly string[] Trust = ["信任", "Trust"];

    internal static int[] ProcessIds(IReadOnlyList<string>? executables)
    {
        if (executables is not { Count: > 0 }) return [];
        var ids = new List<int>();
        foreach (string name in executables.Select(path => System.IO.Path.GetFileNameWithoutExtension(path.Replace('/', '\\')))
                     .Where(name => name.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try { foreach (var process in Process.GetProcessesByName(name)) using (process) ids.Add(process.Id); }
            catch (InvalidOperationException) { }
        }
        return [.. ids];
    }

    /// The app's main window on screen, or null while it has none. Electron
    /// apps also own a GPU window as large as the main one; it never counts.
    internal static AutomationElement? MainWindow(int[] processes)
    {
        if (processes.Length == 0) return null;
        Condition owned = processes.Length == 1 ? new PropertyCondition(AutomationElement.ProcessIdProperty, processes[0])
            : new OrCondition(processes.Select(id => (Condition)new PropertyCondition(AutomationElement.ProcessIdProperty, id)).ToArray());
        try
        {
            return AutomationElement.RootElement.FindAll(TreeScope.Children, owned).Cast<AutomationElement>()
                .Where(window => window.Current.ClassName != "Intermediate D3D Window" && !window.Current.IsOffscreen
                    && window.Current.BoundingRectangle is { IsEmpty: false, Width: > 200, Height: > 150 })
                .OrderByDescending(window => window.Current.BoundingRectangle.Width * window.Current.BoundingRectangle.Height).FirstOrDefault();
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or COMException) { return null; }
    }

    private static Condition Named(IEnumerable<string> names, ControlType? type = null)
    {
        var options = names.Select(name => (Condition)new PropertyCondition(AutomationElement.NameProperty, name)).ToArray();
        Condition name = options.Length == 1 ? options[0] : new OrCondition(options);
        var visible = new PropertyCondition(AutomationElement.IsOffscreenProperty, false);
        return type == null ? new AndCondition(name, visible) : new AndCondition(name, visible, new PropertyCondition(AutomationElement.ControlTypeProperty, type));
    }

    /// Which page the app shows: its custom connectors list Pacer's tool; its
    /// connector market has the Custom Connector button.
    internal static string? View(AutomationElement window)
    {
        try
        {
            if (window.FindFirst(TreeScope.Descendants, Named([Tool])) != null) return "customConnectors";
            return window.FindFirst(TreeScope.Descendants, Named(CustomConnector, ControlType.Button)) != null ? "connectors" : null;
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or COMException) { return null; }
    }

    /// The button to point at, in screen pixels: Custom Connector, or the
    /// Trust button nearest Pacer's tool.
    ///
    /// WorkBuddy shows its window's contents to UI Automation only while a
    /// screen reader runs. Custom Connector sits at a fixed spot in the top
    /// right of its connectors page, so without the contents the ring goes
    /// there, measured from the window's frame at its own DPI. Trust moves with
    /// the list, so it is ringed only when the contents can be read.
    internal static Rect? Target(AutomationElement window, string target)
    {
        try
        {
            if (target == "customConnector")
                return window.FindFirst(TreeScope.Descendants, Named(CustomConnector, ControlType.Button))?.Current.BoundingRectangle
                    ?? CustomConnectorFromFrame(window);
            if (window.FindFirst(TreeScope.Descendants, Named([Tool])) is not { } tool) return null;
            Rect anchor = tool.Current.BoundingRectangle;
            return window.FindAll(TreeScope.Descendants, Named(Trust, ControlType.Button)).Cast<AutomationElement>()
                .Select(button => button.Current.BoundingRectangle).Where(rect => !rect.IsEmpty)
                .OrderBy(rect => Math.Abs(rect.Top + rect.Height / 2 - (anchor.Top + anchor.Height / 2)) + Math.Max(0, anchor.Left - rect.Left))
                .Cast<Rect?>().FirstOrDefault();
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or COMException) { return null; }
    }

    // Custom Connector in WorkBuddy 5.9.3, measured at 150% and given here at
    // 100%: its right edge 31 and its top 46 from the window's top right, 136 by 32.
    internal static Rect? CustomConnectorFromFrame(AutomationElement window)
    {
        Rect frame = window.Current.BoundingRectangle;
        var handle = new IntPtr(window.Current.NativeWindowHandle);
        if (frame.IsEmpty || frame.Width < 700 || handle == IntPtr.Zero) return null;
        double scale = Math.Max(1, GetDpiForWindow(handle)) / 96.0;
        return FromFrame(frame, scale);
    }
    internal static Rect FromFrame(Rect frame, double scale)
        => new(frame.Right - (31 + 136) * scale, frame.Top + 46 * scale, 136 * scale, 32 * scale);

    internal static bool IsForeground(int[] processes)
    {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero) return false;
        GetWindowThreadProcessId(window, out uint process);
        return processes.Contains((int)process);
    }

    /// Brings the app's window forward after a click in Pacer, which may do so.
    internal static void Raise(AutomationElement window)
    {
        try
        {
            var handle = new IntPtr(window.Current.NativeWindowHandle);
            if (handle == IntPtr.Zero) return;
            if (IsIconic(handle)) ShowWindow(handle, 9);
            SetForegroundWindow(handle);
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or COMException) { }
    }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(IntPtr window, int command);
}

/// A ring around the button to click in another app, with a bubble beside it,
/// drawn over that app while it is in front. The ring lets clicks through.
internal sealed class AppPointer
{
    private static AppPointer? current;
    private readonly Window ring, bubble;
    private readonly TextBlock bubbleText;
    private readonly DispatcherTimer timer;
    private readonly IReadOnlyList<string> executables;
    private readonly Func<string, string> pointerText;
    private readonly Action<string?> viewChanged;
    private readonly Action notFound;
    private readonly DateTime started = DateTime.UtcNow;
    // While the app starts, a missing button is not yet a failure.
    private readonly TimeSpan grace;
    private string target;
    private bool busy, closed;
    private int misses;

    internal string Provider { get; }
    internal string TargetKind => target;
    internal static AppPointer? Current => current;

    private AppPointer(string provider, IReadOnlyList<string> executables, string target, string stop,
        Func<string, string> pointerText, Action<string?> viewChanged, Action notFound, TimeSpan grace)
    {
        Provider = provider; this.executables = executables; this.target = target; this.grace = grace;
        this.pointerText = pointerText; this.viewChanged = viewChanged; this.notFound = notFound;
        var accent = new SolidColorBrush(Color.FromRgb(11, 99, 206)); accent.Freeze();
        var frame = new Border { BorderThickness = new Thickness(3), CornerRadius = new CornerRadius(10), BorderBrush = accent };
        var glow = new Border { BorderThickness = new Thickness(6), CornerRadius = new CornerRadius(13), BorderBrush = accent, Margin = new Thickness(-4), Opacity = 0.35 };
        var ringContent = new Grid { Margin = new Thickness(4) }; ringContent.Children.Add(glow); ringContent.Children.Add(frame);
        ring = Overlay(ringContent);
        // People who turn animations off see a steady ring.
        if (SystemParameters.ClientAreaAnimation)
            glow.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.45, 0, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever });
        bubbleText = new TextBlock { Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 260 };
        var stopButton = new Button { Content = stop, Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(8, 2, 8, 3), VerticalAlignment = VerticalAlignment.Center,
            Foreground = Brushes.White, Background = new SolidColorBrush(Color.FromArgb(56, 255, 255, 255)), BorderThickness = new Thickness(0), Cursor = System.Windows.Input.Cursors.Hand };
        stopButton.Click += (_, _) => Stop();
        System.Windows.Automation.AutomationProperties.SetAutomationId(stopButton, "pointer.stop");
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var label = new StackPanel();
        label.Children.Add(new TextBlock { Text = "Pacer", Foreground = new SolidColorBrush(Color.FromArgb(200, 255, 255, 255)), FontSize = 11, FontWeight = FontWeights.SemiBold });
        label.Children.Add(bubbleText);
        row.Children.Add(label); row.Children.Add(stopButton);
        bubble = Overlay(new Border { Background = accent, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 8, 10, 9), Child = row });
        bubble.SizeToContent = SizeToContent.WidthAndHeight;
        ring.SourceInitialized += (_, _) => NativeWindowBounds.MakeInputTransparent(ring);
        bubble.SourceInitialized += (_, _) => NativeWindowBounds.MakeNonActivating(bubble);
        timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(400) };
        timer.Tick += async (_, _) => await TickAsync();
    }

    private static Window Overlay(UIElement content) => new()
    {
        WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
        ShowInTaskbar = false, ShowActivated = false, ResizeMode = ResizeMode.NoResize, Content = content, Width = 1, Height = 1, Left = -10000, Top = -10000
    };

    /// Points at the target in the app; a new pointer replaces any other.
    internal static void Show(string provider, IReadOnlyList<string> executables, string target, string stop,
        Func<string, string> pointerText, Action<string?> viewChanged, Action notFound, TimeSpan grace = default)
    {
        current?.Stop();
        current = new AppPointer(provider, executables, target, stop, pointerText, viewChanged, notFound, grace);
        current.timer.Start();
        _ = current.TickAsync();
    }

    /// Follows the card: the trust step moves the ring; any other ends it.
    internal static void Follow(string provider, string? stage)
    {
        if (current is not { } pointer || pointer.Provider != provider) return;
        if (stage is "customConnector" or "trust") { if (stage == "trust") pointer.target = "trust"; }
        else pointer.Stop();
    }

    internal void Stop()
    {
        if (closed) return;
        closed = true; timer.Stop();
        ring.Close(); bubble.Close();
        if (current == this) current = null;
    }

    private async Task TickAsync()
    {
        if (busy || closed) return;
        // A pointer that nobody follows goes away on its own.
        if (DateTime.UtcNow - started > TimeSpan.FromMinutes(3)) { Stop(); return; }
        busy = true;
        try
        {
            string kind = target;
            var (front, rect, view) = await Task.Run(() =>
            {
                int[] processes = AppAutomation.ProcessIds(executables);
                if (processes.Length == 0) return (false, (Rect?)null, (string?)null);
                bool foreground = AppAutomation.IsForeground(processes);
                if (AppAutomation.MainWindow(processes) is not { } window) return (foreground, null, null);
                string? seen = AppAutomation.View(window);
                // Once the custom connectors show, the ring moves on to Trust.
                return (foreground, AppAutomation.Target(window, seen == "customConnectors" ? "trust" : kind), seen);
            });
            if (closed) return;
            if (view == "customConnectors" && target == "customConnector") target = "trust";
            if (view != null) viewChanged(view);
            if (!front || rect is not { } bounds)
            {
                Hide();
                if (front && DateTime.UtcNow - started > grace && ++misses >= 15)
                {
                    if (target == "customConnector") notFound();
                    Stop();
                }
                return;
            }
            misses = 0;
            Place(bounds);
        }
        finally { busy = false; }
    }

    private void Hide()
    {
        if (ring.IsVisible) ring.Hide();
        if (bubble.IsVisible) bubble.Hide();
    }

    private void Place(Rect bounds)
    {
        const double inset = 10;
        if (!ring.IsVisible) ring.Show();
        NativeWindowBounds.ApplyPixels(ring, new MotionBounds(bounds.Left - inset, bounds.Top - inset, bounds.Width + inset * 2, bounds.Height + inset * 2));
        NativeWindowBounds.RaiseWithoutActivation(ring);
        bubbleText.Text = pointerText(target);
        if (!bubble.IsVisible) bubble.Show();
        bubble.UpdateLayout();
        var scale = VisualTreeHelper.GetDpi(bubble);
        double width = bubble.ActualWidth * scale.DpiScaleX, height = bubble.ActualHeight * scale.DpiScaleY;
        // Below the button, kept on the button's screen.
        var screen = System.Windows.Forms.Screen.FromRectangle(new System.Drawing.Rectangle((int)bounds.Left, (int)bounds.Top, (int)Math.Max(1, bounds.Width), (int)Math.Max(1, bounds.Height))).WorkingArea;
        double x = Math.Clamp(bounds.Left + bounds.Width / 2 - width / 2, screen.Left + 8, Math.Max(screen.Left + 8, screen.Right - width - 8));
        double y = bounds.Bottom + inset + 8;
        if (y + height > screen.Bottom - 8) y = bounds.Top - inset - 8 - height;
        NativeWindowBounds.ApplyPixels(bubble, new MotionBounds(x, y, width, height));
        NativeWindowBounds.RaiseWithoutActivation(bubble);
    }
}
