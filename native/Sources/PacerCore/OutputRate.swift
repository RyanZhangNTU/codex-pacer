import Foundation

public struct OutputEstimate: Equatable, Sendable {
    public static let freshnessInterval: TimeInterval = 15
    public let value: Double
    public let reportedAt: Date
    public let isFresh: Bool
    public var expiresAt: Date { reportedAt.addingTimeInterval(Self.freshnessInterval) }
}

/// Estimates reported output tokens over wall-clock time, not model-side decode speed.
public struct OutputRate: Equatable, Sendable {
    // Share counter, burst and freshness semantics with the phase-aware path;
    // this adapter simply has no confirmed tool intervals to subtract.
    private var rate = GenerationRate()
    public init() {}
    public mutating func startTurn(at _: Date) { rate.start() }
    public mutating func finishTurn() { rate.finish() }
    public mutating func observe(totalOutput: Int, at date: Date) {
        rate.observe(total: totalOutput, at: date)
    }
    public var expiresAt: Date? { rate.expiresAt }
    public func estimate(at now: Date) -> OutputEstimate? { rate.estimate(at: now) }
    public func tokensPerSecond(at now: Date) -> Double? { estimate(at: now)?.value }
}
