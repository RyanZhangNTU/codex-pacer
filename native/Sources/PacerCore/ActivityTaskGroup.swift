import Foundation

/// One user conversation and its observed descendants, scoped to one host.
/// A Claude task also holds the Codex threads its Codex for Claude runs started.
public struct ActivityTaskGroup: Sendable {
    public let primary: SessionActivity
    public let members: [SessionActivity]
    public var runningSubagentCount: Int {
        members.filter { $0.id != primary.id && $0.phase == .running && !$0.isCodexDelegation }.count
    }
    /// The Codex threads this task's Codex for Claude runs started, oldest first.
    /// Their sub-threads count with them, not on their own.
    public var delegations: [SessionActivity] {
        members.filter { $0.id != primary.id && $0.codexDelegation != nil }.sorted {
            let left = $0.codexDelegation!.started, right = $1.codexDelegation!.started
            return left == right ? $0.id < $1.id : left < right
        }
    }
    public var isRunning: Bool { members.contains { $0.phase == .running && $0.codexGoalPause == nil } }
    public var isWaiting: Bool { !isRunning && members.contains { $0.phase == .waitingForInput } }
    func canClearUnconfirmed(requests: [PendingAttentionRequest]) -> Bool {
        !isRunning && !isWaiting && !requests.contains { request in members.contains { $0.id == request.activity.id } }
    }
    public func displayedRate(at now: Date) -> OutputEstimate? {
        let active = members.filter { $0.phase == .running }
        let measured = (active.isEmpty ? members : active).compactMap { $0.displayedOutputEstimate(at: now) }
        guard !measured.isEmpty else { return nil }
        return OutputEstimate(value: measured.reduce(0) { $0 + $1.value },
            reportedAt: measured.map(\.reportedAt).max()!,
            isFresh: measured.contains(where: \.isFresh))
    }
    public func rateIsEstimated(at now: Date) -> Bool {
        let active = members.filter { $0.phase == .running }
        return displayedRate(at: now)?.isFresh != true || (active.isEmpty ? members : active).contains { $0.displayedRateIsEstimated(at: now) }
    }
    public static func make(_ activities: [SessionActivity]) -> [ActivityTaskGroup] {
        var nodes = Dictionary(activities.filter { !$0.isInternalReview }.map { ($0.canonicalized().id, $0.canonicalized()) },
            uniquingKeysWith: { old, new in (new.lastObserved ?? .distantPast) >= (old.lastObserved ?? .distantPast) ? new : old })
        let reviews = Set(activities.filter(\.isInternalReview).map { $0.canonicalized().id })
        for parent in Array(nodes.values) {
            for (child, evidence) in parent.subagentStates {
                let id = parent.provider.activityID(sessionID: child, sourceHostID: parent.sourceHostID)
                guard !reviews.contains(id) else { continue }
                var value = nodes[id] ?? SessionActivity(id: id, sourceHost: parent.sourceHost, sourceHostID: parent.sourceHostID, phaseAwareRate: true, provider: parent.provider, sessionID: child)
                value.applySubagentEvidence(evidence)
                nodes[id] = value
            }
        }
        func root(_ activity: SessionActivity) -> String {
            var current = activity, seen = Set<String>()
            for _ in 0..<64 {
                guard seen.insert(current.id).inserted else { return seen.min()! }
                // A Codex for Claude thread belongs to the Claude task that started it.
                if let owner = current.codexDelegation?.parentID, let next = nodes[owner] { current = next; continue }
                guard let parent = current.parentThreadID,
                      let next = nodes[current.provider.activityID(sessionID: parent, sourceHostID: current.sourceHostID)] else { return current.id }
                current = next
            }
            return seen.min()!
        }
        let grouped = Dictionary(grouping: nodes.values, by: root)
        return grouped.keys.sorted().compactMap { id in
            guard let primary = nodes[id], let members = grouped[id] else { return nil }
            return ActivityTaskGroup(primary: primary, members: members.sorted { $0.id < $1.id })
        }
    }
}
