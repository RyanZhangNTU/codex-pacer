using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class BackdropPresentationChecks
{
    internal static async Task Run()
    {
        foreach (bool animate in new[] { false, true })
        {
            await using var engine = new EngineClient(); var system = new Source(); var surfaces = new List<Surface>();
            var window = new IslandWindow(engine, true, false, animationOverride: animate, displayMode: 1,
                backdropSystemFactory: () => system, backdropFactory: _ => { var value = new Surface(); surfaces.Add(value); return value; }) { IsHitTestVisible = false, ShowActivated = false };
            try
            {
                window.ApplyPreferences(new() { IslandAppearance = "liquidGlass", DisplayMode = "notch" }); window.Show();
                await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
                window.Reveal(); await window.WaitForPresentationAsync();
                var shell = (Border)window.FindName("Shell");
                Check(window.GlassVisible && ((SolidColorBrush)shell.Background).Color.A == 1, "Glass leaves a hit-testable content surface");
                var pattern = (IExpandCollapseProvider)UIElementAutomationPeer.CreatePeerForElement(window).GetPattern(PatternInterface.ExpandCollapse);
                Check(pattern.ExpandCollapseState == ExpandCollapseState.Expanded, "The expanded state remains accessible over glass");
                int frames = 0;
                window.FrameApplied += _ =>
                {
                    if (!window.GlassVisible) return;
                    var frame = NativeCompositionBackdrop.Frame(window, shell, shell.Clip);
                    Check(surfaces[^1].Last?.SameGeometry(frame) == true, "Each normal or reduced-motion frame uses the exact content contour, origin and DPI"); frames++;
                };
                pattern.Collapse(); await window.WaitForPresentationAsync();
                Check(pattern.ExpandCollapseState == ExpandCollapseState.Collapsed && frames > 0, "Accessible collapse drives the same glass transition");
                Check(((SolidColorBrush)((Grid)window.FindName("Header")).Background).Color.A == 255, "Notch mode keeps the collapsed header Black");
                pattern.Expand(); await window.WaitForPresentationAsync();
                Check(pattern.ExpandCollapseState == ExpandCollapseState.Expanded && window.GlassVisible, "Accessible expansion restores the glass panel");
                system.Set(new(26200, false, false)); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                Check(!window.GlassVisible && ((SolidColorBrush)shell.Background).Color == Color.FromRgb(11, 12, 14), "System fallback makes the real WPF surface opaque Black");
                Check(window.SurfaceDecision.Preferred == "liquidGlass", "Fallback leaves the preference intact");
                system.Set(new(26200, true, false)); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                Check(window.GlassVisible && surfaces.Count == 2, "Restoring system effects recreates the native material");
                var settings = (Button)window.FindName("SettingsButton");
                var settingsPeer = new ButtonAutomationPeer(settings);
                Check(settingsPeer.GetName() == UiText.For(false).Text("common.settings") && settingsPeer.GetPattern(PatternInterface.Invoke) is IInvokeProvider,
                    "Glass preserves named accessible content actions");
                window.ApplyPreferences(new() { IslandAppearance = "classic" }); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                Check(!window.GlassVisible && ((SolidColorBrush)shell.Background).Color.A == 255 && surfaces[^1].Disposed, "Classic restores Black and releases the underlay");
                Check(!window.IsActive && !window.ShowInTaskbar, "Material changes never activate the island or add a taskbar entry");
            }
            catch { Console.WriteLine("Backdrop animate=" + animate + " " + window.PresentationDiagnostics); throw; }
            finally { window.AllowClose = true; window.Close(); }
            Check(system.Disposed && surfaces.TrueForAll(value => value.Disposed), "Closing releases both system subscriptions and native resources");
        }
        Console.WriteLine("PASS glass presentation: shared contour and motion, accessible actions, system fallback, restoration and shutdown");
    }
    private sealed class Source : IBackdropSystemSource
    {
        public BackdropSystemState Current { get; private set; } = new(26200, true, false);
        public event Action? Changed; internal bool Disposed;
        internal void Set(BackdropSystemState value) { Current = value; Changed?.Invoke(); }
        public void Dispose() => Disposed = true;
    }
    private sealed class Surface : ICompositionBackdrop
    {
        public IntPtr WindowHandle => IntPtr.Zero;
        public event Action? DeviceRemoved { add { } remove { } }
        internal BackdropFrame? Last; internal bool Disposed;
        public void Apply(BackdropFrame frame) => Last = frame;
        public void MakeBlack() { }
        public void Hide() { }
        public void Dispose() => Disposed = true;
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
