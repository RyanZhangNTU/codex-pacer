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
    }

    struct Call {
        let modelID: String?
        let displayName: String?
        let tokens: Int?
        let duration: Double?

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

    static func typedSteps(_ data: Data, offset: Int, cascade: String, trajectory: String) throws -> [TypedStep] {
        guard let list = try JSONFieldView.document(data).fields(["steps"])["steps"] else { throw JSONFieldView.Failure.malformed }
        return try list.elements(maximumCount: 128).enumerated().map { position, element in
            let index = offset + position
            let fields = try element.fields(["type", "status", "metadata", "requestedInteraction"])
            guard let meta = try fields["metadata"]?.fields(["sourceTrajectoryStepInfo", "executionId", "createdAt", "viewableAt",
                                                              "finishedGeneratingAt", "internalMetadata", "requestedInteraction"]),
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
            return TypedStep(index: index, type: type, status: typedStatus,
                             created: AntigravityStore.date(meta["createdAt"]?.string()), transition: transition,
                             viewable: AntigravityStore.date(meta["viewableAt"]?.string()),
                             finished: AntigravityStore.date(meta["finishedGeneratingAt"]?.string()),
                             execution: meta["executionId"]?.string(limit: 128), wait: wait)
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
                  let model = try fields["chatModel"]?.fields(["responseModel", "modelDisplayName", "streamingDuration", "timeToFirstToken", "usage"]) else { continue }
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
                         displayName: model["modelDisplayName"]?.string(limit: 120), tokens: tokens, duration: duration)
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
            let waiting = open.compactMap { step in status(step) == .waiting ? typed[step.index] : nil }.first { $0.wait != nil }
            if let waiting, let kind = waiting.wait {
                at = waiting.transition ?? waiting.created ?? at
                pending = PendingAttentionRequest(id: CompletionDismissalStore.digest([turn, String(waiting.index), kind.rawValue]),
                    threadID: row.id, sourceHostID: nil, sourceName: AgentProvider.antigravity.displayName,
                    kind: kind, detectedAt: at, provider: .antigravity, suppressesNotice: watermark.map { at <= $0 } ?? true)
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
        return Result(activity: task, request: pending)
    }
}
