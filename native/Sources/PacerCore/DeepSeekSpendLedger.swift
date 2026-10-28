import Foundation

/// Estimated spend of each DeepSeek response over the last eight days. Only
/// times, amounts and the root session are kept, keyed by response so a
/// reread cannot double it. A sub-agent's spend belongs to its root session.
public struct DeepSeekSpendLedger: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let at: Date
        public let cost: Double
        public let peak: Bool
        public let task: String?
        /// The session that incurred the charge, before resolving its root task.
        let session: String?
        let turnID: String?
    }
    /// One task's share of a period.
    public struct TaskSpend: Equatable, Sendable {
        public let task: String
        public let total: Double
        public let peak: Double
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
    var earliestEntryAt: Date? { entries.values.map(\.at).min() }
    /// The root sessions with spend still kept.
    public var taskIDs: Set<String> { Set(entries.values.compactMap(\.task)) }

    @discardableResult mutating func record(id: String, at date: Date, cost: Double, task: String? = nil, session: String? = nil,
                                          turnID: String? = nil) -> Bool {
        guard cost.isFinite, cost >= 0, cost < 100_000, entries[id] == nil else { return false }
        entries[id] = Entry(at: date, cost: cost, peak: DeepSeekPricing.isPeak(at: date), task: task, session: session ?? task, turnID: turnID)
        if entries.count > 100_000, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key { entries.removeValue(forKey: oldest) }
        return true
    }
    /// A parent's header can arrive after its descendants' responses during replay.
    mutating func resolveTasks(parents: [String: String]) {
        for (id, entry) in entries {
            guard let session = entry.session else { continue }
            let root = DeepSeekActivityState.root(of: session, parents: parents)
            if root != entry.task {
                entries[id] = Entry(at: entry.at, cost: entry.cost, peak: entry.peak, task: root, session: session, turnID: entry.turnID)
            }
        }
    }
    /// Own responses match the turn ID; delegated charges match its time bounds.
    func turnSpend(session: String, turnID: String, from start: Date, through end: Date?) -> (total: Double, peak: Double, observed: Bool) {
        entries.values.reduce(into: (0.0, 0.0, false)) { sum, entry in
            if entry.session == session {
                guard entry.turnID == turnID else { return }
            } else {
                guard entry.task == session, entry.at >= start, end.map({ entry.at <= $0 }) ?? true else { return }
            }
            sum.0 += entry.cost; if entry.peak { sum.1 += entry.cost }; sum.2 = true
        }
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
    /// Each task's spend in a period, largest first; spend without a task is left out.
    public func tasks(in interval: DateInterval) -> [TaskSpend] {
        var sums: [String: (Double, Double)] = [:]
        for entry in entries.values where interval.contains(entry.at) && entry.at != interval.end {
            guard let task = entry.task else { continue }
            var sum = sums[task] ?? (0, 0)
            sum.0 += entry.cost; if entry.peak { sum.1 += entry.cost }
            sums[task] = sum
        }
        return sums.map { TaskSpend(task: $0.key, total: $0.value.0, peak: $0.value.1) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.task < $1.task }
    }
    /// Spend in `count` consecutive spans of `span` seconds ending at `date`, oldest first.
    public func recent(_ count: Int, of span: TimeInterval, endingAt date: Date) -> [Double] {
        let count = max(1, min(1008, count)), start = date.addingTimeInterval(-span * Double(count))
        var result = [Double](repeating: 0, count: count)
        for entry in entries.values where entry.at > start && entry.at <= date {
            result[min(count - 1, max(0, Int(entry.at.timeIntervalSince(start) / span)))] += entry.cost
        }
        return result
    }
    /// The spike line when none is set: three times the 90th percentile of the
    /// 10-minute spans with spend in the seven days before `day`, and at least
    /// the minimum. Today is left out, so a spike never raises its own line.
    public func automaticSpikeLimit(before day: Date) -> Double {
        let spans = recent(1008, of: 600, endingAt: day).filter { $0 >= 0.000_5 }.sorted()
        guard !spans.isEmpty else { return DeepSeekWallet.minimumSpikeLimit }
        let typical = spans[max(0, Int((Double(spans.count) * 0.9).rounded(.up)) - 1)]
        return max(DeepSeekWallet.minimumSpikeLimit, typical * 3)
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
