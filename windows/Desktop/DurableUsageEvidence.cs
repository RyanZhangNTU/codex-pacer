using System;
using System.IO;
using System.Text.Json;

namespace CodexPacer.Windows;

/// Upgrade evidence for the opt-in Dot switch, matching Core's
/// DurableUsageEvidence: the local Durable reporter has recorded at least one
/// receipt in this Codex home. Recency is ignored.
internal static class DurableUsageEvidence
{
    internal const string ReceiptsPath = "pacer/codex-progress/durable-marketplace/receipts/latest.json";
    private const int MaximumBytes = 64 * 1024;

    internal static bool HasReceipts(string preferredHome)
    {
        try
        {
            string home = preferredHome.Length > 0 ? preferredHome
                : Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } custom && Path.IsPathFullyQualified(custom) ? custom
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            var file = new FileInfo(Path.Combine(home, ReceiptsPath));
            if (!file.Exists || file.Length > MaximumBytes || file.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
            using var document = JsonDocument.Parse(File.ReadAllBytes(file.FullName));
            if (document.RootElement.ValueKind != JsonValueKind.Object) return false;
            foreach (var receipt in document.RootElement.EnumerateObject())
                if (receipt.Value.ValueKind == JsonValueKind.Object && receipt.Value.TryGetProperty("threadID", out var thread)
                    && thread.ValueKind == JsonValueKind.String) return true;
            return false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }
}
