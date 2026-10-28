import Foundation

/// One DeepSeek Harness v4 session-log event reduced to lifecycle, routing and
/// numeric fields. Message text, tool arguments and results, approval reasons
/// and job labels are never copied out of the parsed line.
enum DeepSeekLogEvent: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        let session: String
        let createdAt: Date
        let project: String?
        let parent: String?
    }
    struct Response: Equatable, Sendable {
        let turn: Int
        let step: Int
        let model: String?
        let usage: DeepSeekUsage?
        /// The first streamed block and the last streamed chunk.
        let firstChunkAt: Date?
        let lastChunkAt: Date?
        let hasText: Bool
        let hasReasoning: Bool
        let toolCalls: Int
    }
    case header(Header)
    case title(String)
    /// `provider` names how Harness bills, such as `deepseek-account`.
    case model(String, effort: String?, reported: Bool, provider: String?)
    case turnStart(Int)
    case stepStart(turn: Int, step: Int)
    case response(Response)
    case toolCall(turn: Int, call: String, kind: ToolKind)
    case toolResult(call: String)
    case approvalAsked(id: String, call: String?)
    case approvalDecided(id: String)
    case turnEnd(turn: Int, outcome: Outcome)

    /// A search or fetch call is billed per call; `name` is kept only for its price.
    enum ToolKind: Equatable, Sendable { case other, question, search(String) }
    enum Outcome: Equatable, Sendable { case completed, failed, interrupted }
}

struct DeepSeekLogRecord: Equatable, Sendable {
    let seq: Int?
    let at: Date
    let event: DeepSeekLogEvent
}

enum DeepSeekSessionLog {
    static let maximumLineBytes = 4 << 20
    /// Large bodies that carry no lifecycle evidence are skipped before parsing.
    private static let wanted: Set<String> = ["session", "session/title", "model/selection", "request/context", "request/header", "turn/start", "step/start",
        "assistant/message", "tool/call", "tool/result", "approval/asked", "approval/decided", "turn/end"]

    static func identifier(_ value: Any?) -> String? {
        guard let raw = value as? String, !raw.isEmpty, raw.utf8.count <= 128,
              raw.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil else { return nil }
        return raw
    }
    /// `session-<uuid>` for a root session, a bare UUID for a delegated child.
    static func sessionID(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let body = raw.hasPrefix("session-") ? String(raw.dropFirst(8)) : raw
        return UUID(uuidString: body)?.uuidString.lowercased()
    }
    static func type(of line: Data) -> String? {
        let prefix = line.prefix(96)
        guard prefix.starts(with: Data(#"{"type":""#.utf8)) else { return nil }
        let rest = prefix.dropFirst(9)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
    }

    /// `light` reads a baseline: responses keep usage and model but skip their
    /// text-bearing stream. A truncated line can still yield a light response.
    static func parse(_ line: Data, truncated: Bool = false, light: Bool = false) -> DeepSeekLogRecord? {
        guard let type = type(of: line), wanted.contains(type) else { return nil }
        if type == "tool/result" { return lightToolResult(line) }
        if type == "request/header" { return lightConfiguration(line) }
        if type == "assistant/message", light || truncated { return lightResponse(line) }
        guard !truncated, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if type == "session" {
            guard object["version"] as? Int == 4, let session = sessionID(object["id"]),
                  let created = milliseconds(object["createdAt"]) else { return nil }
            let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).lastPathComponent : nil }
            return DeepSeekLogRecord(seq: nil, at: created, event: .header(.init(session: session, createdAt: created,
                project: cwd.map { String($0.prefix(240)) }, parent: sessionID(object["parentSession"]))))
        }
        guard let at = milliseconds(object["time"]), let data = object["data"] as? [String: Any] else { return nil }
        let seq = object["seq"] as? Int
        func record(_ event: DeepSeekLogEvent) -> DeepSeekLogRecord { DeepSeekLogRecord(seq: seq, at: at, event: event) }
        let turn = (data["turn"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        switch type {
        case "session/title":
            guard let title = data["title"] as? String else { return nil }
            return record(.title(String(title.prefix(240))))
        case "model/selection", "request/context":
            return model(data).map(record)
        case "turn/start":
            return turn.map { record(.turnStart($0)) }
        case "step/start":
            guard let turn, let step = data["step"] as? Int else { return nil }
            return record(.stepStart(turn: turn, step: step))
        case "assistant/message":
            guard let turn, let step = data["step"] as? Int else { return nil }
            return record(.response(response(data, turn: turn, step: step)))
        case "tool/call":
            guard let turn, let call = identifier(data["callId"]) else { return nil }
            let name = (data["name"] as? String ?? "").lowercased()
            let kind: DeepSeekLogEvent.ToolKind = ["ask_user_question", "ask_user", "question"].contains(name) ? .question
                : DeepSeekPricing.searchTools.contains(name) ? .search(name) : .other
            return record(.toolCall(turn: turn, call: call, kind: kind))
        case "approval/asked":
            return identifier(data["id"]).map { record(.approvalAsked(id: $0, call: identifier(data["callId"]))) }
        case "approval/decided":
            return identifier(data["id"]).map { record(.approvalDecided(id: $0)) }
        case "turn/end":
            guard let turn else { return nil }
            let kind = ((data["reason"] as? [String: Any])?["kind"] as? String ?? "").lowercased()
            let outcome: DeepSeekLogEvent.Outcome = kind == "completed" ? .completed : ["error", "failed", "failure"].contains(kind) ? .failed : .interrupted
            return record(.turnEnd(turn: turn, outcome: outcome))
        default: return nil
        }
    }

    private static func model(_ data: [String: Any]) -> DeepSeekLogEvent? {
        guard let model = ModelDisplay.sanitizedModel(data["model"]) else { return nil }
        let reported = data.keys.contains("reasoningEffort")
        return .model(model, effort: reported ? ModelDisplay.sanitizedEffort(data["reasoningEffort"]) : nil, reported: reported,
            provider: ModelDisplay.sanitizedEffort(data["provider"]))
    }
    /// A request header lists every tool schema; only its leading config is read.
    private static func lightConfiguration(_ line: Data) -> DeepSeekLogRecord? {
        guard let head = envelope(line, before: #","data":"#),
              let start = line.prefix(1024).range(of: Data(#""config":{"#.utf8))?.upperBound,
              let close = line[start..<min(line.endIndex, start + 512)].firstIndex(of: UInt8(ascii: "}")),
              let config = try? JSONSerialization.jsonObject(with: line[(start - 1)...close]) as? [String: Any],
              let event = model(config) else { return nil }
        return DeepSeekLogRecord(seq: head.seq, at: head.at, event: event)
    }

    private static func response(_ data: [String: Any], turn: Int, step: Int) -> DeepSeekLogEvent.Response {
        let message = data["message"] as? [String: Any], source = message?["source"] as? [String: Any]
        let blocks = ((source?["replayState"] as? [String: Any])?["blocks"] as? [[String: Any]] ?? []).prefix(256).compactMap { $0["type"] as? String }
        let raw = data["usage"] as? [String: Any]
        let usage = raw.flatMap { value -> DeepSeekUsage? in
            guard let input = value["inputTokens"] as? Int, let output = value["outputTokens"] as? Int else { return nil }
            return DeepSeekUsage(input: input, cacheRead: value["cacheReadTokens"] as? Int ?? 0,
                cacheWrite: value["cacheWriteTokens"] as? Int ?? 0, output: output)
        }
        // A `*-chunks` run starts at `time0`; each `dt` is the gap to the
        // previous chunk. A block start can precede its first chunk.
        var first: Date?, opened: Date?, last: Date?, text = false, reasoning = false
        for entry in (data["stream"] as? [[String: Any]] ?? []).prefix(4096) {
            guard let type = entry["type"] as? String else { continue }
            if type == "chunk" {
                guard let at = milliseconds(entry["time"]), let chunk = entry["chunk"] as? [String: Any] else { continue }
                if chunk["type"] as? String == "block-start" { opened = min(opened ?? at, at) }
                last = max(last ?? at, at)
            } else if type.hasSuffix("-chunks"), let start = milliseconds(entry["time0"]) {
                let offsets = (entry["dt"] as? [Any] ?? []).prefix(65_536).compactMap { ($0 as? NSNumber)?.doubleValue }
                guard !offsets.isEmpty || !(entry["texts"] as? [Any] ?? []).isEmpty else { continue }
                let end = start.addingTimeInterval(max(0, offsets.reduce(0, +)) / 1000)
                first = min(first ?? start, start); last = max(last ?? end, end)
                if type == "text-chunks" { text = true } else if type == "reasoning-chunks" { reasoning = true }
            }
        }
        return .init(turn: turn, step: step, model: ModelDisplay.sanitizedModel(source?["model"]), usage: usage,
            firstChunkAt: first ?? opened, lastChunkAt: last, hasText: text || blocks.contains("text"),
            hasReasoning: reasoning || blocks.contains("reasoning"), toolCalls: blocks.filter { $0 == "tool-call" }.count)
    }

    /// The envelope and turn/step precede the message body.
    private static func envelope(_ line: Data, before marker: String) -> (seq: Int?, at: Date, data: [String: Any])? {
        guard let end = line.prefix(512).range(of: Data(marker.utf8))?.lowerBound else { return nil }
        let inData = marker != #","data":"#
        guard let object = try? JSONSerialization.jsonObject(with: line[line.startIndex..<end] + Data((inData ? "}}" : "}").utf8)) as? [String: Any],
              let at = milliseconds(object["time"]) else { return nil }
        return (object["seq"] as? Int, at, object["data"] as? [String: Any] ?? [:])
    }
    private static func string(after marker: String, in line: Data, within limit: Int) -> String? {
        guard let start = line.range(of: Data(marker.utf8))?.upperBound else { return nil }
        let window = line[start..<min(line.endIndex, start + limit)]
        guard let end = window.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: window[window.startIndex..<end], as: UTF8.self)
    }
    private static func lightToolResult(_ line: Data) -> DeepSeekLogRecord? {
        guard let head = envelope(line, before: #","message":"#),
              let call = identifier(string(after: #""toolCallId":""#, in: line.prefix(1024), within: 160)) else { return nil }
        return DeepSeekLogRecord(seq: head.seq, at: head.at, event: .toolResult(call: call))
    }
    private static func lightResponse(_ line: Data) -> DeepSeekLogRecord? {
        guard let head = envelope(line, before: #","message":"#), let turn = head.data["turn"] as? Int, turn > 0,
              let step = head.data["step"] as? Int else { return nil }
        // The response's own usage follows its message ID. Text cannot contain
        // this unescaped sequence; a tool input object would also need the ID.
        var usage: DeepSeekUsage?
        if let marker = line.range(of: Data(#""},"usage":{"inputTokens":"#.utf8)),
           line[max(line.startIndex, marker.lowerBound - 44)..<marker.lowerBound].range(of: Data(#""id":""#.utf8)) != nil {
            let start = marker.lowerBound + 11, tail = line[start..<min(line.endIndex, start + 512)]
            if let close = tail.firstIndex(of: UInt8(ascii: "}")),
               let value = try? JSONSerialization.jsonObject(with: line[start...close]) as? [String: Any],
               let input = value["inputTokens"] as? Int, let output = value["outputTokens"] as? Int {
                usage = DeepSeekUsage(input: input, cacheRead: value["cacheReadTokens"] as? Int ?? 0,
                    cacheWrite: value["cacheWriteTokens"] as? Int ?? 0, output: output)
            }
        }
        var model: String?
        if let source = line.range(of: Data(#""kind":"model","provider":""#.utf8)) {
            model = string(after: #""model":""#, in: line[source.upperBound..<min(line.endIndex, source.upperBound + 512)], within: 256)
        }
        return DeepSeekLogRecord(seq: head.seq, at: head.at, event: .response(.init(turn: turn, step: step,
            model: ModelDisplay.sanitizedModel(model), usage: usage, firstChunkAt: nil, lastChunkAt: nil,
            hasText: false, hasReasoning: false, toolCalls: 0)))
    }

    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue / 1000
        guard seconds.isFinite, seconds > 1_500_000_000, seconds < 4_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
