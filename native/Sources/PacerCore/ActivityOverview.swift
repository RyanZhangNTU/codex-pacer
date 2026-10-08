import Foundation

/// Global task state is independent of the conversation selected for navigation.
public struct ActivityOverview: Sendable {
    public let activities: [SessionActivity]
    public let running: [SessionActivity]
    public let waiting: [SessionActivity]
    public let phase: ActivityPhase
    public let tokensPerSecond: Double?
    public let displayedRate: Double?
    public let rateIsFresh: Bool

    public init(activities: [SessionActivity], at now: Date) {
        let groups = ActivityTaskGroup.make(activities)
        self.activities = groups.flatMap(\.members)
        running = groups.filter(\.isRunning).map(\.primary)
        waiting = groups.filter(\.isWaiting).map(\.primary)
        if !running.isEmpty { phase = .running }
        else if !waiting.isEmpty { phase = .waitingForInput }
        else if self.activities.contains(where: { $0.observedPhase(at: now) == .unknown }) { phase = .unknown }
        else { phase = .completed }
        let agents = self.activities.filter { $0.observedPhase(at: now) == .running }
        let rates = agents.compactMap { $0.tokensPerSecond(at: now) }
        // Never carry an old rate from a waiting, ended, stale or internal turn.
        tokensPerSecond = rates.isEmpty ? nil : rates.reduce(0, +)
        let estimates = agents.compactMap { $0.displayedOutputEstimate(at: now) }
        displayedRate = estimates.isEmpty ? nil : estimates.reduce(0) { $0 + $1.value }
        rateIsFresh = !estimates.isEmpty && estimates.count == agents.count && estimates.allSatisfy(\.isFresh)
    }

    public var title: String {
        switch phase {
        case .running: return running.count == 1 ? L10n.text("activity.running") : L10n.text("activity.running_count", running.count)
        case .waitingForInput: return L10n.text("activity.waiting")
        case .unknown: return L10n.text("activity.unknown")
        default: return L10n.text("activity.idle")
        }
    }
    public var compactTitle: String {
        phase == .running && running.count > 1 ? L10n.text("activity.task_count", running.count) : title
    }
}
