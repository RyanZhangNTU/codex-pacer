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
        ["deepSeekLowBalanceLine"] = "deepseekLowBalanceLine", ["deepSeekSpikeLimit"] = "deepseekSpikeLimit"
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
                if (property is "schemaVersion" or "compactLayout" or "warningKinds" or "providerModes" or "positionChosen") continue;
                if (root.TryGetPropertyValue(Key(property), out var saved)) properties[property] = saved?.DeepClone();
            }
            properties["lastSettingsPane"] = properties["lastSettingsPane"]?.GetValue<string>() == "collapsedBar" ? "collapsed" : properties["lastSettingsPane"]?.DeepClone();
            properties["positionChosen"] = root["islandPosition"] is JsonValue position && position.TryGetValue<string>(out var chosen)
                && chosen is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight";
            var providers = properties["providerModes"]!.AsObject();
            foreach (string provider in new[] { "codex", "claude", "deepseek" })
            {
                string? mode = root["providerModule." + provider]?.GetValue<string>();
                providers[provider] = mode is "enabled" or "disabled" ? mode : "automatic";
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
            value = Normalize(properties.Deserialize<DesktopPreferences>(Json) ?? throw new JsonException());
        }
        if (!value.IsValid) throw new JsonException();
        return value;
    }
    private static DesktopPreferences Normalize(DesktopPreferences value) => value with
    {
        Language = value.Language is "en" or "zh-Hans" ? value.Language : "system",
        Position = value.Position is "center" or "topLeft" or "bottomLeft" or "topRight" or "bottomRight" ? value.Position : "center",
        DisplayMode = value.DisplayMode is "notch" or "floating" ? value.DisplayMode : "automatic",
        IslandAppearance = value.IslandAppearance is "classic" ? "classic" : "liquidGlass",
        ExpandedQuotaStyle = value.ExpandedQuotaStyle is "classic" ? "classic" : "split",
        DeepSeekPanelStyle = value.DeepSeekPanelStyle is "simple" ? "simple" : "detailed",
        DeepSeekMode = value.DeepSeekMode is "budget" ? "budget" : "balance",
        DeepSeekBalanceSource = value.DeepSeekBalanceSource is "apiKey" or "web" ? value.DeepSeekBalanceSource : "automatic",
        DeepSeekSpeedSource = value.DeepSeekSpeedSource is "account" ? "account" : "local",
        DeepSeekRingPeriod = value.DeepSeekRingPeriod is "week" ? "week" : "day",
        CompactSingleTask = value.CompactSingleTask is "count" ? "count" : "stage",
        CompactMetric = value.CompactMetric is "pace" ? "pace" : "remaining",
        LastSettingsPane = value.LastSettingsPane is "appearance" or "collapsed" or "reminders" or "codex" or "claude" or "deepseek" or "connections" or "help" or "support" or "whatsNew" ? value.LastSettingsPane : "general"
    };
    internal static byte[] Encode(DesktopPreferences value, ReadOnlySpan<byte> original = default)
    {
        if (!value.IsValid) throw new JsonException();
        JsonObject root = original.IsEmpty ? new() : JsonNode.Parse(original)!.AsObject();
        var properties = JsonSerializer.SerializeToNode(value, Json)!.AsObject();
        if (root["schemaVersion"]?.GetValue<int>() == 1)
            foreach (string property in properties.Select(pair => pair.Key)) root.Remove(property);
        root["schemaVersion"] = Version;
        foreach (var property in properties)
        {
            if (property.Key is "schemaVersion" or "compactLayout" or "warningKinds" or "providerModes" or "positionChosen") continue;
            string key = Key(property.Key);
            if (property.Value == null) root.Remove(key); else root[key] = property.Value.DeepClone();
        }
        if (!value.HasChosenPosition) root.Remove("islandPosition");
        root["settingsPane"] = value.LastSettingsPane == "collapsed" ? "collapsedBar" : value.LastSettingsPane;
        root["floatingIsland"] = value.DisplayMode == "floating";
        foreach (var provider in value.ProviderModes) root["providerModule." + provider.Key] = provider.Value;
        foreach (var ring in new[] { ("quotaRingOuter", value.QuotaRingOuter), ("quotaRingInner", value.QuotaRingInner) })
            if (ring.Item2.Length == 0) root.Remove(ring.Item1); else root[ring.Item1] = ring.Item2;
        if (value.CompactLayout == null) root.Remove("compactIslandLayout");
        else root["compactIslandLayout"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(value.CompactLayout));
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(root, Json);
        if (bytes.Length > PreferencesStore.MaximumBytes) throw new JsonException();
        // A save must be reversible, including the warnings carried by the layout.
        var restored = Decode(bytes);
        if (!restored.WarningKinds.Order().SequenceEqual(value.WarningKinds.Order())) throw new JsonException();
        return bytes;
    }
}
