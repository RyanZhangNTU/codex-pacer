import Foundation

/// Output usage rate after subtracting confirmed blocking-tool intervals.
/// A reporting interval can contain several overlapping tool calls; the caller
/// transitions only when the union of those waits opens/closes.
struct GenerationRate: Equatable, Sendable {
    private struct Sample: Equatable, Sendable { let end: Date; let tokens: Int; let seconds: Double }
    private var baseline: (tokens: Int, date: Date)?
    private var latest: (tokens: Int, date: Date)?
    private var samples: [Sample] = []
    private var waitStart: Date?
    private var waits: [(Date, Date)] = []
    private var retained: OutputEstimate?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.baseline?.tokens == rhs.baseline?.tokens && lhs.baseline?.date == rhs.baseline?.date &&
        lhs.latest?.tokens == rhs.latest?.tokens && lhs.latest?.date == rhs.latest?.date &&
        lhs.samples == rhs.samples && lhs.waitStart == rhs.waitStart &&
        lhs.waits.map(\.0) == rhs.waits.map(\.0) && lhs.waits.map(\.1) == rhs.waits.map(\.1) &&
        lhs.retained == rhs.retained
    }
    mutating func start() {
        // Neither the previous turn's counter nor a cached last-request count
        // proves how many tokens were produced after this turn started.
        baseline = nil; latest = nil; samples = []; waits = []; waitStart = nil; retained = nil
    }
    mutating func finish() { start() }
    mutating func setWaiting(_ waiting: Bool, at date: Date) {
        if waiting { if waitStart == nil { waitStart = date; retained = nil } }
        else if let start = waitStart {
            if date >= start { waits.append((start, date)) }
            waitStart = nil; retained = nil
        }
    }
    mutating func observe(total: Int, at date: Date, cached: Bool = false) {
        guard total >= 0, date >= (latest?.date ?? .distantPast) else { return }
        let previousCount = latest?.tokens
        latest = (total, date)
        // Cached repeats must not refresh the displayed age or shorten the
        // denominator before the next actual counter increase.
        guard previousCount != total else { return }
        if cached { seed(total, at: date); return }
        guard let previous = baseline, total >= (previousCount ?? total) else {
            seed(total, at: date); return
        }
        let wall = date.timeIntervalSince(previous.date)
        let blocked = (waits + (waitStart.map { [($0, date)] } ?? [])).reduce(0.0) {
            $0 + max(0, min(date, $1.1).timeIntervalSince(max(previous.date, $1.0)))
        }
        let active = max(0, wall - blocked)
        guard active <= 120 else { seed(total, at: date); return }
        // A counter reported entirely inside a known wait has no observed
        // generation duration. Do not carry its tokens into a later request.
        if active == 0, waitStart != nil { seed(total, at: date); return }
        // Keep the baseline and wait intervals until a burst spans a usable
        // measurement interval; advancing it here would discard every delta.
        guard active >= 0.25 else { return }
        samples.append(Sample(end: date, tokens: total - previous.tokens, seconds: active))
        baseline = (total, date)
        waits.removeAll { $0.1 <= date }
        samples.removeAll { date.timeIntervalSince($0.end) > 30 }
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        let duration = samples.reduce(0) { $0 + $1.seconds }
        retained = OutputEstimate(value: Double(samples.reduce(0) { $0 + $1.tokens }) / duration,
            reportedAt: date, isFresh: true)
    }
    private mutating func seed(_ total: Int, at date: Date) {
        baseline = (total, date); samples = []; retained = nil
        waits.removeAll { $0.1 <= date }
    }
    var expiresAt: Date? { waitStart == nil ? retained?.expiresAt : nil }
    func estimate(at now: Date) -> OutputEstimate? {
        if waitStart != nil { return OutputEstimate(value: 0, reportedAt: now, isFresh: true) }
        guard let retained, now >= retained.reportedAt, now < retained.expiresAt else { return nil }
        return retained
    }
}
