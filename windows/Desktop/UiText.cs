using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace CodexPacer.Windows;

/// <summary>Literal UI labels from the same catalogs used by the Swift app.</summary>
internal sealed class UiText
{
    private static readonly Lazy<UiText> English = new(() => new UiText("en"));
    private static readonly Lazy<UiText> Chinese = new(() => new UiText("zh-Hans"));
    private readonly IReadOnlyDictionary<string, string> strings;
    internal string Language { get; }
    internal int Count => strings.Count;
    internal static UiText For(bool chinese) => chinese ? Chinese.Value : English.Value;
    private UiText(string language)
    {
        Language = language;
        using Stream stream = typeof(UiText).Assembly.GetManifestResourceStream("CodexPacer.Windows.Assets.Localization." + language + ".json")
            ?? throw new InvalidDataException("A shared UI catalog is missing.");
        if (stream.Length > 1024 * 1024) throw new InvalidDataException("The shared UI catalog is too large.");
        using var document = JsonDocument.Parse(stream);
        JsonElement root = document.RootElement;
        if (root.GetProperty("schemaVersion").GetInt32() != 1 || root.GetProperty("language").GetString() != language)
            throw new InvalidDataException("The shared UI catalog is incompatible.");
        var values = root.GetProperty("strings").EnumerateObject().ToDictionary(property => property.Name, property => property.Value.GetString()
            ?? throw new InvalidDataException("A shared UI string is null."), StringComparer.Ordinal);
        if (values.Count is < 1 or > 8192 || values.Any(pair => pair.Key.Length is < 1 or > 256 || pair.Value.Length > 32 * 1024))
            throw new InvalidDataException("The shared UI catalog contains an invalid entry.");
        strings = values;
    }
    // Formatted business values continue to come from L10n in the engine; do
    // not create a second implementation of Apple's printf/locale formatting.
    /// Whether the shared catalog has this string yet, for pages that wait on a newer catalog.
    internal bool Has(string key) => strings.ContainsKey(key);
    internal string Text(string key) => strings.TryGetValue(key, out string? value) ? value
        : throw new InvalidDataException("Unknown shared UI key: " + key);
}
