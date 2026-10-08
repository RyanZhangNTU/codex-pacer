import Foundation

/// Keeps ended turns independently of the source reader's discovery slots.
public struct CompletionInbox: Sendable {
    private struct Identity: Equatable, Sendable {
        let turnID: String?
        let phase: ActivityPhase
        let failed: Bool
        let changedAt: Date?
        let startedAt: Date?
        init(_ activity: SessionActivity) {
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
    private var entries: [String: Entry] = [:]
    private var dismissed: [String: Identity] = [:]
    private var previous: [String: SessionActivity] = [:]
    public init() {}

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
    public mutating func dismiss(_ activity: SessionActivity) {
        guard let entry = entries[activity.id], Identity(entry.activity) == Identity(activity) else { return }
        dismissed[activity.id] = Identity(activity)
        entries.removeValue(forKey: activity.id)
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
                let unread = (activity.hasLiveEvidence && activity.liveTurnStarted) || (old.map {
                    [.running, .waitingForInput].contains($0.phase) &&
                        ($0.turnID == activity.turnID || ($0.turnID == nil && $0.hasLiveEvidence))
                } ?? false)
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
