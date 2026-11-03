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
    public bool ShowClaudeCloudProjects { get; init; } = true;
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
            showClaudeCloudProjects = ShowClaudeCloudProjects,
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

/// Platform preferences contain display/source choices, never credentials.
internal sealed class PreferencesStore
{
    internal const int MaximumBytes = 60 * 1024;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private readonly string file;
    private static (DesktopPreferences Value, bool Unavailable) Unavailable() => (new() { HideProjects = true }, true);
    internal PreferencesStore(string? file = null) => this.file = Path.GetFullPath(file ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexPacer", "preferences-v1.json"));

    internal (DesktopPreferences Value, bool Unavailable) Load()
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            byte[] bytes = new byte[MaximumBytes + 1];
            int count = 0;
            while (count < bytes.Length)
            {
                int read = stream.Read(bytes, count, bytes.Length - count);
                if (read == 0) break;
                count += read;
            }
            if (count > MaximumBytes) return Unavailable();
            using var document = JsonDocument.Parse(bytes.AsMemory(0, count));
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("schemaVersion", out var version) || version.ValueKind != JsonValueKind.Number ||
                !version.TryGetInt32(out int value) || value != 1)
                return Unavailable();
            var settings = JsonSerializer.Deserialize<DesktopPreferences>(bytes.AsSpan(0, count), Json);
            if (settings != null && settings.IslandAppearance is not ("classic" or "liquidGlass")) settings = settings with { IslandAppearance = "liquidGlass" };
            if (settings != null && settings.ExpandedQuotaStyle is not ("split" or "classic")) settings = settings with { ExpandedQuotaStyle = "split" };
            if (settings != null && settings.DeepSeekPanelStyle is not ("simple" or "detailed")) settings = settings with { DeepSeekPanelStyle = "detailed" };
            return settings is { IsValid: true } ? (settings, false) : Unavailable();
        }
        catch (FileNotFoundException) { return (new(), false); }
        catch (DirectoryNotFoundException) { return (new(), false); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        { return Unavailable(); }
    }

    internal bool Save(DesktopPreferences settings)
    {
        if (!settings.IsValid) return false;
        string temporary = file + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(settings, Json);
            if (bytes.Length > MaximumBytes) return false;
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes); stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, file, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        { return false; }
        finally
        {
            try { File.Delete(temporary); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
