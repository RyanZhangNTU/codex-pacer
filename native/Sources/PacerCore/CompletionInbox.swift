import Foundation

/// Keeps ended turns independently of the source reader's discovery slots.
public struct CompletionInbox: Sendable {
    private struct Identity: Equatable, Sendable {
        let turnID: String?
        let phase: ActivityPhase
        let changedAt: Date?
        init(_ activity: SessionActivity) {
            turnID = activity.turnID; phase = activity.phase; changedAt = activity.phaseChangedAt
        }
    }
    private struct Entry: Sendable {
        var activity: SessionActivity
        var unread: Bool
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
    public mutating func observe(_ activities: [SessionActivity], at now: Date, retention: TimeInterval) {
        let current = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
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
            guard age >= 0, retention == 0 || age < retention else { continue }
            if var entry = entries[activity.id] {
                entry.activity = activity; entries[activity.id] = entry
            } else {
                let old = previous[activity.id]
                let unread = old.map { [.running, .waitingForInput].contains($0.phase) && $0.turnID == activity.turnID } ?? false
                entries[activity.id] = Entry(activity: activity, unread: unread)
            }
        }
        previous = current.filter { !$0.value.isInternalReview }
        prune(at: now, retention: retention)
    }
    public mutating func prune(at now: Date, retention: TimeInterval) {
        guard retention > 0 else { return }
        for (id, entry) in entries where now.timeIntervalSince(entry.activity.phaseChangedAt ?? .distantPast) >= retention {
            dismissed[id] = Identity(entry.activity)
            entries.removeValue(forKey: id)
        }
    }
}
