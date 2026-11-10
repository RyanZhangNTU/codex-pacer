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
    private var persistedCloudEndings: [CompletionDismissalStore.CloudEnding]
    private var sourceNamespaces: [AgentProvider: [String: String]] = [:]
    public init(dismissalStore: CompletionDismissalStore? = nil) {
        self.dismissalStore = dismissalStore
        let saved = dismissalStore?.load()
        persistedDigests = saved?.digests ?? []
        persistedDigestSet = Set(persistedDigests)
        persistedCloudEndings = saved?.cloudEndings ?? []
    }

    /// Rebinding only changes lookup scope; it never deletes another profile's acknowledgments.
    public mutating func bindSourceHomes(provider: AgentProvider, localHome: URL, remoteHomes: [String: String] = [:],
                                         remoteControlHostIDs: Set<String> = [], remoteControlAccountScope: String? = nil,
                                         durableAccountScope: String? = nil) {
        let local = localHome.standardizedFileURL.resolvingSymlinksInPath().path
        let localHash = CompletionDismissalStore.digest(["source-home-v1", provider.rawValue, local])
        var namespaces = ["local": localHash]
        for (host, remoteHome) in remoteHomes where !host.isEmpty && !remoteHome.isEmpty && !host.hasPrefix("remote-control:") {
            namespaces[host] = CompletionDismissalStore.digest(["source-home-v1", provider.rawValue, localHash, host, remoteHome])
        }
        if provider == .codex {
            if let durableAccountScope {
                namespaces[DurableActivityCatalog.hostID] = CompletionDismissalStore.digest(
                    ["source-home-v1", provider.rawValue, localHash, DurableActivityCatalog.hostID, durableAccountScope])
            }
            for host in remoteControlHostIDs where host.range(of: #"^remote-control:[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil {
                // Remote Control has an owner route, not an observed remote configuration directory.
                var fields = ["source-home-v1", provider.rawValue, localHash, "remote-control", host]
                if let remoteControlAccountScope { fields += ["account", remoteControlAccountScope] }
                namespaces[host] = CompletionDismissalStore.digest(fields)
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
            let settled: String?
            if activity.claudeCloud?.role == .thread, let mark = activity.claudeCloud?.completionMark,
               turn.split(separator: "-").count == 2 {
                let value = mark.timeIntervalSince1970 * 1000
                guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
                settled = "cloud-" + String(Int64(value))
            } else { settled = nil }
            fields += ["identified", settled ?? turn]
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
        guard let dismissalStore, let digest = persistentDigest(activity) else { return }
        var changed = false
        if !persistedDigestSet.contains(digest) {
            persistedDigests = CompletionDismissalStore.bounded(persistedDigests + [digest])
            persistedDigestSet = Set(persistedDigests); changed = true
        }
        if let source = cloudSourceDigest(activity) {
            let desired: CompletionDismissalStore.CloudEnding?
            if activity.claudeCloud?.status == .idle, let mark = activity.claudeCloud?.completionMark {
                desired = .init(source: source, mark: mark)
            } else { desired = nil }
            if persistedCloudEndings.first(where: { $0.source == source }) != desired {
                persistedCloudEndings.removeAll { $0.source == source }
                if let desired { persistedCloudEndings.append(desired) }
                persistedCloudEndings = CompletionDismissalStore.boundedCloudEndings(persistedCloudEndings)
                changed = true
            }
        }
        guard changed else { return }
        // A failed save still preserves the current process's normal in-memory acknowledgment.
        dismissalStore.saveDigests(persistedDigests, cloudEndings: persistedCloudEndings)
    }

    private func cloudSourceDigest(_ activity: SessionActivity) -> String? {
        guard activity.claudeCloud?.role == .thread,
              let namespace = sourceNamespaces[activity.provider]?[activity.sourceHostID ?? "local"] else { return nil }
        return CompletionDismissalStore.digest(["cloud-ending-v1", namespace, activity.canonicalized().id])
    }

    private func isAcknowledgedCloudSettlement(_ activity: SessionActivity) -> Bool {
        guard activity.claudeCloud?.status == .resolved, let mark = activity.claudeCloud?.completionMark,
              let source = cloudSourceDigest(activity), let old = persistedCloudEndings.first(where: { $0.source == source }) else { return false }
        let elapsed = mark.timeIntervalSince(old.mark)
        return elapsed >= 0 && elapsed < ClaudeCloudProjectState.settlingTime
    }

    private mutating func forgetCloudSettlement(_ activity: SessionActivity) {
        guard let source = cloudSourceDigest(activity), persistedCloudEndings.contains(where: { $0.source == source }) else { return }
        persistedCloudEndings.removeAll { $0.source == source }
        dismissalStore?.saveDigests(persistedDigests, cloudEndings: persistedCloudEndings)
    }

    /// Re-enabling cloud monitoring replays a baseline. The same retained
    /// ending keeps its original unread state, duration, metrics and expiry.
    private func retainingCloudEnding(_ activity: SessionActivity) -> SessionActivity {
        guard activity.isHistoricalCompletion, let cloud = activity.claudeCloud, cloud.role == .thread,
              let old = entries[activity.id]?.activity, let previousCloud = old.claudeCloud,
              old.phase == activity.phase, old.turnFailed == activity.turnFailed else { return activity }
        let sameTurn = old.turnID != nil && old.turnID == activity.turnID
        let sameMark = previousCloud.completionMark != nil && previousCloud.completionMark == cloud.completionMark
        let settlement: Bool
        if previousCloud.status == .idle, cloud.status == .resolved,
           let previous = previousCloud.completionMark, let current = cloud.completionMark {
            let elapsed = current.timeIntervalSince(previous)
            settlement = elapsed >= 0 && elapsed < ClaudeCloudProjectState.settlingTime
        } else { settlement = false }
        guard sameTurn || sameMark || settlement else { return activity }
        var retained = old
        retained.setClaudeCloud(cloud)
        retained.mergeDisplayMetadata(from: activity)
        return retained
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
        let current = Dictionary(activities.map(retainingCloudEnding).filter { activity in
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
                if [.running, .waitingForInput].contains(activity.phase) { forgetCloudSettlement(activity) }
                continue
            }
            let identity = Identity(activity)
            if let old = entries[activity.id], Identity(old.activity) != identity { entries.removeValue(forKey: activity.id) }
            if (persistentDigest(activity).map { persistedDigestSet.contains($0) } ?? false) || isAcknowledgedCloudSettlement(activity) {
                persistDismissal(activity)
                dismissed[activity.id] = identity
                entries.removeValue(forKey: activity.id)
                continue
            }
            guard dismissed[activity.id] != identity else {
                persistDismissal(activity)
                continue
            }
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
