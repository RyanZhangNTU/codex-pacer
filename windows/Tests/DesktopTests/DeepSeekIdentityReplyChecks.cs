using System;
using System.Collections.Generic;
using System.Text.Json;
using CodexPacer.Windows;

internal static class DeepSeekIdentityReplyChecks
{
    internal static void Run()
    {
        string identity = new('1', 64);
        var payload = new Dictionary<string, object?> {
            ["state"] = "ok", ["normal"] = new[] { "90" }, ["bonus"] = new[] { "1" },
            ["sessionFingerprint"] = identity, ["userToken"] = "SYNTHETIC_PRIVATE_TOKEN"
        };
        DeepSeekWebReply Parse() => DeepSeekWebReply.FromPage(JsonSerializer.SerializeToElement(payload));
        var valid = Parse();
        if (valid.State != "ok" || valid.SessionFingerprint != identity || valid.Normal?[0] != "90" || valid.Bonus?[0] != "1")
            throw new InvalidOperationException("The bounded identity and original wallet values must survive the reply");
        if (JsonSerializer.Serialize(valid).Contains("SYNTHETIC_PRIVATE_TOKEN", StringComparison.Ordinal))
            throw new InvalidOperationException("The page token cannot leave the reply whitelist");
        foreach (object? malformed in new object?[] { null, 123, new string('1', 63), new string('1', 65), new string('g', 64), new string('中', 64), new { value = identity } }) {
            payload["sessionFingerprint"] = malformed;
            if (Parse().State != "invalid") throw new InvalidOperationException("A malformed session digest was accepted");
        }
        payload.Remove("sessionFingerprint");
        if (Parse() is not { State: "ok", SessionFingerprint: null })
            throw new InvalidOperationException("Legacy numeric replies must still parse; Core requires identity before publishing a web balance");
    }
}
