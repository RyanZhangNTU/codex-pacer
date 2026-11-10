using System.Text;
using System.Text.Json.Nodes;
using CodexPacer.Windows;

/// Each display keeps its own place, as Core's IslandScreenMemory does on the Mac.
internal static class IslandScreenMemoryChecks
{
    internal static void Run()
    {
        static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var start = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var left = new IslandPlacement(IslandEdge.Left, 0, 0.4);
        var here = new DesktopPreferences { DisplayMode = "floating", Position = "bottomLeft", PositionChosen = true, IslandPlacement = left };
        Check(here.IslandPositionPerDisplay, "Each display keeps its own place unless turned off");

        // A first launch, or the option just turned on: the display starts from the current place.
        var first = IslandScreenMemory.Arrive(here, "A", "Studio", start);
        Check(IslandScreenMemory.Current(first) == IslandScreenMemory.Current(here), "A display without a place moves nothing");
        Check(IslandScreenMemory.Load(first.IslandDisplayPlaces)["A"] is { Name: "Studio", Used: 1_800_000_000 } entry
            && entry.Place == new IslandScreenMemory.Place("floating", "bottomLeft", left), "Arriving records the display's place");
        // Reached by switching, a new display keeps the current place too: Windows has no notch to take.
        var second = IslandScreenMemory.Arrive(first, "B", "Laptop", start.AddMinutes(1));
        Check(IslandScreenMemory.Current(second) == IslandScreenMemory.Current(here) && IslandScreenMemory.Load(second.IslandDisplayPlaces).Count == 2,
            "A new display keeps the current place");
        // A change on B belongs to B; returning to A restores A's place, and B's comes back after.
        var top = new IslandPlacement(IslandEdge.Top, 0.7, 0);
        var moved = second with { IslandPlacement = top, Position = "center", PositionChosen = false };
        var kept = IslandScreenMemory.RememberCurrent(moved, "B", "Laptop", start.AddMinutes(2));
        Check(IslandScreenMemory.Load(kept.IslandDisplayPlaces)["B"].Place == new IslandScreenMemory.Place("floating", null, top), "A change is recorded for the current display");
        Check(ReferenceEquals(IslandScreenMemory.RememberCurrent(kept, "B", "Laptop", start.AddMinutes(3)), kept), "An unchanged place writes nothing");
        var back = IslandScreenMemory.Arrive(kept, "A", "Studio", start.AddMinutes(4));
        Check(back.IslandPlacement == left && back.Position == "bottomLeft" && back.PositionChosen == true && back.DisplayMode == "floating", "Returning restores the display's own place");
        var again = IslandScreenMemory.Arrive(back, "B", "Laptop", start.AddMinutes(5));
        Check(again.IslandPlacement == top && again.Position == "center" && again.PositionChosen == false, "Each display's place comes back");
        var island = IslandScreenMemory.Arrive(IslandScreenMemory.RememberCurrent(again with { DisplayMode = "notch" }, "B", "Laptop", start.AddMinutes(6)), "A", "Studio", start.AddMinutes(7));
        Check(island.DisplayMode == "floating" && IslandScreenMemory.Arrive(island, "B", "Laptop", start.AddMinutes(8)).DisplayMode == "notch", "The display mode is part of each place");

        // Twelve displays are kept; the one used longest ago goes first.
        var many = here;
        for (int index = 0; index < 13; index++) many = IslandScreenMemory.Arrive(many, "D" + index, "Display " + index, start.AddMinutes(index));
        var limited = IslandScreenMemory.Load(many.IslandDisplayPlaces);
        Check(limited.Count == IslandScreenMemory.Limit && !limited.ContainsKey("D0") && limited.ContainsKey("D12"), "The display used longest ago is forgotten first");

        // The Mac's JSON reads as is; damaged entries are dropped one by one, damaged text reads as empty.
        const string mac = "{\"displays\":{\"A\":{\"edge\":\"left\",\"mode\":\"floating\",\"name\":\"Studio\",\"position\":\"bottomLeft\",\"used\":1800000000,\"x\":0,\"y\":0.4},"
            + "\"B\":{\"mode\":\"sideways\",\"name\":\"Bad\"},\"C\":{\"edge\":\"top\",\"mode\":\"notch\",\"x\":7,\"y\":0,\"position\":\"upside\"},\"\":{\"mode\":\"floating\"}},\"version\":1}";
        var read = IslandScreenMemory.Load(mac);
        Check(read.Count == 2 && read["A"].Place == new IslandScreenMemory.Place("floating", "bottomLeft", left) && read["A"].Used == 1_800_000_000,
            "The Mac's places read the same on Windows");
        Check(read["C"].Place == new IslandScreenMemory.Place("notch", null, null) && read["C"].Name == "", "An invalid spot or corner is dropped without losing the entry");
        Check(IslandScreenMemory.Load(IslandScreenMemory.Save(read)).SequenceEqual(read), "Saved places read back unchanged");
        Check(IslandScreenMemory.Load("{broken").Count == 0 && IslandScreenMemory.Load("[1]").Count == 0
            && IslandScreenMemory.Load(new string(' ', IslandScreenMemory.ByteLimit + 1)).Count == 0, "Damaged or oversized text reads as empty");
        var saved = JsonNode.Parse(IslandScreenMemory.Save(read))!.AsObject();
        Check(saved["version"]!.GetValue<int>() == 1 && saved["displays"]!["A"]!["edge"]!.GetValue<string>() == "left", "Places are stored in the Mac's format");

        // A display's key is its device interface path; twins are told apart from the left.
        var main = new DisplayMonitor(new(1), @"\\?\DISPLAY#DELA0F5#5&1&UID1", "Dell", "DISPLAY1", new(0, 0, 2560, 1440), new(0, 0, 2560, 1400), true);
        var twinLeft = new DisplayMonitor(new(2), "same-path", "Twin", "DISPLAY2", new(-1920, 0, 0, 1080), new(-1920, 0, 0, 1040), false);
        var twinRight = twinLeft with { Handle = new(3), DeviceName = "DISPLAY3", Bounds = new(2560, 0, 4480, 1080), Work = new(2560, 0, 4480, 1040) };
        var unnamed = new DisplayMonitor(new(4), "", "Virtual", "\\\\.\\DISPLAY4", new(0, 1440, 800, 2040), new(0, 1440, 800, 2000), false);
        DisplayMonitor[] all = [main, twinLeft, twinRight, unnamed];
        Check(DisplaySelection.PlaceKey(main, all) == main.DevicePath && DisplaySelection.PlaceKey(twinLeft, all) == "same-path"
            && DisplaySelection.PlaceKey(twinRight, all) == "same-path#1" && DisplaySelection.PlaceKey(unnamed, all) == unnamed.DeviceName,
            "Display keys follow the device path, with twins told apart by arrangement");

        // The option and the places are saved with the other settings; damaged places read as none.
        var withPlaces = back with { IslandPositionPerDisplay = false };
        var decoded = PreferencesCodec.Decode(PreferencesCodec.Encode(withPlaces));
        Check(!decoded.IslandPositionPerDisplay && decoded.IslandDisplayPlaces == withPlaces.IslandDisplayPlaces, "The option and the places survive a save");
        var root = JsonNode.Parse(PreferencesCodec.Encode(withPlaces))!.AsObject();
        Check(root["islandPositionPerDisplay"]!.GetValue<bool>() == false
            && Encoding.UTF8.GetString(Convert.FromBase64String(root["islandDisplayPlaces"]!.GetValue<string>())) == withPlaces.IslandDisplayPlaces,
            "The places are stored as the Mac's data, in base64");
        root["islandDisplayPlaces"] = "@@not base64@@";
        var recovered = PreferencesCodec.Decode(Encoding.UTF8.GetBytes(root.ToJsonString()));
        Check(recovered.IslandDisplayPlaces == null && recovered.IslandPlacement == left && !recovered.IslandPositionPerDisplay, "Damaged places read as none without losing other settings");
        Console.WriteLine("PASS per-display places: arrival, records, limit, the Mac's format, damaged data, display keys and saving");
    }
}
