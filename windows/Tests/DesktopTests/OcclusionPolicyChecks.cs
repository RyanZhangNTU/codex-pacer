using CodexPacer.Windows;

internal static class OcclusionPolicyChecks
{
    internal static void Run()
    {
        void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        var monitor = new ScreenRectangle(-3840, 0, 0, 2160);
        var island = new ScreenRectangle(-2220, 0, -1620, 660);
        bool Covers(ScreenRectangle window, bool above = true, bool visible = true, bool cloaked = false,
            bool layered = false, bool noRedirection = false, bool region = true)
            => FullscreenOcclusionPolicy.Covers(window, monitor, island, above, visible, cloaked, layered, noRedirection, region);
        Check(Covers(monitor), "An opaque fullscreen window above the island pauses decoration even without activation");
        Check(Covers(new(-3848, -8, 8, 2168)), "Extended opaque frame bounds remain a complete cover");
        Check(!Covers(monitor, above: false), "A fullscreen desktop underneath the island cannot pause it");
        Check(!Covers(monitor, visible: false), "Hidden windows cannot cover the island");
        Check(!Covers(monitor, cloaked: true), "Another virtual desktop does not occlude this island");
        Check(!Covers(monitor, layered: true), "A translucent layered overlay may still reveal the island");
        Check(!Covers(monitor, noRedirection: true), "Unknown native composition transparency is treated conservatively");
        Check(!Covers(monitor, region: false), "A region hole can reveal the island despite fullscreen rectangle bounds");
        Check(!Covers(new(-3840, 0, 0, 1080)), "An ordinary overlapping panel does not activate fullscreen suspension");
        Check(!Covers(new(0, 0, 3840, 2160)), "A fullscreen window on another monitor has no effect");
        Check(!Covers(default), "Invalid native bounds never suspend rendering");
        Check(!FullscreenOcclusionPolicy.Covers(monitor, monitor, default, true, true, false, false, false, true), "An unavailable island rectangle is not considered occluded");
    }
}
