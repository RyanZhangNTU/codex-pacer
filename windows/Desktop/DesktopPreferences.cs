using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace CodexPacer.Windows;

internal sealed record DesktopPreferences
{
    public int SchemaVersion { get; init; } = 1;
    public string Language { get; init; } = "system";
    public string Position { get; init; } = "center";
    public string DisplayMode { get; init; } = "automatic";
    public string DisplaySelection { get; init; } = "automatic";
    public string DisplayID { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public int DisplayX { get; init; }
    public int DisplayY { get; init; }
    public bool ShowInFullscreen { get; init; }
    public string IslandAppearance { get; init; } = "liquidGlass";
    public string ExpandedQuotaStyle { get; init; } = "split";
    public string? CompactLayout { get; init; }
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
    public bool SystemNotifications { get; init; }
    public string[] WarningKinds { get; init; } = ["fiveHour", "ssh", "quotaDelay", "lowBalance", "spendSpike", "budget"];
    public double? DeepSeekLowBalanceLine { get; init; }
    public double? DeepSeekSpikeLimit { get; init; }
    public bool? PositionChosen { get; init; }
    public string LastSettingsPane { get; init; } = "general";
    public bool HideProjects { get; init; }
    public bool ShowAppButtons { get; init; } = true;
    public bool ShowEmbeddedCodexSessions { get; init; } = true;
    public bool ShowEmbeddedClaudeSessions { get; init; } = true;
    public bool ShowClaudeCloudProjects { get; init; } = true;
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

    internal bool IsValid => SchemaVersion == 1 && Language is "system" or "en" or "zh-Hans"
        && Position is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight"
        && DisplayMode is "automatic" or "notch" or "floating"
        && DisplaySelection is "automatic" or "primary" or "specified"
        && ValidWindow(DisplayID) && ValidWindow(DisplayName)
        && (DisplaySelection != "specified" || DisplayID.Length > 0 || DisplayName.Length > 0)
        && IslandAppearance is "classic" or "liquidGlass"
        && ExpandedQuotaStyle is "split" or "classic"
        && (CompactLayout == null || Encoding.UTF8.GetByteCount(CompactLayout) <= 8192)
        && CompactSingleTask is "stage" or "count" && CompactMetric is "remaining" or "pace"
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
            showEmbeddedClaudeSessions = ShowEmbeddedClaudeSessions,
            showClaudeCloudProjects = ShowClaudeCloudProjects,
            monitorSSH = MonitorSSH,
            deepseekSettings = new { mode = DeepSeekMode, daily = DeepSeekDailyBudget, weekly = DeepSeekWeeklyBudget,
                ringPeriod = DeepSeekRingPeriod, speedSource = DeepSeekSpeedSource, showsTurnCost = DeepSeekShowsTurnCost, balanceSource = DeepSeekBalanceSource },
            reminderSettings = new { warnings = WarningKinds, lowLine = DeepSeekLowBalanceLine, spikeLine = DeepSeekSpikeLimit },
            codexExecutable = CodexExecutable,
            codexHome = CodexHome,
            claudeHome = ClaudeHome,
            claudeOrganization = ClaudeOrganization,
            deepseekHome = DeepseekHome
        };
    }
}
