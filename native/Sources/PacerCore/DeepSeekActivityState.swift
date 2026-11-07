import Foundation

/// DeepSeek Harness session-log records mapped onto the shared runtime events.
/// A response is logged when its step ends, so stage, speed and cost settle
/// per step rather than per token.
struct DeepSeekActivityState: Sendable {
    private struct Report: Sendable {
        let step: Int
        let seq: Int
        let percent: Int?
    }
    private struct DeferredEnding: Sendable {
        let attaching: Bool
    }
    private struct Progress: Sendable {
        var turn: Int?
        var turnID: String?
        var startSeq: Int?
        var reportSeq: Int?
        var reports: [String: Report] = [:]
        var nestedQuestions: [String: String] = [:]
        var jobs: Set<String> = []
        var deferredEnding: DeferredEnding?
        var requestAt: Date?
        var measuredLatency = false
        var model: String?
        /// The billing provider of the latest request; only official ones are priced.
        var provider: String?
        var calls: [String: DeepSeekLogEvent.ToolKind] = [:]
        var approvals: Set<String> = []
        var costKnown = true
        var startedAt: Date?
        var endedAt: Date?
    }
    private var sessions: [String: SessionActivity] = [:]
    private var progress: [String: Progress] = [:]
    private var requests: [String: PendingAttentionRequest] = [:]
    private var metrics: [String: SessionPerformanceUpdate] = [:]
    private var historicalRunning: Set<String> = []
    private(set) var ledger = DeepSeekSpendLedger()
    /// Each delegated session's parent, so sub-agent spend counts toward its root task.
    private(set) var parents: [String: String] = [:]
    /// Each session's title, kept after its row is gone so its spend still has a name.
    private(set) var titles: [String: String] = [:]
    private(set) var status = RuntimeStreamStatus()
    /// The billing provider of the newest request, for choosing a balance source.
    private(set) var latestProvider: (at: Date, name: String)?
    /// Settlement and its waking turn are separate appends. Quiet delivery can
    /// settle a job without opening a turn, so the wait must also converge.
    /// The grace runs from when Pacer saw the settlement, never only from its
    /// log time, so a late read cannot end a request before its wake arrives.
    static let wakeGrace: TimeInterval = 10
    /// Deadlines of deferred endings whose background work has settled.
    private var wakeDeadlines: [String: Date] = [:]
    var nextWakeDeadline: Date? { wakeDeadlines.values.min() }
    var activities: [SessionActivity] { sessions.values.map(withTurnCost).sorted { $0.id < $1.id } }
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
        progress[key]?.reports.removeAll(); progress[key]?.jobs.removeAll(); progress[key]?.deferredEnding = nil
        progress[key]?.nestedQuestions.removeAll(); wakeDeadlines[key] = nil
    }

    /// Ends deferred requests whose grace has passed. Returns whether any did.
    @discardableResult mutating func finishSettledWaits(now: Date) -> Bool {
        let due = wakeDeadlines.filter { $0.value <= now }.map(\.key)
        guard !due.isEmpty else { return false }
        for key in due { finishSettledWait(key, now: now) }
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
        return true
    }

    private mutating func finishSettledWait(_ key: String, now: Date) {
        guard let deadline = wakeDeadlines[key], deadline <= now else { return }
        wakeDeadlines[key] = nil
        guard var state = progress[key], let ending = state.deferredEnding,
              let turn = state.turnID, var value = sessions[key], let session = value.threadID else { return }
        state.deferredEnding = nil
        value.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": turn, "status": "completed",
                            "at": deadline.timeIntervalSince1970])
        if ending.attaching { value.suppressHistoricalCompletionNotifications() }
        progress[key] = state; sessions[key] = value
        historicalRunning.remove(key)
        status.notifications += 1
    }
    mutating func pruneLedger(now: Date = Date()) {
        ledger.prune(now: now)
        let named = ledger.taskIDs.union(sessions.values.compactMap(\.threadID))
        titles = titles.filter { named.contains($0.key) }
    }
    static func root(of session: String, parents: [String: String]) -> String {
        var current = session
        for _ in 0..<8 { guard let parent = parents[current], parent != session else { break }; current = parent }
        return current
    }
    /// Keeps own-turn identity when delegated spend replays before its parent.
    private mutating func charge(_ cost: Double, id: String, session: String, turnID: String?, at date: Date) {
        ledger.record(id: id, at: date, cost: cost, task: Self.root(of: session, parents: parents), session: session, turnID: turnID)
    }
    /// Resolve costs when publishing, so a baseline does not rescan its growing
    /// ledger after every response. No source read order is baked into the row.
    private func withTurnCost(_ activity: SessionActivity) -> SessionActivity {
        guard let session = activity.threadID, let state = progress[activity.id], state.costKnown,
              let turn = state.turnID, let start = state.startedAt else { return activity }
        let spend = ledger.turnSpend(session: session, turnID: turn, from: start, through: state.endedAt)
        guard spend.observed else { return activity }
        var value = activity
        value.setTurnCost(spend.total, peak: spend.peak, turnID: turn)
        return value
    }

    mutating func consume(_ record: DeepSeekLogRecord, session: String, attaching: Bool, now: Date = Date()) {
        guard record.at.timeIntervalSince(now) <= 300 else { return }
        let key = AgentProvider.deepseek.activityID(sessionID: session), seconds = record.at.timeIntervalSince1970
        if case .turnStart = record.event { finishSettledWait(key, now: record.at) }
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
            if let parent = header.parent {
                fields["parentThreadId"] = parent
                if parents[session] != parent, parents.count < 1024 || parents[session] != nil {
                    parents[session] = parent
                    ledger.resolveTasks(parents: parents)
                }
            }
            metadata(fields); lifecycle = false
        case .title(let title):
            if titles.count < 1024 || titles[session] != nil { titles[session] = title }
            metadata(["name": title]); lifecycle = false
        case let .model(model, effort, reported, provider):
            state.model = model
            if let provider { state.provider = provider }
            if let provider, latestProvider.map({ record.at >= $0.at }) ?? true { latestProvider = (record.at, provider) }
            var fields: [String: Any] = ["model": model]
            if reported { fields["reasoningEffort"] = effort.map { $0 as Any } ?? NSNull() }
            metadata(fields); lifecycle = false
        case .turnStart(let turn):
            let carried = state.deferredEnding != nil ? value.currentProgress : nil
            let jobs = state.deferredEnding != nil ? state.jobs : []
            let id = String(turn) + "." + String(record.seq ?? Int(seconds * 1000))
            wakeDeadlines[key] = nil
            state = Progress(turn: turn, turnID: id, startSeq: record.seq, jobs: jobs,
                             model: state.model, provider: state.provider, startedAt: record.at)
            requests = requests.filter { $0.value.threadID != session }
            value.applyRuntime(event(attaching ? "turn/attached" : "turn/started"))
            if let carried { value.carryProgress(carried, at: record.at) }
        case let .stepStart(turn, step):
            guard turn == state.turn else { break }
            state.requestAt = record.at
            value.applyRuntime(event("item/started", ["itemId": "step-\(step)", "itemType": "reasoning", "hasText": false]))
        case .response(let response):
            guard response.turn == state.turn, let turn = state.turnID else { break }
            if let usage = response.usage {
                let id = session + ":" + String(record.seq ?? Int(seconds * 1000))
                if DeepSeekPricing.isOfficial(provider: state.provider),
                   let cost = DeepSeekPricing.cost(model: response.model ?? state.model, usage: usage, at: record.at) {
                    charge(cost, id: id, session: session, turnID: state.turnID, at: record.at)
                } else { state.costKnown = false }
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
            if case .search(let name) = kind, DeepSeekPricing.isOfficial(provider: state.provider),
               let cost = DeepSeekPricing.toolCost(name, at: record.at) {
                charge(cost, id: session + ":tool:" + call, session: session, turnID: state.turnID, at: record.at)
            }
            value.applyRuntime(event("item/started", ["itemId": call, "itemType": "commandExecution"]))
            if kind == .question { ask(.input, session: session, item: call, at: record.at, value: &value, event: event) }
        case let .progressCall(turn, step, call, percent):
            lifecycle = false
            guard turn == state.turn, let seq = record.seq, seq > (state.startSeq ?? -1), state.reports.count < 128,
                  state.reports[call] == nil else { break }
            state.reports[call] = Report(step: step, seq: seq, percent: percent)
        case let .nestedProgress(root, percent):
            lifecycle = false
            guard state.turn != nil, state.calls[root] == .program else { break }
            Self.report(percent, record: record, state: &state, value: &value)
        case let .nestedQuestion(root, call, opening):
            guard state.turn != nil, state.calls[root] == .program, let seq = record.seq, seq > (state.startSeq ?? -1) else { break }
            if opening {
                guard state.nestedQuestions.count < 64, state.nestedQuestions[call] == nil else { break }
                state.nestedQuestions[call] = root
                ask(.input, session: session, item: call, at: record.at, value: &value, event: event)
            } else if state.nestedQuestions[call] == root {
                state.nestedQuestions.removeValue(forKey: call)
                requests.removeValue(forKey: key + ":" + call)
                settleWaiting(session: session, value: &value, event: event)
            }
        case .toolResult(let call), .progressAccepted(_, _, let call):
            if let report = state.reports[call] {
                lifecycle = false
                guard let seq = record.seq, seq > report.seq else { break }
                // Any later result settles the call; only a matching acknowledgment reports.
                state.reports.removeValue(forKey: call)
                if case let .progressAccepted(turn, step, _) = record.event, turn == state.turn, step == report.step,
                   let percent = report.percent {
                    Self.report(percent, record: record, state: &state, value: &value)
                }
                break
            }
            guard state.calls.removeValue(forKey: call) != nil else { break }
            requests.removeValue(forKey: key + ":" + call)
            for nested in state.nestedQuestions.keys.filter({ state.nestedQuestions[$0] == call }) {
                requests.removeValue(forKey: key + ":" + nested)
                state.nestedQuestions.removeValue(forKey: nested)
            }
            value.applyRuntime(event("item/completed", ["itemId": call, "itemType": "commandExecution"]))
            settleWaiting(session: session, value: &value, event: event)
        case let .jobStarted(id, owner, root):
            lifecycle = false
            guard owner == session, state.turn != nil, state.calls[root] != nil,
                  let seq = record.seq, seq > (state.startSeq ?? -1), state.jobs.count < 64 else { break }
            state.jobs.insert(id)
        case let .jobSettled(id, owner):
            lifecycle = false
            guard owner == session, state.jobs.remove(id) != nil, state.jobs.isEmpty, state.deferredEnding != nil else { break }
            // A replayed settlement keeps its log time; a live one counts from now.
            let seen = attaching ? record.at : max(record.at, now)
            wakeDeadlines[key] = max(seen, state.endedAt ?? seen).addingTimeInterval(Self.wakeGrace)
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
            if outcome == .completed, !state.jobs.isEmpty {
                if value.phase == .waitingForInput { value.applyRuntime(event("thread/status/changed", ["status": "active"])) }
                value.waitForBackground(kinds: ["job"], wakeups: 0, at: record.at)
                state.deferredEnding = DeferredEnding(attaching: attaching)
            } else {
                value.applyRuntime(event("turn/completed", ["status": outcome == .completed ? "completed" : outcome == .failed ? "failed" : "interrupted"]))
                state.jobs.removeAll()
            }
            requests = requests.filter { $0.value.threadID != session }
            state.turn = nil; state.calls.removeAll(); state.approvals.removeAll(); state.reports.removeAll(); state.nestedQuestions.removeAll(); state.requestAt = nil
            state.endedAt = record.at
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
                wakeDeadlines.removeValue(forKey: id)
                requests = requests.filter { !$0.key.hasPrefix(id + ":") }
            }
        }
    }

    private static func report(_ percent: Int, record: DeepSeekLogRecord, state: inout Progress, value: inout SessionActivity) {
        guard let turn = state.turnID, let seq = record.seq, seq > (state.reportSeq ?? state.startSeq ?? -1) else { return }
        state.reportSeq = seq
        value.reportProgress(percent, at: max(record.at, value.currentProgress?.reportedAt ?? record.at), turnID: turn)
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
