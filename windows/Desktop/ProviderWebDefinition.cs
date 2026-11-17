using System;

namespace CodexPacer.Windows;

/// The app-private browser profiles share UI and lifecycle, not credentials.
/// <param name="ReaderRequests">The only requests the reader page may make, each as "METHOD /path", where "{uuid}"
/// stands for one lowercase UUID; it refuses everything else.</param>
/// <param name="ConfirmByReading">The sign-in window confirms a sign-in by reading the account through its own
/// profile every few seconds, wherever the page has gone, instead of comparing the page's session with the one
/// it opened with. A login that leaves the site (a QR code or another provider) still completes.</param>
internal sealed record ProviderWebDefinition(string ID, Uri Origin, string LoginPath, string WorldName,
    string[]? ReaderRequests = null, bool ConfirmByReading = false)
{
    private const string Uuid = "{uuid}";
    internal static readonly ProviderWebDefinition DeepSeek = new("deepseek", DeepSeekWebScripts.Origin, "usage", "CodexPacer.DeepSeek", ["GET /api/v0/users/get_user_summary"]);
    // Claude's quota reads run in its own browser profile, the one that passed claude.ai's verification (#243).
    internal static readonly ProviderWebDefinition Claude = new("claude", new("https://claude.ai/"), "", "CodexPacer.Claude",
        ["GET /api/account", "GET /api/organizations", "GET /api/organizations/" + Uuid + "/usage", "GET /api/organizations/" + Uuid + "/usage?cedar_ember=1"]);
    // Each edition has its own ID, so the sign-in window words itself for the
    // module it signs in (WorkBuddy AI showed WorkBuddy's text, 11/16 review).
    internal static ProviderWebDefinition WorkBuddy(bool china) => new(china ? "workbuddy" : "workbuddy-ai",
        new(china ? "https://www.workbuddy.cn/" : "https://www.workbuddy.ai/"), "profile/plans-usage",
        "CodexPacer.WorkBuddy", ["POST /billing/meter/get-user-resource-summary", "POST /billing/meter/get-user-resource-paid-packages",
            "POST /billing/meter/get-user-resource-free-packages",
            // An enterprise member's credits: the signed-in accounts, then the chosen team's usage (#241).
            "GET /console/accounts", "POST /billing/meter/get-enterprise-user-usage"], ConfirmByReading: true);
    internal bool IsOrigin(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttps && uri.IdnHost == Origin.IdnHost && uri.IsDefaultPort && uri.UserInfo.Length == 0;
    internal bool IsReaderRequest(string value, string method)
    {
        if (ReaderRequests == null || !IsOrigin(value)) return false;
        string request = method + " " + new Uri(value).PathAndQuery;
        return Array.Exists(ReaderRequests, pattern => Matches(pattern, request));
    }
    private static bool Matches(string pattern, string request)
    {
        int at = pattern.IndexOf(Uuid, StringComparison.Ordinal);
        if (at < 0) return pattern == request;
        string head = pattern[..at], tail = pattern[(at + Uuid.Length)..];
        if (request.Length != head.Length + 36 + tail.Length || !request.StartsWith(head, StringComparison.Ordinal) ||
            !request.EndsWith(tail, StringComparison.Ordinal)) return false;
        string id = request.Substring(head.Length, 36);
        return Guid.TryParseExact(id, "D", out var value) && value.ToString("D") == id;
    }
}
