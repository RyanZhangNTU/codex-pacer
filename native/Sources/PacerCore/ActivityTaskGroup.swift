import Foundation

/// One user conversation and its observed descendants, scoped to one host.
public struct ActivityTaskGroup: Sendable {
    public let primary: SessionActivity
    public let members: [SessionActivity]
    public var runningSubagentCount: Int {
        members.filter { $0.id != primary.id && $0.phase == .running }.count
    }
    public var isRunning: Bool { members.contains { $0.phase == .running } }
    public var isWaiting: Bool { !isRunning && members.contains { $0.phase == .waitingForInput } }
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
