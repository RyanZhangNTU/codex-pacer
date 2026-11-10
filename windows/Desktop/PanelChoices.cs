using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexPacer.Windows;

// Core's ExpandedPanelLayout and ExpandedPanelOptions on the Windows side:
// their size limits, and one choice changed at a time. The engine reads every
// field again with Core's per-field fallback.
internal static class PanelChoices
{
    internal const int OptionsByteLimit = 4096;
    internal const int LayoutByteLimit = 2048;

    /// The saved text with one choice changed. Every other field stays exactly
    /// as saved, even a value this version cannot read; unreadable text starts empty.
    internal static string With(string? json, string field, object value)
    {
        var values = Read(json) ?? new JsonObject();
        if (!values.ContainsKey("version")) values["version"] = 1;
        values[field] = value switch
        {
            bool flag => JsonValue.Create(flag),
            int number => JsonValue.Create(number),
            string text => JsonValue.Create(text),
            IEnumerable<string> names => new JsonArray(names.Select(name => (JsonNode?)JsonValue.Create(name)).ToArray()),
            _ => throw new ArgumentException("A panel choice is text, a switch, a number or a list.", nameof(value))
        };
        return values.ToJsonString();
    }

    private static JsonObject? Read(string? json)
    {
        if (string.IsNullOrEmpty(json) || System.Text.Encoding.UTF8.GetByteCount(json) > OptionsByteLimit) return null;
        // Counting builds the object now, so text it cannot hold fails here as damaged.
        try { return JsonNode.Parse(json) is JsonObject values && values.Count >= 0 ? values : null; }
        catch (Exception error) when (error is JsonException or ArgumentException) { return null; }
    }
}
