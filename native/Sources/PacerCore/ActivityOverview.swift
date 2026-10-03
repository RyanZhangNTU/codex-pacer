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
        self.activities = activities.filter { !$0.isInternalReview }
        running = self.activities.filter { $0.observedPhase(at: now) == .running }
        waiting = self.activities.filter { $0.observedPhase(at: now) == .waitingForInput }
        if !running.isEmpty { phase = .running }
        else if !waiting.isEmpty { phase = .waitingForInput }
        else if self.activities.contains(where: { $0.observedPhase(at: now) == .unknown }) { phase = .unknown }
        else { phase = .completed }
        let rates = running.compactMap { $0.tokensPerSecond(at: now) }
        // Never carry an old rate from a waiting, ended, stale or internal turn.
        tokensPerSecond = rates.isEmpty ? nil : rates.reduce(0, +)
        let estimates = running.compactMap { $0.outputEstimate(at: now) }
        // Known blocked tasks contribute zero, but an unmeasured generating
        // task must not turn that partial total into an apparent global zero.
        let incompleteZero = estimates.count < running.count && estimates.allSatisfy { $0.value == 0 }
        displayedRate = estimates.isEmpty || incompleteZero ? nil : estimates.reduce(0) { $0 + $1.value }
        rateIsFresh = !estimates.isEmpty && estimates.count == running.count && estimates.allSatisfy(\.isFresh)
    }

    public var title: String {
        switch phase {
        case .running: return running.count == 1 ? "运行中" : "\(running.count) 个任务运行中"
        case .waitingForInput: return "等待回复"
        case .unknown: return "状态未确认"
        default: return "空闲"
        }
    }
    public var compactTitle: String {
        phase == .running && running.count > 1 ? "\(running.count) 个任务" : title
    }
}
