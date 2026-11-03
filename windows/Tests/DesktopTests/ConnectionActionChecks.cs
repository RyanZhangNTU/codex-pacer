using System.Text.Json;
using CodexPacer.Windows;

internal static class ConnectionActionChecks
{
    internal static void Run()
    {
        foreach (string source in new[] { "remote-ssh-discovered:fixture", "wsl:fixture" })
        {
            string context = Guid.NewGuid().ToString("D");
            var module = new ConnectionModule("claude:" + source, source, "claude", "setup failed", "setupFailed", "warning", "", 0, true, source.StartsWith("wsl:"));
            var page = new ConnectionPage("retrying", "Source retry", "", "warning", 1, 0, true, [], [new(source, "Fixture", "synthetic", [module])]);
            var setup = new ClaudeRemoteSetup(source, context, false, false, true, "Synthetic failure", 1800);
            var snapshot = new EngineSnapshot(1, "snapshot", 1, true, 0, [], [], [], [], [], 0, 0, null, false, ClaudeRemoteSetups: [setup], Connections: page);
            var action = ConnectionActions.SetupRetry(snapshot, module, context);
            Check(action == new RemoteSetupRetry(source, context), "SSH and WSL use the same context-bound retry action");
            var bytes = JsonSerializer.SerializeToUtf8Bytes(action, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            using var json = JsonDocument.Parse(bytes);
            Check(json.RootElement.GetProperty("sourceID").GetString() == source && json.RootElement.GetProperty("context").GetString() == context,
                "Retry DTOs retain the engine command's exact source and context keys");
            Check(ConnectionActions.SetupRetry(snapshot with { ClaudeRemoteSetups = [setup with { Context = Guid.NewGuid().ToString("D") }] }, module, context) == null,
                "A button from an old source context cannot retry its replacement");
            Check(ConnectionActions.SetupRetry(snapshot with { ClaudeRemoteSetups = [setup with { InFlight = true }] }, module, context) == null,
                "An in-flight setup cannot get a second job");
            Check(ConnectionActions.SetupRetry(snapshot with { Connections = page with { Hosts = [] } }, module, context) == null,
                "Removing or disabling the host revokes the old button");
            Check(ConnectionActions.SetupRetry(snapshot with { ClaudeRemoteSetups = [] }, module, context) == null,
                "Missing setup facts cannot borrow another host's context");
            var quota = ConnectionActions.ReadQuota(snapshot, module);
            Check((quota != null) == source.StartsWith("wsl:"), "Only the provider on a verified WSL source exposes the on-demand quota action");
            if (quota != null)
            {
                Check(quota == new SourceQuotaRead("claude", source), "The source quota command never falls back to local credentials");
                Check(ConnectionActions.ReadQuota(snapshot with { Connections = page with { Hosts = [] } }, module) == null,
                    "Revoking the source also removes its quota action");
            }
            Check(ConnectionActions.SetupRetry(snapshot with { Connections = null }, module, context) == null, "Older snapshots remain compatible without enabling unverified actions");
        }
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
