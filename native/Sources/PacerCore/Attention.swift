import Foundation

public struct IslandNotice: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case lowQuota, waitingForInput, completed, interrupted }
    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public init(id: String, kind: Kind, title: String, detail: String) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
    }
}

public struct AttentionPolicy: Sendable {
    private var activityBaseline: [String: SessionActivity]?
    private var quotaScope: String?
    private var lowWindows: Set<String> = []
    public init() {}

    public mutating func quotaNotices(_ snapshot: QuotaSnapshot, at now: Date, threshold: Double = 15) -> [IslandNotice] {
        guard !snapshot.isStale(at: now) else { return [] }
        if quotaScope != snapshot.accountScope { lowWindows.removeAll(); quotaScope = snapshot.accountScope }
        var notices: [IslandNotice] = []
        for window in snapshot.windows {
            guard let remaining = window.remainingPercent, let reset = window.resetsAt, reset > now else { continue }
            let key = "\(window.id):\(Int(reset.timeIntervalSince1970 / 60))"
            if remaining > threshold + 5 { lowWindows.remove(key) }
            if remaining <= threshold, lowWindows.insert(key).inserted {
                notices.append(IslandNotice(id: key, kind: .lowQuota, title: L10n.text("notice.low_quota"),
                    detail: L10n.text("notice.quota_remaining", window.label, Int(remaining.rounded()))))
            }
        }
        let activeIDs = Set(snapshot.windows.compactMap { window -> String? in
            guard let reset = window.resetsAt else { return nil }
            return "\(window.id):\(Int(reset.timeIntervalSince1970 / 60))"
        })
        lowWindows.formIntersection(activeIDs)
        return notices
    }

    public mutating func activityNotices(_ activities: [SessionActivity], at now: Date) -> [IslandNotice] {
        let current = Dictionary(activities.filter { !$0.isInternalReview }.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        defer { activityBaseline = current }
        guard let previous = activityBaseline else { return [] } // no startup replay
        return activities.filter { !$0.isInternalReview }.compactMap { activity in
            let old = previous[activity.id]
            guard old?.phase != activity.phase, let changed = activity.phaseChangedAt, now.timeIntervalSince(changed) >= 0,
                  now.timeIntervalSince(changed) < 60,
                  activity.observedPhase(at: now) != .unknown else { return nil }
            let kind: IslandNotice.Kind
            switch activity.phase {
            case .waitingForInput: kind = .waitingForInput
            case .completed, .interrupted:
                guard let old, [.running, .waitingForInput].contains(old.phase), old.turnID == activity.turnID else { return nil }
                kind = activity.phase == .completed ? .completed : .interrupted
            default: return nil
            }
            return IslandNotice(id: "\(activity.id):\(activity.turnID ?? ""):\(kind.rawValue):\(changed.timeIntervalSince1970)",
                kind: kind, title: kind == .completed ? L10n.text("activity.turn_finished") : activity.phase.label, detail: activity.project)
        }
    }
}
