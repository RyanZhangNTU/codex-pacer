import Foundation

/// Ephemeral views for one bounded line. Context and projection share the
/// validated document and top-level scan; only sanitized values escape it.
struct ClaudeTranscriptFields {
    let values: [String: JSONFieldView]
    init?(_ bytes: Data) {
        guard let document = try? JSONFieldView.document(bytes, maximumBytes: ClaudeActivityRecord.maximumBytes),
              let values = try? document.fields(["type", "subtype", "timestamp", "sessionId", "uuid", "parentUuid", "promptId", "cwd", "agentId", "isMeta", "isSynthetic", "message", "toolUseResult", "durationMs", "sessionTitle", "customTitle", "is_error", "stop_reason", "preventedContinuation", "requestId", "serverClassifierRequest", "origin", "promptSource", "turnOrigin", "hookErrors", "hookAdditionalContext", "entrypoint", "mcpMeta", "effort", "perTurnEffort", "attachment"]) else { return nil }
        self.values = values
    }
}

/// A transcript is a fallback for explicit lifecycle evidence. Completed text
/// records are never projected as a first token or an invented stream delta.
enum ClaudeActivityRecord {
    static let maximumBytes = 1024 * 1024
    private static let dates = ClaudeActivityDateParser()
    static func date(_ value: String) -> Date? { dates.parse(value) }
    static func identifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil else { return nil }
        return UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }
    static func encode(_ value: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    /// Tools whose typed result can name the sub-agent they ran.
    static let agentTools: Set<String> = ["Agent", "Skill", "SendMessage"]
    /// A forked Skill such as `/code-review` runs in a sub-agent and reports
    /// `forked` (Claude Code 2.1.309). `background` marks a launch whose outcome
    /// arrives later as a task notification; otherwise the fork has ended.
    static func agentStatus(_ status: String?, background: Bool?, success: Bool?) -> String? {
        if status == "forked" { return background == true ? "async_launched" : success == true ? "completed" : nil }
        return status.flatMap { ["completed", "async_launched"].contains($0) ? $0 : nil }
    }
    /// The sub-agent a typed tool result started and how it runs. A SendMessage
    /// that revives a stopped agent has no status (Claude Code 2.1.317): it names
    /// the agent in `revivedAgentId`, usually also `resumedAgentId`. The revived
    /// run works in the background, and its task notification names this
    /// SendMessage call instead of the Agent call that first launched it.
    static func agentLaunch(_ response: [String: JSONFieldView]) -> (agent: String, status: String)? {
        if let status = agentStatus(response["status"]?.string(limit: 24), background: response["background"]?.boolean(), success: response["success"]?.boolean()) {
            return identifier(response["agentId"]?.string()).map { ($0, status) }
        }
        guard response["status"] == nil, response["success"]?.boolean() == true,
              let agent = identifier((response["revivedAgentId"] ?? response["resumedAgentId"])?.string()) else { return nil }
        return (agent, "async_launched")
    }

    static func transcript(_ bytes: Data, sessionID: String, parentID: String? = nil, promptID: String? = nil) -> [Data] {
        guard let fields = ClaudeTranscriptFields(bytes) else { return [] }
        return transcript(fields, sessionID: sessionID, parentID: parentID, promptID: promptID)
    }
    static func transcript(_ parsed: ClaudeTranscriptFields, sessionID: String, parentID: String? = nil, promptID: String? = nil) -> [Data] {
        let fields = parsed.values
        guard let kind = fields["type"]?.string(),
              let session = identifier(fields["sessionId"]?.string() ?? sessionID), session == (parentID ?? sessionID) else { return [] }
        // Subagent files have the parent's sessionId. Their own opaque ID comes
        // from the validated file name and never from a user's prompt.
        let fileAgent = parentID == nil ? nil : identifier(fields["agentId"]?.string())
        guard parentID == nil || fields["agentId"] == nil || fileAgent != nil else { return [] }
        guard fileAgent == nil || fileAgent == sessionID || fileAgent == "agent-" + sessionID else { return [] }
        let thread = parentID == nil ? session : sessionID
        if kind == "custom-title", let title = fields["customTitle"]?.string(limit: 240) {
            return [encode(["origin": "transcript", "sessionId": thread, "at": Date().timeIntervalSince1970, "kind": "metadata", "title": title])].compactMap { $0 }
        }
        guard let stamp = fields["timestamp"]?.string(), let at = date(stamp) else { return [] }
        guard fields["serverClassifierRequest"]?.boolean() != true else { return [] }
        var base: [String: Any] = ["origin": "transcript", "sessionId": thread, "at": at.timeIntervalSince1970]
        if let prompt = identifier(fields["promptId"]?.string()) ?? identifier(promptID) { base["promptId"] = prompt }
        else { base["unownedTurn"] = true }
        if let parentID { base["parentId"] = parentID }
        var result: [[String: Any]] = []
        var metadata = base; metadata["kind"] = "metadata"
        if let cwd = fields["cwd"]?.string(limit: 4096) { metadata["project"] = URL(fileURLWithPath: cwd).lastPathComponent; metadata["localDirectory"] = cwd }
        if let title = fields["sessionTitle"]?.string(limit: 240) { metadata["title"] = title }
        let message = fields["message"].flatMap { try? $0.fields(["role", "id", "model", "content", "usage", "stop_reason"]) } ?? [:]
        // `<synthetic>` marks locally generated records, not the working model.
        if let model = message["model"]?.string(limit: 256), !model.hasPrefix("<") {
            metadata["model"] = model
            if let effort = fields["perTurnEffort"]?.string(limit: 32) ?? fields["effort"]?.string(limit: 32) { metadata["effort"] = effort }
        }
        // Apps that embed Claude Code through the Agent SDK launch it as `sdk-*`.
        if let entrypoint = fields["entrypoint"]?.string(limit: 64) { metadata["embedded"] = entrypoint.hasPrefix("sdk-") }
        result.append(metadata)
        let content = message["content"]
        let originFields = fields["origin"].flatMap { try? $0.fields(["kind", "producer", "runId"]) }
        let humanOrigin = originFields?["kind"]?.matchesStringLiteral("human") == true && originFields?["producer"]?.matchesStringLiteral("session-task") != true
        let legacyHuman = fields["origin"] == nil && fields["promptSource"] == nil && fields["turnOrigin"] == nil
        if kind == "user", message["role"]?.matchesStringLiteral("user") == true,
           originFields?["kind"]?.matchesStringLiteral("task-notification") == true,
           originFields?["producer"]?.matchesStringLiteral("session-task") == true,
           originFields?["runId"].map({ identifier($0.string()) != nil }) ?? true,
           fields["turnOrigin"]?.matchesStringLiteral("human") != true, let content {
            let text: JSONFieldView?
            if content.isArray, let elements = try? content.elements(maximumCount: 2), elements.count == 1,
               let item = try? elements[0].fields(["type", "text"]), item["type"]?.matchesStringLiteral("text") == true { text = item["text"] }
            else if !content.isArray { text = content } else { text = nil }
            if let raw = text?.string(limit: 65_537), let notification = ClaudeAgentNotification(raw) {
                var value = base; value["kind"] = "agentNotification"; value["agentId"] = notification.agentID
                value["itemId"] = notification.itemID; value["agentStatus"] = notification.status
                return [encode(value)].compactMap { $0 }
            }
            return []
        }
        // While its chat is mid-turn, Claude Code delivers a background agent's
        // notification as a queued attachment inside the running turn instead
        // of a user record. The notification text is the same. A subagent
        // gets the ones for the agents it launched or revived in its own file.
        if kind == "attachment",
           let attachment = fields["attachment"].flatMap({ try? $0.fields(["type", "commandMode", "origin", "prompt"]) }),
           attachment["type"]?.matchesStringLiteral("queued_command") == true,
           attachment["commandMode"]?.matchesStringLiteral("task-notification") == true {
            if let origin = attachment["origin"] {
                let source = try? origin.fields(["kind", "producer"])
                guard source?["kind"]?.matchesStringLiteral("task-notification") == true,
                      source?["producer"]?.matchesStringLiteral("session-task") == true else { return [] }
            }
            guard let raw = attachment["prompt"]?.string(limit: 65_537), let notification = ClaudeAgentNotification(raw) else { return [] }
            var value = base; value["kind"] = "agentNotification"; value["agentId"] = notification.agentID
            value["itemId"] = notification.itemID; value["agentStatus"] = notification.status
            return [encode(value)].compactMap { $0 }
        }
        if kind == "user", !humanOrigin, !legacyHuman { return [] }
        // Verified in the bundled Claude Code 2.1.293 schema and a controlled
        // Desktop Esc test. Human prompts are never matched against a marker.
        if kind == "user", fields["origin"] == nil, fields["promptSource"] == nil, fields["turnOrigin"] == nil,
           fields["isMeta"]?.boolean() != false, fields["isSynthetic"]?.boolean() != false,
           let prompt = identifier(fields["promptId"]?.string()), let content, content.isArray,
           let elements = try? content.elements(maximumCount: 2), elements.count == 1,
           let marker = try? elements[0].fields(["type", "text"]), marker["type"]?.string(limit: 16) == "text",
           (marker["text"]?.matchesStringLiteral("[Request interrupted by user]") == true ||
            marker["text"]?.matchesStringLiteral("[Request interrupted by user for tool use]") == true) {
            var value = base; value["kind"] = "interrupt"; value["promptId"] = prompt; value["engineInterrupt"] = true
            result.append(value); return result.compactMap(encode)
        }
        var toolStarts: [(String, String)] = [], toolEnds: [String] = [], modelKinds: Set<String> = []
        // A self-reported estimate (`⟦62%⟧`) opens a reply. Only the first few
        // bytes of the text are decoded and only the number leaves this scope.
        var progress: Int?
        if let content, content.isArray, let values = try? content.elements(maximumCount: 128) {
            for item in values {
                guard let f = try? item.fields(["type", "id", "tool_use_id", "name", "text"]), let type = f["type"]?.string() else { continue }
                if type == "tool_use", let id = identifier(f["id"]?.string()) { toolStarts.append((id, f["name"]?.string() ?? "")) }
                else if type == "tool_result", let id = identifier(f["tool_use_id"]?.string()) { toolEnds.append(id) }
                else if ["thinking", "text"].contains(type) {
                    modelKinds.insert(type)
                    if type == "text", kind == "assistant", progress == nil,
                       let leading = f["text"]?.stringPrefix(maximumBytes: ProgressMarker.prefixBytes) {
                        progress = ProgressMarker.percent(leading: leading)
                    }
                }
            }
        }
        if kind == "user", fields["isMeta"]?.boolean() != true, fields["isSynthetic"]?.boolean() != true,
           humanOrigin || legacyHuman,
           toolEnds.isEmpty, let id = identifier(fields["promptId"]?.string() ?? fields["uuid"]?.string()) {
            var value = base; value["kind"] = "prompt"; value["promptId"] = id; result.append(value)
        }
        for id in toolEnds { var value = base; value["kind"] = "toolEnd"; value["itemId"] = id; result.append(value) }
        if kind == "user", toolEnds.count == 1,
           let response = fields["toolUseResult"].flatMap({ try? $0.fields(["status", "agentId", "background", "success", "revivedAgentId", "resumedAgentId"]) }),
           let launch = agentLaunch(response), launch.agent != thread {
            var value = base; value["kind"] = "agentResult"; value["itemId"] = toolEnds[0]
            value["agentId"] = launch.agent; value["agentStatus"] = launch.status; result.append(value)
        }
        // Claude Desktop's next-step box can end the turn from its tool result
        // (`claude/endTurn`, Claude Code 2.1.299); no end_turn or stop summary
        // follows. The turn is over and the box waits for the user's choice.
        // Only the engine's boolean is read, never the box's text.
        if kind == "user", toolEnds.count == 1, base["promptId"] != nil,
           let meta = fields["mcpMeta"].flatMap({ try? $0.fields(["_meta"]) })?["_meta"].flatMap({ try? $0.fields(["claude/endTurn"]) }),
           meta["claude/endTurn"]?.boolean() == true {
            var value = base; value["kind"] = "stopVerified"; value["itemId"] = toolEnds[0]; value["awaitsReply"] = true
            result.append(value)
        }
        if kind == "assistant" {
            let id = identifier(fields["uuid"]?.string() ?? message["id"]?.string()) ?? "assistant"
            if let messageID = identifier(message["id"]?.string()),
               let requestID = identifier(fields["requestId"]?.string()) ?? identifier(message["id"]?.string()),
               let usage = message["usage"].flatMap({ try? $0.fields(["output_tokens"]) }),
               let output = usage["output_tokens"]?.integer(), output > 0, output <= 1_000_000_000_000 {
                var value = base; value["kind"] = "modelBlock"; value["requestId"] = requestID
                value["messageId"] = messageID; value["outputTokens"] = output; value["toolIds"] = toolStarts.map { $0.0 }
                // Claude Code knows a response's stop reason only after it ends.
                if let stop = message["stop_reason"]?.string(limit: 64) ?? fields["stop_reason"]?.string(limit: 64), !stop.isEmpty { value["terminal"] = true }
                result.append(value)
            }
            for type in modelKinds.sorted() {
                var value = base; value["kind"] = type == "thinking" ? "thinking" : "response"
                if type == "text", let progress { value["progress"] = progress }
                value["itemId"] = id; result.append(value)
            }
            for (id, name) in toolStarts {
                var value = base; value["kind"] = "toolStart"; value["itemId"] = id
                // Closed enum only: tool names/arguments never leave the host.
                value["attention"] = name == "AskUserQuestion" ? "input" : name == "ExitPlanMode" ? "approval" : "none"
                if agentTools.contains(name) { value["agentTool"] = true }
                result.append(value)
            }
            if ["end_turn", "stop_sequence", "refusal"].contains(message["stop_reason"]?.string() ?? fields["stop_reason"]?.string() ?? "") {
                // Claude persists one API response per content block, and all
                // blocks can carry the same end_turn. A thinking block is not
                // an observed task ending; the post-hook summary verifies it.
                var value = base; value["kind"] = "stopRequested"; result.append(value)
            }
        }
        if kind == "result", let subtype = fields["subtype"]?.string(), ["success", "error_during_execution", "error_max_turns", "interrupted"].contains(subtype) {
            var value = base; value["kind"] = subtype == "success" ? "stop" : subtype == "interrupted" ? "interrupt" : "failure"; result.append(value)
        }
        if kind == "system", fields["subtype"]?.string() == "stop_hook_summary", fields["preventedContinuation"]?.boolean() == false,
           let errors = fields["hookErrors"], errors.isArray, (try? errors.countElements(maximumCount: 64)) == 0,
           let context = fields["hookAdditionalContext"], context.isArray, (try? context.countElements(maximumCount: 64)) == 0 {
            var value = base; value["kind"] = "stopVerified"; result.append(value)
        }
        return result.compactMap(encode)
    }
}

private final class ClaudeActivityDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter(), whole = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func parse(_ value: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: value) ?? whole.date(from: value)
    }
}

/// Local and SSH collectors deliver the same allowlisted envelope here.
struct ClaudeActivityState: Sendable {
    let sourceID: String?
    let sourceName: String?
    private var sessions: [String: SessionActivity] = [:]
    private var hooks: Set<String> = []
    private var historicalRunning: Set<String> = []
    private var unconfirmedBaseline: [String: Date] = [:]
    private var requests: [String: PendingAttentionRequest] = [:]
    private var metrics: [String: SessionPerformanceUpdate] = [:]
    private var observedMeters: [String: ClaudeObservedRequestMeter] = [:]
    private var typedInterruptPrompts: [String: String] = [:]
    private struct AgentTool: Sendable { let turn: String; let at: Double }
    private var agentTools: [String: AgentTool] = [:]
    private struct AgentCompletion: Sendable {
        let parent: String; let item: String; let turn: String; let toolStartedAt: Double; let launchedAt: Double
        let at: Double; let historical: Bool; let status: String
        var childTurn: String? = nil
        /// A background launch, or the ending of one.
        var background = false
    }
    /// A hook reads its clock only after its interpreter starts, so a
    /// background child's SubagentStart can be stamped after the launch result
    /// that started it. Only that run can begin this soon after its launch.
    private static let launchStartSkew = 5.0
    private var agentCompletions: [String: AgentCompletion] = [:]
    private var agentEnds: [String: AgentCompletion] = [:]
    private var agentLaunches: [String: AgentCompletion] = [:]
    /// When each child's previous run began. One call starts at most one run,
    /// so a launch can claim only the first run after its call started.
    private var previousRunStarts: [String: Double] = [:]
    /// Endings read before their launch, by child and tool item.
    private struct EarlyNotification: Sendable { let thread: String; let at: Double; let historical: Bool; let status: String }
    private var earlyNotifications: [String: EarlyNotification] = [:]
    /// When this source last delivered an exact request span.
    private var lastExactSample: Date?
    /// When each root's latest Stop listed no agent in flight. Claude Code lists
    /// every background task of the session there, agents that subagents launched
    /// included, so every child run begun before that Stop has ended.
    private var agentsIdle: [String: Double] = [:]
    /// When each root's live turn was last interrupted or failed. Claude Code
    /// aborts that turn's foreground agents and keeps background ones running,
    /// so only a child run that no background launch claims ends with it.
    private var rootInterrupts: [String: Double] = [:]
    private var excludedSessions: Set<String> = []
    private(set) var unmatchedRequests = 0
    private(set) var status = RuntimeStreamStatus()
    init(sourceID: String? = nil, sourceName: String? = nil) { self.sourceID = sourceID; self.sourceName = sourceName }
    var activities: [SessionActivity] { sessions.values.sorted { $0.id < $1.id } }
    var attention: [PendingAttentionRequest] { requests.values.sorted { $0.detectedAt < $1.detectedAt } }
    var performanceUpdates: [SessionPerformanceUpdate] { Array(metrics.values) }
    var knownStartedSessionIDs: Set<String> { excludedSessions.union(sessions.values.filter { $0.turnID != nil }.compactMap(\.threadID)) }
    var excludedActivityIDs: Set<String> { Set(excludedSessions.map { AgentProvider.claude.activityID(sessionID: $0, sourceHostID: nil) }) }
    /// Applies only to default-home Desktop mirrors, not independent SSH data.
    mutating func setExcludedSessionIDs(_ ids: Set<String>) {
        guard sourceID == nil else { return }
        excludedSessions = Set(ids.compactMap { ClaudeActivityRecord.identifier($0) })
        var changed = true
        while changed {
            changed = false
            for value in sessions.values {
                if let parent = value.parentThreadID, excludedSessions.contains(parent), let thread = value.threadID {
                    changed = excludedSessions.insert(thread).inserted || changed
                }
            }
        }
        for (id, value) in sessions where value.threadID.map(excludedSessions.contains) ?? false {
            sessions.removeValue(forKey: id); hooks.remove(id); historicalRunning.remove(id); metrics.removeValue(forKey: id)
            observedMeters.removeValue(forKey: id); typedInterruptPrompts.removeValue(forKey: id)
            agentCompletions.removeValue(forKey: id); agentEnds.removeValue(forKey: id)
            agentLaunches.removeValue(forKey: id); previousRunStarts.removeValue(forKey: id)
        }
        agentCompletions = agentCompletions.filter { !excludedSessions.contains($0.value.parent) }
        agentEnds = agentEnds.filter { !excludedSessions.contains($0.value.parent) }
        agentLaunches = agentLaunches.filter { !excludedSessions.contains($0.value.parent) }
        earlyNotifications = earlyNotifications.filter { !excludedSessions.contains($0.value.thread) }
        agentsIdle = agentsIdle.filter { !excludedSessions.contains($0.key) }
        rootInterrupts = rootInterrupts.filter { !excludedSessions.contains($0.key) }
        requests = requests.filter { !excludedSessions.contains($0.value.threadID) }
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
    }
    /// Runs after every read that caught up, the initial baseline included.
    mutating func finalizeHistoricalBaseline(now: Date = Date()) {
        // A read takes the hooks before the transcripts. Child runs that their
        // root outlived end once their records of this read applied.
        endOutlivedChildren(Array(sessions.keys), now: now, historical: true)
        for id in historicalRunning where [.running, .waitingForInput].contains(sessions[id]?.phase ?? .unknown) {
            guard let observed = sessions[id]?.lastObserved, now.timeIntervalSince(observed) <= 900 else { sessions[id]?.markSourceUnavailable(); continue }
            unconfirmedBaseline[id] = observed
        }
        historicalRunning.removeAll()
    }
    /// A baseline tail younger than 15 minutes may still be live. It is checked
    /// again once its evidence reaches that age; newer evidence releases it.
    mutating func expireUnconfirmedBaseline(now: Date = Date()) {
        for (id, observed) in unconfirmedBaseline {
            guard let value = sessions[id], [.running, .waitingForInput].contains(value.phase), value.lastObserved == observed else {
                unconfirmedBaseline.removeValue(forKey: id); continue
            }
            guard now.timeIntervalSince(observed) > 900 else { continue }
            sessions[id]?.markSourceUnavailable(); unconfirmedBaseline.removeValue(forKey: id)
        }
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
    }
    mutating func unavailable() {
        status.connected = false; status.sourceAvailable = nil; status.watchingLogs = false
        status.attachedThreads = 0; requests.removeAll()
        for id in Array(sessions.keys) where ![.completed, .interrupted].contains(sessions[id]!.phase) { sessions[id]?.markSourceUnavailable() }
    }
    /// A missing Claude home is a source issue, not proof of SSH failure.
    /// Parking the helper also ends its live connection evidence.
    mutating func sourceMissing() {
        unavailable(); status.sourceAvailable = false
    }
    mutating func consume(_ bytes: Data, now: Date = Date(), attaching: Bool = false) {
        guard bytes.count <= 1024 * 1024, let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        if frame["kind"] as? String == "status" {
            status.connected = frame["connected"] as? Bool == true
            status.sourceAvailable = frame["claudeHome"] as? Bool
            status.watchingLogs = frame["watchingLogs"] as? Bool == true
            status.fallbackScans = max(0, frame["scans"] as? Int ?? status.fallbackScans)
            status.helperLoopIterations = max(0, frame["loopIterations"] as? Int ?? status.helperLoopIterations)
            status.helperCpuSeconds = max(0, frame["cpuSeconds"] as? Double ?? status.helperCpuSeconds)
            if !status.connected { unavailable() }
            else if status.sourceAvailable == false { sourceMissing() }
            return
        }
        if frame["kind"] as? String == "claudeBatch", let rows = frame["records"] as? [[String: Any]], rows.count <= 512 {
            var live = false
            for row in rows {
                let historical = attaching || frame["attaching"] as? Bool == true || row["historical"] as? Bool == true
                consumeRecord(row, now: now, attaching: historical); live = live || !historical
            }
            if frame["baselineFinal"] as? Bool == true { finalizeHistoricalBaseline(now: now) }
            // A helper batch is one read: the hooks come first, so its child
            // records apply before the root's ending ends their runs.
            else if live { endOutlivedChildren(Array(sessions.keys), now: now, historical: false) }
            // A request's blocks can straddle a read budget. Only a batch that
            // ends a fully drained read (`baselineFinal`) has all of them.
            if live, frame["baselineFinal"] as? Bool == true { releaseCompletedRequests(now: now) }
        } else { consumeRecord(frame, now: now, attaching: attaching) }
        status.attachedThreads = sessions.values.filter { [.running, .waitingForInput].contains($0.phase) }.count
        if sessions.count > 128 {
            for id in sessions.keys.sorted(by: { (sessions[$0]?.lastObserved ?? .distantPast) > (sessions[$1]?.lastObserved ?? .distantPast) }).dropFirst(128) {
                sessions.removeValue(forKey: id); hooks.remove(id); metrics.removeValue(forKey: id); historicalRunning.remove(id); observedMeters.removeValue(forKey: id); typedInterruptPrompts.removeValue(forKey: id); agentCompletions.removeValue(forKey: id); agentEnds.removeValue(forKey: id); agentLaunches.removeValue(forKey: id); previousRunStarts.removeValue(forKey: id)
            }
        }
    }
    private mutating func consumeRecord(_ record: [String: Any], now: Date, attaching: Bool) {
        guard let kind = record["kind"] as? String, let session = ClaudeActivityRecord.identifier(record["sessionId"] as? String),
              let seconds = record["at"] as? Double, seconds.isFinite, seconds > 0, seconds <= now.timeIntervalSince1970 + 300 else { return }
        if sourceID == nil {
            if excludedSessions.contains(session) { return }
            if let parent = ClaudeActivityRecord.identifier(record["parentId"] as? String), excludedSessions.contains(parent) {
                if excludedSessions.count < 256 { excludedSessions.insert(session) }; return
            }
        }
        let date = Date(timeIntervalSince1970: seconds), origin = record["origin"] as? String ?? "telemetry"
        let thread = kind == "request" ? ClaudeActivityRecord.identifier(record["agentId"] as? String) ?? session : session
        let key = AgentProvider.claude.activityID(sessionID: thread, sourceHostID: sourceID)
        // Internal Claude agents also emit tool/stop hooks. A hook ID alone
        // cannot admit a child, including an unknown metadata-only orphan.
        if origin == "hook", ClaudeActivityRecord.identifier(record["parentId"] as? String) != nil,
           sessions[key]?.turnID == nil, kind != "subagentStart" { return }
        var value = sessions[key] ?? SessionActivity(id: thread, project: sourceName ?? "Claude Code", sourceHost: sourceName,
            sourceHostID: sourceID, phaseAwareRate: true, provider: .claude, sessionID: thread)
        // A child's hooks, transcript and telemetry carry its parent's current
        // prompt, which moves on while a background child keeps working. Until
        // it ends, the child's records belong to the turn its SubagentStart opened,
        // also while its source is unavailable: an SSH helper that reconnects
        // replays them.
        var record = record
        if kind != "subagentStart", kind != "prompt", value.parentThreadID != nil, ![.completed, .interrupted].contains(value.phase),
           let current = value.turnID, let incoming = ClaudeActivityRecord.identifier(record["promptId"] as? String), incoming != current {
            record["promptId"] = current
        }
        // The main thread's Stop counts the agents still in flight. None left
        // proves that each child run begun before it has ended, even one whose
        // own ending can no longer be matched.
        if kind == "stopRequested", origin == "hook", record["parentId"] == nil, value.parentThreadID == nil, record["agents"] as? Int == 0 {
            Self.note(&agentsIdle, thread, at: seconds)
        }
        if kind == "discontinuity" {
            observedMeters[key]?.markGap()
            guard !hooks.contains(key) else { return }
            value.markDiscontinuity(); sessions[key] = value; return
        }
        // An estimate can arrive after newer tool hooks: the display observer
        // runs in the background and transcripts are read after the hook
        // spool. It still belongs to the current turn, so it is applied
        // before the newest-evidence rule that lifecycle records follow.
        if let percent = record["progress"] as? Int, kind == "progress" || kind == "response" {
            if record["unownedTurn"] as? Bool != true,
               let turn = ClaudeActivityRecord.identifier(record["promptId"] as? String) ?? value.turnID, turn == value.turnID {
                value.reportProgress(percent, at: date, turnID: turn); sessions[key] = value
            }
            if kind == "progress" { return }
        }
        // The Stop hook saw background work this turn waits for: the request
        // is paused until a notification wakes it, so its ending is not shown.
        if kind == "waiting" {
            guard record["unownedTurn"] as? Bool != true, date >= (value.lastObserved ?? .distantPast) else { return }
            if let turn = ClaudeActivityRecord.identifier(record["promptId"] as? String) ?? value.turnID, turn == value.turnID {
                let kinds = (record["background"] as? [String] ?? []).map { String($0.prefix(24)) }
                value.waitForBackground(kinds: kinds, wakeups: record["wakeups"] as? Int ?? 0, at: date); sessions[key] = value
            }
            return
        }
        if kind == "metadata" {
            var event: [String: Any] = ["method": "metadata", "threadId": thread, "at": seconds]
            if let project = record["project"] as? String, !project.isEmpty { event["cwd"] = String(project.prefix(240)) }
            if let title = record["title"] as? String { event["name"] = String(title.prefix(240)) }
            if let model = record["model"] as? String { event["model"] = String(model.prefix(256)) }
            if let effort = record["effort"] as? String { event["reasoningEffort"] = String(effort.prefix(32)) }
            if let parent = ClaudeActivityRecord.identifier(record["parentId"] as? String) { event["parentThreadId"] = parent }
            value.applyRuntime(event)
            if sourceID == nil, let path = record["localDirectory"] as? String { value.setClaudeNavigation(directory: URL(fileURLWithPath: path), desktopSessionID: nil) }
            if let embedded = record["embedded"] as? Bool { value.setClaudeLaunch(embedded: embedded) }
            sessions[key] = value; return
        }
        if kind == "agentResult" {
            guard let turn = ClaudeActivityRecord.identifier(record["promptId"] as? String),
                  let item = ClaudeActivityRecord.identifier(record["itemId"] as? String), let tool = agentTools[key + ":" + item], tool.turn == turn, seconds >= tool.at,
                  let child = ClaudeActivityRecord.identifier(record["agentId"] as? String), child != thread,
                  let status = record["agentStatus"] as? String, ["completed", "async_launched"].contains(status) else { return }
            let childKey = AgentProvider.claude.activityID(sessionID: child, sourceHostID: sourceID)
            var ownership = AgentCompletion(parent: thread, item: item, turn: turn, toolStartedAt: tool.at, launchedAt: seconds,
                at: seconds, historical: attaching, status: status, background: status == "async_launched")
            if let observed = sessions[childKey], [.running, .waitingForInput].contains(observed.phase),
               let bound = boundAgentCompletion(ownership, to: observed) { ownership = bound }
            if status == "async_launched" {
                // Another copy of a launch already bound to its run, from the
                // transcript or a reconnect replay, keeps that run. Read after
                // a quick revival's SubagentStart, the copy could otherwise
                // claim the newer run inside the skew allowance, and the first
                // run's notification would end it.
                let existing = agentLaunches[childKey]
                let keepsRun = existing.map { $0.item == item && $0.parent == thread && $0.childTurn != nil } ?? false
                if !keepsRun, seconds >= (existing?.at ?? 0) { agentLaunches[childKey] = ownership }
                if agentLaunches.count > 128, let oldest = agentLaunches.min(by: { $0.value.at < $1.value.at })?.key { agentLaunches.removeValue(forKey: oldest) }
                if let launch = agentLaunches[childKey], launch.item == item, let notice = earlyNotifications.removeValue(forKey: childKey + ":" + item) {
                    settle(notice, of: launch, childKey: childKey, now: now)
                }
                return
            }
            agentCompletions[childKey] = ownership
            if agentCompletions.count > 128, let oldest = agentCompletions.min(by: { $0.value.at < $1.value.at })?.key { agentCompletions.removeValue(forKey: oldest) }
            applyAgentCompletion(childKey, now: now)
            return
        }
        if kind == "agentNotification" {
            guard let child = ClaudeActivityRecord.identifier(record["agentId"] as? String),
                  let item = ClaudeActivityRecord.identifier(record["itemId"] as? String),
                  let status = record["agentStatus"] as? String, ["completed", "failed", "killed"].contains(status) else { return }
            let childKey = AgentProvider.claude.activityID(sessionID: child, sourceHostID: sourceID)
            let notice = EarlyNotification(thread: thread, at: seconds, historical: attaching, status: status)
            guard let launch = agentLaunches[childKey], launch.item == item else {
                // The ending can be read before its launch: Claude Code may keep
                // a revived agent's notification in another file than the
                // SendMessage result, and a cold replay reads files in turn. It
                // waits for that launch, which still has to claim the run.
                earlyNotifications[childKey + ":" + item] = notice
                if earlyNotifications.count > 128, let oldest = earlyNotifications.min(by: { $0.value.at < $1.value.at })?.key { earlyNotifications.removeValue(forKey: oldest) }
                return
            }
            settle(notice, of: launch, childKey: childKey, now: now); return
        }
        if kind == "request" {
            // Completed spans only enrich an observed matching turn. They
            // cannot create running activity, a completion or a notification.
            // Both clocks originate on the same host. A tolerance before the
            // turn can misattribute a short previous request after a fast switch.
            let explicit = ClaudeActivityRecord.identifier(record["promptId"] as? String)
            guard sessions[key] != nil, let turn = explicit ?? value.turnID, value.turnID == turn,
                  record["promptId"] == nil || explicit != nil,
                  explicit != nil || (record["startedAt"] as? Double).map({ start in
                      value.turnStartedAt.map { start >= $0.timeIntervalSince1970 } ?? false
                  }) == true else {
                if unmatchedRequests < Int.max { unmatchedRequests += 1 }; return
            }
            guard
                  let responseID = ClaudeActivityRecord.identifier(record["requestId"] as? String),
                  let output = record["outputTokens"] as? Int, output > 0,
                  let spanStart = record["startedAt"] as? Double, spanStart.isFinite, spanStart < seconds,
                  let durationMs = record["durationMs"] as? Double, durationMs.isFinite, durationMs >= 10, durationMs <= 3_600_000,
                  let sample = ResponsePerformance(responseID: responseID, turnID: turn, outputTokens: output,
                    startedAt: date.addingTimeInterval(-durationMs / 1000), completedAt: date, source: .requestUsage) else { return }
            if thread != session {
                let parent = ClaudeActivityRecord.identifier(record["parentAgentId"] as? String) ?? session
                value.applyRuntime(["method": "metadata", "threadId": thread, "parentThreadId": parent, "at": seconds])
            }
            let ttft = (record["ttftMs"] as? Double).flatMap { $0.isFinite && $0 >= 0 && $0 / 1000 <= sample.duration ? $0 / 1000 : nil }
            let update = SessionPerformanceUpdate(id: key, turnID: turn, response: sample, firstTokenLatency: ttft,
                firstTokenReportedAt: ttft.map { Date(timeIntervalSince1970: spanStart).addingTimeInterval($0) })
            if let update { update.apply(to: &value); sessions[key] = value; metrics[key] = update; lastExactSample = now; status.exactRequestSpans = true }
            if observedMeters[key]?.turnID == turn { observedMeters[key]?.authoritative(responseID) }
            return
        }
        if kind == "modelBlock" {
            guard var meter = observedMeters[key], meter.turnID == value.turnID,
                  record["unownedTurn"] as? Bool != true,
                  (record["promptId"] as? String).map({ $0 == meter.turnID }) ?? true,
                  let requestID = ClaudeActivityRecord.identifier(record["requestId"] as? String),
                  let messageID = ClaudeActivityRecord.identifier(record["messageId"] as? String),
                  let output = record["outputTokens"] as? Int, let tools = record["toolIds"] as? [String], tools.count <= 128,
                  tools.allSatisfy({ ClaudeActivityRecord.identifier($0) != nil }) else { return }
            meter.modelBlock(id: requestID, messageID: messageID, outputTokens: output, toolIDs: tools, terminal: record["terminal"] as? Bool == true, at: date)
            observedMeters[key] = meter
            if value.phase == .completed, let end = agentEnds[key], end.childTurn == meter.turnID {
                settleAgentUsage(key, at: Date(timeIntervalSince1970: end.at))
            }
            return
        }
        if kind == "toolStart", record["agentTool"] as? Bool == true,
           let item = ClaudeActivityRecord.identifier(record["itemId"] as? String),
           let turn = ClaudeActivityRecord.identifier(record["promptId"] as? String), turn == value.turnID {
            let previous = agentTools[key + ":" + item]
            agentTools[key + ":" + item] = AgentTool(turn: turn, at: previous?.turn == turn ? min(previous?.at ?? seconds, seconds) : seconds)
            if agentTools.count > 512 { agentTools.removeValue(forKey: agentTools.keys.sorted().first!) }
        }
        if let item = ClaudeActivityRecord.identifier(record["itemId"] as? String), var meter = observedMeters[key],
           meter.turnID == value.turnID, (record["promptId"] as? String).map({ $0 == value.turnID }) ?? true {
            if kind == "toolStart" { meter.toolStarted(item, at: date) }
            else if kind == "toolEnd" { meter.toolEnded(item, at: date) }
            observedMeters[key] = meter
        }
        guard date >= (value.lastObserved ?? .distantPast) else { return }
        if origin == "hook" { hooks.insert(key) }
        if kind == "stopRequested" { return }
        if record["unownedTurn"] as? Bool == true, kind != "metadata" {
            return
        }
        if origin == "transcript", hooks.contains(key), !["stopVerified", "failure", "interrupt", "thinking", "response"].contains(kind) { return }
        if !["prompt", "subagentStart"].contains(kind), let incoming = ClaudeActivityRecord.identifier(record["promptId"] as? String),
           let current = value.turnID, incoming != current { return }
        var turn = ClaudeActivityRecord.identifier(record["promptId"] as? String) ?? value.turnID
        if kind == "interrupt", record["engineInterrupt"] as? Bool == true {
            guard turn == value.turnID, typedInterruptPrompts[key] != turn else { return }
            // An ended next-step box can still be dismissed. Its interrupt
            // clears the reply; SessionActivity preserves the verified ending.
            let endedReply = value.phase == .completed && requests.keys.contains { $0.hasPrefix(key + ":reply-") }
            guard [.running, .waitingForInput].contains(value.phase) || endedReply else { return }
        }
        if kind == "prompt", let prompt = ClaudeActivityRecord.identifier(record["promptId"] as? String) { turn = prompt }
        if turn == nil, ["toolStart", "response", "thinking", "subagentStart"].contains(kind) { turn = "attached-" + String(Int(seconds * 1000)) }
        // A revived child can start again inside the parent prompt that its
        // earlier run already used. An ended turn is retired, so the new run
        // gets its own; the child's records carrying that prompt then map to it.
        // SubagentStart fires only when a run begins, so a later one also opens
        // a new run while the earlier ending is still unread, as when a cold
        // replay drains the hooks before the transcript notifications. A copy
        // with the run's own start time, as a reconnecting SSH helper replays,
        // keeps that run.
        if kind == "subagentStart", let incoming = turn, value.parentThreadID != nil,
           let earlier = value.turnID, earlier == incoming || earlier.hasPrefix(incoming + ".run") {
            let started = value.turnStartedAt?.timeIntervalSince1970
            if started == seconds { turn = earlier }
            else if [.completed, .interrupted].contains(value.phase) || started.map({ seconds > $0 }) == true {
                turn = incoming + ".run" + String(Int((seconds * 1000).rounded()))
            }
        }
        guard let turn else { return }
        let observedTerminal = ["stopVerified", "stop", "interrupt", "failure", "subagentStop"].contains(kind) && value.liveTurnStarted && value.hasLiveEvidence
        let observedModel = ["thinking", "response"].contains(kind) && value.liveTurnStarted && value.hasLiveEvidence && (record["promptId"] as? String) == value.turnID
        let historical = attaching && !observedTerminal && !observedModel
        func event(_ method: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": thread, "turnId": turn, "at": seconds].merging(extra) { _, value in value }
        }
        if let parent = ClaudeActivityRecord.identifier(record["parentId"] as? String) {
            var metadata: [String: Any] = ["parentThreadId": parent]
            if let project = record["project"] as? String { metadata["cwd"] = String(project.prefix(240)) }
            value.applyRuntime(event("metadata", metadata))
        }
        let item = ClaudeActivityRecord.identifier(record["itemId"] as? String) ?? "event-" + String(Int(seconds * 1000))
        let earlierTurn = value.turnID, earlierStart = value.turnStartedAt
        switch kind {
        case "prompt":
            if value.turnID != turn { agentEnds.removeValue(forKey: key) }
            requests = requests.filter { $0.value.threadID != thread }
            if record["typedInterruptMarker"] as? Bool == true { typedInterruptPrompts[key] = turn }
            else { typedInterruptPrompts.removeValue(forKey: key) }
            let carried = value.currentProgress, waited = value.currentBackgroundWait != nil
            let continuesRequest = [.running, .waitingForInput].contains(value.phase) && (record["wake"] as? Bool == true || waited)
            value.applyRuntime(event(attaching ? "turn/attached" : "turn/started"))
            // A wake continues the request; so does a prompt typed while it waits.
            if let carried, continuesRequest { value.carryProgress(carried, at: date) }
            if observedMeters[key]?.turnID != turn { observedMeters[key] = ClaudeObservedRequestMeter(turnID: turn, observedStart: attaching ? nil : date) }
            else if !attaching { observedMeters[key]?.confirmStart(date) }
            noteSupersededRun(key, of: value, earlierTurn: earlierTurn, earlierStart: earlierStart)
        case "subagentStart":
            if value.turnID != turn { agentEnds.removeValue(forKey: key) }
            value.applyRuntime(event(attaching ? "turn/attached" : "turn/started"))
            if observedMeters[key]?.turnID != turn { observedMeters[key] = ClaudeObservedRequestMeter(turnID: turn, observedStart: attaching ? nil : date) }
            else if !attaching { observedMeters[key]?.confirmStart(date) }
            noteSupersededRun(key, of: value, earlierTurn: earlierTurn, earlierStart: earlierStart)
        case "toolStart":
            value.resumeBackgroundWork(at: date)
            value.applyRuntime(event("item/started", ["itemId": item, "itemType": "commandExecution"]))
            if let kind = (record["attention"] as? String).flatMap(PendingAttentionRequest.Kind.init(rawValue:)) {
                attention(kind, thread: thread, item: item, at: date)
                value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [kind == .approval ? "waitingOnApproval" : "waitingOnUserInput"]]))
            }
        case "toolEnd":
            value.applyRuntime(event("item/completed", ["itemId": item, "itemType": "commandExecution"]))
            let requestKey = AgentProvider.claude.activityID(sessionID: thread, sourceHostID: sourceID) + ":" + item
            requests.removeValue(forKey: requestKey)
            if let pending = requests.values.first(where: { $0.threadID == thread }) {
                value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [pending.kind == .approval ? "waitingOnApproval" : "waitingOnUserInput"]]))
            } else { value.applyRuntime(event("thread/status/changed", ["status": "active"])) }
        case "thinking", "response":
            value.resumeBackgroundWork(at: date)
            value.applyRuntime(event("item/started", ["itemId": item, "itemType": kind == "thinking" ? "reasoning" : "agentMessage", "hasText": false]))
        case "responseDelta":
            // Old adapters could copy the *current* prompt into a delayed
            // callback. Require the new adapter's verified input provenance.
            guard record["promptOwned"] as? Bool == true,
                  ClaudeActivityRecord.identifier(record["promptId"] as? String) != nil,
                  record["partial"] as? Bool == true, record["index"] as? Int == 0,
                  ClaudeActivityRecord.identifier(record["displayTurnId"] as? String) != nil, record["hasText"] as? Bool == true else { return }
            value.resumeBackgroundWork(at: date)
            value.applyRuntime(event("item/agentMessage/delta", ["itemId": item, "hasText": true]))
        case "approval", "input":
            attention(kind == "approval" ? .approval : .input, thread: thread, item: item, at: date)
            value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [kind == "approval" ? "waitingOnApproval" : "waitingOnUserInput"]]))
        case "attentionCleared":
            let requestKey = AgentProvider.claude.activityID(sessionID: thread, sourceHostID: sourceID) + ":" + item
            requests.removeValue(forKey: requestKey)
            if let pending = requests.values.first(where: { $0.threadID == thread }) {
                value.applyRuntime(event("thread/status/changed", ["status": "active", "flags": [pending.kind == .approval ? "waitingOnApproval" : "waitingOnUserInput"]]))
            } else { value.applyRuntime(event("thread/status/changed", ["status": "active"])) }
        case "stop", "stopVerified", "failure", "interrupt", "subagentStop":
            // A turn paused for its background work keeps running until the
            // wake; an interrupt or an error still ends it.
            if ["stop", "stopVerified"].contains(kind), value.currentBackgroundWait != nil { sessions[key] = value; return }
            let wasLive = [.running, .waitingForInput].contains(value.phase)
            value.applyRuntime(event("turn/completed", ["status": kind == "failure" ? "failed" : kind == "interrupt" ? "interrupted" : "completed"]))
            // Interrupting or failing the main thread's turn aborts its
            // foreground agents; Claude Code keeps the background ones running.
            if ["interrupt", "failure"].contains(kind), wasLive, value.parentThreadID == nil, value.phase == .interrupted {
                Self.note(&rootInterrupts, thread, at: seconds)
            }
            requests = requests.filter { $0.value.threadID != thread }
            // The ended turn's question stays until the next prompt answers it;
            // a baseline replay cannot tell whether it is still open.
            if kind == "stopVerified", record["awaitsReply"] as? Bool == true, !historical, value.phase == .completed {
                attention(.input, thread: thread, item: "reply-" + item, at: date)
            }
            if ["stop", "stopVerified", "subagentStop"].contains(kind), [.completed, .interrupted].contains(value.phase),
               let meter = observedMeters[key], meter.turnID == turn {
                for sample in meter.settled(at: date) {
                    if let update = SessionPerformanceUpdate(id: key, turnID: turn, response: sample, firstTokenLatency: nil, firstTokenReportedAt: nil) { update.apply(to: &value) }
                }
                if let update = SessionPerformanceUpdate(value) { metrics[key] = update }
            }
        case "unavailable":
            if ![.completed, .interrupted].contains(value.phase) { value.markSourceUnavailable() }
            requests = requests.filter { $0.value.threadID != thread }
        default: return
        }
        // A whole baseline must reach its explicit end before deciding that an
        // old running tail is unconfirmed. Per-record expiry hides old stops.
        if historical {
            value.suppressHistoricalCompletionNotifications()
            if [.running, .waitingForInput].contains(value.phase) { historicalRunning.insert(key) } else { historicalRunning.remove(key) }
        } else { historicalRunning.remove(key) }
        sessions[key] = value.canonicalized(); status.notifications += 1
        if ["prompt", "subagentStart", "toolStart", "thinking", "response"].contains(kind) {
            if let launch = agentLaunches[key] {
                if let bound = boundAgentCompletion(launch, to: value) { agentLaunches[key] = bound }
                else if value.turnStartedAt.map({ $0.timeIntervalSince1970 > launch.launchedAt + Self.launchStartSkew }) == true { agentLaunches.removeValue(forKey: key) }
            }
            applyAgentCompletion(key, now: now)
        }
    }
    /// A background ending settles the run its launch claims, once it comes
    /// from the same task and after the launch.
    private mutating func settle(_ notice: EarlyNotification, of launch: AgentCompletion, childKey: String, now: Date) {
        guard sameTask(launch.parent, notice.thread), notice.at >= launch.launchedAt else { return }
        agentCompletions[childKey] = AgentCompletion(parent: launch.parent, item: launch.item, turn: launch.turn,
            toolStartedAt: launch.toolStartedAt, launchedAt: launch.launchedAt, at: notice.at, historical: notice.historical, status: notice.status,
            childTurn: launch.childTurn, background: true)
        applyAgentCompletion(childKey, now: now)
    }
    private static func note(_ times: inout [String: Double], _ root: String, at seconds: Double) {
        guard seconds > times[root] ?? 0 else { return }
        times[root] = seconds
        if times.count > 128, let oldest = times.min(by: { $0.value < $1.value })?.key { times.removeValue(forKey: oldest) }
    }
    /// Ends each child run that its root outlived, at the run's latest evidence:
    /// a run begun before an agent-free Stop has ended, and one begun before an
    /// interrupted or failed root turn ended with it unless a background launch
    /// claims it. Their own endings may never match: a cold replay can lose the
    /// launch to a rotated spool or an unread transcript head, and an aborted
    /// foreground agent reports no result. An ended turn is retired, so later
    /// records of that run cannot reopen it.
    private mutating func endOutlivedChildren(_ keys: [String], now: Date, historical: Bool) {
        guard !agentsIdle.isEmpty || !rootInterrupts.isEmpty else { return }
        for key in keys {
            guard let child = sessions[key], let parent = child.parentThreadID, let thread = child.threadID,
                  [.running, .waitingForInput].contains(child.phase), let turn = child.turnID,
                  let start = child.turnStartedAt?.timeIntervalSince1970 else { continue }
            let root = rootThread(thread), kind: String
            if agentsIdle[root].map({ start <= $0 }) == true { kind = "subagentStop" }
            else if rootInterrupts[root].map({ start <= $0 }) == true,
                    agentLaunches[key].flatMap({ boundAgentCompletion($0, to: child) }) == nil { kind = "interrupt" }
            else { continue }
            consumeRecord(["kind": kind, "origin": "rootEnded", "sessionId": thread, "parentId": parent, "promptId": turn,
                           "at": max(start, child.lastObserved?.timeIntervalSince1970 ?? start)], now: now, attaching: historical)
        }
    }
    /// A child's new run supersedes its previous one. Remembering when that one
    /// began keeps any launch made before it from claiming the new run.
    private mutating func noteSupersededRun(_ key: String, of child: SessionActivity, earlierTurn: String?, earlierStart: Date?) {
        guard child.parentThreadID != nil, child.turnID != earlierTurn, let earlierStart else { return }
        previousRunStarts[key] = earlierStart.timeIntervalSince1970
    }
    /// The root session of a thread, following observed parents.
    private func rootThread(_ thread: String) -> String {
        var current = thread, seen: Set<String> = []
        while seen.insert(current).inserted, seen.count <= 16,
              let parent = sessions[AgentProvider.claude.activityID(sessionID: current, sourceHostID: sourceID)]?.parentThreadID {
            current = parent
        }
        return current
    }
    /// Hooks file every subagent under the root session, while Claude Code
    /// reports an agent to whichever agent launched or revived it. Ownership
    /// therefore holds anywhere within one task.
    private func sameTask(_ first: String, _ second: String) -> Bool {
        first == second || rootThread(first) == rootThread(second)
    }
    private func boundAgentCompletion(_ completion: AgentCompletion, to child: SessionActivity) -> AgentCompletion? {
        guard let parent = child.parentThreadID, sameTask(parent, completion.parent),
              let turn = child.turnID, let start = child.turnStartedAt?.timeIntervalSince1970 else { return nil }
        // Every run of a child has its own turn, so a bound launch follows that
        // turn even when a reconnect resumes it with a later start.
        if let childTurn = completion.childTurn { return childTurn == turn ? completion : nil }
        // One call starts at most one run: the launch claims the child's first
        // run after the call began, never one that follows it, however its
        // copies' timestamps fall around the skew allowance.
        let key = AgentProvider.claude.activityID(sessionID: child.threadID ?? "", sourceHostID: sourceID)
        guard start >= completion.toolStartedAt, previousRunStarts[key].map({ $0 < completion.toolStartedAt }) ?? true,
              start <= completion.launchedAt + (completion.background ? Self.launchStartSkew : 0) else { return nil }
        var bound = completion; bound.childTurn = turn; return bound
    }
    private mutating func applyAgentCompletion(_ key: String, now: Date) {
        guard let pending = agentCompletions[key], let child = sessions[key],
              let completion = boundAgentCompletion(pending, to: child), let childTurn = completion.childTurn,
              let thread = child.threadID else { return }
        agentCompletions.removeValue(forKey: key)
        guard completion.at >= (child.lastObserved?.timeIntervalSince1970 ?? 0) else { return }
        let kind = completion.status == "failed" ? "failure" : completion.status == "killed" ? "interrupt" : "subagentStop"
        consumeRecord(["kind": kind, "origin": "agentResult", "sessionId": thread,
            "parentId": child.parentThreadID ?? completion.parent, "promptId": childTurn, "at": completion.at], now: now, attaching: completion.historical)
        if [.completed, .interrupted].contains(sessions[key]?.phase ?? .unknown), sessions[key]?.turnID == childTurn {
            if completion.status == "completed" { agentEnds[key] = completion }
            agentLaunches.removeValue(forKey: key)
            let parentKey = AgentProvider.claude.activityID(sessionID: completion.parent, sourceHostID: sourceID)
            agentTools.removeValue(forKey: parentKey + ":" + completion.item)
        }
    }
    /// Without request spans, transcript-timed responses settle as each one
    /// ends rather than at the turn's end. Call after a whole read. While this
    /// source delivers exact spans they decide instead, so an estimate cannot
    /// show ahead of the span for the same response.
    mutating func releaseCompletedRequests(now: Date) {
        if let lastExactSample, now.timeIntervalSince(lastExactSample) < 1800 { return }
        for key in Array(observedMeters.keys) {
            guard var meter = observedMeters[key], var value = sessions[key], value.turnID == meter.turnID,
                  [.running, .waitingForInput].contains(value.phase) else { continue }
            let samples = meter.releaseCompleted()
            observedMeters[key] = meter
            guard !samples.isEmpty else { continue }
            for sample in samples {
                SessionPerformanceUpdate(id: key, turnID: meter.turnID, response: sample, firstTokenLatency: nil, firstTokenReportedAt: nil)?.apply(to: &value)
            }
            sessions[key] = value
            if let update = SessionPerformanceUpdate(value) { metrics[key] = update }
        }
    }
    private mutating func settleAgentUsage(_ key: String, at date: Date) {
        guard let meter = observedMeters[key], var value = sessions[key], value.turnID == meter.turnID else { return }
        for sample in meter.settled(at: date) {
            if let update = SessionPerformanceUpdate(id: key, turnID: meter.turnID, response: sample, firstTokenLatency: nil, firstTokenReportedAt: nil) { update.apply(to: &value) }
        }
        sessions[key] = value
        if let update = SessionPerformanceUpdate(value) { metrics[key] = update }
    }
    private mutating func attention(_ kind: PendingAttentionRequest.Kind, thread: String, item: String, at date: Date) {
        let id = AgentProvider.claude.activityID(sessionID: thread, sourceHostID: sourceID) + ":" + item
        if requests[id]?.kind != kind {
            requests[id] = PendingAttentionRequest(id: id, threadID: thread, sourceHostID: sourceID, sourceName: sourceName,
                kind: kind, detectedAt: date, provider: .claude)
        }
        if requests.count > 128, let oldest = requests.min(by: { $0.value.detectedAt < $1.value.detectedAt })?.key { requests.removeValue(forKey: oldest) }
    }
}
