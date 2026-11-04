using System.Text;
using CodexPacer.Windows;

internal static class IslandPlacementChecks
{
    internal static void Run(string directory)
    {
        var work = new MotionBounds(-960, 38, 960, 722);
        var nearLeft = new MotionBounds(-948, 210, 160, 38);
        Check(IslandPlacementGeometry.SnapEdge(work, nearLeft, IslandEdge.Free) == IslandEdge.Left, "Enters the snap zone");
        Check(IslandPlacementGeometry.SnapEdge(work, nearLeft with { X = -939 }, IslandEdge.Left) == IslandEdge.Left,
            "Small reversals keep the preview");
        Check(IslandPlacementGeometry.SnapEdge(work, nearLeft with { X = -935 }, IslandEdge.Left) == IslandEdge.Free,
            "Dragging away clears the preview");
        Check(IslandPlacementGeometry.SnapEdge(work, nearLeft with { Y = 47 }, IslandEdge.Left) == IslandEdge.Left &&
              IslandPlacementGeometry.SnapEdge(work, nearLeft with { Y = 39 }, IslandEdge.Left) == IslandEdge.Top,
            "Corner jitter is ignored, but moving closer to a different edge changes the candidate");

        var measured = new IslandLayout(default, 460, 420, 38, false, 0, 0);
        foreach (var edge in Enum.GetValues<IslandEdge>())
        {
            var placement = new IslandPlacement(edge, .68, .93);
            var (width, height) = placement.Vertical ? (32, 126) : (160, 38);
            var closed = placement.Arrange(work, measured, width, height, 382, false);
            var open = placement.Arrange(work, measured, width, height, 382, true);
            Check(closed.Position == open.Position && closed.MotionAnchor == open.MotionAnchor, "Expansion keeps the chosen anchor");
            Check(open.Target.X >= work.X && open.Target.X + open.Target.Width <= work.X + work.Width &&
                open.Target.Y >= work.Y && open.Target.Y + open.Target.Height <= work.Y + work.Height, "Expanded bounds avoid taskbars");
            double bottom = work.Y + work.Height;
            Check(edge switch
            {
                IslandEdge.Left => closed.Target.X == work.X && open.Target.X == work.X,
                IslandEdge.Right => closed.Target.X + width == 0 && open.Target.X + open.Target.Width == 0,
                IslandEdge.Top => !open.OpensUp && closed.Target.Y == work.Y && open.Target.Y == work.Y,
                IslandEdge.Bottom => open.OpensUp && closed.Target.Y + height == bottom && open.Target.Y + open.Target.Height == bottom,
                _ => open.OpensUp && closed.Target.Y + height == open.Target.Y + open.Target.Height
            }, "Each edge opens inward; a low floating bar opens upward in place");
            if (edge == IslandEdge.Bottom)
            {
                using var motion = new NativeMotion(directory, closed.Target, position: closed.MotionAnchor);
                motion.RetargetTo(open.Target, true, 0, position: open.MotionAnchor);
                var opening = motion.At(.045).Window;
                motion.RetargetTo(closed.Target, false, .045, position: closed.MotionAnchor);
                var reversing = motion.At(.09).Window;
                Check(opening.Y + opening.Height == bottom && reversing.Y + reversing.Height == bottom, "The bottom anchor holds during a spring reversal");
            }
        }

        // A 1080p screen at 150% leaves about 688 DIP: a bar placed mid-screen has room for
        // neither half of the panel, so the open panel slides inward rather than clipping.
        var shortWork = new MotionBounds(0, 0, 1280, 688);
        foreach (var placement in new[] { new IslandPlacement(IslandEdge.Free, .5, .5), new IslandPlacement(IslandEdge.Left, 0, .5) })
        {
            var (width, height) = placement.Vertical ? (32, 126) : (160, 38);
            var open = placement.Arrange(shortWork, measured, width, height, 402, true);
            double needed = placement.Vertical ? 402 : 38 + 402;
            Check(Math.Abs(open.Target.Height - needed) < .001 && open.Target.Y >= 0 && open.Target.Y + open.Target.Height <= 688,
                "A mid-screen " + placement.Edge + " placement opens its whole panel inside a short work area");
            var tall = placement.Arrange(shortWork, measured, width, height, 900, true);
            Check(Math.Abs(tall.Target.Height - 688) < .001 && tall.Target.Y == 0, "Content taller than the screen fills the work area");
        }

        var main = new DisplayMonitor(new(1), "main", "Main", "DISPLAY1", new(0, 0, 2000, 1200), new(0, 0, 2000, 1160), true);
        var secondary = new DisplayMonitor(new(2), "side", "Side", "DISPLAY2", new(-1920, 70, 0, 1150), new(-1870, 70, 0, 1150), false);
        Check(IslandPlacementGeometry.MonitorAt([main, secondary], -1, 580, main) == secondary &&
            IslandPlacementGeometry.MonitorAt([main, secondary], -1, 30, secondary) == secondary, "Physical coordinates pick the crossed display and retain it in a gap");
        var side = new IslandPlacement(IslandEdge.Left, 0, .55);
        var preferences = secondary.Choose(new() { DisplayMode = "floating", IslandPlacement = side });
        foreach (double scale in new[] { 1, 1.25, 1.5, 2 })
        {
            var area = secondary.AtScale(scale).WorkArea;
            var bar = side.CollapsedFrame(area, 32, 126);
            Check(Math.Abs(bar.X * scale - secondary.Work.Left) < .001 &&
                Math.Abs((bar.Y + bar.Height / 2) * scale - (70 + .55 * 1080)) < .001, "Saved placement follows the work area through DPI changes");
        }
        Check(DisplaySelection.Resolve([main], preferences).FellBack &&
            DisplaySelection.Resolve([main, secondary], preferences).Display == secondary &&
            PreferencesCodec.Decode(PreferencesCodec.Encode(preferences)).IslandPlacement == side, "The original monitor and position survive fallback and reload");
        var unnamedPath = secondary with { DevicePath = "" };
        var namedPreference = PreferencesCodec.Decode(PreferencesCodec.Encode(unnamedPath.Choose(preferences)));
        Check(DisplaySelection.Resolve([main, unnamedPath], namedPreference).Display == unnamedPath &&
            DisplaySelection.Resolve([main], namedPreference).FellBack, "A crossed display without a device path survives restart by name and position");
        foreach (string badPlacement in new[] { "{\"edge\":\"Future\",\"x\":0,\"y\":1}", "{\"edge\":\"Left\",\"x\":-1,\"y\":1}", "{\"edge\":\"Left\"}" })
        {
            var old = PreferencesCodec.Decode(Encoding.UTF8.GetBytes(
                "{\"schemaVersion\":2,\"islandPosition\":\"bottomRight\",\"islandDisplayMode\":\"floating\",\"hideProjects\":true,\"islandPlacement\":" + badPlacement + "}"));
            Check(old.IslandPlacement == null && old.Position == "bottomRight" && old.HideProjects, "Malformed new placement falls back to the old position without losing settings");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
