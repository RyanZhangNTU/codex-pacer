using System.Linq;

namespace CodexPacer.Windows;

internal sealed record RemoteSetupRetry(string SourceID, string Context);
internal sealed record SourceQuotaRead(string Provider, string SourceID);

internal static class ConnectionActions
{
    internal static RemoteSetupRetry? SetupRetry(EngineSnapshot? snapshot, ConnectionModule module, string context)
    {
        if (!module.RetrySetup || module.Provider != "claude" || snapshot?.Connections == null) return null;
        bool visible = snapshot.Connections.Hosts.SelectMany(host => host.Modules).Any(current => current.Id == module.Id && current.RetrySetup);
        var setup = snapshot.ClaudeRemoteSetups?.FirstOrDefault(row => row.SourceID == module.Key);
        return visible && setup is { CanRetry: true, InFlight: false } && setup.Context == context ? new(module.Key, context) : null;
    }
    internal static SourceQuotaRead? ReadQuota(EngineSnapshot? snapshot, ConnectionModule module)
        => module.ReadsQuota && snapshot?.Connections?.Hosts.SelectMany(host => host.Modules)
            .Any(current => current.Id == module.Id && current.ReadsQuota) == true ? new(module.Provider, module.Key) : null;
}
