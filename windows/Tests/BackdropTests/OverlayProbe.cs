using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class OverlayProbe
{
    internal static async Task Run(string output, bool interactive = false, bool input = false)
    {
        IntPtr foreground = ScreenNative.GetForegroundWindow();
        await using var scene = await ProtectedScene.Start(output);
        await using var engine = new EngineClient(); ShellProjection.Client = engine;
        var system = new ProbeSystem(); NativeCompositionBackdrop? native = null;
        bool failCreate = false; int creates = 0, frames = 0;
        var preferences = new DesktopPreferences { DisplayMode = "notch", IslandAppearance = "liquidGlass" };
        var island = new IslandWindow(engine, true, false, animationOverride: true, displayMode: 1,
            backdropSystemFactory: () => system, backdropFactory: window =>
            {
                creates++; if (failCreate) throw new COMException("Injected compositor failure", unchecked((int)0x80004005));
                return native = new NativeCompositionBackdrop(window);
            }) { IsHitTestVisible = false, ShowActivated = false };
        var captures = new List<object>(); var checks = new List<string>();
        void Check(bool value, string name) { if (!value) throw new InvalidOperationException(name); checks.Add(name); }
        void Prefer(string style, string mode = "notch") { preferences = preferences with { IslandAppearance = style, DisplayMode = mode }; island.ApplyPreferences(preferences); }
        async Task Settle() { await island.WaitForPresentationAsync(); await Dispatcher.Yield(DispatcherPriority.ContextIdle); ScreenNative.DwmFlush(); await Task.Delay(100); }
        void Capture(string name)
        {
            var shell = (Border)island.FindName("Shell");
            var content = new WindowInteropHelper(island).Handle;
            var frame = NativeCompositionBackdrop.Frame(island, shell, shell.Clip);
            var bounds = scene.Bounds; var visible = island.VisibleScreenBounds;
            Check(visible.X >= bounds.Left && visible.Y >= bounds.Top && visible.Right <= bounds.Right && visible.Bottom <= bounds.Bottom, "Synthetic scene covers " + name);
            scene.Capture(Path.Combine(output, name + ".png"), content, island.BackdropWindowHandle);
            captures.Add(new { name, x = frame.X - bounds.Left, y = frame.Y - bounds.Top, frame.Width, frame.Height, frame.Scale, frame.Polygon,
                preferred = island.SurfaceDecision.Preferred, reason = island.SurfaceDecision.Reason.ToString(), glass = island.GlassVisible, nonactive = !island.IsActive });
        }
        try
        {
            island.ApplyPreferences(preferences); island.Show();
            await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            island.Reveal(); await Settle();
            Check(island.GlassVisible && system.Current.Transparency && !system.Current.HighContrast, "Real system state permits native glass");
            var content = new WindowInteropHelper(island).Handle;
            Check((ScreenNative.GetWindowLongPtr(content, -20).ToInt64() & 0x08000000) != 0
                && ScreenNative.SendMessage(content, 0x0021, IntPtr.Zero, IntPtr.Zero) == new IntPtr(3), "Normal mouse activation is suppressed on the content window");
            if (input)
            {
                island.IsHitTestVisible = true;
                await NativeInputChecks.Run(island, scene, output);
                native!.InjectDeviceLoss(); await Settle();
                Check(!island.GlassVisible && island.SurfaceDecision.Reason == BackdropReason.DeviceLost, "Native idle device loss uses Black");
                ScreenNative.SendMessage(content, 0x007E, IntPtr.Zero, IntPtr.Zero); await Settle();
                Check(island.GlassVisible, "The real display-message hook retries a lost graphics device");
                File.WriteAllText(Path.Combine(output, "recovery.json"), JsonSerializer.Serialize(new { deviceLossUsesBlack = true, displayMessageRestoresGlass = true, preferred = island.SurfaceDecision.Preferred }));
                return;
            }
            if (interactive)
            {
                island.IsHitTestVisible = true;
                var windowBounds = ScreenNative.Read(content); var protectedBounds = scene.Bounds;
                var screenBounds = System.Windows.Forms.Screen.FromHandle(content).Bounds;
                Check(Math.Max(windowBounds.Left, screenBounds.Left) >= protectedBounds.Left && Math.Max(windowBounds.Top, screenBounds.Top) >= protectedBounds.Top
                    && Math.Min(windowBounds.Right, screenBounds.Right) <= protectedBounds.Right && Math.Min(windowBounds.Bottom, screenBounds.Bottom) <= protectedBounds.Bottom,
                    $"The synthetic scene protects the on-screen interactive crop ({windowBounds.Left},{windowBounds.Top},{windowBounds.Right},{windowBounds.Bottom})");
                scene.Capture(Path.Combine(output, "interactive-protected.png"), content, island.BackdropWindowHandle);
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (clock.Elapsed.TotalSeconds < 180 && !File.Exists(Path.Combine(output, "finish")))
                {
                    var bounds = island.VisibleScreenBounds; var sceneBounds = scene.Bounds;
                    File.WriteAllText(Path.Combine(output, "interactive.json"), JsonSerializer.Serialize(new { content = content.ToInt64(), scene = scene.Handle.ToInt64(),
                        x = bounds.X - sceneBounds.Left, y = bounds.Y - sceneBounds.Top, bounds.Width, bounds.Height, island.IsActive, island.GlassVisible,
                        windowX = windowBounds.Left, windowY = windowBounds.Top, windowWidth = windowBounds.Width, windowHeight = windowBounds.Height,
                        expanded = island.IsExpandedForAutomation, pin = System.Windows.Automation.AutomationProperties.GetName((Button)island.FindName("PinButton")) }));
                    await Task.Delay(250);
                }
                return;
            }
            Check(island.AllowsTransparency && WindowRendering.Mode(island) == "Default", "The existing layered content uses default hardware rendering");
            var peer = UIElementAutomationPeer.CreatePeerForElement(island);
            Check(peer.GetPattern(PatternInterface.ExpandCollapse) is IExpandCollapseProvider, "The content retains its UIA expansion pattern");
            Check(peer.GetChildren().Any(), "The content retains its accessibility children");
            island.FrameApplied += _ =>
            {
                frames++;
                if (island.GlassVisible)
                {
                    var top = ScreenNative.Read(content); var under = ScreenNative.Read(island.BackdropWindowHandle);
                    if (top.Left != under.Left || top.Top != under.Top || top.Width != under.Width || top.Height != under.Height)
                        throw new InvalidOperationException("Content and material HWND bounds diverged during motion.");
                }
            };
            foreach (bool dark in new[] { false, true })
            {
                string theme = dark ? "dark" : "light"; scene.Theme(dark); await Task.Delay(100);
                Prefer("liquidGlass"); island.Reveal(); await Settle(); Capture("glass-" + theme + "-expanded");
                var visible = island.VisibleScreenBounds;
                Check(ScreenNative.WindowFromPoint(new() { X = (int)(visible.X + visible.Width / 2), Y = (int)(visible.Bottom - 8) }) == content, "Layered interior input belongs to WPF on " + theme);
                Check(ScreenNative.WindowFromPoint(new() { X = (int)visible.X + 1, Y = (int)visible.Bottom - 1 }) == scene.Handle, "Outside rounded corner passes to the synthetic scene on " + theme);
                island.CollapseForAutomation(); await Settle(); Capture("glass-" + theme + "-collapsed");
                Prefer("liquidGlass", "floating"); await Settle(); Capture("glass-" + theme + "-capsule");
                Prefer("classic"); island.Reveal(); await Settle(); Capture("classic-" + theme + "-expanded");
                island.CollapseForAutomation(); await Settle(); Capture("classic-" + theme + "-collapsed");
                island.Hide(); await Task.Delay(100); scene.Capture(Path.Combine(output, "reference-" + theme + ".png")); island.Show();
            }
            Prefer("liquidGlass"); island.Reveal(); await Settle();
            foreach (var fallback in new[]
            {
                (Name: "transparency-off", State: system.Current with { Transparency = false }, Reason: BackdropReason.TransparencyOff),
                (Name: "high-contrast", State: system.Current with { HighContrast = true }, Reason: BackdropReason.HighContrast),
                (Name: "old-system", State: system.Current with { Build = 22620 }, Reason: BackdropReason.OldSystem)
            })
            {
                system.Override(fallback.State); await Settle();
                Check(!island.GlassVisible && island.SurfaceDecision.Reason == fallback.Reason && island.SurfaceDecision.Preferred == "liquidGlass", fallback.Name + " uses Black and retains the preference");
                Capture("fallback-" + fallback.Name);
                system.Restore(); await Settle(); Check(island.GlassVisible, fallback.Name + " restores glass");
            }
            Prefer("classic"); await Settle(); failCreate = true; Prefer("liquidGlass"); await Settle();
            Check(!island.GlassVisible && island.SurfaceDecision.Reason == BackdropReason.GraphicsUnavailable, "A native API failure uses Black"); Capture("fallback-api-failure");
            failCreate = false; Prefer("classic"); Prefer("liquidGlass"); await Settle(); Check(island.GlassVisible, "An explicit retry restores glass after an API failure");
            native!.InjectDeviceLoss(); await Settle();
            Check(!island.GlassVisible && island.SurfaceDecision.Reason == BackdropReason.DeviceLost, "Device removal falls back while idle"); Capture("fallback-device-loss");
            ScreenNative.SendMessage(content, 0x007E, IntPtr.Zero, IntPtr.Zero); await Settle(); Check(island.GlassVisible, "A display recovery event recreates the graphics device");
            island.CollapseForAutomation(); await Task.Delay(70); Capture("motion-collapse");
            island.Reveal(); await Task.Delay(70); Capture("motion-reversal"); await Settle();
            // Exercise WPF's real WM_DPICHANGED handling without changing the
            // user's display settings. This is a simulation, not a second monitor.
            int originalDpi = (int)Math.Round(VisualTreeHelper.GetDpi(island).PixelsPerInchX);
            void DpiMessage(int dpi)
            {
                var bounds = ScreenNative.Read(content); var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<ScreenNative.Bounds>());
                try
                {
                    Marshal.StructureToPtr(bounds, pointer, false);
                    ScreenNative.SendMessage(content, 0x02E0, new IntPtr(dpi | (dpi << 16)), pointer);
                }
                finally { Marshal.FreeHGlobal(pointer); }
            }
            DpiMessage(144); await Settle();
            Check(Math.Abs(VisualTreeHelper.GetDpi(island).DpiScaleX - 1.5) < .001, "A simulated 150 percent DPI message updates WPF and material coordinates");
            Capture("dpi-150-simulated"); island.CollapseForAutomation(); await Settle(); island.Reveal(); await Settle();
            DpiMessage(originalDpi); await Settle();
            Check(Math.Abs(VisualTreeHelper.GetDpi(island).PixelsPerInchX - originalDpi) < .01, "The window restores the original display DPI after simulation");
            Check(frames > 10, "Real spring frames keep the two native bounds synchronized");
            var foregroundAfter = ScreenNative.GetForegroundWindow();
            Check(!island.IsActive && foregroundAfter != content && foregroundAfter != island.BackdropWindowHandle && !island.ShowInTaskbar,
                "Glass remains nonactive and outside the taskbar");
            var intrusion = new Window { WindowStyle = WindowStyle.None, Width = 20, Height = 20, Left = scene.Bounds.Left / VisualTreeHelper.GetDpi(island).DpiScaleX + 5,
                Top = 5, ShowActivated = false, ShowInTaskbar = false, Topmost = true, Background = Brushes.Black };
            string forbidden = Path.Combine(output, "guard-must-not-save.png");
            try
            {
                intrusion.Show(); await Dispatcher.Yield(DispatcherPriority.Render);
                bool rejected = false;
                try { scene.Capture(forbidden, content, island.BackdropWindowHandle); } catch (InvalidOperationException) { rejected = true; }
                Check(rejected && !File.Exists(forbidden), "A foreign overlay is rejected before any screenshot is saved");
            }
            finally { intrusion.Close(); }
            File.WriteAllText(Path.Combine(output, "acceptance.json"), JsonSerializer.Serialize(new { checks, creates, frames, system = system.Current,
                externalForegroundChanged = foregroundAfter != foreground,
                monitors = System.Windows.Forms.Screen.AllScreens.Select((screen, index) => new { index, screen.Primary, screen.Bounds, screen.WorkingArea }), captures },
                new JsonSerializerOptions { WriteIndented = true }));
        }
        finally { island.AllowClose = true; island.Close(); ShellProjection.Client = null; }
    }
}

internal sealed class ProbeSystem : IBackdropSystemSource
{
    private readonly BackdropSystemSource real = new(action => Application.Current.Dispatcher.BeginInvoke(action));
    private BackdropSystemState? simulated;
    internal ProbeSystem() => real.Changed += Forward;
    public BackdropSystemState Current => simulated ?? real.Current;
    public event Action? Changed;
    private void Forward() { if (simulated == null) Changed?.Invoke(); }
    internal void Override(BackdropSystemState state) { simulated = state; Changed?.Invoke(); }
    internal void Restore() { simulated = null; Changed?.Invoke(); }
    public void Dispose() { real.Changed -= Forward; real.Dispose(); }
}
