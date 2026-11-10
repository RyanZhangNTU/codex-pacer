using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexPacer.Windows;

/// Core's IslandScreenMemory on Windows. While `islandPositionPerDisplay` is
/// on (the default), each display keeps its own place: the display mode, the
/// Free Move spot and the older corner. The island preferences always hold the
/// current display's place, and this keeps a copy per display in
/// `islandDisplayPlaces`, the Mac's versioned JSON, keyed by the monitor's
/// device interface path. Size, material and the bar's components stay shared.
/// Windows has no hardware notch, so a display used for the first time always
/// starts from the current place.
internal static class IslandScreenMemory
{
    /// Displays kept; the one used longest ago is forgotten first.
    internal const int Limit = 12;
    /// Larger saved text is damaged and reads as empty.
    internal const int ByteLimit = 16384;

    /// One display's place, as the island preferences hold it.
    internal sealed record Place(string Mode, string? Position, IslandPlacement? Placement);
    /// A remembered place with the display's name and when it was last used, in seconds since 1970.
    internal sealed record Entry(Place Place, string Name, double Used);

    internal static Place Current(DesktopPreferences value) =>
        new(value.DisplayMode, value.HasChosenPosition ? value.Position : null, value.IslandPlacement);

    internal static DesktopPreferences Apply(DesktopPreferences value, Place place) => value with
    {
        DisplayMode = place.Mode, Position = place.Position ?? "center", PositionChosen = place.Position != null, IslandPlacement = place.Placement
    };

    /// The island arrives on `display` and takes the place it remembers; a
    /// display without one starts from the current place, so a first launch,
    /// turning the memory on or reaching a new display moves nothing.
    internal static DesktopPreferences Arrive(DesktopPreferences value, string display, string name, DateTimeOffset now)
    {
        var entries = Load(value.IslandDisplayPlaces);
        var current = Current(value);
        var target = entries.TryGetValue(display, out var saved) ? saved.Place : current;
        Remember(entries, target, display, name, now);
        var next = value with { IslandDisplayPlaces = Save(entries) };
        return target == current ? next : Apply(next, target);
    }

    /// Keeps the current place for the display the island is on.
    internal static DesktopPreferences RememberCurrent(DesktopPreferences value, string display, string name, DateTimeOffset now)
    {
        var entries = Load(value.IslandDisplayPlaces);
        var current = Current(value);
        if (entries.TryGetValue(display, out var saved) && saved.Place == current) return value;
        Remember(entries, current, display, name, now);
        return value with { IslandDisplayPlaces = Save(entries) };
    }

    private static void Remember(Dictionary<string, Entry> entries, Place place, string display, string name, DateTimeOffset now)
    {
        entries[display] = new(place, name.Length > 80 ? name[..80] : name, now.ToUnixTimeMilliseconds() / 1000.0);
        Trim(entries);
    }

    private static void Trim(Dictionary<string, Entry> entries)
    {
        while (entries.Count > Limit)
            entries.Remove(entries.OrderBy(pair => pair.Value.Used).ThenBy(pair => pair.Key, StringComparer.Ordinal).First().Key);
    }

    /// The saved places. An entry that cannot be read is dropped on its own;
    /// damaged or oversized text reads as empty.
    internal static Dictionary<string, Entry> Load(string? json)
    {
        var entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
        if (string.IsNullOrEmpty(json) || Encoding.UTF8.GetByteCount(json) > ByteLimit) return entries;
        JsonObject? displays;
        // Counting builds the object now, so text it cannot hold fails here as damaged.
        try { displays = (JsonNode.Parse(json) as JsonObject)?["displays"] as JsonObject; _ = displays?.Count; }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException) { return entries; }
        if (displays == null) return entries;
        foreach (var (display, node) in displays)
        {
            if (display.Length == 0 || node is not JsonObject entry) continue;
            string? Text(string key) => entry[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;
            double? Number(string key) => entry[key] is JsonValue value && value.TryGetValue(out double number) && double.IsFinite(number) ? number : null;
            if (Text("mode") is not ("automatic" or "notch" or "floating") || Text("mode") is not { } mode) continue;
            string? position = Text("position") is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight" ? Text("position") : null;
            IslandPlacement? placement = null;
            if (Edge(Text("edge")) is { } edge && Number("x") is { } x && Number("y") is { } y && new IslandPlacement(edge, x, y) is { IsValid: true } valid)
                placement = valid;
            entries[display] = new(new(mode, position, placement), Text("name") ?? "", Number("used") ?? 0);
        }
        Trim(entries);
        return entries;
    }

    internal static string Save(IReadOnlyDictionary<string, Entry> entries)
    {
        var displays = new JsonObject();
        foreach (var (display, entry) in entries.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            var item = new JsonObject();
            if (entry.Place.Placement is { } placement) item["edge"] = Name(placement.Edge);
            item["mode"] = entry.Place.Mode;
            item["name"] = entry.Name;
            if (entry.Place.Position is { } position) item["position"] = position;
            item["used"] = entry.Used;
            if (entry.Place.Placement is { } spot) { item["x"] = spot.X; item["y"] = spot.Y; }
            displays[display] = item;
        }
        return new JsonObject { ["displays"] = displays, ["version"] = 1 }.ToJsonString();
    }

    // The Mac's edge names.
    private static string Name(IslandEdge edge) => edge switch
    {
        IslandEdge.Top => "top", IslandEdge.Bottom => "bottom", IslandEdge.Left => "left", IslandEdge.Right => "right", _ => "free"
    };
    private static IslandEdge? Edge(string? name) => name switch
    {
        "free" => IslandEdge.Free, "top" => IslandEdge.Top, "bottom" => IslandEdge.Bottom, "left" => IslandEdge.Left, "right" => IslandEdge.Right, _ => null
    };
}
