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
    private var pendingRequests: Set<String> = []
    private struct CompletionKey: Hashable, Sendable {
        let activity: String
        let turn: String
    }
    private var notifiedCompletions: [CompletionKey: Date] = [:]
    public init() {}

    public mutating func requestNotices(_ requests: [PendingAttentionRequest]) -> [IslandNotice] {
        let current = Set(requests.map { $0.id + ":" + $0.kind.rawValue })
        defer { pendingRequests = current }
        return requests.filter { !pendingRequests.contains($0.id + ":" + $0.kind.rawValue) }.map { request in
            IslandNotice(id: "request:" + request.id, kind: .waitingForInput,
                title: L10n.text(request.kind == .approval ? "attention.approval" : "attention.input"),
                detail: request.sourceName ?? L10n.text("activity.local_task"))
        }
    }

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
        let previous = activityBaseline
        notifiedCompletions = notifiedCompletions.filter { now.timeIntervalSince($0.value) < 60 }
        return activities.filter { !$0.isInternalReview }.compactMap { activity in
            let old = previous?[activity.id]
            guard let changed = activity.phaseChangedAt, now.timeIntervalSince(changed) >= -0.001,
                  now.timeIntervalSince(changed) < 60,
                  activity.observedPhase(at: now) != .unknown else { return nil }
            let kind: IslandNotice.Kind
            switch activity.phase {
            case .waitingForInput:
                guard previous != nil, old?.phase != activity.phase else { return nil }
                kind = .waitingForInput
            case .completed, .interrupted:
                let transition = old.map { [.running, .waitingForInput].contains($0.phase) && $0.turnID == activity.turnID } ?? false
                let observedStart = activity.hasLiveEvidence && activity.liveTurnStarted
                guard transition || observedStart else { return nil } // startup logs stay quiet
                let key = CompletionKey(activity: activity.id, turn: activity.turnID ?? String(changed.timeIntervalSince1970))
                guard notifiedCompletions[key] == nil else { return nil }
                notifiedCompletions[key] = changed
                if notifiedCompletions.count > 1024, let oldest = notifiedCompletions.min(by: { $0.value < $1.value })?.key {
                    notifiedCompletions.removeValue(forKey: oldest)
                }
                kind = activity.phase == .completed ? .completed : .interrupted
            default: return nil
            }
            return IslandNotice(id: "\(activity.id):\(activity.turnID ?? ""):\(kind.rawValue):\(changed.timeIntervalSince1970)",
                kind: kind, title: activity.turnFailed ? L10n.text("activity.failed") : kind == .completed ? L10n.text("activity.turn_finished") : activity.phase.label, detail: activity.project)
        }
    }
}
