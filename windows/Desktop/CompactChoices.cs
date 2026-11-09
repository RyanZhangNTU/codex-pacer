using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexPacer.Windows;

// Core's CompactComponentOptions on the Windows side: the collapsed bar's
// per-component choices. The engine normalizes every field again, so the
// shell only needs to read and rewrite the JSON it stores.
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

    // Unreadable text reads as the defaults; the engine applies the same rule per field.
    internal static CompactChoices Parse(string? json)
    {
        if (string.IsNullOrEmpty(json) || System.Text.Encoding.UTF8.GetByteCount(json) > ByteLimit) return Default;
        try { return JsonSerializer.Deserialize<CompactChoices>(json, Json) ?? Default; }
        catch (Exception error) when (error is JsonException or NotSupportedException or InvalidOperationException) { return Default; }
    }

    internal string ToJson() => JsonSerializer.Serialize(this with { Version = 1 }, Json);
}
