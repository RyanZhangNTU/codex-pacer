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
    /// `working` and `coordinating` are all a poll of a cloud Project can tell.
    case starting, thinking, tool, responding, working, coordinating
    public var label: String {
        switch self {
        case .starting: return L10n.text("activity.starting")
        case .thinking: return L10n.text("activity.thinking")
        case .tool: return L10n.text("activity.tool")
        case .responding: return L10n.text("activity.responding")
        case .working: return L10n.text("activity.working")
        case .coordinating: return L10n.text("activity.coordinating")
        }
    }
}

public struct SessionActivity: Equatable, Sendable, Identifiable {
    public private(set) var id: String
    public let provider: AgentProvider
    public let sourceHost: String?
    public let sourceHostID: String?
    public private(set) var title: String?
    private(set) var titleWasExplicitlyCleared = false
    public var project: String
    public private(set) var threadID: String?
    public private(set) var navigationDirectory: URL?
    public private(set) var desktopSessionID: String?
    /// Another app launched this session through a provider SDK/ACP adapter.
    public private(set) var launchedByEmbeddingApp = false
    public private(set) var codexOrigin: CodexSessionOrigin?
    private var codexOriginAt: Date?
    public private(set) var rolloutURL: URL?
    public var isIgnoredCodexSession: Bool { codexOrigin?.ignored == true }
    /// Set on tasks that run in a Claude cloud Project.
    public private(set) var claudeCloud: ClaudeCloudContext?
    /// The same place on claude.ai, for when Claude Desktop cannot open it.
    public var claudeCloudWebURL: URL? { claudeCloud?.url(session: threadID, web: true) }
    public var threadURL: URL? {
        if provider == .deepseek { return nil }
        if provider == .claude {
            if let claudeCloud { return claudeCloud.url(session: threadID, web: false) }
            guard sourceHostID == nil, let desktopSessionID else { return nil }
            var url = URLComponents()
            url.scheme = "claude"; url.host = "code"; url.path = "/continue"
            url.queryItems = [URLQueryItem(name: "session", value: desktopSessionID)]
            return url.url
        }
        guard let threadID else { return nil }
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/" + threadID
        if let sourceHostID {
            let sshPrefix = "remote-ssh-discovered:", controlPrefix = "remote-control:"
            let validSSH = sourceHostID.hasPrefix(sshPrefix) &&
                String(sourceHostID.dropFirst(sshPrefix.count)).range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil
            let validControl = sourceHostID.hasPrefix(controlPrefix) &&
                String(sourceHostID.dropFirst(controlPrefix.count)).range(of: #"^[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil
            guard validSSH || validControl else { return nil }
            url.queryItems = [URLQueryItem(name: "hostId", value: sourceHostID)]
        }
        return url.url
    }
    /// A cloud thread can say more than a turn ending does.
    public var endingLabel: String {
        if claudeCloud?.status == .resolved { return L10n.text("activity.resolved") }
        return L10n.text(claudeCloud?.awaitsReply == true ? "attention.input" : "activity.turn_finished")
    }
    mutating func setClaudeCloud(_ context: ClaudeCloudContext) {
        guard provider == .claude, sourceHostID == ClaudeCloudProjectState.sourceID else { return }
        claudeCloud = context; project = context.projectName
        if phase == .running { stage = context.role == .coordinator ? .coordinating : .working }
    }
    /// An estimate from the reply a cloud thread is writing, shown only while it runs.
    private var cloudReplyRate: OutputEstimate?
    mutating func setCloudReplyRate(_ rate: OutputEstimate?) { cloudReplyRate = rate }
    public private(set) var phase: ActivityPhase = .unknown
    public private(set) var turnID: String?
    public private(set) var turnStartedAt: Date?
    public private(set) var lastObserved: Date?
    public private(set) var phaseChangedAt: Date?
    public private(set) var stage: ActivityStage = .starting
    public private(set) var turnFailed = false
    public private(set) var isHistoricalCompletion = false
    public private(set) var waitingForApproval = false
    public private(set) var modelName: String?
    /// The latest turn's reasoning effort as the source names it, e.g. `xhigh`.
    public private(set) var reasoningEffort: String?
    // A reported null is different from a source that never reported effort.
    private var reasoningEffortReported = false
    private var reasoningEffortReportedAt: Date?
    public private(set) var isInternalReview = false
    /// DeepSeek's estimated cost of the current turn in CNY, from local token
    /// counts and the published price list; the platform bill is authoritative.
    public var turnCost: Double? { costTurnID != nil && costTurnID == turnID ? estimatedCost : nil }
    /// The part of `turnCost` billed at the doubled peak price.
    public var turnPeakCost: Double? { turnCost == nil ? nil : estimatedPeakCost }
    private var estimatedCost: Double?
    private var estimatedPeakCost = 0.0
    private var costTurnID: String?
    mutating func setTurnCost(_ value: Double, peak: Double = 0, turnID: String) {
        guard provider == .deepseek, value.isFinite, value >= 0, self.turnID == turnID else { return }
        estimatedCost = value; estimatedPeakCost = peak.isFinite ? min(value, max(0, peak)) : 0; costTurnID = turnID
    }
    /// A source that reports a model without its effort keeps the known effort
    /// only while the model is unchanged; an explicit null clears it.
    mutating func updateModel(in values: [String: Any], model key: String = "model", effort effortKey: String, at date: Date) {
        guard let model = ModelDisplay.sanitizedModel(values[key]) else { return }
        if values.keys.contains(effortKey), model != modelName || date >= (reasoningEffortReportedAt ?? .distantPast) {
            reasoningEffort = ModelDisplay.sanitizedEffort(values[effortKey])
            reasoningEffortReported = true
            reasoningEffortReportedAt = date
        } else if model != modelName {
            reasoningEffort = nil
            reasoningEffortReported = false
            reasoningEffortReportedAt = nil
        }
        modelName = model
    }
    public private(set) var parentThreadID: String?
    public struct SubagentEvidence: Equatable, Sendable {
        public let parentThreadID: String
        public let state: String
        public let observedAt: Date
    }
    public private(set) var subagentStates: [String: SubagentEvidence] = [:]
    private var subagentStatesObservedAt: Date?
    private var projectedRate = false
    /// The agent's latest estimate, kept with the turn it was written in.
    public private(set) var selfReportedProgress: SelfReportedProgress?
    /// The estimate for the current turn only; a new turn starts without one.
    public var currentProgress: SelfReportedProgress? {
        guard let selfReportedProgress, selfReportedProgress.turnID == turnID else { return nil }
        return selfReportedProgress
    }
    /// A later estimate replaces an earlier one, including a lower one.
    mutating func reportProgress(_ percent: Int, at date: Date, turnID: String) {
        guard turnID == self.turnID, let value = SelfReportedProgress(percent: percent, reportedAt: date, turnID: turnID) else { return }
        if let existing = selfReportedProgress, existing.turnID == turnID, existing.reportedAt > date { return }
        selfReportedProgress = value
    }
    /// A turn that wakes the same request, or a prompt typed while it waits,
    /// continues from the request's last estimate instead of starting over.
    mutating func carryProgress(_ previous: SelfReportedProgress, at date: Date) {
        guard let turnID, previous.turnID != turnID, currentProgress == nil else { return }
        selfReportedProgress = SelfReportedProgress(percent: previous.percent, reportedAt: date, turnID: turnID)
    }
    /// Background work a turn stopped to wait for; the request is not done.
    public struct BackgroundWait: Equatable, Sendable {
        public let turnID: String
        public let since: Date
        /// Task kinds as Claude names them, e.g. `shell` or `subagent`.
        public let kinds: [String]
        public let wakeups: Int
    }
    private var backgroundWait: BackgroundWait?
    /// Orders waiting snapshots, including clears, without hiding transcript evidence.
    private var backgroundWaitObservedAt: Date?
    /// The wait of the current turn only; a new turn clears it.
    public var currentBackgroundWait: BackgroundWait? {
        guard [.running, .waitingForInput].contains(phase) else { return nil }
        return backgroundWait?.turnID == turnID ? backgroundWait : nil
    }
    mutating func resumeBackgroundWork(at date: Date) {
        if let wait = currentBackgroundWait, date > wait.since {
            backgroundWait = nil
            backgroundWaitObservedAt = max(backgroundWaitObservedAt ?? date, date)
        }
    }
    mutating func waitForBackground(kinds: [String], wakeups: Int, at date: Date) {
        guard let turnID, [.running, .waitingForInput].contains(phase) else { return }
        guard date >= (lastObserved ?? .distantPast) else { return }
        guard date >= (backgroundWaitObservedAt ?? .distantPast) else { return }
        backgroundWaitObservedAt = date
        if kinds.isEmpty && wakeups == 0 { backgroundWait = nil; return }
        backgroundWait = BackgroundWait(turnID: turnID, since: date, kinds: Array(kinds.prefix(16)), wakeups: min(max(wakeups, 0), 16))
    }
    /// When the oldest tool still running in this turn started.
    public private(set) var toolWaitStartedAt: Date?
    mutating func applySubagentEvidence(_ evidence: SubagentEvidence) {
        guard !hasLiveEvidence, !isInternalReview, threadID != evidence.parentThreadID,
              parentThreadID == nil || parentThreadID == evidence.parentThreadID else { return }
        updateParent(evidence.parentThreadID)
        if evidence.state == "completed", turnStartedAt.map({ $0 > evidence.observedAt }) != true {
            if ![.completed, .interrupted].contains(phase) { phaseChangedAt = evidence.observedAt }
            phase = .completed; projectedRate = true
        } else if evidence.state == "running" {
            // A parent's cached running hint cannot undo a newer (or equal)
            // ending read from the child's own log. New activations still can.
            if [.completed, .interrupted].contains(phase), let ended = phaseChangedAt,
               evidence.observedAt <= ended { return }
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
    private var lastMeasuredPerformance: ResponsePerformance?
    private var latencyTurnID: String?
    private var latencyStart: Date?
    private var retainedLatency: TimeInterval?
    public private(set) var firstTokenReportedAt: Date?
    private var logTurnStart: Date?
    private var ignoringInheritedHistory = false
    mutating func updateParent(_ value: String?) {
        guard let value, let id = provider.validatedSessionID(value), id != threadID else { return }
        parentThreadID = id
    }
    static func parentID(in metadata: [String: Any], provider: AgentProvider = .codex) -> String? {
        let source = metadata["source"] as? [String: Any]
        let sub = (source?["subAgent"] ?? source?["subagent"]) as? [String: Any]
        let spawn = (sub?["thread_spawn"] ?? sub?["threadSpawn"]) as? [String: Any]
        let raw = (metadata["parentThreadId"] ?? metadata["parent_thread_id"] ?? spawn?["parent_thread_id"] ?? spawn?["parentThreadId"]) as? String
        return raw.flatMap { provider.validatedSessionID($0) }
    }
    private mutating func rememberRate() {
        guard !isIgnoredCodexSession else { return }
        if retainedLatency == nil, let latency = performanceMeter.firstTokenLatency, let turnID {
            latencyTurnID = turnID; retainedLatency = latency
            if firstTokenReportedAt == nil { firstTokenReportedAt = (latencyStart ?? logTurnStart ?? turnStartedAt)?.addingTimeInterval(latency) ?? lastObserved }
        }
        if let sample = responsePerformance {
            let rate = OutputEstimate(value: sample.tokensPerSecond, reportedAt: sample.completedAt, isFresh: true)
            let exact = sample.source != .observedRequest
            if shouldRemember(rate, turn: sample.turnID, performance: sample, exact: exact) {
                lastMeasuredRate = rate; lastMeasuredPerformance = sample
                lastMeasuredTurnID = sample.turnID; lastMeasuredExact = exact
            }
        } else if let at = lastObserved,
                  let sample = (phaseAwareRate ? generationRate.estimate(at: at) : outputRate.estimate(at: at)),
                  sample.value > 0, sample.value.isFinite,
                  shouldRemember(sample, turn: turnID, performance: nil, exact: false) {
            lastMeasuredRate = sample; lastMeasuredPerformance = nil; lastMeasuredTurnID = turnID; lastMeasuredExact = false
        }
    }
    private func shouldRemember(_ sample: OutputEstimate, turn: String?, performance: ResponsePerformance?, exact: Bool) -> Bool {
        guard let previous = lastMeasuredRate else { return true }
        if turn == lastMeasuredTurnID, let performance, let retained = lastMeasuredPerformance,
           performance.source == .observedRequest || retained.source == .observedRequest {
            return performance.supersedes(retained)
        }
        if turn == lastMeasuredTurnID, abs(sample.reportedAt.timeIntervalSince(previous.reportedAt)) < 2 {
            let incoming = performance?.source == .requestUsage, retained = lastMeasuredPerformance?.source == .requestUsage
            if incoming != retained { return incoming }
        }
        return sample.reportedAt > previous.reportedAt || (sample.reportedAt == previous.reportedAt && exact && !lastMeasuredExact)
    }
    /// Display continuity is independent of the new turn's accounting baseline.
    public func displayedOutputEstimate(at now: Date) -> OutputEstimate? {
        // A cloud run reports no usage, only the reply it is writing, and an earlier turn's speed would read as live.
        let measured = claudeCloud != nil && phase == .running ? cloudReplyRate : lastMeasuredRate
        guard let sample = measured, now >= sample.reportedAt else { return nil }
        let fresh = now < sample.expiresAt
        return OutputEstimate(value: sample.value, reportedAt: sample.reportedAt, isFresh: fresh)
    }
    public func displayedRateIsEstimated(at now: Date) -> Bool {
        (claudeCloud != nil && phase == .running) ||
        !lastMeasuredExact || projectedRate || lastMeasuredTurnID != turnID || stage == .tool ||
            performanceMeter.hasPendingOutput || displayedOutputEstimate(at: now)?.isFresh != true
    }
    public mutating func mergeDisplayMetadata(from other: SessionActivity) {
        guard canonicalized().id == other.canonicalized().id else { return }
        if parentThreadID == nil { parentThreadID = other.parentThreadID }
        if navigationDirectory == nil { navigationDirectory = other.navigationDirectory }
        if desktopSessionID == nil { desktopSessionID = other.desktopSessionID }
        if rolloutURL == nil { rolloutURL = other.rolloutURL }
        if claudeCloud == nil { claudeCloud = other.claudeCloud }
        // Model metadata belongs to a turn. An older card or another source's
        // previous turn must not supply a model for the current one.
        let sameTurn = turnID != nil && turnID == other.turnID
        let bothUnattached = turnID == nil && other.turnID == nil && phase == .unknown && other.phase == .unknown
        if sameTurn, turnCost == nil, other.turnCost != nil {
            estimatedCost = other.estimatedCost; estimatedPeakCost = other.estimatedPeakCost; costTurnID = other.costTurnID
        }
        if sameTurn || bothUnattached {
            if modelName == nil { modelName = other.modelName }
            let ownEffortAt = reasoningEffortReportedAt ?? .distantPast
            let otherEffortAt = other.reasoningEffortReportedAt ?? .distantPast
            if modelName != nil, modelName == other.modelName, other.reasoningEffortReported,
               !reasoningEffortReported || otherEffortAt > ownEffortAt ||
                (otherEffortAt == ownEffortAt && other.reasoningEffort == nil && reasoningEffort != nil) {
                reasoningEffort = other.reasoningEffort
                reasoningEffortReported = true
                reasoningEffortReportedAt = other.reasoningEffortReportedAt
            }
        }
        if let origin = other.codexOrigin,
           codexOrigin == nil || (other.codexOriginAt ?? .distantPast) > (codexOriginAt ?? .distantPast) {
            setCodexOrigin(origin, at: other.codexOriginAt)
        }
        if let key = other.latencyTurnID, key == turnID || (turnID == nil && !liveStatusOnly) {
            if retainedLatency == nil { retainedLatency = other.retainedLatency; latencyTurnID = key }
            if latencyStart == nil { latencyStart = other.latencyStart; latencyTurnID = key }
            if firstTokenReportedAt == nil { firstTokenReportedAt = other.firstTokenReportedAt }
        }
        if turnID == other.turnID, subagentStatesObservedAt == nil {
            subagentStates = other.subagentStates
            subagentStatesObservedAt = other.subagentStatesObservedAt
        }
        if let sample = other.lastMeasuredRate,
           shouldRemember(sample, turn: other.lastMeasuredTurnID, performance: other.lastMeasuredPerformance, exact: other.lastMeasuredExact) {
            lastMeasuredRate = sample; lastMeasuredTurnID = other.lastMeasuredTurnID; lastMeasuredExact = other.lastMeasuredExact
            lastMeasuredPerformance = other.lastMeasuredPerformance
        }
    }
    private var waitingCallID: String?
    private var toolCalls: Set<String> = []
    private var outputRate = OutputRate()
    private var generationRate = GenerationRate()
    private var performanceMeter = ResponsePerformanceMeter()
    public var responsePerformance: ResponsePerformance? { performanceMeter.latest }
    /// A released turn can receive numeric accounting without new activity.
    mutating func enrichCompletedUsage(_ event: [String: Any]) {
        guard [.completed, .interrupted].contains(phase), event["threadId"] as? String == threadID,
              event["turnId"] as? String == turnID, event["cachedUsage"] as? Bool != true,
              let seconds = event["at"] as? Double, seconds.isFinite,
              let total = event["outputTokens"] as? Int else { return }
        performanceMeter.observeRuntime(total: total, last: event["lastOutputTokens"] as? Int,
            reasoning: event["lastReasoningTokens"] as? Int, at: Date(timeIntervalSince1970: seconds), allowAfterFinish: true)
        rememberRate()
    }
    public var firstTokenLatency: TimeInterval? {
        if latencyTurnID == turnID || turnID == nil, let retainedLatency { return retainedLatency }
        return performanceMeter.firstTokenLatency
    }
    private mutating func observeFirstText(at date: Date) {
        guard retainedLatency == nil, latencyTurnID == turnID, let start = latencyStart,
              date >= start, date.timeIntervalSince(start) <= 3600 else { return }
        retainedLatency = date.timeIntervalSince(start)
        firstTokenReportedAt = date
    }
    static func loggedFirstOutput(_ payload: [String: Any]) -> Double? {
        if let value = payload["first_output_at_ms"] as? Double { return value }
        guard let item = payload["item"] as? [String: Any], let kind = item["type"] as? String,
              ["AgentMessage", "Reasoning", "agentMessage", "reasoning"].contains(kind) else { return nil }
        let hasText = ["text", "summary_text", "summary", "content"].contains { key in
            if let value = item[key] as? String { return !value.isEmpty }
            if let values = item[key] as? [Any] {
                return values.prefix(64).contains {
                    if let text = $0 as? String { return !text.isEmpty }
                    return (($0 as? [String: Any])?["text"] as? String)?.isEmpty == false
                }
            }
            return false
        }
        guard hasText else { return nil }
        return payload[kind.lowercased() == "reasoning" ? "completed_at_ms" : "started_at_ms"] as? Double
    }
    mutating func mergePerformance(from other: SessionActivity) {
        guard canonicalized().id == other.canonicalized().id, turnID == other.turnID else { return }
        performanceMeter.merge(from: other.performanceMeter)
        performanceMeter.apply(sample: nil, latency: other.firstTokenLatency)
        if firstTokenReportedAt == nil { firstTokenReportedAt = other.firstTokenReportedAt }
        rememberRate()
    }
    mutating func applyPerformance(_ update: SessionPerformanceUpdate) {
        guard canonicalized().id == update.id, turnID == update.turnID else { return }
        performanceMeter.apply(sample: update.response, latency: update.firstTokenLatency)
        if firstTokenReportedAt == nil { firstTokenReportedAt = update.firstTokenReportedAt }
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
        value.id = provider.activityID(sessionID: threadID, sourceHostID: sourceHostID)
        return value
    }

    public init(id: String, project: String = L10n.text("activity.local_task"), sourceHost: String? = nil, sourceHostID: String? = nil, phaseAwareRate: Bool = false,
                provider: AgentProvider = .codex, sessionID: String? = nil) {
        self.id = id
        self.provider = provider
        self.phaseAwareRate = phaseAwareRate
        self.sourceHost = sourceHost
        self.sourceHostID = sourceHostID
        self.project = project
        // Canonical host IDs may contain dots (SSH aliases/IP addresses). Do
        // not strip a supposed file extension before checking their UUID tail.
        if let sessionID { threadID = provider.validatedSessionID(sessionID) }
        else { threadID = provider.sessionID(in: id) }
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

    /// The latest launch wins: a session resumed in a terminal shows again.
    public mutating func setClaudeLaunch(embedded: Bool) {
        if provider == .claude { launchedByEmbeddingApp = embedded }
    }
    public mutating func setCodexOrigin(_ origin: CodexSessionOrigin, at: Date? = nil) {
        guard provider == .codex, codexOriginAt == nil || at == nil || at! >= codexOriginAt! else { return }
        codexOrigin = origin; codexOriginAt = at; launchedByEmbeddingApp = origin.embedded
    }
    mutating func inheritCodexOrigin(_ origin: CodexSessionOrigin) {
        codexOrigin = origin; launchedByEmbeddingApp = origin.embedded
    }
    public mutating func setCodexRollout(_ url: URL) {
        if provider == .codex, sourceHostID == nil, url.isFileURL { rolloutURL = url }
    }
    /// A transcript UUID alone cannot establish a Desktop conversation route.
    /// Directories are local navigation metadata and never enter SSH frames.
    public mutating func setClaudeNavigation(directory: URL? = nil, desktopSessionID: String? = nil) {
        guard provider == .claude else { return }
        if let directory, sourceHostID == nil, directory.isFileURL,
           directory.path.hasPrefix("/"), directory.absoluteString.utf8.count <= 4096,
           directory.host == nil || directory.host == "" || directory.host == "localhost",
           directory.query == nil, directory.fragment == nil,
           !directory.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            navigationDirectory = directory.standardizedFileURL
        }
        if let desktopSessionID, sourceHostID == nil, desktopSessionID.utf8.count <= 256 {
            let suffix = String(desktopSessionID.dropFirst(6))
            if desktopSessionID.hasPrefix("local_"), suffix.utf8.count == 36, UUID(uuidString: suffix) != nil {
                self.desktopSessionID = desktopSessionID
            }
        }
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
        if claudeCloud != nil { return displayedOutputEstimate(at: now) }
        let legacy = phaseAwareRate ? generationRate.estimate(at: now) : outputRate.estimate(at: now)
        if legacy?.value == 0 { return legacy }
        if let sample = responsePerformance, now >= sample.completedAt {
            return OutputEstimate(value: sample.tokensPerSecond, reportedAt: sample.completedAt,
                isFresh: now.timeIntervalSince(sample.completedAt) < OutputEstimate.freshnessInterval)
        }
        return legacy
    }
    public var rateExpiresAt: Date? {
        if claudeCloud != nil, phase == .running { return cloudReplyRate?.expiresAt }
        if let sample = lastMeasuredRate { return sample.expiresAt }
        guard phase == .running else { return nil }
        if let sample = responsePerformance { return sample.completedAt.addingTimeInterval(OutputEstimate.freshnessInterval) }
        return phaseAwareRate ? generationRate.expiresAt : outputRate.expiresAt
    }
    public func detail(at now: Date) -> String {
        if turnFailed, phase == .interrupted { return L10n.text("activity.failed") }
        if observedPhase(at: now) == .unknown, phase == .waitingForInput { return L10n.text("activity.last_waiting") }
        if observedPhase(at: now) == .unknown, phase == .running, stage == .tool { return L10n.text("activity.last_tool") }
        // The turn stopped for its background work; its last stage is over.
        if observedPhase(at: now) == .running, currentBackgroundWait != nil { return L10n.text("activity.background_wait") }
        return observedPhase(at: now) == .running ? stage.label : observedPhase(at: now).label
    }

    public mutating func consume(_ line: Data) {
        guard provider == .codex,
              let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        consume(value)
    }
    var acceptsLogAttention: Bool { provider == .codex && !ignoringInheritedHistory && !isInternalReview && !isIgnoredCodexSession }
    mutating func consume(_ value: [String: Any]) {
        guard provider == .codex, let payload = value["payload"] as? [String: Any] else { return }
        defer { rememberRate() }
        if value["type"] as? String == "session_meta" {
            if let raw = payload["id"] as? String, let uuid = UUID(uuidString: raw) {
                let identity = uuid.uuidString.lowercased()
                if let threadID, identity != threadID {
                    // Forked logs embed ancestor headers/history before their
                    // own first turn. They cannot rename or meter this cursor.
                    ignoringInheritedHistory = true
                    return
                }
                threadID = identity
                ignoringInheritedHistory = false
            }
            if let title = payload["title"] as? String { updateTitle(title) }
            if let origin = CodexSessionOrigin.sanitized(payload) {
                setCodexOrigin(origin, at: (value["timestamp"] as? String).flatMap(Self.parseDate))
            }
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
            return
        }
        guard !isIgnoredCodexSession else { return }
        if ignoringInheritedHistory {
            // The first owned settings/item/accounting event proves that the
            // copied prefix has ended. Its body is otherwise ignored normally.
            guard payload["thread_id"] as? String == threadID else { return }
            ignoringInheritedHistory = false
        }
        if value["type"] as? String == "turn_context" {
            guard let timestamp = value["timestamp"] as? String, let date = Self.parseDate(timestamp),
                  date >= (lastObserved ?? .distantPast) else { return }
            // A current turn context is an explicit anchor when the start lies
            // outside the initial tail, or when the app attached mid-turn.
            if let contextTurn = payload["turn_id"] as? String, contextTurn != turnID {
                beginTurn(contextTurn, at: date)
            }
            updateModel(in: payload, effort: "effort", at: date)
            if modelName?.lowercased().hasPrefix("codex-auto-review") == true { isInternalReview = true }
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
        if value["type"] as? String == "event_msg", payload["type"] as? String == "item_completed" {
            guard payload["thread_id"] as? String == threadID, payload["turn_id"] as? String == turnID,
                  retainedLatency == nil, let began = logTurnStart,
                  let ms = Self.loggedFirstOutput(payload), ms.isFinite,
                  let stamp = value["timestamp"] as? String, let reported = Self.parseDate(stamp) else { return }
            let first = Date(timeIntervalSince1970: ms / 1000)
            guard first >= began, first <= reported, first.timeIntervalSince(began) <= 3600 else { return }
            latencyTurnID = turnID; retainedLatency = first.timeIntervalSince(began)
            firstTokenReportedAt = first
            return // Numeric timing does not drive lifecycle or TPS accounting.
        }
        if value["type"] as? String == "event_msg", payload["type"] as? String == "task_complete",
           payload["turn_id"] as? String == turnID, retainedLatency == nil,
           let milliseconds = payload["time_to_first_token_ms"] as? Double,
           milliseconds.isFinite, milliseconds >= 0, milliseconds <= 3_600_000,
           (payload["duration_ms"] as? Double).map({ milliseconds <= $0 }) ?? true {
            latencyTurnID = turnID; retainedLatency = milliseconds / 1000
            firstTokenReportedAt = logTurnStart?.addingTimeInterval(milliseconds / 1000) ??
                (value["timestamp"] as? String).flatMap(Self.parseDate)
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
            if [.completed, .interrupted].contains(phase) { return }
        }
        lastObserved = date
        if value["type"] as? String == "response_item" {
            consumeResponse(payload, kind: kind, at: date)
            return
        }
        switch kind {
        case "task_started":
            beginTurn(eventTurn, at: date)
            if let context = payload["_model_context"] as? [String: Any] {
                updateModel(in: context, effort: "effort", at: date)
                if modelName?.lowercased().hasPrefix("codex-auto-review") == true { isInternalReview = true }
            }
            logTurnStart = date
            if retainedLatency == nil, let ms = payload["first_output_latency_ms"] as? Double,
               ms.isFinite, ms >= 0, ms <= 3_600_000 {
                latencyTurnID = eventTurn; retainedLatency = ms / 1000
                firstTokenReportedAt = date.addingTimeInterval(ms / 1000)
            }
        case "task_complete", "turn_aborted":
            retireTurn(turnID)
            phase = kind == "turn_aborted" ? .interrupted : .completed
            turnFailed = false; waitingForApproval = false
            waitingCallID = nil
            toolCalls.removeAll()
            outputRate.finishTurn(); generationRate.finish(); liveItems.removeAll(); toolWaitStartedAt = nil; backgroundWait = nil; backgroundWaitObservedAt = nil
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
        isHistoricalCompletion = false
        logTurnStart = nil
        if (id != nil && id != latencyTurnID) || (id == nil && [.completed, .interrupted].contains(phase)) {
            latencyTurnID = id; latencyStart = nil; retainedLatency = nil
            firstTokenReportedAt = nil
        }
        // An unknown ID during reconnect does not prove the old turn ended.
        if let id { identifyTurn(id) }
        subagentStates = [:]; subagentStatesObservedAt = nil; projectedRate = false
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
        generationRate.start(); liveItems.removeAll(); toolWaitStartedAt = nil; backgroundWait = nil; backgroundWaitObservedAt = nil
        performanceMeter.start(turnID: id, at: date, observed: observed)
        phaseChangedAt = date
    }

    private mutating func retireTurn(_ id: String?) {
        guard let id, !retiredTurns.contains(id) else { return }
        retiredTurns.append(id)
        if retiredTurns.count > 64 { retiredTurns.removeFirst(retiredTurns.count - 64) }
    }

    private mutating func identifyTurn(_ id: String) {
        if let latencyTurnID, latencyTurnID != id { latencyStart = nil; retainedLatency = nil; firstTokenReportedAt = nil }
        latencyTurnID = id
        if id != lastIdentifiedTurn { retireTurn(lastIdentifiedTurn) }
        lastIdentifiedTurn = id; turnID = id
        performanceMeter.identify(id)
    }

    /// Retain provenance while rejecting lifecycle/rate assumptions across a gap.
    mutating func markDiscontinuity() {
        logTurnStart = nil
        phase = .unknown
        turnFailed = false; waitingForApproval = false
        turnID = nil
        turnStartedAt = nil
        lastObserved = nil
        phaseChangedAt = nil
        waitingCallID = nil
        toolCalls.removeAll()
        outputRate = OutputRate(); generationRate = GenerationRate(); liveItems.removeAll(); toolWaitStartedAt = nil; backgroundWait = nil; backgroundWaitObservedAt = nil; hasLiveEvidence = false
        performanceMeter = ResponsePerformanceMeter()
    }

    mutating func markUnconfirmed() {
        logTurnStart = nil
        phase = .unknown
        waitingForApproval = false
        outputRate.finishTurn(); generationRate.finish(); liveItems.removeAll(); toolWaitStartedAt = nil; backgroundWait = nil; backgroundWaitObservedAt = nil; hasLiveEvidence = false; liveTurnStarted = false; liveStatusOnly = false
    }

    mutating func markPartialRate() {
        guard phaseAwareRate else { return }
        logTurnStart = nil
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
                  let parent = threadID, subagentStatesObservedAt.map({ date >= $0 }) ?? true else { return }
            // A replayed snapshot cannot date its breadcrumbs. Anchor a newly
            // seen running state at this turn's start, so it cannot revive a
            // child that ended during the turn; the child's log reports new runs.
            let runningAt = event["replayed"] as? Bool == true ? min(turnStartedAt ?? date, date) : date
            var next: [String: SubagentEvidence] = [:]
            for (raw, state) in states {
                guard let id = provider.validatedSessionID(raw), id != parent,
                      ["running", "completed"].contains(state) else { continue }
                next[id] = subagentStates[id].flatMap { $0.state == state ? $0 : nil } ??
                    SubagentEvidence(parentThreadID: parent, state: state, observedAt: state == "running" ? runningAt : date)
            }
            subagentStates = next
            subagentStatesObservedAt = date
            return
        }
        if method == "thread/name/updated" {
            guard event["name"] is String || event["name"] is NSNull else { return }
            updateName(event["name"] as? String)
            return
        }
        if method == "metadata" {
            if let origin = CodexSessionOrigin.sanitized(event) { setCodexOrigin(origin, at: date) }
            if sourceHostID == nil, let path = event["localRolloutPath"] as? String { setCodexRollout(URL(fileURLWithPath: path)) }
            updateParent(Self.parentID(in: event, provider: provider))
            if let name = event["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateTitle(name)
            }
            // App-server thread settings describe configuration for future
            // turns, not the model of the active one; they still mark a review.
            let configured = event["modelScope"] as? String == "threadConfiguration"
            if !configured { updateModel(in: event, effort: "reasoningEffort", at: date) }
            if let cwd = event["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            let source = (event["source"] as? String ?? "").lowercased().replacingOccurrences(of: "_", with: "")
            if provider == .codex {
                let model = configured ? event["model"] as? String : modelName
                isInternalReview = isInternalReview || ["guardianreview", "autoreview", "subagentreview"].contains(source) ||
                    model?.lowercased().hasPrefix("codex-auto-review") == true
            }
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
            isHistoricalCompletion = false
            identifyTurn(eventTurn); liveStatusOnly = false
            retireTurn(eventTurn)
            phase = event["status"] as? String == "completed" ? .completed : .interrupted
            turnFailed = event["status"] as? String == "failed"; waitingForApproval = false
            phaseChangedAt = date; lastObserved = date; hasLiveEvidence = true
            generationRate.finish(); outputRate.finishTurn(); liveItems.removeAll(); toolWaitStartedAt = nil; backgroundWait = nil; backgroundWaitObservedAt = nil; toolCalls.removeAll()
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
            let duplicateStart = method == "turn/started" && turnID == eventTurn && hasLiveEvidence && liveTurnStarted
            let retained = turnID == eventTurn ? performanceMeter : nil
            let originalStart = retained == nil ? nil : turnStartedAt
            let start = originalStart ?? (event["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? date
            if !duplicateStart {
                beginTurn(eventTurn, at: start <= date ? start : date, observed: method == "turn/started")
                if let retained { performanceMeter.merge(from: retained) }
            }
            if method == "turn/started", latencyStart == nil {
                latencyTurnID = eventTurn; latencyStart = start <= date ? start : date
            }
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
        if method == "item/completed", modelItem {
            if event["hasText"] as? Bool == true { observeFirstText(at: date) }
            performanceMeter.modelOutput(at: date, textDelta: event["hasText"] as? Bool == true)
        }
        if method == "item/started", let id = event["itemId"] as? String {
            if toolItem {
                if liveItems.isEmpty || toolWaitStartedAt == nil { toolWaitStartedAt = date }
                if liveItems.count < 128 { liveItems.insert(id) }
                generationRate.setWaiting(true, at: date); phase = .running; stage = .tool
                performanceMeter.setWaiting(true, at: date)
            } else if modelItem {
                if event["hasText"] as? Bool == true {
                    observeFirstText(at: date); performanceMeter.modelOutput(at: date, textDelta: true)
                }
                generationRate.setWaiting(false, at: date); phase = .running
                stage = kind == "reasoning" ? .thinking : .responding
            }
        } else if method == "item/completed", let id = event["itemId"] as? String, liveItems.remove(id) != nil {
            if liveItems.isEmpty {
                toolWaitStartedAt = nil
                generationRate.setWaiting(false, at: date); phase = .running; stage = .thinking
                performanceMeter.inputBoundary(at: date)
            }
        } else if method.hasSuffix("/delta") || method.contains("TextDelta") || method.contains("textDelta") {
            let first = (event["firstDeltaAt"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? date
            if event["hasText"] as? Bool == true {
                observeFirstText(at: first)
                performanceMeter.modelOutput(at: first, textDelta: true)
                if first != date { performanceMeter.modelOutput(at: date, textDelta: false) }
            }
            generationRate.setWaiting(false, at: date); phase = .running
            stage = method.contains("reasoning") ? .thinking : .responding
        } else if method == "thread/tokenUsage/updated", let total = event["outputTokens"] as? Int {
            generationRate.observe(total: total, at: date, cached: event["cachedUsage"] as? Bool == true)
            performanceMeter.observeRuntime(total: total, last: event["lastOutputTokens"] as? Int,
                reasoning: event["lastReasoningTokens"] as? Int, at: date, cached: event["cachedUsage"] as? Bool == true)
        }
    }

    /// Adapters supply lifecycle, text-presence and numeric fields only. Text bodies are never retained.
    public mutating func applyRuntime(_ event: [String: Any]) {
        guard let session = event["threadId"] as? String, let normalized = provider.validatedSessionID(session), normalized == threadID,
              (event["turnId"] as? String).map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              (event["itemId"] as? String).map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { return }
        var normalizedEvent = event
        normalizedEvent["threadId"] = normalized
        consumeLive(normalizedEvent)
    }

    /// Late authoritative usage enriches the matching observed request without changing lifecycle.
    public mutating func applyRequestUsage(responseID: String, turnID: String, outputTokens: Int,
                                          reasoningTokens: Int? = nil, at date: Date) {
        guard self.turnID == turnID, outputTokens > 0, date.timeIntervalSince1970.isFinite,
              reasoningTokens.map({ $0 >= 0 && $0 <= outputTokens }) ?? true else { return }
        performanceMeter.observeRequest(id: responseID, turn: turnID, output: outputTokens, reasoning: reasoningTokens, at: date)
        rememberRate()
    }

    public mutating func markSourceUnavailable() { markUnconfirmed() }

    /// An initial log/spool baseline is historical even when it contains live-shaped events.
    public mutating func suppressHistoricalCompletionNotifications() {
        guard provider != .codex else { return }
        liveTurnStarted = false
        isHistoricalCompletion = [.completed, .interrupted].contains(phase)
    }

    private static let dates = LogDateParser()
    static func parseDate(_ string: String) -> Date? { dates.parse(string) }
}
