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

/// The shell of a floating guide beside an app: a card in the bottom-right
/// corner of the screen Settings is on, with Pacer's mark, a header and Close.
/// It stays above other windows without taking focus and never reads the
/// app's window. Each guide fills `Body` below the header.
internal abstract class GuideFloatWindow : Window
{
    private readonly System.Drawing.Rectangle area;
    private protected readonly UiText ui;
    private protected readonly TextBlock Header;
    private protected readonly StackPanel Body;
    /// The float has shown; before that, it waits for something to show.
    internal bool Presented { get; private set; }

    /// <param name="resources">Settings' palette, so the float and its pictures match it.</param>
    /// <param name="area">The work area of Settings' screen, in pixels.</param>
    /// <param name="id">The float's automation ID; Close is `id.close`.</param>
    private protected GuideFloatWindow(UiText ui, ResourceDictionary resources, System.Drawing.Rectangle area, string id)
    {
        this.ui = ui; this.area = area;
        WindowRendering.Prepare(this); FontFamily = PacerFonts.Interface; Language = PacerFonts.RenderingLanguage(ui);
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true;
        ShowInTaskbar = false; ShowActivated = false; ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.WidthAndHeight;
        Title = "Pacer";
        Resources.MergedDictionaries.Add(resources);
        AutomationProperties.SetAutomationId(this, id);

        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var glyph = new IconGlyph { Symbol = "xmark", Width = 11, Height = 11 }; glyph.SetResourceReference(IconGlyph.InkProperty, "SettingsSecondary");
        string close = ui.Text("progress_guide.float.close");
        var closeButton = new Button { Style = (Style)FindResource("SettingsSidebarButton"), Width = 24, Height = 24, Padding = new Thickness(0), Content = glyph, ToolTip = close, VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetAutomationId(closeButton, id + ".close"); AutomationProperties.SetName(closeButton, close);
        closeButton.Click += (_, _) => Close();
        DockPanel.SetDock(closeButton, Dock.Right); top.Children.Add(closeButton);
        var icon = new DecorativeImage { Width = 16, Height = 16, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center,
            Source = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets/Pacer.ico"))) };
        top.Children.Add(icon);
        Header = new TextBlock { FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        Header.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        top.Children.Add(Header);

        Body = new StackPanel(); Body.Children.Add(top);
        var card = new Border { Width = 400, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(16, 10, 10, 16), Margin = new Thickness(14), Child = Body,
            Effect = new DropShadowEffect { BlurRadius = 20, ShadowDepth = 3, Direction = 270, Opacity = 0.22 } };
        card.SetResourceReference(Border.BackgroundProperty, "SettingsBackground"); card.SetResourceReference(Border.BorderBrushProperty, "SettingsCardBorder");
        Content = card;
        SourceInitialized += (_, _) => NativeWindowBounds.MakeNonActivating(this);
        // SizeToContent applies the new HWND bounds after WPF's SizeChanged event.
        SizeChanged += (_, _) => Dispatcher.InvokeAsync(() => { if (IsVisible) Place(); }, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// Shows the float the first time, in front without taking focus.
    private protected void ShowFloat()
    {
        if (Presented) return;
        Presented = true;
        Show(); UpdateLayout(); Place();
        NativeWindowBounds.RaiseWithoutActivation(this);
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

/// Shows Core's current instruction beside the provider app and keeps checking it after Settings closes.
internal sealed class HarnessGuideFloat : GuideFloatWindow
{
    private static HarnessGuideFloat? current;
    private static EngineClient? engine;
    private static PreferencesSession? session;
    internal static HarnessGuideFloat? Current => current;

    internal static ResourceDictionary StandaloneResources(bool dark, SystemAppearance? appearance, Color? accent)
    {
        var resources = new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) };
        SettingsPalette.Apply(resources, dark, true, appearance, main: true, accent);
        return resources;
    }

    internal static void Open(EngineModule module, EngineClient client, PreferencesSession preferences, UiText ui, ResourceDictionary resources,
        bool light, System.Drawing.Rectangle area)
    {
        if (module.ProgressGuide is not { } guide || (module.PendingFloat == null && guide.FloatTitle == null && guide.Stage != "ready")) return;
        if (current is { } open && open.Provider == module.Provider && engine == client
            && !(open.reachedApp && SettingsWindow.RestartingHarness(module.Provider)))
        {
            open.pending = module.PendingFloat ?? open.pending;
            Follow();
            return;
        }
        current?.Close(); CodexHooksGuideFloat.Current?.Close();
        var shown = new HarnessGuideFloat(module.Provider, ui, resources, light, area, module.PendingFloat);
        var timer = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += async (_, _) =>
        {
            if (current != shown) { timer.Stop(); return; }
            Follow();
            if (current == shown && client.LatestSnapshot is { Demo: false })
                await SettingsWindow.CheckHarnessAppAsync(client, preferences, module.Provider, polling: true);
        };
        shown.Closed += (_, _) =>
        {
            timer.Stop();
            if (current == shown) { current = null; engine = null; session = null; }
        };
        current = shown; engine = client; session = preferences;
        timer.Start();
        Follow();
    }

    internal static void Follow()
    {
        if (current is not { } shown || engine is not { } client || session is not { } preferences) return;
        var module = client.LatestSnapshot?.Modules?.FirstOrDefault(value => value.Provider == shown.Provider);
        if (client.IsConnectionClosed || module is not { Enabled: true }
            || preferences.Current.DisabledHarnessProgress.Contains(shown.Provider, StringComparer.Ordinal))
        { shown.Close(); return; }
        shown.Update(module, SettingsWindow.RestartingHarness(shown.Provider), DateTime.UtcNow);
    }

    internal void Update(EngineModule module, bool restarting, DateTime now)
    {
        var age = now - OpenedAt;
        if (age >= TimeSpan.FromMinutes(10)) { Close(); return; }
        var guide = module.ProgressGuide;
        if ((!restarting || reachedApp) && guide != null && (guide.FloatTitle != null || guide.Stage == "ready"))
        {
            emptySince = null; reachedApp = true;
            if (guide.FloatTitle == null)
                guide = guide with { FloatTitle = ui.Text("progress_guide.float.done").Replace("%@", module.DisplayName ?? module.Provider, StringComparison.Ordinal) };
            Present(guide);
            doneSince = guide.Stage is "ready" or "firstTask" ? doneSince ?? now : null;
            if (now - doneSince >= TimeSpan.FromSeconds(8)) Close();
            return;
        }
        doneSince = null;
        if (!reachedApp && pending is { } message && age <= TimeSpan.FromMinutes(2)
            && (restarting || module.PendingFloat != null || guide == null))
        {
            Draw(guide?.Chip ?? "", message.Title, message.Next, null, null);
            return;
        }
        // A read can catch the app between writes. Give its next snapshot time to arrive.
        emptySince ??= now;
        if (!reachedApp || now - emptySince >= TimeSpan.FromSeconds(2.5)) Close();
    }

    private DateTime? emptySince, doneSince;
    private bool reachedApp;
    private PendingGuideFloat? pending;
    private readonly bool light;
    private readonly TextBlock title, next;
    private readonly Border art;
    private (string Chip, string? Title, string? Next, string? Picture, AntigravityApprovalCard? Card)? last;
    internal string Provider { get; }
    internal DateTime OpenedAt { get; } = DateTime.UtcNow;

    internal HarnessGuideFloat(string provider, UiText ui, ResourceDictionary resources, bool light, System.Drawing.Rectangle area,
        PendingGuideFloat? pending = null)
        : base(ui, resources, area, "guide_float")
    {
        Provider = provider; this.light = light; this.pending = pending;
        title = new TextBlock { FontSize = 14.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        title.SetResourceReference(TextBlock.ForegroundProperty, "SettingsPrimary");
        AutomationProperties.SetAutomationId(title, "guide_float.title");
        // The float never takes focus, so a screen reader hears each new step.
        AutomationProperties.SetLiveSetting(title, AutomationLiveSetting.Polite);
        art = new Border { Margin = new Thickness(0, 10, 0, 0) };
        next = new TextBlock { FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0) };
        next.SetResourceReference(TextBlock.ForegroundProperty, "SettingsSecondary");
        AutomationProperties.SetAutomationId(next, "guide_float.next");

        Body.Children.Add(title); Body.Children.Add(art); Body.Children.Add(next);
    }

    /// Shows the guide's step, or updates it in place.
    internal void Present(HarnessProgressGuide guide) =>
        Draw(guide.Chip, guide.FloatTitle, guide.FloatNext, guide.FloatPicture, guide.ApprovalCard);

    private void Draw(string chip, string? heading, string? following, string? kind, AntigravityApprovalCard? card)
    {
        var content = (chip, heading, following, kind, card);
        if (last != content)
        {
            last = content;
            Header.Text = "Pacer · " + chip;
            title.Text = heading ?? "";
            art.Child = ProgressGuidePicture.Draw(kind, card, Provider, ui, light);
            // The card's picture keeps its own width there; here it fills the float.
            if (art.Child is FrameworkElement drawn) { drawn.HorizontalAlignment = HorizontalAlignment.Stretch; drawn.MaxWidth = double.PositiveInfinity; }
            art.Visibility = art.Child == null ? Visibility.Collapsed : Visibility.Visible;
            next.Text = following ?? "";
            next.Visibility = following == null ? Visibility.Collapsed : Visibility.Visible;
            if (Presented) UIElementAutomationPeer.FromElement(title)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
        ShowFloat();
    }
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
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(IntPtr window, int command);
}
