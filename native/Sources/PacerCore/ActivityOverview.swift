import Foundation

/// Global task state is independent of the conversation selected for navigation.
public struct ActivityOverview: Sendable {
    public let activities: [SessionActivity]
    public let running: [SessionActivity]
    public let waiting: [SessionActivity]
    public let phase: ActivityPhase
    public let tokensPerSecond: Double?

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
