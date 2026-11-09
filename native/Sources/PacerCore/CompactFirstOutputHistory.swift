import Foundation

/// The latest first-output measurements, newest last, for the median choice.
/// Only a new measurement is added, so repeated publications of the same value
/// at the same time do not skew it.
public struct CompactFirstOutputHistory: Equatable, Sendable {
    public static let limit = 5
    private struct Sample: Equatable, Sendable {
        let stamp: Date
        let seconds: Double
    }
    /// The newest measurements by when they were taken, oldest first.
    private var samples: [Sample] = []
    public var values: [Double] { samples.map(\.seconds) }

    public init() {}

    /// Measurements can arrive out of order, several in one batch; each takes
    /// its place by when it was taken, and one already kept is not counted twice.
    public mutating func record(_ seconds: Double?, measuredAt stamp: Date?) {
        guard let seconds, seconds.isFinite, (0...3600).contains(seconds), let stamp,
              !samples.contains(where: { $0.stamp == stamp }) else { return }
        let index = samples.firstIndex { $0.stamp > stamp } ?? samples.endIndex
        samples.insert(Sample(stamp: stamp, seconds: seconds), at: index)
        if samples.count > Self.limit { samples.removeFirst(samples.count - Self.limit) }
    }

    public var median: Double? { Self.median(values) }

    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted(), middle = sorted.count / 2
        guard !sorted.isEmpty else { return nil }
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
