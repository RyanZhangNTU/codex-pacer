import Foundation

/// What the account was charged, from successive balance readings. A drop
/// between two readings is spend wherever it happened (this Mac, another
/// device, server-side tools); a rise is a top-up and is ignored. Only
/// amounts and times are kept, for eight local days, and never the account.
public struct DeepSeekBalanceHistory: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let at: Date
        public let total: Double
    }
    public static let defaultsKey = "deepseekBalanceHistory"
    static let retention: TimeInterval = 8 * 86_400
    static let sampleRetention: TimeInterval = 2 * 3600
    /// Recent readings, for spend over the last minutes.
    public private(set) var samples: [Sample] = []
    /// Charges per local day, keyed by the day's start.
    private var charged: [Date: Double] = [:]
    /// The first reading; earlier spend was never seen by the account side.
    public private(set) var since: Date?
    /// The balance source; readings from another source may be another account.
    public private(set) var source: String?
    public init() {}

    public var last: Sample? { samples.last }

    public mutating func record(total: Double, at date: Date, source: String? = nil, calendar: Calendar = .current) {
        guard total.isFinite, total >= 0 else { return }
        if self.source != source { self = Self(); self.source = source }
        if let last, date <= last.at { return }
        if let last {
            let drop = last.total - total
            if drop > 0.000_5 { charge(drop, from: last.at, to: date, calendar: calendar) }
        } else { since = date }
        samples.append(Sample(at: date, total: total))
        let keep = date.addingTimeInterval(-Self.sampleRetention)
        samples.removeAll { $0.at < keep }
        if samples.count > 512 { samples.removeFirst(samples.count - 512) }
        let cutoff = date.addingTimeInterval(-Self.retention)
        charged = charged.filter { $0.key >= cutoff }
        if let since, since < cutoff { self.since = cutoff }
    }

    /// A drop over a gap that crosses midnight is shared by time between the days.
    private mutating func charge(_ amount: Double, from start: Date, to end: Date, calendar: Calendar) {
        let span = end.timeIntervalSince(start)
        var cursor = start
        while cursor < end {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { return }
            let stop = min(end, day.end)
            charged[day.start, default: 0] += span > 0 ? amount * stop.timeIntervalSince(cursor) / span : amount
            cursor = stop
        }
    }

    /// Charges in the local day starting at `day`, from `since` to the last reading.
    public func charged(onDayStarting day: Date) -> Double { charged[day] ?? 0 }

    /// The interval the account side has seen of a local day: nil before the first reading.
    public func coverage(of day: DateInterval) -> DateInterval? {
        guard let since, let last, since < day.end, last.at > day.start else { return nil }
        return DateInterval(start: max(day.start, since), end: min(day.end, last.at))
    }

    /// Charges in `count` spans of `span` seconds ending at `now`, oldest first.
    /// A drop between two readings is shared by time across the spans it covers.
    public func spent(_ count: Int, of span: TimeInterval, endingAt now: Date) -> [Double] {
        var result = [Double](repeating: 0, count: max(1, count))
        let start = now.addingTimeInterval(-span * Double(result.count))
        for (previous, next) in zip(samples, samples.dropFirst()) {
            let drop = previous.total - next.total, length = next.at.timeIntervalSince(previous.at)
            guard drop > 0.000_5, length > 0, next.at > start, previous.at < now else { continue }
            for index in result.indices {
                let from = start.addingTimeInterval(span * Double(index))
                let overlap = min(from.addingTimeInterval(span), next.at).timeIntervalSince(max(from, previous.at))
                if overlap > 0 { result[index] += drop * overlap / length }
            }
        }
        return result
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= 64 * 1024,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
