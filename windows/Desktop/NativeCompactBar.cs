using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed record CompactEdit(string Kind, string? Component = null, string? Lane = null, string? Before = null, int? Offset = null);
internal sealed record CompactEntry(string Provider, string Text, string StripText, bool Dimmed, double? Value = null, bool? Low = null);
internal sealed record CompactRing(string Provider, double? Remaining, bool Dimmed, double? Time = null, bool? Low = null,
    bool? Exhausted = null, string? Window = null);
internal sealed record CompactComponent(string Id, string Label, string ShortLabel, string Detail, string Symbol, string HideLabel,
    bool Available, bool Shown, bool Visible, bool StripEligible, string? Text, string? StripText,
    string? Unit, string? StripUnit, string Help, string Accessibility, CompactEntry[] Entries,
    string? Tone = null, double? MaxWidth = null);
internal sealed record CompactGroup(string Id, string Label, string[] Components);
internal sealed record CompactWindow(string Provider, string Label, string Selection, bool WeeklyOnly);
// Points for one bar size, from Core's CompactBarMetrics.
internal sealed record CompactMetrics(double Scale, double Height, double StripWidth, double Inset, double Gap, double LaneGap,
    double Divider, double Value, double Unit, double Status, double Badge, double Gauge, double Warning, double StripValue,
    double StripUnit, double StripInset, double StripGap, double Shoulder, double Radius)
{
    internal static CompactMetrics Standard { get; } = new(1, 36, 32, 13, 8, 16, 14, 13, 10, 12.5, 22, 20, 15, 11.5, 9, 10, 8, 8, 19);
}
internal sealed record CompactProjection(int Version, string LayoutJSON, string[] Warnings,
    string[] EditorLeading, string[] EditorTrailing, string[] Leading, string[] Trailing,
    CompactComponent[] Components, CompactGroup[] Groups, CompactWindow[] Windows, CompactRing[] Rings,
    string[] RingChoices, bool GaugeClock, bool SingleTaskCount,
    CompactChoices? ComponentOptions = null, CompactMetrics? Metrics = null, bool? SingleTaskPercent = null)
{
    internal CompactChoices Choices => ComponentOptions ?? CompactChoices.Default;
    internal CompactMetrics Sizes => Metrics ?? CompactMetrics.Standard;
}

internal sealed class NativeCompactBar
{
    private static readonly Lazy<NativeCompactBar> SharedValue = new(() => new(""));
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly System.Collections.Generic.Dictionary<string, CompactProjection> previous = new();
    /// The last read returned Empty only because its projection has not arrived yet.
    internal bool LastPending { get; private set; }
    private EngineClient? previousClient;
    internal static NativeCompactBar Shared => SharedValue.Value;
    internal NativeCompactBar(string directory) { }
    private static CompactProjection Empty { get; } = new(1, "", [], [], [], [], [], [], [], [], [], [], false, false);
    private static bool Valid(CompactProjection value) => value is { Version: 1, Components: not null, Leading: not null, Trailing: not null }
        && value.Components.Length <= 64 && value.Leading.Length <= value.Components.Length && value.Trailing.Length <= value.Components.Length;
    private static object Input(DesktopPreferences preferences, string language, string[] providers, JsonElement? context,
        bool attached, bool strip, CompactEdit? action) => new
    {
        compact = new { layout = preferences.CompactLayout, warnings = preferences.WarningKinds, language, providers,
            options = new { singleTask = preferences.CompactSingleTask, metric = preferences.CompactMetric,
                codexWindow = preferences.CodexQuotaWindow, claudeWindow = preferences.ClaudeQuotaWindow,
                rings = new[] { preferences.QuotaRingOuter, preferences.QuotaRingInner } }, action, context, attached, strip,
            componentOptions = preferences.CompactComponentOptions, size = preferences.CompactBarSize }
    };
    internal CompactProjection Read(DesktopPreferences preferences, string language, string[] providers, JsonElement? context = null,
        bool attached = false, bool strip = false, CompactEdit? action = null)
    {
        object input = Input(preferences, language, providers, context, attached, strip, action);
        var state = ShellProjection.Read<CompactProjection>("projectCompactBar", input, Valid);
        // Only a clock tick may reuse the previous display while a query is pending.
        // Provider, source values, options and language remain part of the key.
        var node = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(input, Json))!;
        if (node["compact"]?["context"] is System.Text.Json.Nodes.JsonObject clock) clock.Remove("now");
        string key = node.ToJsonString();
        if (!ReferenceEquals(previousClient, ShellProjection.Client)) { previous.Clear(); previousClient = ShellProjection.Client; }
        LastPending = false;
        if (state.Value is { } value)
        {
            if (previous.Count >= 32) previous.Clear(); previous[key] = value; return value;
        }
        if (state.Pending && previous.TryGetValue(key, out var known)) return known;
        LastPending = state.Pending; return Empty;
    }
    internal Task<CompactProjection> ReadAsync(DesktopPreferences preferences, string language, string[] providers,
        JsonElement? context = null, bool attached = false, bool strip = false, CompactEdit? action = null)
        => ShellProjection.QueryAsync<CompactProjection>("projectCompactBar", Input(preferences, language, providers, context, attached, strip, action), Valid);
    internal async Task<DesktopPreferences> EditAsync(DesktopPreferences preferences, string language, string[] providers, CompactEdit action)
    {
        var value = await ReadAsync(preferences, language, providers, action: action);
        return preferences with { CompactLayout = value.LayoutJSON, WarningKinds = value.Warnings };
    }
    internal static string[] Providers(DesktopPreferences preferences, EngineSnapshot? snapshot)
    {
        var model = snapshot ?? ShellProjection.Client?.LatestSnapshot;
        if (model?.Modules is { } modules) return modules.Where(value => value.Enabled).Select(value => value.Provider).ToArray();
        return model?.QuotaDashboard?.Providers.Select(value => value.Provider).ToArray()
            ?? model?.Sources.Select(value => value.Provider).Distinct().ToArray() ?? [];
    }
}
