import Foundation

/// One measurement of the parent's conversation window. Counts are the raw provider values.
public struct TaskContextLevel: Equatable, Sendable {
    public let usedTokens: Int
    public let capacityTokens: Int
    public let fraction: Double
    public let measuredAt: Date

    init?(used: Int?, capacity: Int?, at date: Date, codex: Bool = false) {
        guard let used, used >= 0, let capacity, capacity > 0 else { return nil }
        usedTokens = used; capacityTokens = capacity; measuredAt = date
        if codex {
            // Codex TUI rounds the percentage remaining before taking its complement.
            let baseline = 12_000
            let remaining = capacity > baseline
                ? Double(max(0, capacity - max(baseline, used))) / Double(capacity - baseline) : 0
            fraction = (100 - (remaining * 100).rounded()) / 100
        } else {
            fraction = min(1, Double(used) / Double(capacity))
        }
    }

    public var accessibilityValue: String {
        L10n.text("activity.context_used", Int((fraction * 100).rounded()))
    }

    static func count(_ raw: Any?) -> Int? {
        guard let n = raw as? NSNumber, !["f", "d"].contains(String(cString: n.objCType)),
              let encoded = try? JSONSerialization.data(withJSONObject: n, options: .fragmentsAllowed),
              let value = Int(String(decoding: encoded, as: UTF8.self)), value >= 0 else { return nil }
        return value
    }

    static func claudeCapacity(model: String?, extended: Bool) -> Int {
        guard !extended else { return 1_000_000 }
        let name = model?.lowercased() ?? ""
        if name.hasSuffix("[1m]") { return 1_000_000 }
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "." })
        if parts.contains("fable") { return 1_000_000 }
        let version = parts.compactMap { $0.count <= 2 ? Int($0) : nil }
        let major = version.first ?? 0, minor = version.dropFirst().first ?? 0
        if parts.contains("opus") && (major > 4 || major == 4 && minor >= 7)
            || parts.contains("sonnet") && major >= 5
            || parts.contains("haiku") && (major > 5 || major == 5 && minor >= 5) { return 1_000_000 }
        return 200_000
    }
}

/// Spool and transcript can replay in either order. Keep the sample and the compaction
/// evidence independently so an older snapshot cannot restore a pre-compaction level.
struct TaskContextState: Equatable, Sendable {
    static let timeout: TimeInterval = 600
    private var sample: TaskContextLevel?
    struct Start: Equatable, Sendable {
        let at: Date
        let turn: String?
    }
    private struct End: Equatable, Sendable {
        let at: Date
        let startedAt: Date?
    }
    private(set) var start: Start?
    private var postHook: End?
    var boundary: Date?
    private var claudeExceededDefault = false
    private var extendedSetting = false
    private var settingAt: Date?

    mutating func setClaudeModel(_ model: String, at date: Date) {
        guard date >= (settingAt ?? .distantPast) else { return }
        extendedSetting = model.lowercased().hasSuffix("[1m]")
        settingAt = date
    }

    mutating func preCompact(turn: String?, at date: Date) {
        if date > (start?.at ?? .distantPast) { start = Start(at: date, turn: turn) }
    }

    mutating func postCompact(turn: String?, at date: Date) {
        guard date > (postHook?.at ?? .distantPast) else { return }
        postHook = End(at: date, startedAt: start.flatMap { $0.at <= date && $0.turn == turn ? $0.at : nil })
    }

    func compactingSince(turn: String?, beganAt: Date?, now: Date) -> Date? {
        guard let start, start.turn == nil || start.turn == turn, start.at >= (beganAt ?? .distantPast),
              start.at > (postHook?.at ?? .distantPast), start.at > (boundary ?? .distantPast),
              start.at <= now, now.timeIntervalSince(start.at) < Self.timeout else { return nil }
        return start.at
    }

    var level: TaskContextLevel? {
        guard let sample else { return nil }
        var cutoff = boundary ?? .distantPast
        if let end = postHook, end.at > cutoff {
            // A hook can arrive after the transcript has already measured the new
            // window. Keep that boundary's reading even when the next compaction begins.
            if let start = end.startedAt {
                if cutoff < start { cutoff = end.at }
            } else if end.at.timeIntervalSince(cutoff) >= Self.timeout { cutoff = end.at }
        }
        guard sample.measuredAt >= cutoff else { return nil }
        if claudeExceededDefault, sample.capacityTokens < 1_000_000 {
            return TaskContextLevel(used: sample.usedTokens, capacity: 1_000_000, at: sample.measuredAt)
        }
        return sample
    }

    mutating func measure(_ value: TaskContextLevel?) {
        if let value, value.measuredAt >= (sample?.measuredAt ?? .distantPast) { sample = value }
    }

    mutating func measureClaude(used: Int, model: String?, afterCompaction: Bool = false, preTokens: Int? = nil, at date: Date) {
        // A boundary has no model. Use the last main-thread measurement's capacity
        // even if unrelated transcript metadata (for example a sidechain) arrived later.
        let inferred = (afterCompaction && !extendedSetting ? sample?.capacityTokens : nil)
            ?? TaskContextLevel.claudeCapacity(model: model, extended: extendedSetting)
        if max(used, preTokens ?? 0) > inferred { claudeExceededDefault = true }
        let capacity = claudeExceededDefault ? 1_000_000 : inferred
        measure(TaskContextLevel(used: used, capacity: capacity, at: date))
    }

    mutating func merge(_ other: Self) {
        if let sample = other.sample, sample.measuredAt > (self.sample?.measuredAt ?? .distantPast) { measure(sample) }
        if let next = other.start, next.at > (start?.at ?? .distantPast) { start = next }
        if let next = other.postHook, next.at > (postHook?.at ?? .distantPast) { postHook = next }
        if let next = other.boundary, next > (boundary ?? .distantPast) { boundary = next }
        claudeExceededDefault = claudeExceededDefault || other.claudeExceededDefault
        if let at = other.settingAt, at > (settingAt ?? .distantPast) {
            extendedSetting = other.extendedSetting; settingAt = at
        }
    }
}
