import Foundation

/// Keeps ended turns independently of the source reader's discovery slots.
public struct CompletionInbox: Sendable {
    fileprivate struct Identity: Equatable, Sendable {
        let provider: AgentProvider
        let sourceHostID: String?
        let turnID: String?
        let phase: ActivityPhase
        let failed: Bool
        let changedAt: Date?
        let startedAt: Date?
        init(_ activity: SessionActivity) {
            provider = activity.provider
            sourceHostID = activity.sourceHostID
            turnID = activity.turnID; phase = activity.phase; changedAt = activity.phaseChangedAt
            failed = activity.turnFailed
            startedAt = activity.turnStartedAt
        }
    }
    private struct Entry: Sendable {
        var activity: SessionActivity
        var unread: Bool
        var nameUpdate: SessionNameUpdate?
    }
    /// Captures an ending and its bound reader scope across asynchronous navigation.
    public struct AcknowledgmentToken: Equatable, Sendable {
        fileprivate let activityID: String
        fileprivate let identity: Identity
        fileprivate let namespace: String?
    }
    /// The selected reader scope, including opens that do not originate from an ending.
    public struct SourceToken: Equatable, Sendable {
        fileprivate let provider: AgentProvider
        fileprivate let sourceHostID: String?
        fileprivate let namespace: String?
    }
    private var entries: [String: Entry] = [:]
    private var dismissed: [String: Identity] = [:]
    private var previous: [String: SessionActivity] = [:]
    private let dismissalStore: CompletionDismissalStore?
    private var persistedDigests: [String]
    private var persistedDigestSet: Set<String>
    private var sourceNamespaces: [AgentProvider: [String: String]] = [:]
    public init(dismissalStore: CompletionDismissalStore? = nil) {
        self.dismissalStore = dismissalStore
        persistedDigests = dismissalStore?.loadDigests() ?? []
        persistedDigestSet = Set(persistedDigests)
    }

    /// Rebinding only changes lookup scope; it never deletes another profile's acknowledgments.
    public mutating func bindSourceHomes(provider: AgentProvider, localHome: URL, remoteHomes: [String: String] = [:],
                                         remoteControlHostIDs: Set<String> = []) {
        let local = localHome.standardizedFileURL.resolvingSymlinksInPath().path
        let localHash = CompletionDismissalStore.digest(["source-home-v1", provider.rawValue, local])
        var namespaces = ["local": localHash]
        for (host, remoteHome) in remoteHomes where !host.isEmpty && !remoteHome.isEmpty && !host.hasPrefix("remote-control:") {
            namespaces[host] = CompletionDismissalStore.digest(["source-home-v1", provider.rawValue, localHash, host, remoteHome])
        }
        if provider == .codex {
            for host in remoteControlHostIDs where host.range(of: #"^remote-control:[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil {
                // Remote Control has an owner route, not an observed remote configuration directory.
                namespaces[host] = CompletionDismissalStore.digest(["source-home-v1", provider.rawValue, localHash, "remote-control", host])
            }
        }
        if let old = sourceNamespaces[provider], old != namespaces {
            let changed = Set(old.keys).union(namespaces.keys).filter { old[$0] != namespaces[$0] }
            entries = entries.filter { $0.value.activity.provider != provider || !changed.contains($0.value.activity.sourceHostID ?? "local") }
            dismissed = dismissed.filter { $0.value.provider != provider || !changed.contains($0.value.sourceHostID ?? "local") }
            previous = previous.filter { $0.value.provider != provider || !changed.contains($0.value.sourceHostID ?? "local") }
        }
        sourceNamespaces[provider] = namespaces
    }

    private func persistentDigest(_ activity: SessionActivity) -> String? {
        guard dismissalStore != nil,
              let namespace = sourceNamespaces[activity.provider]?[activity.sourceHostID ?? "local"] else { return nil }
        var fields = ["completion-v1", activity.provider.rawValue, namespace, activity.sourceHostID ?? "local",
                      activity.canonicalized().id, activity.phase.rawValue, activity.turnFailed ? "failed" : "ok"]
        if let turn = activity.turnID {
            // Runtime and historical logs can timestamp the same explicit turn differently.
            fields += ["identified", turn]
        } else {
            func milliseconds(_ date: Date?) -> String? {
                guard let date else { return "absent" }
                let value = date.timeIntervalSince1970 * 1000
                guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
                return String(Int64(value.rounded()))
            }
            guard let started = milliseconds(activity.turnStartedAt), let ended = milliseconds(activity.phaseChangedAt) else { return nil }
            fields += ["legacy", started, ended]
        }
        return CompletionDismissalStore.digest(fields)
    }

    private mutating func persistDismissal(_ activity: SessionActivity) {
        guard let dismissalStore, let digest = persistentDigest(activity), !persistedDigestSet.contains(digest) else { return }
        persistedDigests = CompletionDismissalStore.bounded(persistedDigests + [digest])
        persistedDigestSet = Set(persistedDigests)
        // A failed save still preserves the current process's normal in-memory acknowledgment.
        dismissalStore.saveDigests(persistedDigests)
    }

    /// Disabling one module must not dismiss the other module's unread endings.
    public mutating func remove(provider: AgentProvider) {
        entries = entries.filter { $0.value.activity.provider != provider }
        dismissed = dismissed.filter { $0.value.provider != provider }
        previous = previous.filter { $0.value.provider != provider }
    }

    /// Remove a verified source mirror without acknowledging any real ending.
    public mutating func remove(activityIDs: Set<String>) {
        for id in activityIDs {
            entries.removeValue(forKey: id)
            dismissed.removeValue(forKey: id)
            previous.removeValue(forKey: id)
        }
    }

    public var activities: [SessionActivity] { entries.values.map(\.activity) }
    public var unreadActivities: [SessionActivity] {
        entries.values.filter(\.unread).map(\.activity).sorted {
            let left = $0.phaseChangedAt ?? .distantPast, right = $1.phaseChangedAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
    public func isUnread(_ activity: SessionActivity) -> Bool {
        entries[activity.id].map { $0.unread && Identity($0.activity) == Identity(activity) } ?? false
    }
    public func acknowledgment(for activity: SessionActivity) -> AcknowledgmentToken? {
        guard let entry = entries[activity.id], Identity(entry.activity) == Identity(activity) else { return nil }
        return AcknowledgmentToken(activityID: activity.id, identity: Identity(entry.activity),
            namespace: sourceNamespaces[activity.provider]?[activity.sourceHostID ?? "local"])
    }
    public func sourceToken(for activity: SessionActivity) -> SourceToken {
        SourceToken(provider: activity.provider, sourceHostID: activity.sourceHostID,
            namespace: sourceNamespaces[activity.provider]?[activity.sourceHostID ?? "local"])
    }
    public func isCurrentSource(_ token: SourceToken) -> Bool {
        sourceNamespaces[token.provider]?[token.sourceHostID ?? "local"] == token.namespace
    }
    @discardableResult
    public mutating func dismiss(_ activity: SessionActivity) -> Bool {
        guard let token = acknowledgment(for: activity) else { return false }
        return dismiss(activity, acknowledging: token)
    }
    @discardableResult
    public mutating func dismiss(_ activity: SessionActivity, acknowledging token: AcknowledgmentToken) -> Bool {
        guard acknowledgment(for: activity) == token, let entry = entries[activity.id] else { return false }
        persistDismissal(entry.activity)
        dismissed[activity.id] = Identity(activity)
        entries.removeValue(forKey: activity.id)
        return true
    }
    public mutating func updateNames(_ updates: [SessionNameUpdate]) {
        for update in updates {
            guard var entry = entries[update.id] else { continue }
            update.apply(to: &entry.activity)
            entry.nameUpdate = update
            entries[update.id] = entry
        }
    }
    public mutating func updatePerformance(_ updates: [SessionPerformanceUpdate]) {
        for update in updates {
            guard var entry = entries[update.id] else { continue }
            update.apply(to: &entry.activity)
            entries[update.id] = entry
        }
    }
    @discardableResult
    public mutating func observe(_ activities: [SessionActivity], at now: Date, retention: TimeInterval) -> [SessionActivity] {
        // A released stream may be followed by an older log baseline. Only a
        // newer state/new live turn can supersede a retained or dismissed ending.
        let current = Dictionary(activities.filter { activity in
            let ended = entries[activity.id].map { Identity($0.activity) } ?? dismissed[activity.id]
            guard let ended, let endedAt = ended.changedAt else { return true }
            if activity.hasLiveEvidence, activity.liveTurnStarted, activity.turnID != ended.turnID { return true }
            if let turn = activity.turnID, turn != ended.turnID,
               let started = activity.turnStartedAt, let previousStart = ended.startedAt,
               started > previousStart { return true }
            // Source state can be reclaimed or its bounded idle marker evicted.
            // An unknown transport state alone cannot revoke a proven ending.
            if activity.phase == .unknown { return false }
            let changed = activity.phaseChangedAt ?? activity.lastObserved ?? .distantPast
            return changed > endedAt || (changed == endedAt && [.completed, .interrupted].contains(activity.phase))
        }.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for activity in current.values {
            guard !activity.isInternalReview, [.completed, .interrupted].contains(activity.phase),
                  let changedAt = activity.phaseChangedAt else {
                entries.removeValue(forKey: activity.id); dismissed.removeValue(forKey: activity.id)
                continue
            }
            let identity = Identity(activity)
            if let old = entries[activity.id], Identity(old.activity) != identity { entries.removeValue(forKey: activity.id) }
            if let digest = persistentDigest(activity), persistedDigestSet.contains(digest) {
                dismissed[activity.id] = identity
                entries.removeValue(forKey: activity.id)
                continue
            }
            guard dismissed[activity.id] != identity else { continue }
            let age = now.timeIntervalSince(changedAt)
            // Converting Date through Unix seconds can round the same instant
            // slightly forward. Do not lose a just-delivered ending to that
            // sub-millisecond difference; genuinely future records stay out.
            guard age >= -0.001, retention == 0 || age < retention else { continue }
            if var entry = entries[activity.id] {
                let previousMetrics = entry.activity
                entry.activity = activity
                entry.activity.mergePerformance(from: previousMetrics)
                // Older log replay must not undo a later metadata-only rename.
                entry.nameUpdate?.apply(to: &entry.activity)
                entries[activity.id] = entry
            } else {
                let old = previous[activity.id]
                let unread = !activity.isHistoricalCompletion && ((activity.hasLiveEvidence && activity.liveTurnStarted) || (old.map {
                    [.running, .waitingForInput].contains($0.phase) &&
                        ($0.turnID == activity.turnID || ($0.turnID == nil && $0.hasLiveEvidence))
                } ?? false))
                entries[activity.id] = Entry(activity: activity, unread: unread, nameUpdate: nil)
            }
        }
        previous = current.filter { !$0.value.isInternalReview }
        prune(at: now, retention: retention)
        return Array(current.values)
    }
    public mutating func prune(at now: Date, retention: TimeInterval) {
        guard retention > 0 else { return }
        for (id, entry) in entries where now.timeIntervalSince(entry.activity.phaseChangedAt ?? .distantPast) >= retention {
            dismissed[id] = Identity(entry.activity)
            entries.removeValue(forKey: id)
        }
    }
}
