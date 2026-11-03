using CodexPacer.Windows;

internal static class FullscreenDisplayChecks
{
    internal static void Run()
    {
        void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var left = new ScreenRectangle(-1920, 0, 0, 1080); var right = new ScreenRectangle(0, 0, 2560, 1440);
        var app = new FullscreenCandidate(left, left, true, false, false, false, false, false, false, true);
        Check(FullscreenDisplayPolicy.IsApplication(app, left), "A borderless application is fullscreen on its target screen");
        Check(!FullscreenDisplayPolicy.IsApplication(app, right), "Another monitor's fullscreen cannot hide this island");
        foreach (var excluded in new[]
        {
            app with { Visible = false }, app with { Minimized = true }, app with { Cloaked = true }, app with { Layered = true },
            app with { ToolWindow = true }, app with { OwnProcess = true }, app with { Shell = true }, app with { RegionContainsMonitor = false },
            app with { Client = new(-1920, 32, 0, 1080) }, app with { Bounds = new(-1920, 0, -1, 1080) }
        }) Check(!FullscreenDisplayPolicy.IsApplication(excluded, left), "Hidden, minimized, cloaked, transparent, own, shell and ordinary maximized windows are excluded");
        var spanning = app with { Bounds = new(-1920, 0, 2560, 1440), Client = new(-1920, 0, 2560, 1440) };
        Check(FullscreenDisplayPolicy.IsApplication(spanning, left) && FullscreenDisplayPolicy.IsApplication(spanning, right), "A spanning application covers either target");
        Check(FullscreenDisplayPolicy.IsApplication(app, left) && !FullscreenOcclusionPolicy.Covers(left, left, new(-1000, 0, -600, 400), true, true, false, false, true, true),
            "Independent composition can be fullscreen without claiming known opaque occlusion");
        Check(FullscreenDisplayPolicy.Visible(true, false, false), "A requested island returns on the ordinary desktop");
        Check(!FullscreenDisplayPolicy.Visible(true, false, true), "Fullscreen-off hides the island");
        Check(FullscreenDisplayPolicy.Visible(true, true, true), "Fullscreen-on retains the island");
        foreach (bool showAbove in new[] { false, true })
        foreach (bool fullscreen in new[] { false, true })
            Check(!FullscreenDisplayPolicy.Visible(false, showAbove, fullscreen), "Fullscreen transitions never resurrect a manually hidden island");
    }
}
