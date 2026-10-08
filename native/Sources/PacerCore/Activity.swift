import Foundation

public enum ActivityPhase: String, Codable, Sendable {
    case running, waitingForInput, completed, interrupted, unknown
    public var label: String {
        switch self {
        case .running: return L10n.text("activity.running_long")
        case .waitingForInput: return L10n.text("activity.waiting_long")
        case .completed: return L10n.text("activity.idle")
        case .interrupted: return L10n.text("activity.interrupted")
        case .unknown: return L10n.text("activity.unknown")
        }
    }
}

public enum ActivityStage: String, Sendable {
    case starting, thinking, tool, responding
    public var label: String {
        switch self {
        case .starting: return L10n.text("activity.starting")
        case .thinking: return L10n.text("activity.thinking")
        case .tool: return L10n.text("activity.tool")
        case .responding: return L10n.text("activity.responding")
        }
    }
}

public struct SessionActivity: Equatable, Sendable, Identifiable {
    public private(set) var id: String
    public let sourceHost: String?
    public let sourceHostID: String?
    public private(set) var title: String?
    private(set) var titleWasExplicitlyCleared = false
    public var project: String
    public private(set) var threadID: String?
    public var threadURL: URL? {
        guard let threadID else { return nil }
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/" + threadID
        if let sourceHostID {
            let prefix = "remote-ssh-discovered:"
            guard sourceHostID.hasPrefix(prefix),
                  String(sourceHostID.dropFirst(prefix.count)).range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil else { return nil }
            url.queryItems = [URLQueryItem(name: "hostId", value: sourceHostID)]
        }
        return url.url
    }
    public private(set) var phase: ActivityPhase = .unknown
    public private(set) var turnID: String?
    public private(set) var turnStartedAt: Date?
    public private(set) var lastObserved: Date?
    public private(set) var phaseChangedAt: Date?
    public private(set) var stage: ActivityStage = .starting
    public private(set) var turnFailed = false
    public private(set) var waitingForApproval = false
    public private(set) var modelName: String?
    public private(set) var isInternalReview = false
    public private(set) var parentThreadID: String?
    public struct SubagentEvidence: Equatable, Sendable {
        public let parentThreadID: String
        public let state: String
        public let observedAt: Date
    }
    public private(set) var subagentStates: [String: SubagentEvidence] = [:]
    private var projectedRate = false
    mutating func applySubagentEvidence(_ evidence: SubagentEvidence) {
        guard !hasLiveEvidence, !isInternalReview, threadID != evidence.parentThreadID,
              parentThreadID == nil || parentThreadID == evidence.parentThreadID else { return }
        updateParent(evidence.parentThreadID)
        if evidence.state == "completed", turnStartedAt.map({ $0 > evidence.observedAt }) != true {
            if ![.completed, .interrupted].contains(phase) { phaseChangedAt = evidence.observedAt }
            phase = .completed; projectedRate = true
        } else if evidence.state == "running" {
            projectedRate = lastMeasuredRate.map { $0.reportedAt < evidence.observedAt } ?? true
            if ![.running, .waitingForInput].contains(phase) {
                phase = .running; stage = .starting; phaseChangedAt = evidence.observedAt
                lastObserved = evidence.observedAt
            }
        }
    }
    private var lastMeasuredRate: OutputEstimate?
    private var lastMeasuredTurnID: String?
    private var lastMeasuredExact = false
    mutating func updateParent(_ value: String?) {
        guard let value, let id = UUID(uuidString: value)?.uuidString.lowercased(), id != threadID else { return }
        parentThreadID = id
    }
    static func parentID(in metadata: [String: Any]) -> String? {
        let source = metadata["source"] as? [String: Any]
        let sub = (source?["subAgent"] ?? source?["subagent"]) as? [String: Any]
        let spawn = (sub?["thread_spawn"] ?? sub?["threadSpawn"]) as? [String: Any]
        let raw = (metadata["parentThreadId"] ?? metadata["parent_thread_id"] ?? spawn?["parent_thread_id"] ?? spawn?["parentThreadId"]) as? String
        return raw.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
    }
    private mutating func rememberRate() {
        if let sample = responsePerformance {
            if lastMeasuredRate == nil || sample.completedAt >= lastMeasuredRate!.reportedAt {
                lastMeasuredRate = OutputEstimate(value: sample.tokensPerSecond, reportedAt: sample.completedAt, isFresh: true)
                lastMeasuredTurnID = sample.turnID; lastMeasuredExact = true
            }
        } else if let at = lastObserved,
                  let sample = (phaseAwareRate ? generationRate.estimate(at: at) : outputRate.estimate(at: at)),
                  sample.value > 0, sample.value.isFinite,
                  lastMeasuredRate == nil || sample.reportedAt > lastMeasuredRate!.reportedAt {
            lastMeasuredRate = sample; lastMeasuredTurnID = turnID; lastMeasuredExact = false
        }
    }
    /// Display continuity is independent of the new turn's accounting baseline.
    public func displayedOutputEstimate(at now: Date) -> OutputEstimate? {
        guard let sample = lastMeasuredRate, now >= sample.reportedAt else { return nil }
        let fresh = !projectedRate && lastMeasuredTurnID == turnID && stage != .tool &&
            !performanceMeter.hasPendingOutput && now < sample.expiresAt
        return OutputEstimate(value: sample.value, reportedAt: sample.reportedAt, isFresh: fresh)
    }
    public func displayedRateIsEstimated(at now: Date) -> Bool {
        !lastMeasuredExact || displayedOutputEstimate(at: now)?.isFresh != true
    }
    public mutating func mergeDisplayMetadata(from other: SessionActivity) {
        guard canonicalized().id == other.canonicalized().id else { return }
        if parentThreadID == nil { parentThreadID = other.parentThreadID }
        if turnID == other.turnID, subagentStates.isEmpty { subagentStates = other.subagentStates }
        if let sample = other.lastMeasuredRate,
           lastMeasuredRate == nil || sample.reportedAt > lastMeasuredRate!.reportedAt ||
            (sample.reportedAt == lastMeasuredRate!.reportedAt && other.lastMeasuredExact && !lastMeasuredExact) {
            lastMeasuredRate = sample; lastMeasuredTurnID = other.lastMeasuredTurnID; lastMeasuredExact = other.lastMeasuredExact
        }
    }
    private var waitingCallID: String?
    private var toolCalls: Set<String> = []
    private var outputRate = OutputRate()
    private var generationRate = GenerationRate()
    private var performanceMeter = ResponsePerformanceMeter()
    public var responsePerformance: ResponsePerformance? { performanceMeter.latest }
    public var firstTokenLatency: TimeInterval? { performanceMeter.firstTokenLatency }
    mutating func mergePerformance(from other: SessionActivity) {
        guard canonicalized().id == other.canonicalized().id, turnID == other.turnID else { return }
        performanceMeter.merge(from: other.performanceMeter)
        rememberRate()
    }
    mutating func applyPerformance(_ update: SessionPerformanceUpdate) {
        guard canonicalized().id == update.id, turnID == update.turnID else { return }
        performanceMeter.apply(sample: update.response, latency: update.firstTokenLatency)
        rememberRate()
    }
    private var phaseAwareRate: Bool
    private var liveItems: Set<String> = []
    public private(set) var hasLiveEvidence = false
    public private(set) var liveTurnStarted = false
    private var liveStatusOnly = false
    private var retiredTurns: [String] = []
    private var lastIdentifiedTurn: String?
    public func canonicalized() -> SessionActivity {
        guard let threadID else { return self }
        var value = self
        value.id = (sourceHostID ?? "local") + ":" + threadID
        return value
    }

    public init(id: String, project: String = L10n.text("activity.local_task"), sourceHost: String? = nil, sourceHostID: String? = nil, phaseAwareRate: Bool = false) {
        self.id = id
        self.phaseAwareRate = phaseAwareRate
        self.sourceHost = sourceHost
        self.sourceHostID = sourceHostID
        self.project = project
        // Canonical host IDs may contain dots (SSH aliases/IP addresses). Do
        // not strip a supposed file extension before checking their UUID tail.
        threadID = (UUID(uuidString: String(id.suffix(36))) ??
            UUID(uuidString: String((id as NSString).deletingPathExtension.suffix(36))))?.uuidString.lowercased()
    }

    mutating func updateTitle(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed?.isEmpty == false ? String(trimmed!.prefix(240)) : nil
        titleWasExplicitlyCleared = false
    }

    mutating func updateName(_ value: String?) {
        updateTitle(value)
        titleWasExplicitlyCleared = title == nil
    }

    public func observedPhase(at now: Date = Date()) -> ActivityPhase {
        if [.completed, .interrupted].contains(phase) { return phase }
        guard lastObserved != nil else { return .unknown }
        // A long tool call or sparse counter reports do not end an observed turn.
        return phase
    }
    public func tokensPerSecond(at now: Date) -> Double? {
        guard observedPhase(at: now) == .running else { return nil }
        return outputEstimate(at: now).flatMap { $0.isFresh ? $0.value : nil }
    }
    public func outputEstimate(at now: Date) -> OutputEstimate? {
        guard phase == .running else { return nil }
        let legacy = phaseAwareRate ? generationRate.estimate(at: now) : outputRate.estimate(at: now)
        if legacy?.value == 0 { return legacy }
        if let sample = responsePerformance, now >= sample.completedAt {
            return OutputEstimate(value: sample.tokensPerSecond, reportedAt: sample.completedAt,
                isFresh: now.timeIntervalSince(sample.completedAt) < OutputEstimate.freshnessInterval)
        }
        return legacy
    }
    public var rateExpiresAt: Date? {
        guard phase == .running else { return nil }
        if let sample = responsePerformance { return sample.completedAt.addingTimeInterval(OutputEstimate.freshnessInterval) }
        return phaseAwareRate ? generationRate.expiresAt : outputRate.expiresAt
    }
    public func detail(at now: Date) -> String {
        if turnFailed, phase == .interrupted { return L10n.text("activity.failed") }
        if observedPhase(at: now) == .unknown, phase == .waitingForInput { return L10n.text("activity.last_waiting") }
        if observedPhase(at: now) == .unknown, phase == .running, stage == .tool { return L10n.text("activity.last_tool") }
        return observedPhase(at: now) == .running ? stage.label : observedPhase(at: now).label
    }

    public mutating func consume(_ line: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = value["payload"] as? [String: Any] else { return }
        defer { rememberRate() }
        if value["type"] as? String == "session_meta" {
            if let title = payload["title"] as? String { updateTitle(title) }
            updateParent(Self.parentID(in: payload))
            let source = payload["source"] as? [String: Any]
            let rawSubagent = source?["subagent"] ?? source?["subAgent"]
            let subagent = rawSubagent as? [String: Any]
            let role = (subagent?["other"] as? String)?.lowercased()
            let threadSource = (payload["thread_source"] as? String)?.lowercased()
            isInternalReview = isInternalReview || rawSubagent as? String == "review" || subagent?["review"] != nil ||
                ["guardian", "auto_review", "autoreview"].contains(role ?? "") ||
                ["guardian_review", "auto_review", "autoreview"].contains(threadSource ?? "")
            if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            if let id = payload["id"] as? String, let uuid = UUID(uuidString: id) { threadID = uuid.uuidString.lowercased() }
            return
        }
        if value["type"] as? String == "turn_context" {
            guard let timestamp = value["timestamp"] as? String, let date = Self.parseDate(timestamp),
                  date >= (lastObserved ?? .distantPast) else { return }
            modelName = payload["model"] as? String ?? modelName
            if modelName?.lowercased().hasPrefix("codex-auto-review") == true { isInternalReview = true }
            // A current turn context is an explicit anchor when the start lies
            // outside the initial tail, or when the app attached mid-turn.
            if let contextTurn = payload["turn_id"] as? String, contextTurn != turnID {
                beginTurn(contextTurn, at: date)
            }
            return
        }
        if value["type"] as? String == "token_usage_record" {
            guard payload["thread_id"] as? String == threadID,
                  let turn = payload["turn_id"] as? String, turn == turnID,
                  let id = payload["response_id"] as? String, id.count <= 256,
                  let usage = payload["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int,
                  let stamp = value["timestamp"] as? String, let date = Self.parseDate(stamp) else { return }
            performanceMeter.observeRequest(id: id, turn: turn, output: output,
                reasoning: usage["reasoning_output_tokens"] as? Int, at: date)
            return // Accounting cannot create activity, change state or extend retention.
        }
        guard ["event_msg", "response_item"].contains(value["type"] as? String ?? ""),
              let timestamp = value["timestamp"] as? String,
              let date = Self.parseDate(timestamp),
              date >= (lastObserved ?? .distantPast) else { return }
        let kind = payload["type"] as? String
        let eventTurn = payload["turn_id"] as? String
        if ["task_complete", "turn_aborted"].contains(kind ?? ""), value["type"] as? String == "event_msg" {
            // Without an observed start/context there is no current turn to end.
            guard let turnID, eventTurn == turnID else { return }
        }
        lastObserved = date
        if value["type"] as? String == "response_item" {
            consumeResponse(payload, kind: kind, at: date)
            return
        }
        switch kind {
        case "task_started":
            beginTurn(eventTurn, at: date)
        case "task_complete", "turn_aborted":
            retireTurn(turnID)
            phase = kind == "turn_aborted" ? .interrupted : .completed
            turnFailed = false; waitingForApproval = false
            waitingCallID = nil
            toolCalls.removeAll()
            outputRate.finishTurn(); generationRate.finish(); liveItems.removeAll()
            performanceMeter.finish()
            phaseChangedAt = date
        case "token_count":
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any],
               let output = total["output_tokens"] as? Int {
                outputRate.observe(totalOutput: output, at: date)
                generationRate.observe(total: output, at: date)
                let last = info["last_token_usage"] as? [String: Any]
                performanceMeter.observeRuntime(total: output, last: last?["output_tokens"] as? Int,
                    reasoning: last?["reasoning_output_tokens"] as? Int, at: date)
            }
        default: break
        }
    }

    private mutating func beginTurn(_ id: String?, at date: Date, observed: Bool = true) {
        rememberRate()
        // An unknown ID during reconnect does not prove the old turn ended.
        if let id { identifyTurn(id) }
        subagentStates = [:]; projectedRate = false
        hasLiveEvidence = false; liveTurnStarted = false; liveStatusOnly = false
        turnID = id
        turnStartedAt = date
        phase = .running
        turnFailed = false; waitingForApproval = false
        stage = .starting
        lastObserved = date
        waitingCallID = nil
        toolCalls.removeAll()
        outputRate.startTurn(at: date)
        generationRate.start(); liveItems.removeAll()
        performanceMeter.start(turnID: id, at: date, observed: observed)
        phaseChangedAt = date
    }

    private mutating func retireTurn(_ id: String?) {
        guard let id, !retiredTurns.contains(id) else { return }
        retiredTurns.append(id)
        if retiredTurns.count > 64 { retiredTurns.removeFirst(retiredTurns.count - 64) }
    }

    private mutating func identifyTurn(_ id: String) {
        if id != lastIdentifiedTurn { retireTurn(lastIdentifiedTurn) }
        lastIdentifiedTurn = id; turnID = id
        performanceMeter.identify(id)
    }

    /// Retain provenance while rejecting lifecycle/rate assumptions across a gap.
    mutating func markDiscontinuity() {
        phase = .unknown
        turnFailed = false; waitingForApproval = false
        turnID = nil
        turnStartedAt = nil
        lastObserved = nil
        phaseChangedAt = nil
        waitingCallID = nil
        toolCalls.removeAll()
        outputRate = OutputRate(); generationRate = GenerationRate(); liveItems.removeAll(); hasLiveEvidence = false
        performanceMeter = ResponsePerformanceMeter()
    }

    mutating func markUnconfirmed() {
        phase = .unknown
        waitingForApproval = false
        outputRate.finishTurn(); generationRate.finish(); liveItems.removeAll(); hasLiveEvidence = false; liveTurnStarted = false; liveStatusOnly = false
    }

    mutating func markPartialRate() {
        guard phaseAwareRate else { return }
        let date = lastObserved ?? Date()
        generationRate.start()
        performanceMeter.start(turnID: turnID, at: date, observed: false)
        generationRate.setWaiting(!toolCalls.isEmpty, at: date)
    }

    private mutating func observeWork(at date: Date) {
        if [.completed, .interrupted, .unknown].contains(phase) {
            // Fresh reasoning/calls prove activity, but do not identify a turn.
            beginTurn(phase == .unknown ? turnID : nil, at: date, observed: false)
        }
    }

    private mutating func consumeResponse(_ payload: [String: Any], kind: String?, at date: Date) {
        switch kind {
        case "function_call", "custom_tool_call":
            guard let callID = payload["call_id"] as? String else { return }
            observeWork(at: date)
            performanceMeter.modelOutput(at: date, textDelta: false)
            if toolCalls.count < 64 { toolCalls.insert(callID) }
            generationRate.setWaiting(true, at: date)
            performanceMeter.setWaiting(true, at: date)
            let name = payload["name"] as? String ?? ""
            // The async input tool returns immediately and does not pause the task.
            if name == "request_user_input" || name.hasSuffix(".request_user_input") {
                waitingCallID = callID
                phase = .waitingForInput
                waitingForApproval = false
                phaseChangedAt = date
            } else if phase == .running { stage = .tool }
        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String else { return }
            guard toolCalls.contains(callID) || waitingCallID == callID else { return }
            toolCalls.remove(callID)
            if toolCalls.isEmpty { generationRate.setWaiting(false, at: date); performanceMeter.inputBoundary(at: date) }
            if waitingCallID == callID {
                waitingCallID = nil
                phase = .running
                waitingForApproval = false
                phaseChangedAt = date
            }
            if phase == .running { stage = toolCalls.isEmpty ? .thinking : .tool }
        case "reasoning":
            observeWork(at: date)
            performanceMeter.modelOutput(at: date, textDelta: false)
            if phase == .running && (toolCalls.isEmpty || phaseAwareRate) { stage = .thinking }
            if phaseAwareRate { generationRate.setWaiting(false, at: date) }
        case "message":
            if payload["role"] as? String == "assistant", payload["phase"] as? String == "commentary" {
                observeWork(at: date)
            }
            if phase == .running, payload["role"] as? String == "assistant" {
                performanceMeter.modelOutput(at: date, textDelta: false)
                stage = .responding
                if phaseAwareRate { generationRate.setWaiting(false, at: date) }
            }
        default: break
        }
    }

    /// Accept only the small, sanitized event envelope emitted by our probe.
    mutating func consumeLive(_ event: [String: Any]) {
        guard let method = event["method"] as? String,
              let remoteID = event["threadId"] as? String, remoteID == threadID,
              let seconds = event["at"] as? Double, seconds.isFinite else { return }
        let date = Date(timeIntervalSince1970: seconds)
        defer { rememberRate() }
        if method == "subagents/updated" {
            guard event["turnId"] as? String == turnID, let states = event["states"] as? [String: String], states.count <= 64,
                  let parent = threadID else { return }
            var next: [String: SubagentEvidence] = [:]
            for (raw, state) in states {
                guard let id = UUID(uuidString: raw)?.uuidString.lowercased(), id != parent,
                      ["running", "completed"].contains(state) else { continue }
                next[id] = subagentStates[id].flatMap { $0.state == state ? $0 : nil } ?? SubagentEvidence(parentThreadID: parent, state: state, observedAt: date)
            }
            subagentStates = next
            return
        }
        if method == "thread/name/updated" {
            guard event["name"] is String || event["name"] is NSNull else { return }
            updateName(event["name"] as? String)
            return
        }
        if method == "metadata" {
            updateParent(Self.parentID(in: event))
            if let name = event["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateTitle(name)
            }
            modelName = event["model"] as? String ?? modelName
            if let cwd = event["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            let source = (event["source"] as? String ?? "").lowercased().replacingOccurrences(of: "_", with: "")
            isInternalReview = isInternalReview || ["guardianreview", "autoreview", "subagentreview"].contains(source) ||
                modelName?.lowercased().hasPrefix("codex-auto-review") == true
            return
        }
        if method == "thread/observed" {
            // The remote runtime's metadata read confirms activity even during
            // a quiet tool/sleep, before this subscriber sees an item or turn ID.
            guard event["status"] as? String == "active" else { return }
            if !hasLiveEvidence || [.completed, .interrupted, .unknown].contains(phase) {
                beginTurn(nil, at: date, observed: false); generationRate.start()
                liveStatusOnly = true
            }
            hasLiveEvidence = true; liveTurnStarted = true; lastObserved = date
            let flags = event["flags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") {
                phase = .waitingForInput; waitingForApproval = flags.contains("waitingOnApproval")
                generationRate.setWaiting(true, at: date)
            } else if phase == .waitingForInput { phase = .running; waitingForApproval = false }
            return
        }
        if method == "thread/status/changed" {
            let status = event["status"] as? String
            // Loading/error status cannot revoke an authoritative turn ending.
            guard ![.completed, .interrupted].contains(phase) else { return }
            if ["notLoaded", "systemError"].contains(status ?? "") {
                markUnconfirmed(); lastObserved = date; phaseChangedAt = date
            }
            // Idle status alone cannot prove that a particular turn completed.
            if status == "active", let flags = event["flags"] as? [String],
               flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput"), turnID != nil {
                phase = .waitingForInput; phaseChangedAt = date
                waitingForApproval = flags.contains("waitingOnApproval")
                generationRate.setWaiting(true, at: date)
            } else if status == "active", phase == .waitingForInput {
                phase = .running; phaseChangedAt = date
                waitingForApproval = false
                if liveItems.isEmpty { generationRate.setWaiting(false, at: date) }
            }
            return
        }
        guard ["turn/started", "turn/attached", "turn/completed", "item/started", "item/completed", "thread/tokenUsage/updated",
               "item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta"].contains(method),
              let eventTurn = event["turnId"] as? String, !eventTurn.isEmpty else { return }
        guard !retiredTurns.contains(eventTurn) else { return }
        if method == "turn/completed" {
            guard turnID == eventTurn || (turnID == nil && liveStatusOnly), [.running, .waitingForInput].contains(phase) else { return }
            identifyTurn(eventTurn); liveStatusOnly = false
            retireTurn(eventTurn)
            phase = event["status"] as? String == "completed" ? .completed : .interrupted
            turnFailed = event["status"] as? String == "failed"; waitingForApproval = false
            phaseChangedAt = date; lastObserved = date; hasLiveEvidence = true
            generationRate.finish(); outputRate.finishTurn(); liveItems.removeAll(); toolCalls.removeAll()
            performanceMeter.finish()
            return
        }
        if !["turn/started", "turn/attached"].contains(method), turnID == eventTurn, [.completed, .interrupted].contains(phase) { return }
        if method == "thread/tokenUsage/updated" {
            // Delayed accounting from another turn cannot start or switch the
            // current task. A metadata-confirmed active turn may adopt its ID.
            guard [.running, .waitingForInput].contains(phase),
                  turnID == eventTurn || (turnID == nil && liveStatusOnly) else { return }
        }
        if ["turn/started", "turn/attached"].contains(method) {
            let retained = method == "turn/attached" && turnID == eventTurn ? performanceMeter : nil
            let originalStart = retained == nil ? nil : turnStartedAt
            let start = originalStart ?? (event["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? date
            beginTurn(eventTurn, at: start <= date ? start : date, observed: method == "turn/started")
            if let retained { performanceMeter.merge(from: retained) }
            if method == "turn/attached" { generationRate.start() }
            liveTurnStarted = true; liveStatusOnly = false
        } else if turnID == nil, liveStatusOnly, hasLiveEvidence, liveTurnStarted,
                  [.running, .waitingForInput].contains(phase) {
            // Runtime metadata already confirmed this new turn. Its first
            // item only supplies the missing ID; restarting the accumulator
            // here would erase that evidence and let an older completed log
            // override every subsequent item and the ending.
            identifyTurn(eventTurn); liveStatusOnly = false
        } else if turnID != eventTurn || !hasLiveEvidence {
            // Attaching halfway through a request must not divide all of that
            // request's tokens by the short period since we attached.
            beginTurn(eventTurn, at: date, observed: false)
            generationRate.start()
            liveStatusOnly = false
        } else if [.completed, .interrupted].contains(phase) { return }
        hasLiveEvidence = true; phaseAwareRate = true; lastObserved = max(date, lastObserved ?? date)
        let kind = RuntimeItemKind.normalized(event["itemType"] as? String ?? "")
        let modelItem = ["reasoning", "agentMessage", "plan"].contains(kind)
        let toolItem = RuntimeItemKind.isTool(kind)
        if method == "item/completed", modelItem { performanceMeter.modelOutput(at: date, textDelta: false) }
        if method == "item/started", let id = event["itemId"] as? String {
            if toolItem {
                if liveItems.count < 128 { liveItems.insert(id) }
                generationRate.setWaiting(true, at: date); phase = .running; stage = .tool
                performanceMeter.modelOutput(at: date, textDelta: false)
                performanceMeter.setWaiting(true, at: date)
            } else if modelItem {
                if event["hasText"] as? Bool == true { performanceMeter.modelOutput(at: date, textDelta: true) }
                generationRate.setWaiting(false, at: date); phase = .running
                stage = kind == "reasoning" ? .thinking : .responding
            }
        } else if method == "item/completed", let id = event["itemId"] as? String, liveItems.remove(id) != nil {
            if liveItems.isEmpty {
                generationRate.setWaiting(false, at: date); phase = .running; stage = .thinking
                performanceMeter.inputBoundary(at: date)
            }
        } else if method.hasSuffix("/delta") || method.contains("TextDelta") || method.contains("textDelta") {
            let first = (event["firstDeltaAt"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? date
            if event["hasText"] as? Bool == true {
                performanceMeter.modelOutput(at: first, textDelta: true)
                if first != date { performanceMeter.modelOutput(at: date, textDelta: false) }
            }
            generationRate.setWaiting(false, at: date); phase = .running
            stage = method.contains("reasoning") ? .thinking : .responding
        } else if method == "thread/tokenUsage/updated", let total = event["outputTokens"] as? Int {
            generationRate.observe(total: total, at: date)
            performanceMeter.observeRuntime(total: total, last: event["lastOutputTokens"] as? Int,
                reasoning: event["lastReasoningTokens"] as? Int, at: date, cached: event["cachedUsage"] as? Bool == true)
        }
    }

    private static let dates = LogDateParser()
    private static func parseDate(_ string: String) -> Date? { dates.parse(string) }
}

/// Reads recent files and resumed sessions from the read-only Codex index.
/// Startup and catch-up reads are bounded; conversation text is never retained.
public actor LocalActivityReader {
    private struct Cursor {
        var offset: UInt64
        var fragment: Data
        var activity: SessionActivity
        var identity: UInt64
    }
    private var cursors: [URL: Cursor] = [:]
    private var metadata: [URL: (identity: UInt64, activity: SessionActivity)] = [:]
    private let maxFiles = 16
    private let maxBytes = 128 * 1024
    private let startupBytes = 512 * 1024

    public init() {}
    public func reset() { cursors.removeAll(); metadata.removeAll() }

    public func read(home: URL, now: Date = Date(), phaseAwareRate: Bool = false,
                     excludingThreads: Set<String> = [], includeCoveredMetrics: Bool = false, metricsOnly: Bool = false,
                     subagentStates: [String: SessionActivity.SubagentEvidence] = [:]) -> (activities: [SessionActivity], watchURLs: [URL]) {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now)!]
        var files: [(URL, Date)] = []
        var watchURLs: [URL] = []
        let manager = FileManager.default
        if !metricsOnly { for day in days {
            let directory = home.appendingPathComponent("sessions/\(formatter.string(from: day))")
            var existing = directory
            while !manager.fileExists(atPath: existing.path), existing.path != home.path {
                existing.deleteLastPathComponent()
            }
            if manager.fileExists(atPath: existing.path) { watchURLs.append(existing) }
            let entries = (try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((file, date))
            }
        }
        } else {
            files = cursors.keys.map { ($0, cursors[$0]?.activity.lastObserved ?? .distantPast) }
        }
        let indexed = metricsOnly ? [] : SessionIndex.entries(home: home)
        for entry in indexed {
            let file = entry.url
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if !files.contains(where: { $0.0 == file }) { files.append((file, date)) }
            watchURLs.append(file.deletingLastPathComponent())
        }
        for file in Array(cursors.keys) {
            if let id = cursors[file]?.activity.threadID, let evidence = subagentStates[id] { cursors[file]?.activity.applySubagentEvidence(evidence) }
        }
        var unavailable: [SessionActivity] = []
        for (file, cursor) in cursors where !manager.isReadableFile(atPath: file.path) {
            var activity = cursor.activity
            if ![.completed, .interrupted].contains(activity.phase) { activity.markUnconfirmed() }
            unavailable.append(activity)
            cursors.removeValue(forKey: file)
            metadata.removeValue(forKey: file)
        }
        for (file, cursor) in cursors where [.running, .waitingForInput].contains(cursor.activity.phase) && !files.contains(where: { $0.0 == file }) {
            files.append((file, cursor.activity.lastObserved ?? .distantPast))
        }
        // Reviews must not consume the user-task discovery slots.
        func covered(_ file: URL) -> Bool {
            excludingThreads.contains(String(file.deletingPathExtension().lastPathComponent.suffix(36)).lowercased())
        }
        var selected = metricsOnly ? Array(cursors.keys) : cursors.filter {
            [.running, .waitingForInput].contains($0.value.activity.phase) && !covered($0.key)
        }.map(\.key)
        let candidates = Array(files.sorted { $0.1 > $1.1 }.prefix(256).map(\.0))
        metadata = metadata.filter { candidates.contains($0.key) }
        if !metricsOnly { for file in candidates {
            guard selected.count < maxFiles else { break }
            let id = String(file.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
            if excludingThreads.contains(id) { continue }
            let identity = ((try? manager.attributesOfItem(atPath: file.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if metadata[file]?.identity != identity {
                var activity = SessionActivity(id: file.lastPathComponent, phaseAwareRate: phaseAwareRate)
                if let handle = try? FileHandle(forReadingFrom: file) {
                    defer { try? handle.close() }
                    // Session metadata can include a long instruction block.
                    var header = Data()
                    while header.count < 1024 * 1024 {
                        guard let chunk = try? handle.read(upToCount: 32768), !chunk.isEmpty else { break }
                        header.append(chunk)
                        if let end = header.firstIndex(of: 10) { activity.consume(header.prefix(upTo: end)); break }
                    }
                }
                metadata[file] = (identity, activity)
            }
            if metadata[file]?.activity.isInternalReview != true, !selected.contains(file) { selected.append(file) }
        }
        }
        // Keep covered baselines for reconnects without spending fallback slots.
        if includeCoveredMetrics && !metricsOnly {
            let metricFiles = candidates.filter(covered).prefix(32)
            selected += metricFiles.filter { !selected.contains($0) }
        }
        if !metricsOnly { cursors = cursors.filter { selected.contains($0.key) || covered($0.key) } }
        for file in selected {
            let id = String(file.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
            if excludingThreads.contains(id), !includeCoveredMetrics { continue }
            guard let attributes = try? manager.attributesOfItem(atPath: file.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                if var activity = cursors.removeValue(forKey: file)?.activity {
                    if ![.completed, .interrupted].contains(activity.phase) { activity.markUnconfirmed() }
                    unavailable.append(activity)
                }
                metadata.removeValue(forKey: file)
                continue
            }
            let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if var existing = cursors[file], existing.identity == identity, existing.offset == size {
                if let entry = indexed.first(where: { $0.url == file }) { existing.activity.updateTitle(entry.title); existing.activity.updateParent(entry.parentThreadID); cursors[file] = existing }
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            var cursor = cursors[file]
            if cursor == nil || cursor!.offset > size || cursor!.identity != identity {
                var activity = metadata[file]?.activity ?? SessionActivity(id: file.lastPathComponent, phaseAwareRate: phaseAwareRate)
                if let anchor = latestTurnAnchor(handle: handle, size: size) { activity.consume(anchor) }
                cursor = Cursor(offset: 0, fragment: Data(), activity: activity, identity: identity)
            }
            guard var current = cursor else { continue }
            var dropPartial = false
            let budget = current.offset == 0 ? startupBytes : maxBytes
            if size - current.offset > UInt64(budget) {
                current.offset = size - UInt64(budget)
                current.fragment.removeAll()
                if cursors[file] != nil {
                    current.activity.markDiscontinuity()
                    if let anchor = latestTurnAnchor(handle: handle, size: size) { current.activity.consume(anchor) }
                }
                dropPartial = true
                current.activity.markPartialRate()
            }
            do {
                try handle.seek(toOffset: current.offset)
                let data = try handle.read(upToCount: budget) ?? Data()
                current.offset += UInt64(data.count)
                current.fragment.append(data)
                if dropPartial, let end = current.fragment.firstIndex(of: 10) {
                    current.fragment.removeSubrange(...end)
                }
                while let end = current.fragment.firstIndex(of: 10) {
                    current.activity.consume(current.fragment.prefix(upTo: end))
                    current.fragment.removeSubrange(...end)
                }
                if current.fragment.count > maxBytes { current.fragment.removeAll() }
                if let entry = indexed.first(where: { $0.url == file }) { current.activity.updateTitle(entry.title); current.activity.updateParent(entry.parentThreadID) }
                if let id = current.activity.threadID, let evidence = subagentStates[id] { current.activity.applySubagentEvidence(evidence) }
                if cursors[file] == nil, [.running, .waitingForInput].contains(current.activity.phase),
                   now.timeIntervalSince(current.activity.lastObserved ?? .distantPast) > 900 { current.activity.markUnconfirmed() }
                if current.activity.isInternalReview {
                    metadata[file] = (identity, current.activity)
                    cursors.removeValue(forKey: file)
                } else { cursors[file] = current }
            } catch {
                if ![.completed, .interrupted].contains(current.activity.phase) { current.activity.markUnconfirmed() }
                unavailable.append(current.activity)
                cursors.removeValue(forKey: file)
                metadata.removeValue(forKey: file)
            }
        }
        return ((cursors.values.map(\.activity) + unavailable).filter { !$0.isInternalReview }.sorted { ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast) },
                watchURLs + selected.sorted { (cursors[$0]?.activity.lastObserved ?? .distantPast) > (cursors[$1]?.activity.lastObserved ?? .distantPast) })
    }
    /// Recover the latest explicit turn anchor without loading conversation history.
    /// Scan at most 8 MiB backwards, retaining at most one bounded line.
    private func latestTurnAnchor(handle: FileHandle, size: UInt64) -> Data? {
        var offset = size
        let floor = size > 8 * 1024 * 1024 ? size - 8 * 1024 * 1024 : 0
        var fragment = Data()
        while offset > floor {
            let start = max(floor, offset > 128 * 1024 ? offset - 128 * 1024 : 0)
            do {
                try handle.seek(toOffset: start)
                var data = try handle.read(upToCount: Int(offset - start)) ?? Data()
                data.append(fragment)
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropFirst().reversed() {
                    guard line.count <= 1024 * 1024,
                          line.range(of: Data("turn_context".utf8)) != nil || line.range(of: Data("task_started".utf8)) != nil,
                          let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let payload = value["payload"] as? [String: Any], payload["turn_id"] as? String != nil,
                          value["type"] as? String == "turn_context" ||
                          (value["type"] as? String == "event_msg" && payload["type"] as? String == "task_started") else { continue }
                    return Data(line)
                }
                fragment = lines.first.map(Data.init) ?? Data()
                if fragment.count > 1024 * 1024 { fragment.removeAll() }
                offset = start
            } catch { return nil }
        }
        return nil
    }

}

/// Shared formatters avoid constructing two ICU parsers for every appended record.
private final class LogDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func parse(_ value: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: value) ?? whole.date(from: value)
    }
}
