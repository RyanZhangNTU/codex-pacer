import Foundation

/// One user conversation and its observed descendants, scoped to one host.
/// A Claude task also holds the Codex threads its Codex for Claude runs started.
public struct ActivityTaskGroup: Sendable {
    public let primary: SessionActivity
    public let members: [SessionActivity]
    public var runningSubagentCount: Int {
        members.filter { $0.id != primary.id && $0.phase == .running && !$0.isCodexDelegation }.count
    }
    /// One thread per Codex for Claude run this task started, oldest first.
    /// A run's sub-threads count with it, not on their own. A review run works
    /// in a sub-thread; that sub-thread is the run.
    public var delegations: [SessionActivity] {
        let linked = members.filter { $0.id != primary.id && $0.codexDelegation != nil }
        let ids = Set(linked.map(\.id))
        // The review sub-thread first, then the run's own thread, then any other sub-thread.
        func rank(_ value: SessionActivity) -> Int {
            if value.isCodexReviewRun { return 0 }
            return value.parentThreadID.map { ids.contains(value.provider.activityID(sessionID: $0, sourceHostID: value.sourceHostID)) } == true ? 2 : 1
        }
        var runs: [URL: SessionActivity] = [:]
        for value in linked.sorted(by: { $0.id < $1.id }) {
            let directory = value.codexDelegation!.directory
            if let kept = runs[directory], rank(kept) <= rank(value) { continue }
            runs[directory] = value
        }
        return runs.values.sorted {
            let left = $0.codexDelegation!.started, right = $1.codexDelegation!.started
            return left == right ? $0.id < $1.id : left < right
        }
    }
    public var isRunning: Bool { members.contains { $0.phase == .running && $0.codexGoalPause == nil } }
    public var isWaiting: Bool { !isRunning && members.contains { $0.phase == .waitingForInput } }
    func canClearUnconfirmed(requests: [PendingAttentionRequest]) -> Bool {
        !isRunning && !isWaiting && !requests.contains { request in members.contains { $0.id == request.activity.id } }
    }
    /// The threads whose speed the task's row adds up: its own and its subagents'.
    /// A Codex for Claude run shows its speed on its own line.
    private var ratedMembers: [SessionActivity] { members.filter { $0.id == primary.id || !$0.isCodexDelegation } }
    public func displayedRate(at now: Date) -> OutputEstimate? {
        let rated = ratedMembers, active = rated.filter { $0.phase == .running }
        let measured = (active.isEmpty ? rated : active).compactMap { $0.displayedOutputEstimate(at: now) }
        guard !measured.isEmpty else { return nil }
        return OutputEstimate(value: measured.reduce(0) { $0 + $1.value },
            reportedAt: measured.map(\.reportedAt).max()!,
            isFresh: measured.contains(where: \.isFresh))
    }
    public func rateIsEstimated(at now: Date) -> Bool {
        let rated = ratedMembers, active = rated.filter { $0.phase == .running }
        return displayedRate(at: now)?.isFresh != true || (active.isEmpty ? rated : active).contains { $0.displayedRateIsEstimated(at: now) }
    }
    static func nodes(in activities: [SessionActivity]) -> [String: SessionActivity] {
        var nodes = Dictionary(activities.filter { !$0.isInternalReview }.map { ($0.canonicalized().id, $0.canonicalized()) },
            uniquingKeysWith: { old, new in (new.lastObserved ?? .distantPast) >= (old.lastObserved ?? .distantPast) ? new : old })
        let reviews = Set(activities.filter(\.isInternalReview).map { $0.canonicalized().id })
        for parent in Array(nodes.values) {
            for (child, evidence) in parent.subagentStates {
                let id = parent.provider.activityID(sessionID: child, sourceHostID: parent.sourceHostID)
                guard !reviews.contains(id) else { continue }
                var value = nodes[id] ?? SessionActivity(id: id, sourceHost: parent.sourceHost, sourceHostID: parent.sourceHostID, phaseAwareRate: true, provider: parent.provider, sessionID: child)
                value.applySubagentEvidence(evidence)
                if let link = value.codexDelegation ?? parent.codexDelegation { value.codexDelegation = link }
                nodes[id] = value
            }
        }
        return nodes
    }
    public static func make(_ activities: [SessionActivity]) -> [ActivityTaskGroup] {
        let nodes = nodes(in: activities)
        func root(_ activity: SessionActivity) -> String {
            var current = activity, seen = Set<String>()
            for _ in 0..<64 {
                guard seen.insert(current.id).inserted else { return seen.min()! }
                // A Codex for Claude thread belongs to the Claude task that started it.
                if let owner = current.codexDelegation?.parentID {
                    guard let next = nodes[owner] else { return owner }
                    current = next; continue
                }
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
