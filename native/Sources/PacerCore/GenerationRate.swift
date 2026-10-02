import Foundation

/// Experimental usage rate after subtracting confirmed blocking-tool intervals.
/// A reporting interval can contain several overlapping tool calls; the caller
/// transitions only when the union of those waits opens/closes.
struct GenerationRate: Equatable, Sendable {
    private struct Sample: Equatable, Sendable { let end: Date; let tokens: Int; let seconds: Double }
    private var baseline: (tokens: Int, date: Date)?
    private var samples: [Sample] = []
    private var waitStart: Date?
    private var waits: [(Date, Date)] = []
    private var retained: OutputEstimate?
    private var completeAnchor: Date?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.baseline?.tokens == rhs.baseline?.tokens && lhs.baseline?.date == rhs.baseline?.date &&
        lhs.samples == rhs.samples && lhs.waitStart == rhs.waitStart &&
        lhs.waits.map(\.0) == rhs.waits.map(\.0) && lhs.waits.map(\.1) == rhs.waits.map(\.1) &&
        lhs.retained == rhs.retained && lhs.completeAnchor == rhs.completeAnchor
    }
    mutating func start(at date: Date, complete: Bool) {
        samples = []; waits = []; waitStart = nil; retained = nil
        completeAnchor = complete ? date : nil
        baseline = complete ? baseline.map { ($0.tokens, date) } : nil
    }
    mutating func finish() { samples = []; waits = []; waitStart = nil; retained = nil; completeAnchor = nil }
    mutating func setWaiting(_ waiting: Bool, at date: Date) {
        if waiting { if waitStart == nil { waitStart = date } }
        else if let start = waitStart {
            if date >= start { waits.append((start, date)) }
            waitStart = nil
        }
    }
    mutating func observe(total: Int, last: Int? = nil, at date: Date) {
        guard total >= 0 else { return }
        if baseline == nil, let anchor = completeAnchor, let last, last >= 0, last <= total, anchor < date {
            baseline = (total - last, anchor)
        }
        guard let previous = baseline else { baseline = (total, date); return }
        guard date > previous.date else { return }
        let delta = total - previous.tokens
        baseline = (total, date)
        if delta < 0 { samples = []; retained = nil; waits = []; completeAnchor = nil; return }
        let wall = date.timeIntervalSince(previous.date)
        let blocked = (waits + (waitStart.map { [($0, date)] } ?? [])).reduce(0.0) {
            $0 + max(0, min(date, $1.1).timeIntervalSince(max(previous.date, $1.0)))
        }
        waits.removeAll { $0.1 <= date }
        let active = wall - blocked
        guard wall <= 120, active >= 0.25 else { samples = []; return }
        samples.append(Sample(end: date, tokens: delta, seconds: active))
        samples.removeAll { date.timeIntervalSince($0.end) > 30 }
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        let duration = samples.reduce(0) { $0 + $1.seconds }
        retained = OutputEstimate(value: Double(samples.reduce(0) { $0 + $1.tokens }) / duration,
            reportedAt: date, isFresh: true)
    }
    func estimate(at now: Date) -> OutputEstimate? {
        if waitStart != nil { return OutputEstimate(value: 0, reportedAt: now, isFresh: true) }
        guard let retained, now >= retained.reportedAt else { return nil }
        return OutputEstimate(value: retained.value, reportedAt: retained.reportedAt,
            isFresh: now.timeIntervalSince(retained.reportedAt) <= 15)
    }
}
