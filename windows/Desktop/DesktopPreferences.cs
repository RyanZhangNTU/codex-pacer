using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexPacer.Windows;

[JsonConverter(typeof(JsonStringEnumConverter<IslandEdge>))]
internal enum IslandEdge { Free, Top, Bottom, Left, Right }

// The center of the collapsed bar relative to the monitor's work area.
// A docked edge overrides the coordinate across that edge.
internal sealed record IslandPlacement(IslandEdge Edge, double X, double Y)
{
    internal bool IsValid => Enum.IsDefined(Edge) && X is >= 0 and <= 1 && Y is >= 0 and <= 1;
    internal bool Vertical => Edge is IslandEdge.Left or IslandEdge.Right;
}

internal sealed record DesktopPreferences
{
    public int SchemaVersion { get; init; } = 1;
    public int WelcomeGuideVersion { get; init; }
    public string? WhatsNewVersion { get; init; }
    public string Language { get; init; } = "system";
    public string Position { get; init; } = "center";
    public IslandPlacement? IslandPlacement { get; init; }
    public string DisplayMode { get; init; } = "automatic";
    public string DisplaySelection { get; init; } = "automatic";
    public string DisplayID { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public int DisplayX { get; init; }
    public int DisplayY { get; init; }
    // Each display keeps its own place while this is on; IslandScreenMemory's JSON holds them.
    public bool IslandPositionPerDisplay { get; init; } = true;
    public string? IslandDisplayPlaces { get; init; }
    public bool ShowInFullscreen { get; init; }
    public string IslandAppearance { get; init; } = "liquidGlass";
    public string ExpandedQuotaStyle { get; init; } = "split";
    public string? CompactLayout { get; init; }
    // Core's CompactComponentOptions as JSON; null keeps every default.
    public string? CompactComponentOptions { get; init; }
    public string CompactBarSize { get; init; } = "standard";
    // Core's ExpandedPanelLayout and ExpandedPanelOptions as JSON; null is the
    // automatic layout and every default.
    public string? ExpandedPanelLayout { get; init; }
    public string? ExpandedPanelOptions { get; init; }
    internal static readonly string[] BarSizes = ["small", "standard", "large", "extraLarge"];
    internal static readonly string[] Appearances = ["classic", "liquidGlass", "liquidGlassLight", "graphite"];
    public string CompactSingleTask { get; init; } = "stage";
    public string CompactMetric { get; init; } = "remaining";
    public string CodexQuotaWindow { get; init; } = "auto";
    public string ClaudeQuotaWindow { get; init; } = "auto";
    public string QuotaRingOuter { get; init; } = "";
    public string QuotaRingInner { get; init; } = "";
    public string DeepSeekPanelStyle { get; init; } = "detailed";
    public string DeepSeekMode { get; init; } = "balance";
    public string DeepSeekBalanceSource { get; init; } = "automatic";
    public double? DeepSeekDailyBudget { get; init; }
    public double? DeepSeekWeeklyBudget { get; init; }
    public string DeepSeekRingPeriod { get; init; } = "day";
    public string DeepSeekSpeedSource { get; init; } = "local";
    public bool DeepSeekShowsTurnCost { get; init; } = true;
    // Progress rings are on until the user turns one off, as on the Mac; a saved choice is kept.
    public bool DeepSeekProgressRing { get; init; } = true;
    public bool SystemNotifications { get; init; }
    public string[] WarningKinds { get; init; } = ["fiveHour", "ssh", "quotaDelay", "lowBalance", "spendSpike", "budget"];
    public double? DeepSeekLowBalanceLine { get; init; }
    public double? DeepSeekSpikeLimit { get; init; }
    public bool? PositionChosen { get; init; }
    public string LastSettingsPane { get; init; } = "overview";
    // The Mac's window theme and accent keys and values.
    public string AppTheme { get; init; } = "auto";
    public string AccentColor { get; init; } = "multicolor";
    internal static readonly string[] AccentChoices = ["multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"];
    internal static bool ValidAccent(string? value) => value != null && AccentChoices.Contains(value);
    public bool HideProjects { get; init; }
    public bool ShowAppButtons { get; init; } = true;
    public bool ShowEmbeddedCodexSessions { get; init; } = true;
    public bool MonitorRemoteControl { get; init; }
    public bool MonitorWSL { get; init; }
    public bool WslOptInMigrated { get; init; } = true;
    public bool ShowEmbeddedClaudeSessions { get; init; } = true;
    public bool ShowClaudeCloudProjects { get; init; } = true;
    public bool ClaudeProgressRing { get; init; } = true;
    public bool CodexProgressRing { get; init; } = true;
    public bool MonitorSSH { get; init; } = true;
    public bool AutomaticUpdates { get; init; } = true;
    public int RetentionMinutes { get; init; } = 30;
    public string CodexExecutable { get; init; } = "";
    public string CodexHome { get; init; } = "";
    public string ClaudeHome { get; init; } = "";
    public string ClaudeOrganization { get; init; } = "";
    public string DeepseekHome { get; init; } = "";
    public Dictionary<string, string> ProviderModes { get; init; } = new()
        { ["codex"] = "automatic", ["claude"] = "automatic", ["deepseek"] = "automatic" };

    internal bool IsValid => SchemaVersion == 1 && WelcomeGuideVersion >= 0 && (WhatsNewVersion == null || WhatsNewVersion.Length <= 64)
        && Language is "system" or "en" or "zh-Hans"
        && Position is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight"
        && (IslandPlacement == null || IslandPlacement.IsValid)
        && DisplayMode is "automatic" or "notch" or "floating"
        && DisplaySelection is "automatic" or "primary" or "specified"
        && ValidWindow(DisplayID) && ValidWindow(DisplayName)
        && (DisplaySelection != "specified" || DisplayID is not ("" or "0") || DisplayName.Length > 0)
        && Appearances.Contains(IslandAppearance)
        && ExpandedQuotaStyle is "split" or "classic"
        && (CompactLayout == null || Encoding.UTF8.GetByteCount(CompactLayout) <= 8192)
        && (CompactComponentOptions == null || Encoding.UTF8.GetByteCount(CompactComponentOptions) <= CompactChoices.ByteLimit)
        && (IslandDisplayPlaces == null || Encoding.UTF8.GetByteCount(IslandDisplayPlaces) <= IslandScreenMemory.ByteLimit)
        && (ExpandedPanelLayout == null || Encoding.UTF8.GetByteCount(ExpandedPanelLayout) <= PanelChoices.LayoutByteLimit)
        && (ExpandedPanelOptions == null || Encoding.UTF8.GetByteCount(ExpandedPanelOptions) <= PanelChoices.OptionsByteLimit)
        && BarSizes.Contains(CompactBarSize)
        && CompactSingleTask is "stage" or "count" or "percent" && CompactMetric is "remaining" or "pace"
        && ValidWindow(CodexQuotaWindow) && ValidWindow(ClaudeQuotaWindow)
        && ValidRing(QuotaRingOuter) && ValidRing(QuotaRingInner)
        && DeepSeekPanelStyle is "simple" or "detailed" && DeepSeekMode is "balance" or "budget"
        && DeepSeekBalanceSource is "automatic" or "web" or "apiKey"
        && DeepSeekRingPeriod is "day" or "week" && DeepSeekSpeedSource is "local" or "account"
        && ValidAmount(DeepSeekDailyBudget) && ValidAmount(DeepSeekWeeklyBudget)
        && ValidAmount(DeepSeekLowBalanceLine) && ValidAmount(DeepSeekSpikeLimit)
        && WarningKinds is { Length: <= 6 } && WarningKinds.Distinct().Count() == WarningKinds.Length
        && WarningKinds.All(value => value is "fiveHour" or "ssh" or "quotaDelay" or "lowBalance" or "spendSpike" or "budget")
        && LastSettingsPane is { Length: > 0 and <= 64 } && !LastSettingsPane.Any(char.IsControl)
        && AppTheme is "auto" or "light" or "dark" && ValidAccent(AccentColor)
        && RetentionMinutes is >= 0 and <= 10080
        && ValidPath(CodexExecutable) && ValidPath(CodexHome) && ValidPath(ClaudeHome) && ValidPath(DeepseekHome)
        && (ClaudeOrganization == "" || ClaudeOrganization is { Length: 36 } && Guid.TryParseExact(ClaudeOrganization, "D", out _))
        && ProviderModes is { Count: 3 }
        && ProviderModes.All(pair => pair.Key is "codex" or "claude" or "deepseek" && pair.Value is "automatic" or "enabled" or "disabled");

    private static bool ValidPath(string? value) => value != null && Encoding.UTF8.GetByteCount(value) <= 32768
        && !value.Any(char.IsControl) && (value.Length == 0 || Path.IsPathFullyQualified(value));
    private static bool ValidAmount(double? value) => value == null || double.IsFinite(value.Value) && value.Value > 0;
    private static bool ValidRing(string? value) => value is "" or "none" or "codex" or "claude" or "deepseek";
    private static bool ValidWindow(string? value) => value != null && Encoding.UTF8.GetByteCount(value) <= 1024 && !value.Any(char.IsControl);
    // Older profiles stored a corner without the explicit-choice marker.
    internal bool HasChosenPosition => PositionChosen ?? Position != "center";

    internal object EngineConfiguration()
    {
        if (!IsValid) throw new ArgumentException("Invalid Windows settings.");
        return new
        {
            providerModes = ProviderModes, hideProjects = HideProjects, retentionMinutes = RetentionMinutes,
            showEmbeddedCodexSessions = ShowEmbeddedCodexSessions,
            monitorRemoteControl = MonitorRemoteControl,
            monitorWSL = MonitorWSL,
            showEmbeddedClaudeSessions = ShowEmbeddedClaudeSessions,
            showClaudeCloudProjects = ShowClaudeCloudProjects,
            claudeProgressRing = ClaudeProgressRing,
            codexProgressRing = CodexProgressRing,
            deepseekProgressRing = DeepSeekProgressRing,
            monitorSSH = MonitorSSH,
            deepseekSettings = new { mode = DeepSeekMode, daily = DeepSeekDailyBudget, weekly = DeepSeekWeeklyBudget,
                ringPeriod = DeepSeekRingPeriod, speedSource = DeepSeekSpeedSource, showsTurnCost = DeepSeekShowsTurnCost, balanceSource = DeepSeekBalanceSource },
            reminderSettings = new { warnings = WarningKinds, lowLine = DeepSeekLowBalanceLine, spikeLine = DeepSeekSpikeLimit },
            expandedPanel = new { layout = ExpandedPanelLayout, options = ExpandedPanelOptions, deepseekDetailed = DeepSeekPanelStyle != "simple" },
            codexExecutable = CodexExecutable,
            codexHome = CodexHome,
            claudeHome = ClaudeHome,
            claudeOrganization = ClaudeOrganization,
            deepseekHome = DeepseekHome
        };
    }
}
