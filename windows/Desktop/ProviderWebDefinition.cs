using System;

namespace CodexPacer.Windows;

/// The app-private browser profiles share UI and lifecycle, not credentials.
internal sealed record ProviderWebDefinition(string ID, Uri Origin, string LoginPath, string WorldName)
{
    internal static readonly ProviderWebDefinition DeepSeek = new("deepseek", DeepSeekWebScripts.Origin, "usage", "CodexPacer.DeepSeek");
    internal static readonly ProviderWebDefinition Claude = new("claude", new("https://claude.ai/"), "", "CodexPacer.Claude");
    internal bool IsOrigin(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttps && uri.IdnHost == Origin.IdnHost && uri.IsDefaultPort && uri.UserInfo.Length == 0;
    internal bool IsReaderRequest(string value, string method) => ID == "deepseek" && method == "GET" && IsOrigin(value) &&
        new Uri(value).AbsolutePath == "/api/v0/users/get_user_summary";
}
