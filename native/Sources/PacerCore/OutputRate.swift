import Foundation

/// Estimates reported output tokens over wall-clock time, not model-side decode speed.
public struct OutputRate: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let start: Date
        let end: Date
        let tokens: Int
    }
    private var baseline: (tokens: Int, date: Date)?
    private var samples: [Sample] = []
    public init() {}

    public static func == (lhs: OutputRate, rhs: OutputRate) -> Bool {
        lhs.baseline?.tokens == rhs.baseline?.tokens && lhs.baseline?.date == rhs.baseline?.date && lhs.samples == rhs.samples
    }
    public mutating func startTurn(at date: Date) {
        samples.removeAll()
        // A known session counter can anchor the new turn without counting the idle gap.
        baseline = baseline.map { ($0.tokens, date) }
    }
    public mutating func finishTurn() { samples.removeAll() }
    public mutating func observe(totalOutput: Int, at date: Date) {
        guard totalOutput >= 0 else { return }
        guard let previous = baseline else { baseline = (totalOutput, date); return }
        guard date > previous.date else { return }
        let seconds = date.timeIntervalSince(previous.date)
        let delta = totalOutput - previous.tokens
        baseline = (totalOutput, date)
        guard delta >= 0, seconds >= 0.25, seconds <= 120 else { samples.removeAll(); return }
        samples.append(Sample(start: previous.date, end: date, tokens: delta))
        samples.removeAll { date.timeIntervalSince($0.end) > 30 }
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
    }
    public func tokensPerSecond(at now: Date) -> Double? {
        guard let last = samples.last, now >= last.end, now.timeIntervalSince(last.end) <= 15 else { return nil }
        let seconds = samples.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard seconds > 0 else { return nil }
        return Double(samples.reduce(0) { $0 + $1.tokens }) / seconds
    }
}
