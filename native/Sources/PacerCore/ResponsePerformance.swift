import Foundation

/// Settled output throughput for one model response, not a decoder benchmark.
public struct ResponsePerformance: Equatable, Sendable {
    public enum Source: String, Sendable { case requestUsage, runtimeUsage }
    public let responseID: String?
    public let turnID: String
    public let outputTokens: Int
    public let reasoningTokens: Int?
    public let startedAt: Date
    public let completedAt: Date
    public let source: Source
    public var duration: TimeInterval { completedAt.timeIntervalSince(startedAt) }
    public var tokensPerSecond: Double { Double(outputTokens) / duration }
    public var visibleOutputTokens: Int? { reasoningTokens.map { max(0, outputTokens - $0) } }

    public init?(responseID: String?, turnID: String, outputTokens: Int, reasoningTokens: Int? = nil,
                 startedAt: Date, completedAt: Date, source: Source) {
        let seconds = completedAt.timeIntervalSince(startedAt)
        guard !turnID.isEmpty, turnID.count <= 256, outputTokens > 0,
              seconds.isFinite, seconds >= 0.01, seconds <= 3600,
              startedAt.timeIntervalSince1970.isFinite, completedAt.timeIntervalSince1970.isFinite,
              responseID == nil || (responseID!.count <= 256 && !responseID!.isEmpty),
              reasoningTokens == nil || (reasoningTokens! >= 0 && reasoningTokens! <= outputTokens) else { return nil }
        self.responseID = responseID; self.turnID = turnID; self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens; self.startedAt = startedAt; self.completedAt = completedAt; self.source = source
    }
}

/// Keeps only numeric timing/counter metadata. No text or tool output is stored.
struct ResponsePerformanceMeter: Equatable, Sendable {
    private(set) var latest: ResponsePerformance?
    private(set) var firstTokenLatency: TimeInterval?
    private var turnID: String?
    private var turnStart: Date?
    private var responseStart: Date?
    private var generatedEnd: Date?
    private var observedStart = false
    private var cumulative: Int?
    private var seenResponses: [String] = []
    private var waiting = false
    private var finished = false
    private var hasRequestUsage = false

    mutating func start(turnID: String?, at date: Date, observed: Bool) {
        self = Self(); self.turnID = turnID; turnStart = observed ? date : nil
        responseStart = observed ? date : nil; observedStart = observed
    }
    mutating func identify(_ id: String) { if turnID == nil { turnID = id } }
    mutating func finish() { finished = true }
    mutating func modelOutput(at date: Date, textDelta: Bool) {
        guard !finished else { return }
        if textDelta, firstTokenLatency == nil, observedStart, let start = turnStart, date >= start {
            firstTokenLatency = date.timeIntervalSince(start)
        }
        waiting = false
        if responseStart != nil { generatedEnd = max(generatedEnd ?? date, date) }
    }
    mutating func setWaiting(_ value: Bool, at date: Date) {
        guard !finished else { return }
        if value { waiting = true }
        else if waiting {
            waiting = false; responseStart = date; generatedEnd = nil
        }
    }
    mutating func inputBoundary(at date: Date) {
        guard !finished else { return }
        guard waiting || generatedEnd == nil else { return } // A background tool finishing mid-response is not a new model request.
        responseStart = date; generatedEnd = nil; waiting = false
    }
    mutating func observeRuntime(total: Int, last: Int?, reasoning: Int?, at date: Date, cached: Bool = false) {
        guard total >= 0 else { return }
        let previous = cumulative
        cumulative = total
        guard !hasRequestUsage, !cached, previous != total, !finished, let last, last > 0,
              let turnID, let start = responseStart, let end = generatedEnd, end >= start,
              date >= end, date.timeIntervalSince(end) <= 30 else { return }
        // An unchanged/replayed `last` cannot create a second response. A known
        // output item must precede usage; a startup snapshot alone is not work.
        if let previous, total >= previous, last > total - previous { return }
        if let sample = ResponsePerformance(responseID: nil, turnID: turnID, outputTokens: last, reasoningTokens: reasoning,
            startedAt: start, completedAt: end, source: .runtimeUsage) {
            latest = sample
        }
        responseStart = date; generatedEnd = nil
    }
    mutating func observeRequest(id: String, turn: String, output: Int, reasoning: Int?, at date: Date) {
        guard turn == turnID, !id.isEmpty, id.count <= 256, !seenResponses.contains(id) else { return }
        hasRequestUsage = true
        if generatedEnd == nil, let old = latest, old.source == .runtimeUsage, date >= old.completedAt,
           date.timeIntervalSince(old.completedAt) <= 30,
           let exact = ResponsePerformance(responseID: id, turnID: turn, outputTokens: output, reasoningTokens: reasoning,
               startedAt: old.startedAt, completedAt: old.completedAt, source: .requestUsage) {
            latest = exact; seenResponses.append(id)
            return
        }
        guard let start = responseStart, let end = generatedEnd, date >= end, date.timeIntervalSince(end) <= 30 else { return }
        seenResponses.append(id); if seenResponses.count > 64 { seenResponses.removeFirst(seenResponses.count - 64) }
        if let sample = ResponsePerformance(responseID: id, turnID: turn, outputTokens: output, reasoningTokens: reasoning,
            startedAt: start, completedAt: end, source: .requestUsage) {
            latest = sample
        }
        responseStart = date; generatedEnd = nil
    }
    mutating func merge(from other: Self) {
        guard turnID == other.turnID else { return }
        apply(sample: other.latest, latency: other.firstTokenLatency)
    }
    mutating func apply(sample: ResponsePerformance?, latency: TimeInterval?) {
        if firstTokenLatency == nil, let latency, latency.isFinite, latency >= 0 { firstTokenLatency = latency }
        guard let sample, sample.turnID == turnID else { return }
        if latest == nil || sample.completedAt > latest!.completedAt ||
            (abs(sample.completedAt.timeIntervalSince(latest!.completedAt)) < 2 && sample.source == .requestUsage && latest!.source != .requestUsage) {
            latest = sample
        }
    }
}
