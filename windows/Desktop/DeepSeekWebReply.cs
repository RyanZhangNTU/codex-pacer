using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexPacer.Windows;

/// Only these reduced values can cross the browser/engine boundary.
internal sealed record DeepSeekWebReply([property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("normal")] IReadOnlyList<string>? Normal = null,
    [property: JsonPropertyName("bonus")] IReadOnlyList<string>? Bonus = null,
    [property: JsonPropertyName("otherCurrency")] bool OtherCurrency = false,
    [property: JsonPropertyName("estimation")] string? Estimation = null,
    [property: JsonPropertyName("alertEnabled")] bool AlertEnabled = false,
    [property: JsonPropertyName("alertBound")] string? AlertBound = null)
{
    internal static DeepSeekWebReply FromPage(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("state", out var state) || state.ValueKind != JsonValueKind.String)
            return new("invalid");
        string? name = state.GetString();
        if (name is "signedOut" or "challenge" or "offline" or "invalid") return new(name);
        if (name != "ok" || !MoneyList(value, "normal", out var normal) || !MoneyList(value, "bonus", out var bonus)) return new("invalid");
        return new("ok", normal, bonus, Flag(value, "otherCurrency"), Money(value, "estimation"),
            Flag(value, "alertEnabled"), Money(value, "alertBound"));
    }
    private static bool Flag(JsonElement value, string key) => value.TryGetProperty(key, out var field) && field.ValueKind == JsonValueKind.True;
    private static string? Money(JsonElement value, string key) => value.TryGetProperty(key, out var field) ? Money(field) : null;
    private static string? Money(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not string text || text.Length > 64 ||
            !double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double number) || !double.IsFinite(number) || number < 0 || number >= 1e9) return null;
        return number.ToString("R", CultureInfo.InvariantCulture);
    }
    private static bool MoneyList(JsonElement value, string key, out IReadOnlyList<string> result)
    {
        var numbers = new List<string>(); result = numbers;
        if (!value.TryGetProperty(key, out var list) || list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > 64) return false;
        foreach (var item in list.EnumerateArray()) if (Money(item) is string number) numbers.Add(number);
        return true;
    }
}

internal sealed class DeepSeekWebScripts
{
    internal static readonly Uri Origin = new("https://platform.deepseek.com/");
    internal static readonly DeepSeekWebScripts Shared = new();
    internal string Summary { get; }
    internal string SignedIn { get; }
    private DeepSeekWebScripts()
    {
        using var stream = typeof(DeepSeekWebScripts).Assembly.GetManifestResourceStream("CodexPacer.Windows.Assets.Web.deepseek-scripts.json")
            ?? throw new InvalidDataException("The original browser scripts are missing.");
        if (stream.Length > 32 * 1024) throw new InvalidDataException("The original browser scripts are too large.");
        using var data = JsonDocument.Parse(stream);
        if (data.RootElement.GetProperty("schemaVersion").GetInt32() != 1 || data.RootElement.GetProperty("origin").GetString() != Origin.AbsoluteUri)
            throw new InvalidDataException("The browser script resource is incompatible.");
        Summary = data.RootElement.GetProperty("summaryScript").GetString() ?? throw new InvalidDataException();
        SignedIn = data.RootElement.GetProperty("signedInScript").GetString() ?? throw new InvalidDataException();
    }
    internal static bool IsPlatform(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttps && uri.IdnHost == Origin.IdnHost && uri.IsDefaultPort && uri.UserInfo.Length == 0;
}
