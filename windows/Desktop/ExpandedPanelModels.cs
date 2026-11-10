using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexPacer.Windows;

// Core's ExpandedPanelOptions after per-field fallback, as the engine sends it.
internal sealed record PanelOptions
{
    internal static PanelOptions Default { get; } = new();
    public int PageSize { get; init; } = 3;
    public string RowStyle { get; init; } = "twoLine";
    public IReadOnlyList<string> RowFields { get; init; } = ["rate", "turnTime", "model", "source", "subagents", "cost"];
    public string CodexPeriods { get; init; } = "both";
    public string ClaudePeriods { get; init; } = "both";
    public string QuotaArrange { get; init; } = "pair";
    public bool QuotaDetails { get; init; } = true;
    public bool PaceTick { get; init; } = true;
    public string DeepseekDial { get; init; } = "budget";
    public bool DeepseekPeak { get; init; } = true;
    public int SpendTasks { get; init; } = 2;
    public bool SpendElsewhere { get; init; } = true;
    public bool WeekLine { get; init; } = true;
    public IReadOnlyList<string> HeaderActions { get; init; } = ["markRead", "pin", "settings"];

    internal bool OneLine => RowStyle == "oneLine";
    /// Compares choices by value; the lists make record equality compare references.
    internal string Key => string.Join(";", PageSize, RowStyle, string.Join(",", RowFields), CodexPeriods, ClaudePeriods, QuotaArrange,
        QuotaDetails, PaceTick, DeepseekDial, DeepseekPeak, SpendTasks, SpendElsewhere, WeekLine, string.Join(",", HeaderActions));
    /// Whether a task row draws the field in the chosen style, as Core's `shows`.
    internal bool Shows(string field) => RowFields.Contains(field) && (!OneLine || field is "rate" or "turnTime");
    internal bool InHeader(string action) => HeaderActions.Contains(action);
    internal string Periods(string provider) => provider switch { "codex" => CodexPeriods, "claude" => ClaudePeriods, _ => "both" };
}

internal sealed record PanelGauge(string Provider, string Period, bool Split);
internal sealed record PanelSection(string Kind, IReadOnlyList<string> Providers, bool Actions, bool Joined, bool SpendBeside, bool ShowsHeader,
    string Title, string? Detail, DashboardLayout? Split = null, DashboardLayout? Classic = null)
{
    internal string Key => Kind + ":" + string.Join(",", Providers);
}
internal sealed record EngineExpandedPanel(int SchemaVersion, PanelOptions Options, bool BudgetDial, IReadOnlyList<PanelSection> Sections,
    IReadOnlyList<PanelGauge>? Gauges = null)
{
    internal PanelGauge? Gauge(string provider) => Gauges?.FirstOrDefault(value => value.Provider == provider);
}

// The settings page's projection from Core's ExpandedPanelPresentation.
internal sealed record PanelBlock(string Id, string Label, string Detail, string Symbol, string Group, bool Available, bool Placed, bool Locked);
internal sealed record PanelGroup(string Id, string Label, IReadOnlyList<string> Blocks);
internal sealed record PanelEditorSection(string Kind, IReadOnlyList<string> Providers, bool Actions, bool Joined, bool SpendBeside);
internal sealed record PanelEditorProjection(int Version, string? LayoutJSON, IReadOnlyList<string> Blocks, IReadOnlyList<string> Visible,
    IReadOnlyList<PanelBlock> Catalog, IReadOnlyList<PanelGroup> Groups, IReadOnlyList<PanelEditorSection> Sections, PanelOptions Options)
{
    internal bool IsValid => Version == 1 && Blocks != null && Visible != null && Catalog is { Count: <= 16 } && Groups != null
        && Sections is { Count: <= 16 } && Options != null && Visible.All(Blocks.Contains);
}
internal sealed record PanelAction(string Kind, string? Block = null, string? Before = null, int? Offset = null);
