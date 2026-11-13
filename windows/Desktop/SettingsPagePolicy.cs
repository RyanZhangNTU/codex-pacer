using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace CodexPacer.Windows;

internal static class SettingsPagePolicy
{
    private static readonly string[] ProviderOrder = ["codex", "claude", "deepseek"];
    internal static string InitialHelpProvider(IEnumerable<string> enabled)
        => ProviderOrder.FirstOrDefault(enabled.Contains) ?? "codex";
    internal static bool ShowExpandedQuotaStyle(IEnumerable<string> enabled)
        => !enabled.ToHashSet(StringComparer.Ordinal).SetEquals(["deepseek"]);
    internal static Uri PricingDocumentation(string language)
        => new("https://api-docs.deepseek.com/" + (language == "zh-Hans" ? "zh-cn/" : "") + "quick_start/pricing");
    /// Where a failed update can be downloaded by hand, as the Mac's Download from GitHub.
    internal static readonly Uri DownloadPage = new("https://github.com/RyanZhangNTU/codex-pacer/releases/latest");
    internal static bool OpenDownloadPage(Func<Uri, bool>? launch = null) => Open(DownloadPage, launch);
    internal static bool OpenTransparency(Func<Uri, bool>? launch = null)
        => Open(new("ms-settings:easeofaccess-visualeffects"), launch);
    internal static bool OpenPricing(string language, Func<Uri, bool>? launch = null)
        => Open(PricingDocumentation(language), launch);
    internal static Uri? HarnessUsageGuide(string provider, string? value)
        => provider == "workbuddy" && value == "https://www.workbuddy.ai/docs/workbuddy/usage" ? new(value) : null;
    internal static bool OpenHarnessUsage(Uri guide, Func<Uri, bool>? launch = null) => Open(guide, launch);
    private static bool Open(Uri uri, Func<Uri, bool>? launch)
    {
        try
        {
            if (launch != null) return launch(uri);
            using var process = Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
            return process != null;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }
}
