import Foundation

/// A response's usage repeats on each persisted content block. This meter
/// counts that response once and uses only observed prompt/tool boundaries.
/// A response is settled once one of its blocks carries the stop reason, which
/// Claude Code knows only after the response ends, or at the turn's terminal
/// summary. It never turns block time into TTFT.
struct ClaudeObservedRequestMeter: Sendable {
    struct Request: Sendable {
        let id: String
        let messageID: String
        var firstBlock: Date
        var lastBlock: Date
        var outputTokens: Int
        var requiredTools: Set<String>
        var terminal: Bool
    }
    let turnID: String
    private(set) var observedStart: Date?
    private var requests: [String: Request] = [:]
    private var toolStarts: [String: Date] = [:]
    private var toolEnds: [String: Date] = [:]
    private var exact: Set<String> = []
    private var released: Set<String> = []
    private var ambiguous = false
    init(turnID: String, observedStart: Date?) { self.turnID = turnID; self.observedStart = observedStart }
    mutating func confirmStart(_ date: Date) { if observedStart == nil { observedStart = date } }
    mutating func markGap() { ambiguous = true }
    mutating func authoritative(_ requestID: String) { if exact.count < 64 { exact.insert(requestID) } }
    mutating func toolStarted(_ id: String, at date: Date) {
        guard let start = observedStart, date >= start else { return }
        guard toolStarts[id] != nil || toolStarts.count < 128 else { ambiguous = true; return }
        toolStarts[id] = min(toolStarts[id] ?? date, date)
    }
    mutating func toolEnded(_ id: String, at date: Date) {
        guard let start = observedStart, date >= start else { return }
        guard toolEnds[id] != nil || toolEnds.count < 128 else { ambiguous = true; return }
        // A later background result cannot move the first required result.
        toolEnds[id] = min(toolEnds[id] ?? date, date)
    }
    mutating func modelBlock(id: String, messageID: String, outputTokens: Int, toolIDs: [String], terminal: Bool = false, at date: Date) {
        guard let start = observedStart, date >= start, outputTokens > 0, outputTokens <= 1_000_000_000_000 else { return }
        guard requests[id] != nil || requests.count < 64 else { ambiguous = true; return }
        if var previous = requests[id] {
            guard previous.messageID == messageID else { ambiguous = true; return }
            previous.firstBlock = min(previous.firstBlock, date)
            if date >= previous.lastBlock { previous.lastBlock = date; previous.outputTokens = outputTokens }
            previous.requiredTools.formUnion(toolIDs); previous.terminal = previous.terminal || terminal
            requests[id] = previous
        } else {
            requests[id] = Request(id: id, messageID: messageID, firstBlock: date, lastBlock: date,
                outputTokens: outputTokens, requiredTools: Set(toolIDs), terminal: terminal)
        }
    }
    /// Samples for responses that have ended, in order up to the first that
    /// has not, each returned once. Claude Code writes a response's blocks in
    /// one append or ends with the stop-bearing one, so callers release them
    /// after a whole read rather than per record.
    mutating func releaseCompleted() -> [ResponsePerformance] {
        let ordered = ordered()
        let count = ordered.prefix { $0.terminal }.count
        guard count > 0 else { return [] }
        let samples = settled(at: ordered[count - 1].lastBlock, limit: count).filter { sample in
            sample.responseID.map { !released.contains($0) } ?? false
        }
        for sample in samples { if let id = sample.responseID, released.count < 64 { released.insert(id) } }
        return samples
    }
    private func ordered() -> [Request] {
        requests.values.sorted { $0.firstBlock == $1.firstBlock ? $0.id < $1.id : $0.firstBlock < $1.firstBlock }
    }
    func settled(at terminal: Date, limit: Int? = nil) -> [ResponsePerformance] {
        guard !ambiguous, let start = observedStart else { return [] }
        let ordered = Array(ordered().prefix(limit ?? Int.max))
        var samples: [ResponsePerformance] = [], boundary = start, previous: Request?
        for request in ordered {
            if let previous {
                boundary = previous.lastBlock
                if !previous.requiredTools.isEmpty {
                    var results: [Date] = []
                    for id in previous.requiredTools {
                        guard let began = toolStarts[id], let ended = toolEnds[id], began >= previous.firstBlock,
                              ended >= began, ended >= previous.lastBlock else { return samples }
                        results.append(ended)
                    }
                    guard let lastResult = results.max(), lastResult < request.firstBlock else { return samples }
                    boundary = lastResult
                }
            }
            // Overlapping outputs or an unknown/missing required tool cannot
            // manufacture a tiny new window. Keep the last safe measurement.
            guard request.firstBlock >= boundary, request.lastBlock <= terminal,
                  let sample = ResponsePerformance(responseID: request.id, turnID: turnID,
                    outputTokens: request.outputTokens, startedAt: boundary, completedAt: request.lastBlock,
                    source: .observedRequest) else { return samples }
            if !exact.contains(request.id) { samples.append(sample) }
            previous = request
        }
        return samples
    }
}
