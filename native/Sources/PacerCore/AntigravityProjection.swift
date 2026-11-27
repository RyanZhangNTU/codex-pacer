import Foundation

struct AntigravityProjection {
    enum Status: String {
        case done = "DONE", canceled = "CANCELED", error = "ERROR", waiting = "WAITING"
        case running = "RUNNING", generating = "GENERATING", pending = "PENDING"

        init?(database: Int) {
            switch database {
            case 2: self = .running
            case 3: self = .done
            case 6: self = .canceled
            case 7: self = .error
            case 8: self = .generating
            case 9: self = .waiting
            default: return nil
            }
        }

        var settled: Bool { self == .done || self == .canceled || self == .error }
    }

    struct TypedStep {
        let index: Int
        let type: Int
        var status: Status?
        let created: Date?
        let transition: Date?
        let viewable: Date?
        let finished: Date?
        let execution: String?
        let wait: PendingAttentionRequest.Kind?
        var progress: Int?
        var completed: Date?
        var requestsProgressApproval = false
        var usesProgressServer = false
        var unidentifiedMCPTool = false
    }

    struct Call {
        let modelID: String?
        let displayName: String?
        let tokens: Int?
        let duration: Double?
        let permitsMissedToolInference: Bool

        func performance(planner: TypedStep, turn: String, started: Date) -> ResponsePerformance? {
            guard let tokens, let duration, (1...3600).contains(duration),
                  let created = planner.created, let end = planner.finished,
                  created >= started.addingTimeInterval(-1), end >= started, end > created,
                  abs(end.timeIntervalSince(created) - duration) <= 1 else { return nil }
            return ResponsePerformance(responseID: String(planner.index), turnID: turn, outputTokens: tokens,
                startedAt: end.addingTimeInterval(-duration), completedAt: end, source: .requestUsage)
        }
    }

    /// Metadata caches belong to one trajectory and input anchor. Rebuild mutable step
    /// state on every successful read, retaining only settled timing outside the tail.
    struct Enrichment {
        var steps: [Int: TypedStep] = [:]
        var firstViewable: Date?
        var planner: TypedStep?
        var responses: [(step: TypedStep, call: Call)] = []
        var call: Call? { responses.last?.step.index == planner?.index ? responses.last?.call : nil }
        var catalog = AntigravityModelCatalog()
        var fetchedPlanner: Int?
        var child: SubagentDisplay?
        var runState: AntigravityStore.RunState?
        var updated: Date?
        var fresh = false
        var conflictingFamily = false
        var conflictingState = false
    }

    static func typedSteps(_ data: Data, offset: Int, anchor: Int?, cascade: String, trajectory: String) throws -> [TypedStep] {
        guard let list = try JSONFieldView.document(data).fields(["steps"])["steps"] else { throw JSONFieldView.Failure.malformed }
        return try list.elements(maximumCount: 128).enumerated().map { position, element in
            let index = offset + position
            let fields = try element.fields(["type", "status", "metadata", "requestedInteraction", "generic", "mcpTool"])
            guard let meta = try fields["metadata"]?.fields(["sourceTrajectoryStepInfo", "executionId", "createdAt", "viewableAt",
                                                              "finishedGeneratingAt", "completedAt", "internalMetadata", "requestedInteraction"]),
                  let owner = try meta["sourceTrajectoryStepInfo"]?.fields(["cascadeId", "trajectoryId", "stepIndex"]),
                  AntigravityStore.uuid(owner["cascadeId"]?.string()) == cascade,
                  AntigravityStore.uuid(owner["trajectoryId"]?.string()) == trajectory,
                  (owner["stepIndex"] == nil ? 0 : owner["stepIndex"]?.integer()) == index else { throw JSONFieldView.Failure.malformed }
            let type: Int
            let name = fields["type"]?.string()
            switch name {
            case "CORTEX_STEP_TYPE_USER_INPUT": type = 14
            case "CORTEX_STEP_TYPE_PLANNER_RESPONSE": type = 15
            case "CORTEX_STEP_TYPE_SYSTEM_MESSAGE": type = 101
            default: type = name?.hasPrefix("CORTEX_STEP_TYPE_") == true ? 132 : -1
            }
            let status = fields["status"]?.string(limit: 64)
            let prefix = "CORTEX_STEP_STATUS_"
            let typedStatus = status.flatMap { $0.hasPrefix(prefix) ? Status(rawValue: String($0.dropFirst(prefix.count))) : nil }
            let interaction = try (fields["requestedInteraction"] ?? meta["requestedInteraction"])?.fields(["askQuestion", "permission"])
            var wait: PendingAttentionRequest.Kind?
            if interaction?.count == 1 {
                if interaction?["permission"]?.isObject == true { wait = .approval }
                if interaction?["askQuestion"]?.isObject == true { wait = .input }
            }
            let transitions = try meta["internalMetadata"]?.fields(["statusTransitions"])["statusTransitions"]?.elements(maximumCount: 64)
            let changed = try transitions?.last?.fields(["updatedStatus", "timestamp"])
            let transition = changed?["updatedStatus"]?.string() == status ? AntigravityStore.date(changed?["timestamp"]?.string()) : nil
            var percent: Int?
            var usesProgressServer = false, unidentifiedMCPTool = false
            var asksForProgress = false
            if name == "CORTEX_STEP_TYPE_GENERIC" {
                let args = try? fields["generic"]?.fields(["args"])["args"]?.fields(["ServerName", "ToolName", "Arguments"])
                unidentifiedMCPTool = args == nil
                usesProgressServer = args?["ServerName"]?.matchesStringLiteral(AntigravityProgressPlugin.server) == true
                if usesProgressServer, typedStatus == .done, let anchor, index > anchor,
                   args?["ToolName"]?.matchesStringLiteral(CodexProgressEvidence.tool) == true,
                   let json = args?["Arguments"]?.string(limit: 128) {
                    percent = CodexProgressEvidence.percent(json)
                }
            } else if name == "CORTEX_STEP_TYPE_MCP_TOOL" {
                // 2.35.2 retypes a finished call as MCP_TOOL; a waiting call stays GENERIC.
                let tool = try? fields["mcpTool"]?.fields(["serverName", "toolCall"])
                usesProgressServer = tool?["serverName"]?.matchesStringLiteral(AntigravityProgressPlugin.server) == true
                unidentifiedMCPTool = tool?["serverName"]?.hasNonemptyString != true
                if usesProgressServer, typedStatus == .done, let anchor, index > anchor,
                   let call = try? tool?["toolCall"]?.fields(["name", "argumentsJson"]),
                   call["name"]?.matchesStringLiteral(CodexProgressEvidence.tool) == true,
                   let json = call["argumentsJson"]?.string(limit: 128) {
                    percent = CodexProgressEvidence.percent(json)
                }
            }
            if let anchor, index > anchor {
                // An omitted wire status is filled from the database before the projection selects waiting steps.
                if typedStatus == .waiting || typedStatus == nil, wait == .approval,
                   let resource = try? interaction?["permission"]?.fields(["resource"])["resource"]?.fields(["action", "target"]) {
                    asksForProgress = resource["action"]?.string(limit: 4) == "mcp" &&
                        resource["target"]?.string(limit: 64) == AntigravityProgressPlugin.toolTarget
                }
            }
            return TypedStep(index: index, type: type, status: typedStatus,
                             created: AntigravityStore.date(meta["createdAt"]?.string()), transition: transition,
                             viewable: AntigravityStore.date(meta["viewableAt"]?.string()),
                             finished: AntigravityStore.date(meta["finishedGeneratingAt"]?.string()),
                             execution: meta["executionId"]?.string(limit: 128), wait: wait, progress: percent,
                             completed: AntigravityStore.date(meta["completedAt"]?.string()) ?? transition, requestsProgressApproval: asksForProgress,
                             usesProgressServer: usesProgressServer, unidentifiedMCPTool: unidentifiedMCPTool)
        }
    }

    /// The negative evidence belongs to the whole conversation, across input anchors.
    /// Keep the settled prefix in constant space as steps fall out of the API tail.
    struct ProgressToolHistory {
        private struct Prefix {
            var nextIndex = 0
            var firstInput: (index: Int, at: Date)?
            var finishedTool = false
        }
        private var prefix = Prefix()
        private var rulesOutMiss = false
        private(set) var lastProgressToolAt: Date?

        mutating func observe(_ row: AntigravityStore.Summary, trajectory: AntigravityStore.Trajectory?,
                              transcript: AntigravityTranscript, live: Enrichment) -> MissedProgressConversation? {
            guard live.fresh, !live.conflictingState else { return nil }
            for step in live.steps.values where step.usesProgressServer || (step.status == .waiting && step.requestsProgressApproval) {
                rulesOutMiss = true
                if step.status == .waiting || step.status == .done {
                    let at = step.completed ?? step.transition ?? step.created ?? row.updated
                    lastProgressToolAt = max(lastProgressToolAt ?? .distantPast, at)
                }
            }
            if live.responses.contains(where: { !$0.call.permitsMissedToolInference }) { rulesOutMiss = true }
            guard !rulesOutMiss, row.parent == nil, row.depth == 0,
                  let tail = trajectory?.tail, let offset = tail.first?.index else { return nil }

            if offset == 0 { prefix = Prefix() }
            if let input = prefix.firstInput, let record = transcript.records[input.index],
               record.type != "USER_INPUT" || abs(record.created.timeIntervalSince(input.at)) >= 1 {
                prefix = Prefix()
            }
            var scan = prefix
            if scan.nextIndex < offset {
                // A cold start may have only transcript records before the tail. They
                // identify built-in tools but cannot tell which server handled MCP.
                guard offset - scan.nextIndex <= transcript.records.count else { return nil }
                for index in scan.nextIndex..<offset {
                    guard let record = transcript.records[index] else { return nil }
                    switch record.type {
                    case "USER_INPUT": if scan.firstInput == nil { scan.firstInput = (index, record.created) }
                    case "PLANNER_RESPONSE", "SYSTEM_MESSAGE": break
                    case "GENERIC", "MCP_TOOL": return nil
                    default: if scan.firstInput != nil { scan.finishedTool = true }
                    }
                }
                scan.nextIndex = offset
                prefix = scan
            }
            for (position, local) in tail.enumerated() {
                guard local.index == offset + position, let step = live.steps[local.index], !step.unidentifiedMCPTool else { return nil }
                guard step.index >= scan.nextIndex else { continue }
                if scan.firstInput == nil, step.type == 14 {
                    let record = transcript.records[step.index]
                    let summaryTime = row.inputIndex == step.index ? row.inputTime : nil
                    guard let date = step.created ?? (record?.type == "USER_INPUT" ? record?.created : nil) ?? summaryTime else { return nil }
                    scan.firstInput = (step.index, date)
                }
                if scan.firstInput != nil, step.type == 132, step.status == .done { scan.finishedTool = true }
                scan.nextIndex = step.index + 1
                if prefix.nextIndex == step.index, step.status?.settled == true { prefix = scan }
            }
            guard let input = scan.firstInput, scan.finishedTool else { return nil }
            return .init(id: row.id, firstInputAt: input.at)
        }
    }

    // Older responses can omit the tool list. If supplied, inspect only its names.
    private static func permitsMissedToolInference(_ tools: JSONFieldView?) -> Bool {
        guard let tools else { return true }
        guard let entries = try? tools.elements(maximumCount: 256) else { return false }
        return entries.allSatisfy {
            guard let name = try? $0.fields(["name"])["name"]?.string(limit: 128), !name.isEmpty else { return false }
            return name != "call_mcp_tool"
        }
    }

    static func calls(_ data: Data, planners: [TypedStep]) throws -> [Int: Call] {
        let owned = Dictionary(uniqueKeysWithValues: planners.map { ($0.index, $0) })
        let records = try JSONFieldView.document(data).fields(["generatorMetadata"])["generatorMetadata"]?.elements(maximumCount: 4096)
        var matches: [Int: Call] = [:]
        var ambiguous: Set<Int> = []
        for record in records ?? [] {
            let fields = try record.fields(["stepIndices", "executionId", "chatModel"])
            let execution = fields["executionId"]?.string()
            let indices = try fields["stepIndices"]?.elements(maximumCount: 128).compactMap { value -> Int? in
                guard let index = value.integer(), let planner = owned[index] else { return nil }
                if let execution, let owner = planner.execution, execution != owner { return nil }
                return index
            } ?? []
            guard !indices.isEmpty,
                  let model = try fields["chatModel"]?.fields(["responseModel", "modelDisplayName", "streamingDuration", "timeToFirstToken", "usage", "tools"]) else { continue }
            let usage = try model["usage"]?.fields(["outputTokens", "thinkingOutputTokens", "responseOutputTokens"])
            func count(_ key: String) -> Int? {
                guard let n = usage?[key]?.unsignedInteger(), n <= UInt64(Int32.max) else { return nil }
                return Int(n)
            }
            var tokens = count("outputTokens")
            if usage?["outputTokens"] == nil, let thought = count("thinkingOutputTokens"), let reply = count("responseOutputTokens") {
                tokens = thought + reply
            }
            func seconds(_ key: String) -> Double? {
                guard let raw = model[key]?.string(limit: 40), raw.hasSuffix("s"),
                      let value = Double(raw.dropLast()), value.isFinite, value >= 0 else { return nil }
                return value
            }
            let duration = seconds("timeToFirstToken").flatMap { first in seconds("streamingDuration").map { first + $0 } }
            let call = Call(modelID: model["responseModel"]?.string(limit: 128),
                         displayName: model["modelDisplayName"]?.string(limit: 120), tokens: tokens, duration: duration,
                         permitsMissedToolInference: permitsMissedToolInference(model["tools"]))
            for index in Set(indices) {
                if matches.updateValue(call, forKey: index) != nil { ambiguous.insert(index) }
            }
        }
        for index in ambiguous { matches.removeValue(forKey: index) }
        return matches
    }

    struct Turn {
        let id: String
        var started: Date
        var dated: Bool

        mutating func reconcileStart(_ date: Date?) -> Bool {
            guard let date else { return true }
            if dated && abs(date.timeIntervalSince(started)) >= 1 { return false }
            started = date
            dated = true
            return true
        }
    }

    struct Result {
        var activity: SessionActivity
        var request: PendingAttentionRequest?
        var needsRecheck = false
    }

    static func project(_ row: AntigravityStore.Summary, trajectory: AntigravityStore.Trajectory?,
                        transcript: AntigravityTranscript, live: Enrichment, dependent: Bool, unconfirmedDependent: Bool, watermark: Date?,
                        turnCache: inout Turn?, witnessed: String?, previous: SessionActivity?, dependentEnded: Date?, scope: String) -> Result {
        let updated = max(row.updated, live.updated ?? .distantPast)
        func session(_ stage: ActivityStage) -> SessionActivity {
            var task = SessionActivity.observedSession(provider: .antigravity, session: row.id, stage: stage, at: updated)
            task.updateParent(row.parent)
            task.applyObservedTitle(row.parent == nil ? row.title : nil, project: nil)
            task.subagentDisplay = live.child
            return task
        }
        var task = session(.starting)
        func unknown(recheck: Bool = false) -> Result {
            task.markSourceUnavailable()
            return Result(activity: task, needsRecheck: recheck)
        }
        guard !live.conflictingState, let trajectory, let last = trajectory.last else { return unknown() }

        let typed = live.fresh ? live.steps : [:]
        func status(_ step: AntigravityStore.Step) -> Status? {
            typed[step.index]?.status ?? Status(database: step.status)
        }
        // An API transition can arrive before its integer reaches SQLite (and vice versa).
        // Keep unresolved DB steps older than the bounded API tail, too.
        let offset = trajectory.tail[0].index
        let open = trajectory.unresolved.filter { $0.index < offset } + trajectory.tail.filter { status($0)?.settled != true }
        let runState = live.runState ?? row.runState
        let active = runState == .running || (live.runState == nil && !open.isEmpty)
        guard let anchor = trajectory.anchor else {
            guard active else { return unknown() }
            if open.contains(where: { $0.type == 132 }) { return Result(activity: session(.tool)) }
            return Result(activity: session(last.type == 15 ? .thinking : .starting))
        }
        let record = transcript.records[anchor.index]
        let recorded = record?.type == (anchor.type == 14 ? "USER_INPUT" : "SYSTEM_MESSAGE") ? record?.created : nil
        let hinted = anchor.type == 14 && (row.inputIndex < 0 || row.inputIndex == anchor.index) ? row.inputTime : nil
        // A matching summary hint can retain fractions missing from a transcript.
        let fileStart: Date?
        if let recorded, let hinted, abs(recorded.timeIntervalSince(hinted)) >= 1 { fileStart = recorded }
        else { fileStart = hinted ?? recorded }
        let created = typed[anchor.index]?.created ?? fileStart
        // An undated input still has an owned DB index. Keep its identity as the
        // transcript, summary and API fill in the time on subsequent passes.
        if turnCache?.reconcileStart(created) != true {
            let identity = created.map { String(floor($0.timeIntervalSince1970)) } ?? "undated"
            turnCache = Turn(id: CompletionDismissalStore.digest([scope, row.id, trajectory.id, String(anchor.index), identity]),
                             started: created ?? updated, dated: created != nil)
        }
        guard let cached = turnCache else { return unknown() }
        let started = cached.started, turn = cached.id
        let observed = watermark.map { (cached.dated && started > $0) || witnessed == turn } ?? false
        let settled = live.planner
        let plannerIndex = trajectory.tail.last(where: { $0.type == 15 && status($0)?.settled == true })?.index ?? settled?.index
        let plannerRecord = plannerIndex.flatMap { transcript.records[$0] }.flatMap {
            $0.type == "PLANNER_RESPONSE" && $0.created >= started.addingTimeInterval(-1) ? $0 : nil
        }
        let matchingCall = settled?.index == plannerIndex ? live.call : nil
        func resolve(_ id: String?, display: String? = nil) -> AntigravityModel? {
            id.flatMap(live.catalog.resolve) ?? AntigravityModel(id: id, displayName: display)
        }
        let model = resolve(plannerRecord?.model) ?? resolve(matchingCall?.modelID, display: matchingCall?.displayName)
        let state: SessionActivity.ObservedTurnState
        var pending: PendingAttentionRequest?, background: String?, toolSince: Date?
        var at = updated

        if runState == .idle, open.isEmpty {
            if unconfirmedDependent && !dependent { return unknown() }
            if dependent || (row.runState == .idle && row.background) {
                guard live.fresh || dependent else { return unknown() }
                state = .working(.tool); background = dependent ? "subagent" : "background"
            } else if status(last) == .canceled {
                state = .interrupted(failed: false)
            } else if last.type == 15, status(last) == .done {
                state = .finished
            } else { return unknown() }
        } else if active {
            let waits = open.compactMap { step in status(step) == .waiting ? typed[step.index] : nil }
            let waiting = waits.first(where: \.requestsProgressApproval) ?? waits.first { $0.wait != nil }
            if let waiting, let kind = waiting.wait {
                at = waiting.transition ?? waiting.created ?? at
                let identity = waiting.requestsProgressApproval ? [row.id, String(waiting.index)] : [turn, String(waiting.index), kind.rawValue]
                pending = PendingAttentionRequest(id: CompletionDismissalStore.digest(identity),
                    threadID: row.id, sourceHostID: nil, sourceName: AgentProvider.antigravity.displayName,
                    kind: kind, detectedAt: at, provider: .antigravity, suppressesNotice: watermark.map { at <= $0 } ?? true)
                pending?.requestsProgressApproval = waiting.requestsProgressApproval
                state = .waiting(kind)
            } else if open.contains(where: { $0.type == 132 }) {
                state = .working(.tool)
                toolSince = open.filter { $0.type == 132 }.compactMap { typed[$0.index] }.compactMap { $0.transition ?? $0.created }.min()
            } else if open.isEmpty, dependent {
                state = .working(.tool); background = "subagent"
            } else if open.contains(where: { $0.type == 15 }) || [15, 132].contains(last.type) {
                state = .working(.thinking)
            } else { state = .working(.starting) }
        } else { return unknown(recheck: live.runState == .idle && !open.isEmpty) }

        switch state {
        case .finished, .interrupted:
            let phase: ActivityPhase = status(last) == .canceled ? .interrupted : .completed
            if let previous, previous.turnID == turn, previous.phase == phase, let ended = previous.phaseChangedAt {
                at = ended
            } else if previous?.turnID == turn, previous?.currentBackgroundWait != nil, let dependentEnded {
                at = max(at, dependentEnded)
            }
        case .working, .waiting: break
        }
        task.applyObservedTurn(state, id: turn, started: started, at: at, live: observed, model: model?.name, effort: model?.effort)
        if let previous { task.mergePerformance(from: previous) }
        task.observeToolStart(toolSince)
        if let background { task.waitForBackground(kinds: [background], wakeups: 0, at: at) }
        let sample = live.responses.reversed().lazy.compactMap {
            $0.call.performance(planner: $0.step, turn: turn, started: started)
        }.first
        let first = cached.dated && anchor.type == 14 ? live.firstViewable : nil
        SessionPerformanceUpdate(id: task.id, turnID: turn, response: sample, firstTokenLatency: first?.timeIntervalSince(started),
                                 firstTokenReportedAt: first)?.apply(to: &task)
        if let watermark {
            if let prior = previous?.currentProgress, prior.turnID == turn, prior.reportedAt > watermark {
                task.reportProgress(prior.percent, at: prior.reportedAt, turnID: turn)
            }
            for step in typed.values.sorted(by: { $0.index < $1.index }) where step.index > anchor.index {
                if let percent = step.progress, let completed = step.completed, completed > watermark {
                    task.reportProgress(percent, at: completed, turnID: turn)
                }
            }
        }
        return Result(activity: task, request: pending)
    }
}
