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
    public string[] WarningKinds { get; init; } = ["fiveHour", "ssh", "quotaDelay", "lowBalance", "spendSpike", "budget", "lowCredits", "resetExpiry"];
    internal static readonly string[] WarningChoices = ["fiveHour", "ssh", "quotaDelay", "lowBalance", "spendSpike", "budget", "lowCredits", "resetExpiry"];
    public double? DeepSeekLowBalanceLine { get; init; }
    public double? DeepSeekSpikeLimit { get; init; }
    /// Days ahead that a Codex banked reset counts as expiring; null is Core's default (three days).
    public int? CodexResetExpiryDays { get; init; }
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
    // Dot (Durable) tasks are opt-in. An upgraded profile decides once from
    // local Dot progress receipts; a new profile starts off.
    public bool MonitorDurable { get; init; }
    public bool DurableOptInMigrated { get; init; } = true;
    public bool MonitorWSL { get; init; }
    public bool WslOptInMigrated { get; init; } = true;
    public bool ShowEmbeddedClaudeSessions { get; init; } = true;
    public bool ShowClaudeCloudProjects { get; init; } = true;
    public bool ClaudeProgressRing { get; init; } = true;
    // Settings → Collaboration, the Claude → Codex pair, off until the user turns
    // it on. PreferencesCodec stores these under the Mac's per-pair keys
    // (`collaboration.claude>codex.*`); keys from earlier builds are ignored.
    // Model, effort and fast mode follow Codex until the user picks one, and a
    // pick is kept while they follow Codex again. The runner applies these.
    public bool CodexDelegation { get; init; }
    public string CodexDelegationTrigger { get; init; } = "ask";
    public bool CodexDelegationFollowModel { get; init; } = true;
    public string CodexDelegationModel { get; init; } = "";
    [JsonPropertyName("collaboration.claude>codex.pickedEffort")]
    public bool CodexDelegationPickedEffort { get; init; }
    public bool CodexDelegationFollowEffort { get; init; } = true;
    public string CodexDelegationEffort { get; init; } = "high";
    [JsonPropertyName("collaboration.claude>codex.pickedFast")]
    public bool CodexDelegationPickedFast { get; init; }
    public bool CodexDelegationFollowFast { get; init; } = true;
    public bool CodexDelegationFast { get; init; }
    public string CodexDelegationRecords { get; init; } = "turn";
    public int CodexDelegationRecordsHours { get; init; } = 24;
    public string CodexDelegationSandbox { get; init; } = "workspace-write-network";
    public bool CodexDelegationWorktree { get; init; }
    public string CodexDelegationInstructions { get; init; } = "";
    public bool CodexDelegationMemory { get; init; }
    public int CodexDelegationConcurrency { get; init; } = 3;
    // Percent of Codex quota left below which runs don't start; 0 never holds them back.
    public int CodexDelegationQuotaFloor { get; init; }
    internal static readonly string[] DelegationTriggers = ["ask", "command"];
    internal static readonly string[] DelegationEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"];
    internal static readonly string[] DelegationRecords = ["turn", "timed", "keep"];
    internal static readonly int[] DelegationRecordsHours = [2, 6, 12, 24, 48, 72, 168];
    internal static readonly string[] DelegationSandboxes = ["read-only", "workspace-write", "workspace-write-network", "danger-full-access"];
    internal static readonly int[] DelegationConcurrency = [1, 2, 3, 4];
    internal static readonly int[] DelegationQuotaFloors = [0, 10, 20];
    internal const int DelegationInstructionsLimit = 4000;
    /// A model slug: letters, digits and the punctuation Codex uses in them.
    internal static bool ValidDelegationModel(string? value) => value != null
        && (value.Length == 0 || System.Text.RegularExpressions.Regex.IsMatch(value, @"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}\z"));
    /// Standing instructions: at most 4000 characters, lines and tabs but no other control characters.
    internal static bool ValidDelegationInstructions(string? value) => value is { Length: <= DelegationInstructionsLimit }
        && !value.Any(c => char.IsControl(c) && c is not ('\n' or '\r' or '\t'));
    internal static string CleanDelegationInstructions(string? value)
    {
        string text = new((value ?? "").Where(c => !char.IsControl(c) || c is '\n' or '\r' or '\t').ToArray());
        text = text.Trim();
        return text.Length <= DelegationInstructionsLimit ? text : text[..DelegationInstructionsLimit];
    }
    internal DesktopPreferences SetDelegationFollowEffort(bool follow, string? fallback) => this with
    {
        CodexDelegationFollowEffort = follow,
        CodexDelegationEffort = !follow && !CodexDelegationPickedEffort && fallback != null && DelegationEfforts.Contains(fallback)
            ? fallback : CodexDelegationEffort,
        CodexDelegationPickedEffort = !follow || !CodexDelegationFollowEffort || CodexDelegationPickedEffort
    };
    internal DesktopPreferences SetDelegationFollowFast(bool follow, bool? fallback) => this with
    {
        CodexDelegationFollowFast = follow,
        CodexDelegationFast = !follow && !CodexDelegationPickedFast ? fallback ?? CodexDelegationFast : CodexDelegationFast,
        CodexDelegationPickedFast = !follow || !CodexDelegationFollowFast || CodexDelegationPickedFast
    };
    /// Every Collaboration choice but the pair's switch back to its default.
    internal DesktopPreferences RestoringDelegationDefaults()
    {
        var initial = new DesktopPreferences();
        return this with
        {
            CodexDelegationTrigger = initial.CodexDelegationTrigger, CodexDelegationFollowModel = initial.CodexDelegationFollowModel,
            CodexDelegationModel = initial.CodexDelegationModel, CodexDelegationFollowEffort = initial.CodexDelegationFollowEffort,
            CodexDelegationPickedEffort = false,
            CodexDelegationEffort = initial.CodexDelegationEffort, CodexDelegationFollowFast = initial.CodexDelegationFollowFast,
            CodexDelegationPickedFast = false,
            CodexDelegationFast = initial.CodexDelegationFast, CodexDelegationRecords = initial.CodexDelegationRecords,
            CodexDelegationRecordsHours = initial.CodexDelegationRecordsHours, CodexDelegationSandbox = initial.CodexDelegationSandbox,
            CodexDelegationWorktree = initial.CodexDelegationWorktree, CodexDelegationInstructions = initial.CodexDelegationInstructions,
            CodexDelegationMemory = initial.CodexDelegationMemory, CodexDelegationConcurrency = initial.CodexDelegationConcurrency,
            CodexDelegationQuotaFloor = initial.CodexDelegationQuotaFloor
        };
    }
    /// Whether every Collaboration choice besides the switch is at its default.
    internal bool DelegationIsDefault => RestoringDelegationDefaults() == this;
    /// Whether every advanced choice (access, context, limits) is at its default.
    internal bool DelegationAdvancedIsDefault
    {
        get
        {
            var initial = new DesktopPreferences();
            return CodexDelegationSandbox == initial.CodexDelegationSandbox && CodexDelegationWorktree == initial.CodexDelegationWorktree
                && CodexDelegationInstructions.Length == 0 && CodexDelegationMemory == initial.CodexDelegationMemory
                && CodexDelegationConcurrency == initial.CodexDelegationConcurrency && CodexDelegationQuotaFloor == initial.CodexDelegationQuotaFloor;
        }
    }
    public bool CodexProgressRing { get; init; } = true;
    // A module's progress ring is on unless listed here, like the built-in rings.
    public string[] DisabledHarnessProgress { get; init; } = [];
    // Modules whose task rows leave out the credits each turn used.
    public string[] HiddenTurnCredits { get; init; } = [];
    // Data folders chosen for local modules, by module ID.
    public Dictionary<string, string> HarnessHomes { get; init; } = new();
    // Each credits module's dial center, bar value and reminders, by module ID.
    public Dictionary<string, HarnessCreditsChoice> HarnessCredits { get; init; } = new();
    internal HarnessCreditsChoice Credits(string provider) => HarnessCredits.TryGetValue(provider, out var choice) ? choice : HarnessCreditsChoice.Default;
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
        && DelegationTriggers.Contains(CodexDelegationTrigger) && ValidDelegationModel(CodexDelegationModel) && DelegationEfforts.Contains(CodexDelegationEffort)
        && DelegationRecords.Contains(CodexDelegationRecords) && DelegationRecordsHours.Contains(CodexDelegationRecordsHours)
        && DelegationSandboxes.Contains(CodexDelegationSandbox) && ValidDelegationInstructions(CodexDelegationInstructions)
        && DelegationConcurrency.Contains(CodexDelegationConcurrency) && DelegationQuotaFloors.Contains(CodexDelegationQuotaFloor)
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
        && WarningKinds is { Length: <= 8 } && WarningKinds.Distinct().Count() == WarningKinds.Length
        && WarningKinds.All(WarningChoices.Contains) && CodexResetExpiryDays is null or (>= 1 and <= 30)
        && LastSettingsPane is { Length: > 0 and <= 64 } && !LastSettingsPane.Any(char.IsControl)
        && AppTheme is "auto" or "light" or "dark" && ValidAccent(AccentColor)
        && RetentionMinutes is >= 0 and <= 10080
        && ValidPath(CodexExecutable) && ValidPath(CodexHome) && ValidPath(ClaudeHome) && ValidPath(DeepseekHome)
        && (ClaudeOrganization == "" || ClaudeOrganization is { Length: 36 } && Guid.TryParseExact(ClaudeOrganization, "D", out _))
        && ProviderModes is { Count: >= 3 and <= 128 }
        && LegacyProviders.All(ProviderModes.ContainsKey)
        && ProviderModes.All(pair => ValidProviderId(pair.Key) && ValidProviderMode(pair.Value))
        && ValidModuleList(DisabledHarnessProgress, legacy: false) && ValidModuleList(HiddenTurnCredits, legacy: true)
        && HarnessHomes is { Count: <= 128 } && HarnessHomes.All(pair => ValidProviderId(pair.Key) && !IsLegacyProvider(pair.Key) && ValidPath(pair.Value))
        && HarnessCredits is { Count: <= 128 } && HarnessCredits.All(pair => ValidProviderId(pair.Key) && !IsLegacyProvider(pair.Key) && pair.Value is { IsValid: true });

    private static bool ValidModuleList(string[]? ids, bool legacy) => ids is { Length: <= 128 }
        && ids.Distinct(StringComparer.Ordinal).Count() == ids.Length && ids.All(id => id != null && ValidProviderId(id) && (legacy || !IsLegacyProvider(id)));

    internal static IReadOnlyList<string> LegacyProviders => ModuleIds.Legacy;
    internal static bool IsLegacyProvider(string id) => ModuleIds.IsLegacy(id);
    internal const string HarnessPanePrefix = "harness.";
    internal static bool IsStoredHarnessPane(string? value) => value?.StartsWith(HarnessPanePrefix, StringComparison.Ordinal) == true
        && ValidProviderId(value[HarnessPanePrefix.Length..]);
    internal static bool ValidProviderId(string id) => ModuleIds.Valid(id);
    internal static bool ValidProviderMode(string? value) => value is "automatic" or "enabled" or "disabled";

    private static bool ValidPath(string? value) => value != null && Encoding.UTF8.GetByteCount(value) <= 32768
        && !value.Any(char.IsControl) && (value.Length == 0 || Path.IsPathFullyQualified(value));
    private static bool ValidAmount(double? value) => value == null || double.IsFinite(value.Value) && value.Value > 0;
    // Any module can fill a ring; the engine ignores one it can't draw.
    private static bool ValidRing(string? value) => value is "" or "none" || value != null && ValidProviderId(value);
    private static bool ValidWindow(string? value) => value != null && Encoding.UTF8.GetByteCount(value) <= 1024 && !value.Any(char.IsControl);
    // Older profiles stored a corner without the explicit-choice marker.
    internal bool HasChosenPosition => PositionChosen ?? Position != "center";

    // Lane names that Core's CompactIslandLayout reads as its warnings component: the component
    // and the separate warnings and earlier names that schema 7 merged into it.
    private static readonly HashSet<string> WarningLaneNames = ["warnings", "lowQuotaWarning", "sshWarning", "quotaDelayWarning", "quotaWarning", "freshness"];
    /// Whether the saved collapsed bar places its warnings component, read as Core reads the
    /// layout: none saved, or one it cannot read, is the standard bar, which does.
    internal static bool WarningsOnBar(string? layout)
    {
        if (layout == null) return true;
        try
        {
            using var document = JsonDocument.Parse(layout);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out int schema) || schema < 1)
                return true;
            var lanes = new List<JsonElement>();
            foreach (string lane in schema == 1 ? new[] { "leading", "trailing", "center" } : ["leading", "trailing"])
            {
                if (root.TryGetProperty(lane, out var names)) lanes.Add(names);
                else if (lane != "center") return true;
            }
            bool placed = false;
            foreach (var names in lanes)
            {
                if (names.ValueKind != JsonValueKind.Array) return true;
                foreach (var name in names.EnumerateArray())
                {
                    if (name.ValueKind != JsonValueKind.String) return true;
                    placed |= WarningLaneNames.Contains(name.GetString()!);
                }
            }
            return placed;
        }
        catch (JsonException) { return true; }
    }

    internal object EngineConfiguration()
    {
        if (!IsValid) throw new ArgumentException("Invalid Windows settings.");
        return new
        {
            providerModes = ProviderModes, hideProjects = HideProjects, retentionMinutes = RetentionMinutes,
            showEmbeddedCodexSessions = ShowEmbeddedCodexSessions,
            monitorDurable = MonitorDurable,
            monitorWSL = MonitorWSL,
            showEmbeddedClaudeSessions = ShowEmbeddedClaudeSessions,
            showClaudeCloudProjects = ShowClaudeCloudProjects,
            claudeProgressRing = ClaudeProgressRing,
            // What follows Codex goes as null; the engine writes the runner's config.json from this.
            codexDelegation = new
            {
                enabled = CodexDelegation, trigger = CodexDelegationTrigger,
                model = CodexDelegationFollowModel || CodexDelegationModel.Length == 0 ? null : CodexDelegationModel,
                effort = CodexDelegationFollowEffort ? null : CodexDelegationEffort,
                fast = CodexDelegationFollowFast ? (bool?)null : CodexDelegationFast,
                records = CodexDelegationRecords, recordsHours = CodexDelegationRecordsHours, sandbox = CodexDelegationSandbox,
                worktree = CodexDelegationWorktree, instructions = CodexDelegationInstructions, memory = CodexDelegationMemory,
                maxConcurrent = CodexDelegationConcurrency, quotaFloor = CodexDelegationQuotaFloor == 0 ? (int?)null : CodexDelegationQuotaFloor
            },
            codexProgressRing = CodexProgressRing,
            deepseekProgressRing = DeepSeekProgressRing,
            disabledHarnessProgress = DisabledHarnessProgress,
            hiddenTurnCredits = HiddenTurnCredits,
            harnessHomes = HarnessHomes,
            harnessCredits = HarnessCredits.ToDictionary(pair => pair.Key, pair => new
            {
                center = pair.Value.Center, bar = pair.Value.Bar, lowCredits = pair.Value.LowCredits,
                expiryReminder = pair.Value.ExpiryReminder, expiryDays = pair.Value.ExpiryDays
            }),
            monitorSSH = MonitorSSH,
            deepseekSettings = new { mode = DeepSeekMode, daily = DeepSeekDailyBudget, weekly = DeepSeekWeeklyBudget,
                ringPeriod = DeepSeekRingPeriod, speedSource = DeepSeekSpeedSource, showsTurnCost = DeepSeekShowsTurnCost, balanceSource = DeepSeekBalanceSource },
            // The reminders that follow the bar's warnings notify only while it shows them. Only this
            // flag reaches the engine, so reordering the bar stays a presentation edit.
            reminderSettings = new { warnings = WarningKinds, lowLine = DeepSeekLowBalanceLine, spikeLine = DeepSeekSpikeLimit, resetDays = CodexResetExpiryDays,
                warningsOnBar = WarningsOnBar(CompactLayout) },
            expandedPanel = new { layout = ExpandedPanelLayout, options = ExpandedPanelOptions, deepseekDetailed = DeepSeekPanelStyle != "simple" },
            codexExecutable = CodexExecutable,
            codexHome = CodexHome,
            claudeHome = ClaudeHome,
            claudeOrganization = ClaudeOrganization,
            deepseekHome = DeepseekHome
        };
    }
}

/// One credits module's choices, as Core's HarnessCreditsSettings: what the
/// dial's center and the collapsed bar show, the low line and the expiry reminder.
public sealed record HarnessCreditsChoice
{
    public static readonly HarnessCreditsChoice Default = new();
    internal static readonly string[] Figures = ["monthlyPercent", "monthlyRemaining", "available"];
    public string Center { get; init; } = "monthlyPercent";
    public string Bar { get; init; } = "available";
    /// Credits that count as low; empty follows a tenth of the month's credits.
    public double? LowCredits { get; init; }
    public bool ExpiryReminder { get; init; } = true;
    /// Days ahead that count as soon, for the reminder and the dial.
    public int ExpiryDays { get; init; } = 3;
    internal bool IsValid => Figures.Contains(Center) && Figures.Contains(Bar) && LowCredits is null or (>= 0 and <= 1e9)
        && ExpiryDays is >= 1 and <= 30;
}
