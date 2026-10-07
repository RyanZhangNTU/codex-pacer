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
    public let usesResponseRate: Bool

    public init(activities: [SessionActivity], at now: Date) {
        self.activities = activities.filter { !$0.isInternalReview }
        running = self.activities.filter { $0.observedPhase(at: now) == .running }
        waiting = self.activities.filter { $0.observedPhase(at: now) == .waitingForInput }
        if !running.isEmpty { phase = .running }
        else if !waiting.isEmpty { phase = .waitingForInput }
        else if self.activities.contains(where: { $0.observedPhase(at: now) == .unknown }) { phase = .unknown }
        else { phase = .completed }
        let generating = running.filter { $0.outputEstimate(at: now)?.value != 0 }
        let responses = generating.compactMap(\.responsePerformance)
        usesResponseRate = !responses.isEmpty
        if !responses.isEmpty {
            // Different request windows cannot be added as concurrent decode
            // speed. Divide total output by total measured duration instead.
            let mean = responses.reduce(0.0) { $0 + Double($1.outputTokens) } / responses.reduce(0) { $0 + $1.duration }
            displayedRate = mean
            rateIsFresh = responses.count == generating.count && responses.allSatisfy {
                now >= $0.completedAt && now.timeIntervalSince($0.completedAt) < OutputEstimate.freshnessInterval
            }
            tokensPerSecond = rateIsFresh ? mean : nil
            return
        }
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
