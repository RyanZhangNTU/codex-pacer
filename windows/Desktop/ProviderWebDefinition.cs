using System;

namespace CodexPacer.Windows;

/// The app-private browser profiles share UI and lifecycle, not credentials.
internal sealed record ProviderWebDefinition(string ID, Uri Origin, string LoginPath, string WorldName,
    string[]? ReaderPaths = null, string ReaderMethod = "GET", bool WatchSignIn = true)
{
    internal static readonly ProviderWebDefinition DeepSeek = new("deepseek", DeepSeekWebScripts.Origin, "usage", "CodexPacer.DeepSeek", ["/api/v0/users/get_user_summary"]);
    internal static readonly ProviderWebDefinition Claude = new("claude", new("https://claude.ai/"), "", "CodexPacer.Claude");
    internal static ProviderWebDefinition WorkBuddy(bool china) => new("workbuddy",
        new(china ? "https://www.workbuddy.cn/" : "https://www.workbuddy.ai/"), "profile/plans-usage",
        "CodexPacer.WorkBuddy", ["/billing/meter/get-user-resource-summary", "/billing/meter/get-user-resource-paid-packages",
            "/billing/meter/get-user-resource-free-packages"], "POST", WatchSignIn: false);
    internal bool IsOrigin(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttps && uri.IdnHost == Origin.IdnHost && uri.IsDefaultPort && uri.UserInfo.Length == 0;
    internal bool IsReaderRequest(string value, string method) => ReaderPaths != null && method == ReaderMethod && IsOrigin(value) &&
        Array.IndexOf(ReaderPaths, new Uri(value).PathAndQuery) >= 0;
}
