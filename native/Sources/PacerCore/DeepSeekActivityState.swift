import Foundation

/// DeepSeek Harness session-log records mapped onto the shared runtime events.
/// A response is logged when its step ends, so stage, speed and cost settle
/// per step rather than per token.
struct DeepSeekActivityState: Sendable {
    private struct Progress: Sendable {
        var turn: Int?
        var turnID: String?
        var requestAt: Date?
        var measuredLatency = false
        var model: String?
        var calls: [String: DeepSeekLogEvent.ToolKind] = [:]
        var approvals: Set<String> = []
        var cost = 0.0
        var costKnown = true
    }
    private var sessions: [String: SessionActivity] = [:]
    private var progress: [String: Progress] = [:]
    private var requests: [String: PendingAttentionRequest] = [:]
    private var metrics: [String: SessionPerformanceUpdate] = [:]
    private var historicalRunning: Set<String> = []
    private(set) var ledger = DeepSeekSpendLedger()
    private(set) var status = RuntimeStreamStatus()
    /// The billing provider of the newest request, for choosing a balance source.
    private(set) var latestProvider: (at: Date, name: String)?
    var activities: [SessionActivity] { sessions.values.sorted { $0.id < $1.id } }
    var attention: [PendingAttentionRequest] { requests.values.sorted { $0.detectedAt < $1.detectedAt } }
    var performanceUpdates: [SessionPerformanceUpdate] { Array(metrics.values) }
    /// Sessions whose turn is open without recent evidence; liveness then
    /// depends on whether Harness still holds the session's lock.
    func openSessions(quietFor interval: TimeInterval = 0, now: Date = Date()) -> Set<String> {
        Set(sessions.values.filter {
            [.running, .waitingForInput].contains($0.phase) && now.timeIntervalSince($0.lastObserved ?? .distantPast) >= interval
        }.compactMap(\.threadID))
    }

    mutating func setAvailable(_ available: Bool, watching: Bool) {
        status.connected = available; status.sourceAvailable = available; status.watchingLogs = watching
        if !available { for session in openSessions() { release(session) } }
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
    }
    /// A baseline replay ends with its open turns either confirmed by a
    /// live lock holder or marked unconfirmed, like a stopped Harness.
    mutating func finalizeHistoricalBaseline(live: Set<String>) {
        for key in historicalRunning {
            guard let session = sessions[key]?.threadID, [.running, .waitingForInput].contains(sessions[key]!.phase), !live.contains(session) else { continue }
            release(session)
        }
        historicalRunning.removeAll()
    }
    /// An open turn whose writer released the lock has stopped without an end record.
    mutating func expire(candidates: Set<String>, live: Set<String>) {
        for session in candidates.subtracting(live) { release(session) }
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
    }
    private mutating func release(_ session: String) {
        let key = AgentProvider.deepseek.activityID(sessionID: session)
        sessions[key]?.markSourceUnavailable()
        requests = requests.filter { $0.value.threadID != session }
        progress[key]?.calls.removeAll(); progress[key]?.approvals.removeAll(); progress[key]?.turn = nil
    }
    mutating func pruneLedger(now: Date = Date()) { ledger.prune(now: now) }

    mutating func consume(_ record: DeepSeekLogRecord, session: String, attaching: Bool, now: Date = Date()) {
        guard record.at.timeIntervalSince(now) <= 300 else { return }
        let key = AgentProvider.deepseek.activityID(sessionID: session), seconds = record.at.timeIntervalSince1970
        var value = sessions[key] ?? SessionActivity(id: key, project: "DeepSeek", phaseAwareRate: true, provider: .deepseek, sessionID: session)
        var state = progress[key] ?? Progress()
        func event(_ method: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": session, "turnId": state.turnID ?? "", "at": seconds].merging(extra) { _, new in new }
        }
        func metadata(_ fields: [String: Any]) { value.applyRuntime(["method": "metadata", "threadId": session, "at": seconds].merging(fields) { _, new in new }) }
        var lifecycle = true
        switch record.event {
        case .header(let header):
            var fields: [String: Any] = [:]
            if let project = header.project { fields["cwd"] = project }
            if let parent = header.parent { fields["parentThreadId"] = parent }
            metadata(fields); lifecycle = false
        case .title(let title):
            metadata(["name": title]); lifecycle = false
        case let .model(model, effort, reported, provider):
            state.model = model
            if let provider, latestProvider.map({ record.at >= $0.at }) ?? true { latestProvider = (record.at, provider) }
            var fields: [String: Any] = ["model": model]
            if reported { fields["reasoningEffort"] = effort.map { $0 as Any } ?? NSNull() }
            metadata(fields); lifecycle = false
        case .turnStart(let turn):
            let id = String(turn) + "." + String(record.seq ?? Int(seconds * 1000))
            state = Progress(turn: turn, turnID: id, model: state.model)
            requests = requests.filter { $0.value.threadID != session }
            value.applyRuntime(event(attaching ? "turn/attached" : "turn/started"))
        case let .stepStart(turn, step):
            guard turn == state.turn else { break }
            state.requestAt = record.at
            value.applyRuntime(event("item/started", ["itemId": "step-\(step)", "itemType": "reasoning", "hasText": false]))
        case .response(let response):
            guard response.turn == state.turn, let turn = state.turnID else { break }
            if let usage = response.usage {
                let id = session + ":" + String(record.seq ?? Int(seconds * 1000))
                if let cost = DeepSeekPricing.cost(model: response.model ?? state.model, usage: usage, at: record.at) {
                    state.cost += cost; ledger.record(id: id, at: record.at, cost: cost)
                } else { state.costKnown = false }
                if state.costKnown { value.setTurnCost(state.cost, turnID: turn) }
                if let start = state.requestAt, let end = response.lastChunkAt, end > start,
                   let sample = ResponsePerformance(responseID: id, turnID: turn, outputTokens: usage.output,
                       startedAt: start, completedAt: end, source: .requestUsage) {
                    let first = state.measuredLatency ? nil : response.firstChunkAt.flatMap { $0 >= start && $0 <= end ? $0 : nil }
                    if let update = SessionPerformanceUpdate(id: key, turnID: turn, response: sample,
                        firstTokenLatency: first.map { $0.timeIntervalSince(start) }, firstTokenReportedAt: first) {
                        update.apply(to: &value); metrics[key] = update
                        if first != nil { state.measuredLatency = true }
                    }
                }
            }
            state.requestAt = nil
            if response.toolCalls == 0, response.hasText {
                value.applyRuntime(event("item/started", ["itemId": "step-\(response.step)", "itemType": "agentMessage", "hasText": false]))
            }
        case let .toolCall(turn, call, kind):
            guard turn == state.turn else { break }
            if state.calls.count < 128 { state.calls[call] = kind }
            value.applyRuntime(event("item/started", ["itemId": call, "itemType": "commandExecution"]))
            if kind == .question { ask(.input, session: session, item: call, at: record.at, value: &value, event: event) }
        case .toolResult(let call):
            guard state.calls.removeValue(forKey: call) != nil else { break }
            requests.removeValue(forKey: key + ":" + call)
            value.applyRuntime(event("item/completed", ["itemId": call, "itemType": "commandExecution"]))
            settleWaiting(session: session, value: &value, event: event)
        case let .approvalAsked(id, _):
            guard state.turn != nil, state.approvals.count < 64 else { break }
            state.approvals.insert(id)
            ask(.approval, session: session, item: "approval-" + id, at: record.at, value: &value, event: event)
        case .approvalDecided(let id):
            guard state.approvals.remove(id) != nil else { break }
            requests.removeValue(forKey: key + ":approval-" + id)
            settleWaiting(session: session, value: &value, event: event)
        case let .turnEnd(turn, outcome):
            guard turn == state.turn else { break }
            value.applyRuntime(event("turn/completed", ["status": outcome == .completed ? "completed" : outcome == .failed ? "failed" : "interrupted"]))
            requests = requests.filter { $0.value.threadID != session }
            state.turn = nil; state.calls.removeAll(); state.approvals.removeAll(); state.requestAt = nil
        }
        if lifecycle {
            if attaching {
                value.suppressHistoricalCompletionNotifications()
                if [.running, .waitingForInput].contains(value.phase) { historicalRunning.insert(key) } else { historicalRunning.remove(key) }
            } else { historicalRunning.remove(key) }
            status.notifications += 1
        }
        sessions[key] = value.canonicalized(); progress[key] = state
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
        if sessions.count > 128 {
            for id in sessions.keys.sorted(by: { (sessions[$0]?.lastObserved ?? .distantPast) > (sessions[$1]?.lastObserved ?? .distantPast) }).dropFirst(128) {
                sessions.removeValue(forKey: id); progress.removeValue(forKey: id); metrics.removeValue(forKey: id); historicalRunning.remove(id)
                requests = requests.filter { !$0.key.hasPrefix(id + ":") }
            }
        }
    }

    private mutating func ask(_ kind: PendingAttentionRequest.Kind, session: String, item: String, at date: Date,
                              value: inout SessionActivity, event: (String, [String: Any]) -> [String: Any]) {
        let id = AgentProvider.deepseek.activityID(sessionID: session) + ":" + item
        if requests[id]?.kind != kind {
            requests[id] = PendingAttentionRequest(id: id, threadID: session, sourceHostID: nil, sourceName: nil, kind: kind, detectedAt: date, provider: .deepseek)
        }
        if requests.count > 128, let oldest = requests.min(by: { $0.value.detectedAt < $1.value.detectedAt })?.key { requests.removeValue(forKey: oldest) }
        value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [kind == .approval ? "waitingOnApproval" : "waitingOnUserInput"]]))
    }
    private func settleWaiting(session: String, value: inout SessionActivity, event: (String, [String: Any]) -> [String: Any]) {
        if let pending = requests.values.first(where: { $0.threadID == session }) {
            value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [pending.kind == .approval ? "waitingOnApproval" : "waitingOnUserInput"]]))
        } else { value.applyRuntime(event("thread/status/changed", ["status": "active"])) }
    }
}
