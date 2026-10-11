import Foundation

/// Remote Claude lifecycle needs Pacer's hooks on each SSH host: transcripts
/// alone cannot confirm that a turn ended. Like Codex SSH monitoring, it needs
/// no separate step: while SSH monitoring is on, hosts that are connected and
/// have a Claude home are configured once per adapter digest, so an update
/// refreshes them too. A failed host waits before retrying instead of
/// contacting it on every status update.
public enum ClaudeRemoteAutoSetup {
    public static let digestsKey = "claudeRemoteSetupDigests"
    public static let retryInterval: TimeInterval = 30 * 60

    /// Configured digests are keyed by SSH alias, the identity setup acts on.
    public static func configuredDigests(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: digestsKey) as? [String: String] ?? [:]
    }

    public static func recordConfigured(alias: String, digest: String, defaults: UserDefaults = .standard) {
        var digests = configuredDigests(defaults: defaults)
        digests[alias] = digest
        // Keep only a bounded, valid map; aliases come from validated targets.
        defaults.set(Dictionary(uniqueKeysWithValues: digests.sorted { $0.key < $1.key }.suffix(32).map { ($0.key, $0.value) }), forKey: digestsKey)
    }

    public static func pending(targets: [RemoteActivityTarget], statuses: [String: RuntimeStreamStatus], configured: [String: String],
                               digest: String, failures: [String: Date], inFlight: Set<String>, now: Date) -> [RemoteActivityTarget] {
        targets.filter { target in
            guard let status = statuses[target.id], status.connected, status.sourceAvailable != false,
                  configured[target.alias] != digest, !inFlight.contains(target.id) else { return false }
            return failures[target.id].map { now.timeIntervalSince($0) >= retryInterval } ?? true
        }
    }
}
