using System;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CodexPacer.Windows;

// Core's CompactComponentOptions on the Windows side: the collapsed bar's
// per-component choices. The engine normalizes every field again; the shell
// reads them the same way and changes one field at a time.
internal sealed record CompactChoices
{
    internal const int ByteLimit = 4096;
    internal static CompactChoices Default { get; } = new();
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        NumberHandling = JsonNumberHandling.Strict
    };

    public int Version { get; init; } = 1;
    public string MultiRing { get; init; } = "service";
    public string MultiCore { get; init; } = "count";
    public bool EndMark { get; init; } = true;
    public string StatusShow { get; init; } = "urgent";
    public string StatusWidth { get; init; } = "medium";
    public string RateMeasure { get; init; } = "total";
    public string FirstOutput { get; init; } = "latest";
    public string QuotaMultiple { get; init; } = "alternate";
    public string RingLayout { get; init; } = "concentric";
    public bool PaceTick { get; init; } = true;
    public bool LowColor { get; init; } = true;
    public bool RingDim { get; init; } = true;
    public string TimeStyle { get; init; } = "percent";
    public string ClockShow { get; init; } = "always";
    public string WarningStyle { get; init; } = "capsule";
    public int WarningLimit { get; init; } = 2;

    // Each field reads on its own, as Core decodes it: a missing, damaged or
    // unknown value takes its default without resetting the others.
    internal static CompactChoices Parse(string? json)
    {
        if (Read(json) is not { } values) return Default;
        var fallback = Default;
        string Text(string key, string standard, params string[] allowed)
            => values[key] is JsonValue value && value.TryGetValue(out string? text) && allowed.Contains(text) ? text! : standard;
        bool Flag(string key, bool standard) => values[key] is JsonValue value && value.TryGetValue(out bool flag) ? flag : standard;
        int limit = values["warningLimit"] is JsonValue number && number.TryGetValue(out int read) && read is >= 0 and <= 6 ? read : fallback.WarningLimit;
        return new CompactChoices
        {
            MultiRing = Text("multiRing", fallback.MultiRing, "service", "average", "segments"),
            MultiCore = Text("multiCore", fallback.MultiCore, "count", "percent"),
            EndMark = Flag("endMark", fallback.EndMark),
            StatusShow = Text("statusShow", fallback.StatusShow, "urgent", "stage", "count"),
            StatusWidth = Text("statusWidth", fallback.StatusWidth, "short", "medium", "long"),
            RateMeasure = Text("rateMeasure", fallback.RateMeasure, "total", "average"),
            FirstOutput = Text("firstOutput", fallback.FirstOutput, "latest", "median"),
            QuotaMultiple = Text("quotaMultiple", fallback.QuotaMultiple, "alternate", "pair", "lowest"),
            RingLayout = Text("ringLayout", fallback.RingLayout, "concentric", "sideBySide", "split"),
            PaceTick = Flag("paceTick", fallback.PaceTick),
            LowColor = Flag("lowColor", fallback.LowColor),
            RingDim = Flag("ringDim", fallback.RingDim),
            TimeStyle = Text("timeStyle", fallback.TimeStyle, "percent", "countdown"),
            ClockShow = Text("clockShow", fallback.ClockShow, "always", "peak"),
            WarningStyle = Text("warningStyle", fallback.WarningStyle, "capsule", "dot"),
            WarningLimit = limit
        };
    }

    /// The saved text with one choice changed. Every other field stays exactly
    /// as saved, even a value this version cannot read, so one damaged field
    /// never resets the rest; unreadable text starts from the defaults.
    internal static string With(string? json, string field, object value)
    {
        var values = Read(json) ?? new JsonObject();
        if (!values.ContainsKey("version")) values["version"] = 1;
        values[field] = value switch
        {
            bool flag => JsonValue.Create(flag),
            int number => JsonValue.Create(number),
            string text => JsonValue.Create(text),
            _ => throw new ArgumentException("A component choice is text, a switch or a number.", nameof(value))
        };
        return values.ToJsonString();
    }

    private static JsonObject? Read(string? json)
    {
        if (string.IsNullOrEmpty(json) || System.Text.Encoding.UTF8.GetByteCount(json) > ByteLimit) return null;
        // Counting builds the object now, so text it cannot hold fails here as damaged.
        try { return JsonNode.Parse(json) is JsonObject values && values.Count >= 0 ? values : null; }
        catch (Exception error) when (error is JsonException or ArgumentException) { return null; }
    }

    internal string ToJson() => JsonSerializer.Serialize(this with { Version = 1 }, Json);
}
