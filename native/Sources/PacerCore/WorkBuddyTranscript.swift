import Foundation

/// WorkBuddy writes one JSON object per line. Project only the fields used to
/// match a turn, its tool calls and its final reply.
struct WorkBuddyTranscript {
    struct Question: Equatable {
        let call: String
        let time: Date
    }

    struct Turn: Equatable {
        enum Ending: Equatable { case reply, cancelled, failed }
        struct Estimate: Equatable { let percent: Int; let at: Date }
        struct Model: Equatable {
            let requestedID: String
            let executedID: String
            var label: String?
            var displayName: String { label ?? (executedID == "default-model" ? L10n.text("provider.automatic") : executedID) }
        }
        struct Response: Equatable {
            let step: Int
            let id: String
            let start: Date?
            var boundary: Date
            var accounted = false
        }
        let id: String
        let started: Date
        var tail: String
        var ending: Ending?
        var ended: Date?
        var question: Question?
        var model: Model?
        var effort: String?
        var calls: Set<String> = []
        var pendingProgress: [String: Estimate] = [:]
        var progress: Estimate?
        var response: Response?
        var rate: ResponsePerformance?

        mutating func observeResponse(_ metadata: [String: JSONFieldView], at time: Date) {
            guard let step = metadata["stepSeq"]?.integer(), step > 0,
                  let message = WorkBuddyTranscript.identifier(metadata["messageId"]) else { return }
            if let previous = response, previous.step == step {
                guard previous.id == message else { response = .init(step: step, id: message, start: nil, boundary: time); return }
            } else {
                if let previous = response, previous.step > step { return }
                let start: Date?
                if let previous = response {
                    start = previous.step == step - 1 && calls.isEmpty ? previous.boundary : nil
                } else {
                    start = step == 1 && calls.isEmpty ? started : nil
                }
                response = .init(step: step, id: message, start: start, boundary: time)
            }
            guard var response else { return }
            response.boundary = max(response.boundary, time)
            // WorkBuddy attaches the response's usage to its last model item.
            // Tool results only advance the boundary for the following step.
            if !response.accounted, let usage = try? metadata["usage"]?.fields(["outputTokens", "requests"]),
               usage["requests"]?.integer() == 1, let tokens = usage["outputTokens"]?.integer(), (1...100_000_000).contains(tokens) {
                response.accounted = true
                if let start = response.start,
                   let measured = ResponsePerformance(responseID: message, turnID: id, outputTokens: tokens,
                                                      startedAt: start, completedAt: time, source: .observedRequest) {
                    rate = measured
                }
            }
            self.response = response
        }

        func applyMeasurements(to task: inout SessionActivity, turnID: String, credits: Double?, notBefore: Date? = nil) {
            if let credits, notBefore.map({ started >= $0 }) ?? true { task.setTurnCredits(credits, turnID: turnID) }
            if let progress, progress.at >= (notBefore ?? started) {
                task.reportProgress(progress.percent, at: progress.at, turnID: turnID)
            }
            if let rate, rate.startedAt >= (notBefore ?? started),
               let sample = ResponsePerformance(responseID: rate.responseID, turnID: turnID, outputTokens: rate.outputTokens,
                    startedAt: rate.startedAt, completedAt: rate.completedAt, source: rate.source),
               let update = SessionPerformanceUpdate(id: task.id, turnID: turnID, response: sample,
                    firstTokenLatency: nil, firstTokenReportedAt: nil) {
                update.apply(to: &task)
            }
        }
    }

    private(set) var turn: Turn?
    private var identity: String?
    private var offset: UInt64 = 0
    private var droppingLine = false
    private static let readLimit = 256 * 1024
    private static let eventFields: Set<String> = ["type", "role", "status", "sessionId", "id", "parentId",
        "timestamp", "providerData", "name", "callId", "content", "arguments", "output", "isError", "is_error"]
    private static let metadataFields: Set<String> = ["conversationRequestId", "startsNewUserRequest", "isPartialAborted",
        "skipRun", "model", "requestModelId", "requestModelName", "responseModelId", "responseModelName", "messageId", "stepSeq", "usage"]

    mutating func observeThoughtLevel(_ effort: String?, selectedModel: String?, updated: Date) {
        // The database holds the session's current selection. Keep the first
        // matching setting for this observed turn and ignore later edits.
        guard var current = turn, let model = current.model, model.requestedID == selectedModel, current.effort == nil,
              let effort = ModelDisplay.sanitizedEffort(effort),
              ["disabled", "enabled", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort),
              current.ended.map({ updated <= $0.addingTimeInterval(3) }) ?? true else { return }
        current.effort = effort
        turn = current
    }

    /// Only advance past complete lines. A file replacement or a tail beyond
    /// the read budget requires a fresh turn anchor before reporting an end.
    mutating func read(_ file: URL, session: String, files: any PlatformFileSystem, now: Date) throws {
        guard let metadata = files.metadata(file), metadata.isRegularFile else {
            self = Self()
            return
        }
        if identity != metadata.identity || offset > metadata.size || metadata.size - offset > UInt64(Self.readLimit) {
            self = Self()
            identity = metadata.identity
            if metadata.size > UInt64(Self.readLimit) {
                offset = metadata.size - UInt64(Self.readLimit)
                droppingLine = true
            }
        }
        guard metadata.size > offset else { return }
        let data = try files.read(file, offset: offset, maximumBytes: Int(metadata.size - offset))
        guard files.metadata(file)?.identity == identity else { self = Self(); return }
        var start = data.startIndex
        for end in data.indices where data[end] == 10 {
            if !droppingLine, end > start {
                if !consume(Data(data[start..<end]), session: session, now: now) { turn = nil }
            }
            droppingLine = false
            start = end + 1
        }
        offset += UInt64(start - data.startIndex)
    }

    @discardableResult mutating func consume(_ bytes: Data, session: String, now: Date) -> Bool {
        guard let root = try? JSONFieldView.document(bytes, maximumBytes: Self.readLimit),
              let values = try? root.fields(Self.eventFields) else { return false }
        guard let type = values["type"]?.string(), ["message", "reasoning", "function_call", "function_call_result"].contains(type),
              values["sessionId"]?.string() == session,
              let id = Self.identifier(values["id"]),
              let stamp = values["timestamp"]?.integer(), stamp > 0,
              let metadata = try? values["providerData"]?.fields(Self.metadataFields),
              let request = Self.identifier(metadata["conversationRequestId"]) else { return true }
        let time = Date(timeIntervalSince1970: Double(stamp) / 1000)
        guard time <= now.addingTimeInterval(1) else { return true }
        if type == "message", values["role"]?.matchesStringLiteral("user") == true {
            guard metadata["startsNewUserRequest"]?.boolean() == true else { return true }
            if let turn, time < turn.started || turn.id == request { return true }
            turn = Turn(id: request, started: time, tail: id)
            return true
        }
        guard var current = turn, current.id == request, time >= current.started else { return true }
        let parent = Self.identifier(values["parentId"])
        let cancelled = metadata["isPartialAborted"]?.boolean() == true ||
            (metadata["skipRun"]?.boolean() == true && values["status"]?.matchesStringLiteral("incomplete") == true)
        if cancelled {
            current.ending = .cancelled
            current.ended = time
            current.question = nil
            turn = current
            return true
        }
        guard parent == current.tail, current.ending != .cancelled else { return true }
        current.tail = id
        if type == "reasoning" || type == "function_call" ||
            (type == "message" && values["role"]?.matchesStringLiteral("assistant") == true && values["status"]?.matchesStringLiteral("completed") == true) {
            if var model = Self.model(metadata) {
                if let previous = current.model, previous.requestedID == model.requestedID {
                    if model.executedID == previous.executedID { model.label = model.label ?? previous.label }
                } else { current.effort = nil }
                current.model = model
            }
            current.observeResponse(metadata, at: time)
        }
        switch type {
        case "function_call":
            guard let call = Self.identifier(values["callId"]), current.calls.count < 64 else { return false }
            current.calls.insert(call)
            current.ending = nil
            current.ended = nil
            if values["name"]?.matchesStringLiteral("AskUserQuestion") == true {
                current.question = Question(call: call, time: time)
            }
            if let percent = Self.progressPercent(name: values["name"], arguments: values["arguments"]) {
                current.pendingProgress[call] = .init(percent: percent, at: time)
            }
        case "function_call_result":
            guard let call = Self.identifier(values["callId"]), current.calls.remove(call) != nil else { return false }
            if let boundary = current.response?.boundary { current.response?.boundary = max(boundary, time) }
            if current.question?.call == call { current.question = nil }
            // WorkBuddy can stamp a response a few milliseconds before it
            // persists the matching call. The call ID and parent still agree.
            if let estimate = current.pendingProgress.removeValue(forKey: call), time >= estimate.at.addingTimeInterval(-1),
               max(time, estimate.at) >= (current.progress?.at ?? .distantPast),
               values["status"]?.matchesStringLiteral("completed") == true,
               values["isError"]?.boolean() != true, values["is_error"]?.boolean() != true,
               CodexProgressEvidence.textReceiptAccepted(values["output"]) {
                current.progress = .init(percent: estimate.percent, at: max(time, estimate.at))
            }
        case "message":
            guard values["role"]?.matchesStringLiteral("assistant") == true else { return true }
            if values["status"]?.matchesStringLiteral("completed") == true,
               current.calls.isEmpty, Self.hasOutputText(values["content"]) {
                current.ending = .reply
                current.ended = time
            }
            if values["status"]?.matchesStringLiteral("failed") == true {
                current.ending = .failed
                current.ended = time
            }
        default: break
        }
        turn = current
        return true
    }

    private static func model(_ metadata: [String: JSONFieldView]) -> Turn.Model? {
        let requested = modelIdentifier(metadata["requestModelId"])
        let reported = modelIdentifier(metadata["responseModelId"]) ?? modelIdentifier(metadata["model"])
        guard let requestedID = requested ?? reported else { return nil }
        let executed = reported == "default-model" ? requestedID : reported ?? requestedID
        let responseName = modelIdentifier(metadata["responseModelName"])
        let name = responseName ??
            (executed == requestedID && executed != "default-model" ? modelIdentifier(metadata["requestModelName"]) : nil)
        return .init(requestedID: requestedID, executedID: executed, label: name)
    }

    private static func modelIdentifier(_ field: JSONFieldView?) -> String? {
        guard let value = field?.string(limit: 257), !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.hasPrefix("<") else { return nil }
        return value
    }

    private static func identifier(_ value: JSONFieldView?) -> String? {
        guard let value = value?.string(limit: 129), (1...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }) else { return nil }
        return value
    }

    private static func progressPercent(name: JSONFieldView?, arguments: JSONFieldView?) -> Int? {
        if name?.matchesStringLiteral(CodexProgressEvidence.qualified) == true {
            return CodexProgressEvidence.percentInToolArguments(arguments)
        }
        // WorkBuddy resolves deferred MCP tools through a native wrapper.
        // Only open the bounded arguments for that wrapper, never arbitrary tools.
        guard name?.matchesStringLiteral("DeferExecuteTool") == true, let arguments else { return nil }
        let object: JSONFieldView
        if arguments.isObject { object = arguments }
        else {
            guard let raw = arguments.string(limit: 512),
                  let decoded = try? JSONFieldView.document(Data(raw.utf8), maximumBytes: 512) else { return nil }
            object = decoded
        }
        guard let wrapper = try? object.fields(["toolName", "params"], maximumCount: 4),
              wrapper["toolName"]?.matchesStringLiteral(CodexProgressEvidence.qualified) == true else { return nil }
        return CodexProgressEvidence.percent(wrapper["params"])
    }

    private static func hasOutputText(_ content: JSONFieldView?) -> Bool {
        guard let items = try? content?.elements(maximumCount: 64) else { return false }
        return items.contains {
            guard let fields = try? $0.fields(["type", "text"]) else { return false }
            return fields["type"]?.matchesStringLiteral("output_text") == true && fields["text"]?.hasNonemptyString == true
        }
    }

}
