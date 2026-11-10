using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

// This query confirms the complete edit without restarting any collector.
internal static class PreferencesAcknowledgement
{
    private sealed record Reply(string Digest, string LayoutJSON, string[] Warnings);
    internal static async Task<DesktopPreferences> ValidateAsync(EngineClient engine, DesktopPreferences value, TimeSpan? timeout = null)
    {
        string json = JsonSerializer.Serialize(value, PreferencesCodec.Json);
        var reply = await engine.QueryAsync<Reply>("validatePreferences", new { shell = new
        {
            preferences = json,
            compact = new { layout = value.CompactLayout, warnings = value.WarningKinds, language = "en", providers = new[] { "codex", "claude", "deepseek" }, attached = false, strip = false,
                options = new { singleTask = value.CompactSingleTask, metric = value.CompactMetric, codexWindow = value.CodexQuotaWindow,
                    claudeWindow = value.ClaudeQuotaWindow, rings = new[] { value.QuotaRingOuter, value.QuotaRingInner } },
                componentOptions = value.CompactComponentOptions, size = value.CompactBarSize }
        } }, timeout ?? TimeSpan.FromSeconds(3));
        string expected = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(json)));
        if (reply.Digest != expected || reply.LayoutJSON == null || reply.Warnings == null
            || !reply.Warnings.Order().SequenceEqual(value.WarningKinds.Order())) throw new IOException("Incompatible preference acknowledgement.");
        // Keep the absence of a custom layout until a layout/warning edit needs one.
        bool needsLayout = value.CompactLayout != null || !value.WarningKinds.Order().SequenceEqual(new DesktopPreferences().WarningKinds.Order());
        return needsLayout ? value with { CompactLayout = reply.LayoutJSON, WarningKinds = reply.Warnings } : value;
    }
}
