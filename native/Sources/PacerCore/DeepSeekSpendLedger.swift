import Foundation

/// Estimated spend of each DeepSeek response over the last eight days. Only
/// times and amounts are kept, keyed by response so a reread cannot double it.
public struct DeepSeekSpendLedger: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let at: Date
        public let cost: Double
        public let peak: Bool
    }
    public struct Day: Equatable, Sendable {
        public let start: Date
        public let total: Double
        public let peak: Double
    }
    static let retention: TimeInterval = 8 * 86_400
    private var entries: [String: Entry] = [:]
    public init() {}
    public var isEmpty: Bool { entries.isEmpty }

    mutating func record(id: String, at date: Date, cost: Double) {
        guard cost.isFinite, cost >= 0, cost < 100_000, entries[id] == nil else { return }
        entries[id] = Entry(at: date, cost: cost, peak: DeepSeekPricing.isPeak(at: date))
        if entries.count > 100_000, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries.removeValue(forKey: oldest) }
    }
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        if entries.values.contains(where: { $0.at < cutoff }) { entries = entries.filter { $0.value.at >= cutoff } }
    }

    public func total(in interval: DateInterval) -> (total: Double, peak: Double) {
        entries.values.reduce(into: (0.0, 0.0)) { sum, entry in
            guard interval.contains(entry.at), entry.at != interval.end else { return }
            sum.0 += entry.cost; if entry.peak { sum.1 += entry.cost }
        }
    }
    /// Spend in each local clock hour of the day containing `date`.
    public func hourly(on date: Date, calendar: Calendar = .current) -> [Double] {
        var result = [Double](repeating: 0, count: 24)
        guard let day = calendar.dateInterval(of: .day, for: date) else { return result }
        for entry in entries.values where entry.at >= day.start && entry.at < day.end {
            result[min(23, max(0, calendar.component(.hour, from: entry.at)))] += entry.cost
        }
        return result
    }
    /// The last `count` local days, oldest first, ending with today.
    public func days(_ count: Int = 7, endingAt date: Date, calendar: Calendar = .current) -> [Day] {
        guard let today = calendar.dateInterval(of: .day, for: date) else { return [] }
        return (0..<max(1, min(8, count))).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today.start),
                  let day = calendar.dateInterval(of: .day, for: start) else { return nil }
            let sum = total(in: day)
            return Day(start: day.start, total: sum.total, peak: sum.peak)
        }
    }
    /// Average spend from midnight to this time of day over the previous
    /// `count` days, the basis for calling today fast or slow.
    public func typicalByThisTime(_ date: Date, days count: Int = 7, calendar: Calendar = .current) -> Double? {
        guard let today = calendar.dateInterval(of: .day, for: date) else { return nil }
        let elapsed = date.timeIntervalSince(today.start)
        var totals: [Double] = []
        for offset in 1...max(1, min(7, count)) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today.start) else { continue }
            totals.append(total(in: DateInterval(start: start, duration: elapsed)).total)
        }
        guard let earliest = entries.values.map(\.at).min(), earliest < today.start else { return nil }
        return totals.reduce(0, +) / Double(totals.count)
    }
    /// Mean daily spend over the previous seven full days and today so far.
    public func averageDaily(endingAt date: Date, calendar: Calendar = .current) -> Double? {
        guard let earliest = entries.values.map(\.at).min(), let today = calendar.dateInterval(of: .day, for: date) else { return nil }
        let start = max(earliest, calendar.date(byAdding: .day, value: -7, to: today.start) ?? earliest)
        let elapsedDays = max(1, date.timeIntervalSince(start) / 86_400)
        return total(in: DateInterval(start: start, end: max(start, date))).total / elapsedDays
    }
}
