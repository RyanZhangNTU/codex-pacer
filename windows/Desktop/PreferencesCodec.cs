using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexPacer.Windows;

// JSON represents UserDefaults Data as base64. Other values use the Mac keys.
internal static class PreferencesCodec
{
    internal const int Version = 2;
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    private static readonly Dictionary<string, string> Keys = new()
    {
        ["language"] = "appLanguage", ["position"] = "islandPosition", ["displayMode"] = "islandDisplayMode",
        ["codexQuotaWindow"] = "quotaWindowID", ["claudeQuotaWindow"] = "claudeQuotaWindowID",
        ["retentionMinutes"] = "completedRetentionMinutes", ["lastSettingsPane"] = "settingsPane",
        ["claudeOrganization"] = "claudeWebOrganizationID",
        ["automaticUpdates"] = "SUEnableAutomaticChecks",
        ["deepSeekPanelStyle"] = "deepseekPanelStyle", ["deepSeekMode"] = "deepseekMode",
        ["deepSeekBalanceSource"] = "deepseekBalanceSource", ["deepSeekDailyBudget"] = "deepseekDailyBudget",
        ["deepSeekWeeklyBudget"] = "deepseekWeeklyBudget", ["deepSeekRingPeriod"] = "deepseekRingPeriod",
        ["deepSeekSpeedSource"] = "deepseekSpeedSource", ["deepSeekShowsTurnCost"] = "deepseekShowsTurnCost",
        ["deepSeekLowBalanceLine"] = "deepseekLowBalanceLine", ["deepSeekSpikeLimit"] = "deepseekSpikeLimit",
        ["deepSeekProgressRing"] = "deepseekProgressRing"
    };
    private static string Key(string property) => Keys.GetValueOrDefault(property, property);
    internal static DesktopPreferences Decode(ReadOnlySpan<byte> bytes)
    {
        var root = JsonNode.Parse(bytes, documentOptions: new() { MaxDepth = 32 }) as JsonObject ?? throw new JsonException();
        int version = root["schemaVersion"]?.GetValue<int>() ?? throw new JsonException();
        if (version is not (1 or Version)) throw new JsonException();
        DesktopPreferences value;
        if (version == 1)
        {
            value = root.Deserialize<DesktopPreferences>(Json) ?? throw new JsonException();
            value = Normalize(value);
        }
        else
        {
            var properties = JsonSerializer.SerializeToNode(new DesktopPreferences(), Json)!.AsObject();
            foreach (string property in properties.Select(pair => pair.Key).ToArray())
            {
                if (property is "schemaVersion" or "compactLayout" or "compactComponentOptions" or "islandDisplayPlaces" or "expandedPanelLayout" or "expandedPanelOptions" or "warningKinds" or "providerModes" or "positionChosen" or "displaySelection" or "displayID" or "islandPlacement") continue;
                if (root.TryGetPropertyValue(Key(property), out var saved)) properties[property] = saved?.DeepClone();
            }
            string displayID = ReadDisplayID(root);
            properties["displayID"] = displayID;
            bool namedDisplay = NamedDisplayFallback(root) &&
                root["displayName"] is JsonValue name && name.TryGetValue<string>(out var displayName) && !string.IsNullOrEmpty(displayName);
            properties["displaySelection"] = MainDisplay(displayID) && !namedDisplay ? MainDisplayMode(root, displayID) : "specified";
            properties["lastSettingsPane"] = properties["lastSettingsPane"]?.GetValue<string>() == "collapsedBar" ? "collapsed" : properties["lastSettingsPane"]?.DeepClone();
            properties["positionChosen"] = root["islandPosition"] is JsonValue position && position.TryGetValue<string>(out var chosen)
                && chosen is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight";
            var providers = properties["providerModes"]!.AsObject();
            const string prefix = "providerModule.";
            foreach (var entry in root)
            {
                if (!entry.Key.StartsWith(prefix, StringComparison.Ordinal)) continue;
                string provider = entry.Key[prefix.Length..];
                if (DesktopPreferences.ValidProviderId(provider) && entry.Value is JsonValue valueNode
                    && valueNode.TryGetValue<string>(out string? mode) && DesktopPreferences.ValidProviderMode(mode))
                    providers[provider] = mode;
            }
            foreach (string ring in new[] { "quotaRingOuter", "quotaRingInner" })
            {
                if (!root.ContainsKey(ring)) properties[ring] = "";
                else
                {
                    string? saved = root[ring]?.GetValue<string>();
                    properties[ring] = saved is "codex" or "claude" or "deepseek" ? saved : "none";
                }
            }
            if (root["islandDisplayMode"]?.GetValue<string>() is not ("automatic" or "notch" or "floating") && root["floatingIsland"]?.GetValue<bool>() == true) properties["displayMode"] = "floating";
            if (root["compactIslandLayout"] is JsonValue layout)
            {
                byte[] data = Convert.FromBase64String(layout.GetValue<string>());
                if (data.Length > 8192) throw new JsonException();
                properties["compactLayout"] = new UTF8Encoding(false, true).GetString(data);
                var layoutObject = JsonNode.Parse(data) as JsonObject;
                if (layoutObject?["warnings"] is JsonArray warnings)
                    properties["warningKinds"] = warnings.DeepClone();
            }
            value = Normalize(properties.Deserialize<DesktopPreferences>(Json) ?? throw new JsonException()) with
            {
                IslandPlacement = ReadIslandPlacement(root["islandPlacement"]), CompactComponentOptions = ReadComponentOptions(root["compactComponentOptions"]),
                IslandDisplayPlaces = ReadDisplayPlaces(root["islandDisplayPlaces"]),
                ExpandedPanelLayout = ReadData(root["expandedPanelLayout"], PanelChoices.LayoutByteLimit),
                ExpandedPanelOptions = ReadData(root["expandedPanelOptions"], PanelChoices.OptionsByteLimit)
            };
        }
        if (!value.IsValid) throw new JsonException();
        return value with
        {
            WslOptInMigrated = root["wslOptInMigrated"] is JsonValue marker && marker.TryGetValue<bool>(out bool migrated) && migrated,
            DurableOptInMigrated = root["durableOptInMigrated"] is JsonValue durable && durable.TryGetValue<bool>(out bool decided) && decided
        };
    }
    // Damaged component choices read as the defaults without touching other settings.
    private static string? ReadComponentOptions(JsonNode? node)
    {
        if (node is not JsonValue value || !value.TryGetValue<string>(out var text)) return null;
        try
        {
            byte[] data = Convert.FromBase64String(text);
            if (data.Length > CompactChoices.ByteLimit || JsonNode.Parse(data) is not JsonObject) return null;
            return new UTF8Encoding(false, true).GetString(data);
        }
        catch (Exception error) when (error is FormatException or JsonException or DecoderFallbackException or ArgumentException) { return null; }
    }
    // A damaged panel layout reads as automatic and damaged choices as the
    // defaults, without touching other settings.
    private static string? ReadData(JsonNode? node, int limit)
    {
        if (node is not JsonValue value || !value.TryGetValue<string>(out var text)) return null;
        try
        {
            byte[] data = Convert.FromBase64String(text);
            if (data.Length > limit || JsonNode.Parse(data) is not JsonObject) return null;
            return new UTF8Encoding(false, true).GetString(data);
        }
        catch (Exception error) when (error is FormatException or JsonException or DecoderFallbackException or ArgumentException) { return null; }
    }
    // Damaged places read as none; each display then starts from the current place.
    private static string? ReadDisplayPlaces(JsonNode? node)
    {
        if (node is not JsonValue value || !value.TryGetValue<string>(out var text)) return null;
        try
        {
            byte[] data = Convert.FromBase64String(text);
            if (data.Length > IslandScreenMemory.ByteLimit || JsonNode.Parse(data) is not JsonObject) return null;
            return new UTF8Encoding(false, true).GetString(data);
        }
        catch (Exception error) when (error is FormatException or JsonException or DecoderFallbackException or ArgumentException) { return null; }
    }
    private static IslandPlacement? ReadIslandPlacement(JsonNode? node)
    {
        // A damaged position should not reset the rest of the user's settings.
        if (node is not JsonObject placement || !placement.ContainsKey("edge") || !placement.ContainsKey("x") || !placement.ContainsKey("y")) return null;
        try { return placement.Deserialize<IslandPlacement>(Json) is { IsValid: true } value ? value : null; }
        catch (JsonException) { return null; }
    }
    private static DesktopPreferences Normalize(DesktopPreferences value) => value with
    {
        DisplaySelection = value.DisplaySelection is "primary" or "specified" ? value.DisplaySelection : "automatic",
        Language = value.Language is "en" or "zh-Hans" ? value.Language : "system",
        AppTheme = value.AppTheme is "light" or "dark" ? value.AppTheme : "auto",
        AccentColor = DesktopPreferences.ValidAccent(value.AccentColor) ? value.AccentColor : "multicolor",
        Position = value.Position is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight" ? value.Position : "center",
        DisplayMode = value.DisplayMode is "notch" or "floating" ? value.DisplayMode : "automatic",
        IslandAppearance = value.IslandAppearance is "classic" or "graphite" or "liquidGlassLight" ? value.IslandAppearance : "liquidGlass",
        CompactBarSize = DesktopPreferences.BarSizes.Contains(value.CompactBarSize) ? value.CompactBarSize : "standard",
        CompactComponentOptions = value.CompactComponentOptions is { } options && Encoding.UTF8.GetByteCount(options) <= CompactChoices.ByteLimit ? options : null,
        IslandDisplayPlaces = value.IslandDisplayPlaces is { } places && Encoding.UTF8.GetByteCount(places) <= IslandScreenMemory.ByteLimit ? places : null,
        ExpandedPanelLayout = value.ExpandedPanelLayout is { } panelLayout && Encoding.UTF8.GetByteCount(panelLayout) <= PanelChoices.LayoutByteLimit ? panelLayout : null,
        ExpandedPanelOptions = value.ExpandedPanelOptions is { } panelOptions && Encoding.UTF8.GetByteCount(panelOptions) <= PanelChoices.OptionsByteLimit ? panelOptions : null,
        ExpandedQuotaStyle = value.ExpandedQuotaStyle is "classic" ? "classic" : "split",
        DeepSeekPanelStyle = value.DeepSeekPanelStyle is "simple" ? "simple" : "detailed",
        DeepSeekMode = value.DeepSeekMode is "budget" ? "budget" : "balance",
        DeepSeekBalanceSource = value.DeepSeekBalanceSource is "apiKey" or "web" ? value.DeepSeekBalanceSource : "automatic",
        WorkBuddyAccountSite = value.WorkBuddyAccountSite is "china" or "international" ? value.WorkBuddyAccountSite : "automatic",
        DeepSeekSpeedSource = value.DeepSeekSpeedSource is "account" ? "account" : "local",
        DeepSeekRingPeriod = value.DeepSeekRingPeriod is "week" ? "week" : "day",
        CompactSingleTask = value.CompactSingleTask is "count" or "percent" ? value.CompactSingleTask : "stage",
        CompactMetric = value.CompactMetric is "pace" ? "pace" : "remaining",
        LastSettingsPane = value.LastSettingsPane is "overview" or "history" or "general" or "appearance" or "collapsed" or "expandedPanel" or "notifications" or "codex" or "claude" or "deepseek" or "remote" or "about" or "support" or "reminders" or "connections" or "help" or "whatsNew"
            || DesktopPreferences.IsStoredHarnessPane(value.LastSettingsPane) ? value.LastSettingsPane : "overview"
    };
    internal static byte[] Encode(DesktopPreferences value, ReadOnlySpan<byte> original = default)
    {
        if (!value.IsValid) throw new JsonException();
        JsonObject root = original.IsEmpty ? new() : JsonNode.Parse(original)!.AsObject();
        bool preserveMainDisplay = root["schemaVersion"]?.GetValue<int>() == Version && MainDisplay(ReadDisplayID(root))
            && value.DisplaySelection == MainDisplayMode(root, ReadDisplayID(root));
        var properties = JsonSerializer.SerializeToNode(value, Json)!.AsObject();
        if (root["schemaVersion"]?.GetValue<int>() == 1)
            foreach (string property in properties.Select(pair => pair.Key)) root.Remove(property);
        root["schemaVersion"] = Version;
        foreach (var property in properties)
        {
            if (property.Key is "schemaVersion" or "compactLayout" or "compactComponentOptions" or "islandDisplayPlaces" or "expandedPanelLayout" or "expandedPanelOptions" or "warningKinds" or "providerModes" or "positionChosen" or "displaySelection" or "displayID") continue;
            string key = Key(property.Key);
            if (property.Value == null) root.Remove(key); else root[key] = property.Value.DeepClone();
        }
        if (NamedDisplayFallback(root)) root.Remove("displaySelection");
        if (value.DisplaySelection == "specified")
        {
            if (!MainDisplay(value.DisplayID)) root["displayID"] = value.DisplayID;
            else
            {
                // Some virtual or disconnected adapters have no device interface path.
                root.Remove("displayID");
                root["displaySelection"] = "specified";
            }
        }
        else if (!preserveMainDisplay)
        {
            if (value.DisplaySelection == "automatic") root.Remove("displayID");
            else root["displayID"] = 0;
        }
        if (!value.HasChosenPosition) root.Remove("islandPosition");
        root["settingsPane"] = value.LastSettingsPane == "collapsed" ? "collapsedBar" : value.LastSettingsPane;
        root["floatingIsland"] = value.DisplayMode == "floating";
        foreach (var provider in value.ProviderModes) root["providerModule." + provider.Key] = provider.Value;
        foreach (var ring in new[] { ("quotaRingOuter", value.QuotaRingOuter), ("quotaRingInner", value.QuotaRingInner) })
            if (ring.Item2.Length == 0) root.Remove(ring.Item1); else root[ring.Item1] = ring.Item2;
        if (value.CompactLayout == null) root.Remove("compactIslandLayout");
        else root["compactIslandLayout"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(value.CompactLayout));
        if (value.CompactComponentOptions == null) root.Remove("compactComponentOptions");
        else root["compactComponentOptions"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(value.CompactComponentOptions));
        if (value.IslandDisplayPlaces == null) root.Remove("islandDisplayPlaces");
        else root["islandDisplayPlaces"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(value.IslandDisplayPlaces));
        foreach (var (key, data) in new[] { ("expandedPanelLayout", value.ExpandedPanelLayout), ("expandedPanelOptions", value.ExpandedPanelOptions) })
            if (data == null) root.Remove(key); else root[key] = Convert.ToBase64String(Encoding.UTF8.GetBytes(data));
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(root, Json);
        if (bytes.Length > PreferencesStore.MaximumBytes) throw new JsonException();
        // A save must be reversible, including the warnings carried by the layout.
        var restored = Decode(bytes);
        if (!restored.WarningKinds.Order().SequenceEqual(value.WarningKinds.Order())) throw new JsonException();
        return bytes;
    }
    private static bool MainDisplay(string value) => value is "" or "0";
    private static bool NamedDisplayFallback(JsonObject root) =>
        root["displaySelection"] is JsonValue saved && saved.TryGetValue<string>(out var mode) && mode == "specified";
    private static string ReadDisplayID(JsonObject root)
    {
        if (root["displayID"] == null) return "";
        if (root["displayID"] is JsonValue value)
        {
            if (value.TryGetValue<string>(out var path)) return path;
            if (value.TryGetValue<double>(out double number) && number == 0) return "0";
        }
        throw new JsonException();
    }
    private static string MainDisplayMode(JsonObject root, string displayID)
    {
        if (root["displaySelection"] is JsonValue saved && saved.TryGetValue<string>(out var alias) && alias is "automatic" or "primary") return alias;
        return displayID.Length == 0 ? "automatic" : "primary";
    }
}
