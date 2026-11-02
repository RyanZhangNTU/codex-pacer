using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Web.WebView2.Core;

namespace CodexPacer.Windows;

/// Ephemeral input to the original read-only client. Never a preference, history entry or snapshot.
internal sealed class ClaudeWebSessionValue(string cookieHeader, string sessionHash, string? organizationID, string? userAgent)
{
    [JsonPropertyName("cookieHeader")] public string CookieHeader { get; } = cookieHeader;
    [JsonPropertyName("sessionHash")] public string SessionHash { get; } = sessionHash;
    [JsonPropertyName("organizationID")] public string? OrganizationID { get; } = organizationID;
    [JsonPropertyName("userAgent")] public string? UserAgent { get; } = userAgent;
    public override string ToString() => "Claude web session";
}

internal static class ClaudeWebCookies
{
    internal static async Task<ClaudeWebSessionValue?> ReadAsync(CoreWebView2 browser, CancellationToken cancellation)
    {
        var origin = ProviderWebDefinition.Claude.Origin;
        var cookies = await browser.CookieManager.GetCookiesAsync(new Uri(origin, "api/").AbsoluteUri).WaitAsync(cancellation);
        cancellation.ThrowIfCancellationRequested();
        var now = DateTime.UtcNow;
        var allowed = cookies.Where(cookie => cookie.Domain.Trim('.').Equals(origin.IdnHost, StringComparison.OrdinalIgnoreCase) &&
            (cookie.IsSession || cookie.Expires.ToUniversalTime() > now) && AppliesToAPI(cookie.Path) &&
            cookie.Name.Length > 0 && Encoding.UTF8.GetByteCount(cookie.Name) <= 256 && Encoding.UTF8.GetByteCount(cookie.Value) <= 16384 &&
            !cookie.Name.Contains(';') && !cookie.Value.Contains(';') && !cookie.Name.Any(char.IsControl) && !cookie.Value.Any(char.IsControl))
            .OrderByDescending(cookie => cookie.Path.Length).ThenBy(cookie => cookie.Name, StringComparer.Ordinal).ToArray();
        if (allowed.Length > 64) return null;
        var sessions = allowed.Where(cookie => cookie.Name == "sessionKey" && cookie.Value.Length > 0).ToArray();
        if (sessions.Length != 1 || sessions[0].Value.Any(char.IsWhiteSpace)) return null;
        string header = string.Join("; ", allowed.Select(cookie => cookie.Name + "=" + cookie.Value));
        if (Encoding.UTF8.GetByteCount(header) > 32768) return null;
        string hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(sessions[0].Value)));
        string? organization = allowed.FirstOrDefault(cookie => cookie.Name == "lastActiveOrg")?.Value;
        organization = organization is { Length: 36 } && Guid.TryParseExact(organization, "D", out var id) ? id.ToString("D") : null;
        string? agent = browser.Settings.UserAgent;
        if (string.IsNullOrEmpty(agent) || Encoding.UTF8.GetByteCount(agent) > 512 || agent.Any(char.IsControl)) agent = null;
        return new(header, hash, organization, agent);
    }
    private static bool AppliesToAPI(string path) => path.Length > 0 && "/api/".StartsWith(path, StringComparison.Ordinal) &&
        (path == "/api/" || path.EndsWith('/') || "/api/"[path.Length] == '/');
}
