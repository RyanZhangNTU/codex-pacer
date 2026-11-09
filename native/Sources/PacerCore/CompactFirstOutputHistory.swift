import Foundation

/// The latest first-output measurements, newest last, for the median choice.
/// Only a new measurement is added, so repeated publications of the same value
/// at the same time do not skew it.
public struct CompactFirstOutputHistory: Equatable, Sendable {
    public static let limit = 5
    public private(set) var values: [Double] = []
    private var lastStamp: Date?

    public init() {}

    public mutating func record(_ seconds: Double?, measuredAt stamp: Date?) {
        guard let seconds, seconds.isFinite, (0...3600).contains(seconds), let stamp, stamp != lastStamp else { return }
        lastStamp = stamp
        values.append(seconds)
        if values.count > Self.limit { values.removeFirst(values.count - Self.limit) }
    }

    public var median: Double? { Self.median(values) }

    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted(), middle = sorted.count / 2
        guard !sorted.isEmpty else { return nil }
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
