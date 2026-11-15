using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace CodexPacer.Windows;

/// The floating guide beside a module's app while the user clicks through its
/// connectors (Core's `floatTitle`): the click to make now, the card's picture
/// of it, and the click after. It sits in the bottom-right corner of the screen
/// Settings is on, stays above other windows without taking focus, and never
/// reads the app's window. It outlives Settings, which people often close
/// once they're in the app, and checks the app itself while it is open.
internal sealed class HarnessGuideFloat : Window
{
    private static HarnessGuideFloat? current;
    private static EngineClient? engine;
    private static PreferencesSession? session;
    private static System.Windows.Threading.DispatcherTimer? poll;
    internal static HarnessGuideFloat? Current => current;

    /// Opens the guide for the app the card just opened; it replaces any other.
    /// It shows once the card reaches a click in the app.
    internal static void Open(string provider, EngineClient client, PreferencesSession preferences, UiText ui, ResourceDictionary resources,
        Func<string, UIElement> picture, System.Drawing.Rectangle area)
    {
        current?.Close();
        var shown = new HarnessGuideFloat(provider, ui, resources, picture, area);
        var timer = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += async (_, _) =>
        {
            if (current != shown) { timer.Stop(); return; }
            await SettingsWindow.CheckHarnessAppAsync(client, preferences, provider, polling: true);
            Follow();
        };
        shown.Closed += (_, _) =>
        {
            timer.Stop();
            if (current == shown) { current = null; poll = null; engine = null; session = null; }
        };
        current = shown; engine = client; session = preferences; poll = timer;
        timer.Start();
        Follow();
    }

    /// Shows the guide's current click, or closes the float once nothing is
    /// left to do in the app. Until it first shows, the app may still be
    /// starting or reloading.
    internal static void Follow()
    {
        if (current is not { } shown || engine is not { } client || session is not { } preferences) return;
        var guide = client.LatestSnapshot?.Modules?.FirstOrDefault(value => value.Provider == shown.Provider) is { Enabled: true } module
            && !preferences.Current.DisabledHarnessProgress.Contains(module.Provider, StringComparer.Ordinal) ? module.ProgressGuide : null;
        if (client.IsConnectionClosed) { shown.Close(); return; }
        if (guide is { FloatTitle: not null })
        {
            shown.emptySince = null; shown.reachedApp = true; shown.Present(guide);
            // Once done, the guide says so briefly; the card keeps the line.
            shown.doneSince = guide.Stage == "firstTask" ? shown.doneSince ?? DateTime.UtcNow : null;
            if (DateTime.UtcNow - shown.doneSince >= TimeSpan.FromSeconds(8)) shown.Close();
            return;
        }
        // Right after the click, the app restarts or starts; the guide says so
        // until it reaches the first step in the app.
        if (!shown.reachedApp && guide?.Stage is ("reopen" or "launch" or "openConnectors")
            && DateTime.UtcNow - shown.OpenedAt <= TimeSpan.FromMinutes(2))
        {
            string name = client.LatestSnapshot?.Modules?.FirstOrDefault(value => value.Provider == shown.Provider)?.DisplayName ?? shown.Provider;
            string title = shown.ui.Text(guide.Stage == "reopen" ? "progress_guide.float.restarting" : "progress_guide.float.opening").Replace("%@", name, StringComparison.Ordinal);
            shown.Present(guide with { FloatTitle = title, FloatNext = shown.ui.Text("progress_guide.float.then_custom"), Picture = null });
            return;
        }
        // A check can read the app while it writes its approvals; the guide
        // closes only once nothing is left to do for two checks in a row.
        shown.emptySince ??= DateTime.UtcNow;
        if (DateTime.UtcNow - shown.emptySince.Value >= TimeSpan.FromSeconds(2.5)) shown.Close();
    }
    private DateTime? emptySince, doneSince;
    // The guide has shown a step from the app itself, past the restart or start.
    private bool reachedApp;
    private readonly UiText ui;

    private readonly Func<string, UIElement> picture;
    private readonly System.Drawing.Rectangle area;
    private readonly TextBlock header, title, next;
    private readonly Border art;
    private string key = "";
    internal string Provider { get; }
    internal DateTime OpenedAt { get; } = DateTime.UtcNow;
    /// The guide has shown a step; before that, the app is still on its way.
    internal bool Presented { get; private set; }

    /// <param name="resources">Settings' palette, so the float and its pictures match it.</param>
    /// <param name="picture">Draws the card's picture for a step.</param>
    /// <param name="area">The work area of Settings' screen, in pixels.</param>
    internal HarnessGuideFloat(string provider, UiText ui, ResourceDictionary resources, Func<string, UIElement> picture, System.Drawing.Rectangle area)
    {
        Provider = provider; this.picture = picture; this.area = area; this.ui = ui;
        WindowRendering.Prepare(this); FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true;
        ShowInTaskbar = false; ShowActivated = false; ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.WidthAndHeight;
        Title = "Pacer";
        Resources.MergedDictionaries.Add(resources);
        AutomationProperties.SetAutomationId(this, "guide_float");

        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var glyph = new IconGlyph { Symbol = "xmark", Width = 11, Height = 11 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        string close = ui.Text("progress_guide.float.close");
        var closeButton = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 24, Height = 24, Padding = new Thickness(0), Content = glyph, ToolTip = close, VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetAutomationId(closeButton, "guide_float.close"); AutomationProperties.SetName(closeButton, close);
        closeButton.Click += (_, _) => Close();
        DockPanel.SetDock(closeButton, Dock.Right); top.Children.Add(closeButton);
        var icon = new DecorativeImage { Width = 16, Height = 16, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center,
            Source = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) };
        top.Children.Add(icon);
        header = new TextBlock { FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        header.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        top.Children.Add(header);

        title = new TextBlock { FontSize = 14.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        AutomationProperties.SetAutomationId(title, "guide_float.title");
        // The float never takes focus, so a screen reader hears each new step.
        AutomationProperties.SetLiveSetting(title, AutomationLiveSetting.Polite);
        art = new Border { Margin = new Thickness(0, 10, 0, 0) };
        next = new TextBlock { FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0) };
        next.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetAutomationId(next, "guide_float.next");

        var body = new StackPanel(); body.Children.Add(top); body.Children.Add(title); body.Children.Add(art); body.Children.Add(next);
        var card = new Border { Width = 400, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(16, 10, 10, 16), Margin = new Thickness(14), Child = body,
            Effect = new DropShadowEffect { BlurRadius = 20, ShadowDepth = 3, Direction = 270, Opacity = 0.22 } };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsBackground"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        Content = card;
        SourceInitialized += (_, _) => NativeWindowBounds.MakeNonActivating(this);
        SizeChanged += (_, _) => Place();
    }

    /// Shows the guide's step, or updates it in place.
    internal void Present(HarnessProgressGuide guide)
    {
        string shownKey = string.Join("\u0001", guide.Chip, guide.FloatTitle, guide.FloatNext, guide.Picture);
        if (shownKey != key)
        {
            key = shownKey;
            header.Text = "Pacer · " + guide.Chip;
            title.Text = guide.FloatTitle ?? "";
            art.Child = guide.Picture is string kind ? picture(kind) : null;
            // The card's picture keeps its own width there; here it fills the float.
            if (art.Child is FrameworkElement drawn) { drawn.HorizontalAlignment = HorizontalAlignment.Stretch; drawn.MaxWidth = double.PositiveInfinity; }
            art.Visibility = art.Child == null ? Visibility.Collapsed : Visibility.Visible;
            next.Text = guide.FloatNext ?? "";
            next.Visibility = guide.FloatNext == null ? Visibility.Collapsed : Visibility.Visible;
            if (Presented) UIElementAutomationPeer.FromElement(title)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
        if (!Presented)
        {
            Presented = true;
            Show(); UpdateLayout(); Place();
            NativeWindowBounds.RaiseWithoutActivation(this);
        }
    }

    /// The bottom-right corner of Settings' screen; the card's own margin
    /// leaves room for its shadow.
    private void Place()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero || !GetWindowRect(handle, out var frame)) return;
        int width = frame.Right - frame.Left, height = frame.Bottom - frame.Top;
        int gap = (int)Math.Round(4 * Math.Max(1, GetDpiForWindow(handle)) / 96.0);
        SetWindowPos(handle, IntPtr.Zero, Math.Max(area.Left, area.Right - width - gap), Math.Max(area.Top, area.Bottom - height - gap), 0, 0, 0x0001 | 0x0004 | 0x0010);
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
}

/// After the card opens an app, brings its window forward if the app didn't
/// come forward itself while Pacer is still in front. Reads only which
/// process owns the foreground window and the app's own window handles.
internal static class AppWindows
{
    internal static async Task BringForwardAsync(IReadOnlyList<string>? executables, TimeSpan? wait = null)
    {
        var until = DateTime.UtcNow + (wait ?? TimeSpan.FromSeconds(10));
        while (DateTime.UtcNow < until)
        {
            await Task.Delay(500);
            if (await Task.Run(() => TryBringForward(executables))) return;
        }
    }

    /// True once there is nothing left to do: the app is in front, or the user
    /// went to another app. False while the app has no window yet.
    private static bool TryBringForward(IReadOnlyList<string>? executables)
    {
        int[] processes = ProcessIds(executables);
        var foreground = GetForegroundWindow();
        GetWindowThreadProcessId(foreground, out uint owner);
        if (processes.Contains((int)owner)) return true;
        if (owner != (uint)Environment.ProcessId && foreground != IntPtr.Zero) return true;
        if (MainWindow(processes) is not { } window) return false;
        if (IsIconic(window)) ShowWindow(window, 9);
        SetForegroundWindow(window);
        return true;
    }

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

    /// The app's main window: its largest visible top-level window. Electron
    /// apps also own a GPU window as large as the main one; it never counts.
    internal static IntPtr? MainWindow(int[] processes)
    {
        if (processes.Length == 0) return null;
        IntPtr best = IntPtr.Zero; long largest = 0;
        var name = new System.Text.StringBuilder(64);
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint process);
            if (!processes.Contains((int)process) || !IsWindowVisible(window) || !GetWindowRect(window, out var rect)) return true;
            name.Clear(); GetClassName(window, name, name.Capacity);
            long width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            // A minimized window keeps a tiny frame off screen; it still counts.
            if (IsIconic(window)) { width = 201; height = 151; }
            if (name.ToString() == "Intermediate D3D Window" || width <= 200 || height <= 150 || width * height <= largest) return true;
            best = window; largest = width * height;
            return true;
        }, IntPtr.Zero);
        return best == IntPtr.Zero ? null : best;
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int capacity);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(IntPtr window, int command);
}
