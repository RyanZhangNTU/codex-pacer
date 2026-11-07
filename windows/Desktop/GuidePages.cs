using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal sealed record GuideItem(string Symbol, string Title, string Detail, string? Control);
internal sealed record GuideRelease(string Version, string Title, IReadOnlyList<GuideItem> Items);
internal sealed record GuideCatalog(int SchemaVersion, string? Page, int Major, string NextSeen, bool RecordLaunch, bool RecordClose,
    string VersionTitle, IReadOnlyList<string> Steps, IReadOnlyDictionary<string, string> ModuleOff,
    IReadOnlyList<GuideRelease> Releases, IReadOnlyList<GuideRelease> History, IReadOnlyDictionary<string, string> Links, string? SupportCode,
    string? QqGroup = null, string? QqCode = null);
internal sealed record GuideRequest(
    [property: JsonPropertyName("current")] string Current,
    [property: JsonPropertyName("seen")] string? Seen,
    [property: JsonPropertyName("welcomed")] int Welcomed,
    [property: JsonPropertyName("language")] string Language,
    [property: JsonPropertyName("demo")] bool Demo,
    [property: JsonPropertyName("settings")] bool Settings,
    [property: JsonPropertyName("forceWelcome")] bool ForceWelcome,
    [property: JsonPropertyName("forceWhatsNew")] bool ForceWhatsNew);

/// The engine supplies Mac's release selection and monotonic version decision.
internal sealed class GuideSession(PreferencesSession preferences, Func<GuideRequest, Task<GuideCatalog>> query,
    string current, string language, bool demo, bool settings)
{
    private GuideCatalog? confirmed;
    private string? confirmedSeen;
    internal Task<GuideCatalog> LoadAsync(bool forceWelcome = false, bool forceWhatsNew = false)
        => Query(preferences.Current, forceWelcome, forceWhatsNew);
    private async Task<GuideCatalog> Query(DesktopPreferences value, bool welcome = false, bool note = false)
    {
        var result = await query(new(current, value.WhatsNewVersion, value.WelcomeGuideVersion, language, demo, settings, welcome, note));
        confirmedSeen = value.WhatsNewVersion; confirmed = result; return result;
    }
    internal async Task<PreferencesApplyResult> RecordAsync(bool welcomeClosed)
    {
        if (demo) return PreferencesApplyResult.Applied;
        return await preferences.ChangeAsync(async value =>
        {
            var plan = confirmed != null && (value.WhatsNewVersion == confirmedSeen || value.WhatsNewVersion == confirmed.NextSeen) ? confirmed : await Query(value);
            return value with { WhatsNewVersion = plan.NextSeen, WelcomeGuideVersion = welcomeClosed ? Math.Max(value.WelcomeGuideVersion, plan.Major) : value.WelcomeGuideVersion };
        });
    }
    internal static double MaximumNoteHeight(double workHeight, double titleHeight)
        => double.IsFinite(workHeight) && double.IsFinite(titleHeight) ? Math.Min(640, Math.Max(0, workHeight - Math.Max(0, titleHeight) - 48)) : 0;
}

internal static class GuideLinks
{
    internal static bool Open(GuideCatalog catalog, string action, Func<Uri, bool>? launch = null)
    {
        if (action is not ("repository" or "star" or "feature" or "bug" or "donate" or "manual" or "issues" or "releaseNotes")
            || !catalog.Links.TryGetValue(action, out string? text) || !Uri.TryCreate(text, UriKind.Absolute, out var uri)
            || uri.Scheme != "https" || uri.UserInfo.Length != 0 || uri.Port != 443
            || (uri.Host != "github.com" && uri.Host != "buymeacoffee.com")) return false;
        try
        {
            if (launch != null) return launch(uri);
            using var process = Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); return process != null;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }
}

internal static class GuideControls
{
    internal static bool ShowsEmbedded(DesktopPreferences value) => value.ShowEmbeddedCodexSessions && value.ShowEmbeddedClaudeSessions;
    internal static DesktopPreferences SetEmbedded(DesktopPreferences value, bool enabled)
        => value with { ShowEmbeddedCodexSessions = enabled, ShowEmbeddedClaudeSessions = enabled };
}
