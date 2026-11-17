using System;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace CodexPacer.Windows;

/// One claude.ai reply read in Claude's private browser profile, for the engine's own
/// decoder. The engine's HTTPS client looked like another client to Cloudflare, which
/// challenged it again after every sign-in (#243); the browser that passed the
/// verification is the one it cleared. Only the status, three headers and a bounded
/// body leave the browser.
/// <param name="State">"ok", or "offline", "signedOut", "tooLarge" or "invalid" with nothing else.</param>
internal sealed record ClaudeWebFetchValue(string State, int? Status = null, string? ContentType = null,
    string? CfMitigated = null, string? RetryAfter = null, string? Body = null)
{
    /// The engine's own limit; a quota reply is a few KB and must fit one engine command.
    internal const int MaximumBodyBytes = 40 * 1024;

    internal static ClaudeWebFetchValue FromPage(JsonElement json)
    {
        string? state = Text(json, "state");
        if (state is "offline" or "tooLarge") return new(state);
        if (state != "ok" || !json.TryGetProperty("status", out var value) || value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt32(out int status) || status is < 100 or > 599 || Text(json, "body") is not string body ||
            Encoding.UTF8.GetByteCount(body) > MaximumBodyBytes) return new("invalid");
        return new("ok", status, Header(json, "contentType"), Header(json, "cfMitigated"), Header(json, "retryAfter"), body);
    }
    private static string? Text(JsonElement json, string field) => json.ValueKind == JsonValueKind.Object &&
        json.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static string? Header(JsonElement json, string field) =>
        Text(json, field) is { Length: <= 256 } value && !value.Any(char.IsControl) ? value : null;

    /// Runs in the reader's isolated world on its blank claude.ai document. The path is
    /// one the reader admits; the browser sends its own cookies.
    internal static string Script(string path) => "const path = " + JsonSerializer.Serialize(path) + ";\n" + """
        let response;
        try {
            response = await fetch(path, { method: "GET", headers: { Accept: "application/json" },
                credentials: "same-origin", redirect: "error", cache: "no-store" });
        } catch {
            return { state: "offline" };
        }
        const header = name => { const value = response.headers.get(name); return typeof value === "string" ? value.slice(0, 256) : null; };
        const contentType = header("content-type");
        const json = /application\/json/i.test(contentType || "");
        // A JSON reply is read whole within the engine's limit; any other only for the first
        // bytes, which are enough to tell a verification page.
        const limit = json ? 40960 : 4096;
        const parts = [];
        let size = 0, cut = false;
        const reader = response.body ? response.body.getReader() : null;
        while (reader) {
            const { done, value } = await reader.read();
            if (done) break;
            if (size + value.length > limit) {
                parts.push(value.subarray(0, limit - size)); size = limit; cut = true;
                await reader.cancel();
                break;
            }
            parts.push(value); size += value.length;
        }
        if (cut && json) return { state: "tooLarge" };
        const bytes = new Uint8Array(size);
        let at = 0;
        for (const part of parts) { bytes.set(part, at); at += part.length; }
        return { state: "ok", status: response.status, contentType, cfMitigated: header("cf-mitigated"),
            retryAfter: header("retry-after"), body: new TextDecoder().decode(bytes) };
        """;
}
