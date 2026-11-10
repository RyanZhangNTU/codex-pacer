import Foundation

/// Remote Claude lifecycle needs Pacer's hooks on each SSH host: transcripts
/// alone cannot confirm that a turn ended. Like Codex SSH monitoring, it needs
/// no separate step: while SSH monitoring is on, hosts that are connected and
/// have a Claude home are configured once per adapter digest, so an update
/// refreshes them too. A failed host waits before retrying instead of
/// contacting it on every status update.
public enum ClaudeRemoteAutoSetup {
    public static let digestsKey = "claudeRemoteSetupDigests"
    /// Hosts whose setup kept Pacer's request telemetry off, and why.
    public static let telemetryConflictsKey = "claudeRemoteTelemetryConflicts"
    public static let retryInterval: TimeInterval = 30 * 60
    /// A current host is checked again so telemetry settings that changed
    /// there take effect: every 30 minutes while its setup kept telemetry
    /// off, so it recovers on its own, and every six hours otherwise.
    public static let conflictRecheckInterval: TimeInterval = 30 * 60
    public static let recheckInterval: TimeInterval = 6 * 60 * 60

    /// Configured digests are keyed by SSH alias, the identity setup acts on.
    public static func configuredDigests(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: digestsKey) as? [String: String] ?? [:]
    }

    public static func recordConfigured(alias: String, digest: String, conflict: ClaudeTelemetryConflict = .none,
                                        defaults: UserDefaults = .standard) {
        var digests = configuredDigests(defaults: defaults)
        digests[alias] = digest
        // Keep only a bounded, valid map; aliases come from validated targets.
        let kept = Dictionary(uniqueKeysWithValues: digests.sorted { $0.key < $1.key }.suffix(32).map { ($0.key, $0.value) })
        defaults.set(kept, forKey: digestsKey)
        var conflicts = (defaults.dictionary(forKey: telemetryConflictsKey) as? [String: String] ?? [:]).filter { kept[$0.key] != nil }
        if kept[alias] != nil { conflicts[alias] = conflict == .none ? nil : conflict.rawValue }
        defaults.set(conflicts, forKey: telemetryConflictsKey)
    }
    /// The conflict recorded with each host's current setup.
    public static func telemetryConflicts(defaults: UserDefaults = .standard) -> [String: ClaudeTelemetryConflict] {
        (defaults.dictionary(forKey: telemetryConflictsKey) as? [String: String] ?? [:]).compactMapValues(ClaudeTelemetryConflict.init(rawValue:))
    }

    /// `checkedAt` holds this launch's successful setups by target ID. With
    /// it, a current host is also due once per launch and then after its
    /// recheck interval; without it, only a changed digest makes a host due.
    public static func pending(targets: [RemoteActivityTarget], statuses: [String: RuntimeStreamStatus], configured: [String: String],
                               digest: String, failures: [String: Date], inFlight: Set<String>, now: Date,
                               checkedAt: [String: Date]? = nil, conflicts: [String: ClaudeTelemetryConflict] = [:]) -> [RemoteActivityTarget] {
        targets.filter { target in
            guard let status = statuses[target.id], status.connected, status.sourceAvailable != false,
                  !inFlight.contains(target.id) else { return false }
            if configured[target.alias] == digest {
                guard let checkedAt else { return false }
                if let last = checkedAt[target.id] {
                    let keptOff = conflicts[target.alias].map { $0 != ClaudeTelemetryConflict.none } ?? false
                    let interval = keptOff ? conflictRecheckInterval : recheckInterval
                    guard now.timeIntervalSince(last) >= interval else { return false }
                }
            }
            return failures[target.id].map { now.timeIntervalSince($0) >= retryInterval } ?? true
        }
    }
}
