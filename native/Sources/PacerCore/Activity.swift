import Foundation

public enum ActivityPhase: String, Codable, Sendable {
    case running, waitingForInput, completed, interrupted, unknown
    public var label: String {
        switch self {
        case .running: return "正在处理任务"
        case .waitingForInput: return "等待你的回复"
        case .completed: return "任务已结束"
        case .interrupted: return "任务已中断"
        case .unknown: return "状态未确认"
        }
    }
}

public enum ActivityStage: String, Sendable {
    case starting, thinking, tool, responding
    public var label: String {
        switch self {
        case .starting: return "正在处理"
        case .thinking: return "正在处理下一步"
        case .tool: return "正在执行工具"
        case .responding: return "已输出回复，任务仍在继续"
        }
    }
}

public struct SessionActivity: Equatable, Sendable, Identifiable {
    public let id: String
    public var project: String
    public private(set) var threadID: String?
    public var threadURL: URL? { threadID.flatMap { URL(string: "codex://threads/" + $0) } }
    public private(set) var phase: ActivityPhase = .unknown
    public private(set) var turnID: String?
    public private(set) var lastObserved: Date?
    public private(set) var phaseChangedAt: Date?
    public private(set) var stage: ActivityStage = .starting
    public private(set) var modelName: String?
    private var waitingCallID: String?
    private var toolCalls: Set<String> = []
    private var outputRate = OutputRate()

    public init(id: String, project: String = "本地任务") {
        self.id = id
        self.project = project
        threadID = UUID(uuidString: String((id as NSString).deletingPathExtension.suffix(36)))?.uuidString.lowercased()
    }

    public func observedPhase(at now: Date = Date()) -> ActivityPhase {
        guard let lastObserved, now.timeIntervalSince(lastObserved) < 180 else { return .unknown }
        return phase
    }
    public func tokensPerSecond(at now: Date) -> Double? {
        observedPhase(at: now) == .running ? outputRate.tokensPerSecond(at: now) : nil
    }
    public func detail(at now: Date) -> String {
        if observedPhase(at: now) == .unknown, phase == .waitingForInput { return "最后状态：等待你的回复" }
        if observedPhase(at: now) == .unknown, phase == .running, stage == .tool { return "最后状态：等待工具结果" }
        return observedPhase(at: now) == .running ? stage.label : observedPhase(at: now).label
    }

    public mutating func consume(_ line: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = value["payload"] as? [String: Any] else { return }
        if value["type"] as? String == "session_meta" {
            if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            if let id = payload["id"] as? String, let uuid = UUID(uuidString: id) { threadID = uuid.uuidString.lowercased() }
            return
        }
        if value["type"] as? String == "turn_context" {
            modelName = payload["model"] as? String
            return
        }
        guard ["event_msg", "response_item"].contains(value["type"] as? String ?? ""),
              let timestamp = value["timestamp"] as? String,
              let date = Self.parseDate(timestamp),
              date >= (lastObserved ?? .distantPast) else { return }
        lastObserved = date
        let kind = payload["type"] as? String
        if value["type"] as? String == "response_item" {
            consumeResponse(payload, kind: kind, at: date)
            return
        }
        let eventTurn = payload["turn_id"] as? String
        switch kind {
        case "task_started":
            turnID = eventTurn
            phase = .running
            stage = .starting
            waitingCallID = nil
            toolCalls.removeAll()
            outputRate.startTurn(at: date)
            phaseChangedAt = date
        case "task_complete", "turn_aborted":
            // A late completion from a previous turn must not end the current turn.
            guard turnID == nil || eventTurn == turnID else { return }
            phase = kind == "turn_aborted" ? .interrupted : .completed
            waitingCallID = nil
            toolCalls.removeAll()
            outputRate.finishTurn()
            phaseChangedAt = date
        case "token_count":
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any],
               let output = total["output_tokens"] as? Int {
                outputRate.observe(totalOutput: output, at: date)
            }
        default: break
        }
    }

    private mutating func consumeResponse(_ payload: [String: Any], kind: String?, at date: Date) {
        switch kind {
        case "function_call", "custom_tool_call":
            guard let callID = payload["call_id"] as? String else { return }
            if toolCalls.count < 64 { toolCalls.insert(callID) }
            let name = payload["name"] as? String ?? ""
            // The async input tool returns immediately and does not pause the task.
            if name == "request_user_input" || name.hasSuffix(".request_user_input") {
                waitingCallID = callID
                phase = .waitingForInput
                phaseChangedAt = date
            } else if phase == .running { stage = .tool }
        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String else { return }
            guard toolCalls.contains(callID) || waitingCallID == callID else { return }
            toolCalls.remove(callID)
            if waitingCallID == callID {
                waitingCallID = nil
                phase = .running
                phaseChangedAt = date
            }
            if phase == .running { stage = toolCalls.isEmpty ? .thinking : .tool }
        case "reasoning":
            if phase == .running && toolCalls.isEmpty { stage = .thinking }
        case "message":
            if phase == .running, payload["role"] as? String == "assistant" { stage = .responding }
        default: break
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Reads only today's and yesterday's most recently modified session files.
/// Startup and catch-up reads are bounded; conversation text is never retained.
public actor LocalActivityReader {
    private struct Cursor {
        var offset: UInt64
        var fragment: Data
        var activity: SessionActivity
        var identity: UInt64
    }
    private var cursors: [URL: Cursor] = [:]
    private let maxFiles = 16
    private let maxBytes = 128 * 1024
    private let startupBytes = 512 * 1024

    public init() {}
    public func reset() { cursors.removeAll() }

    public func read(home: URL, now: Date = Date()) -> (activities: [SessionActivity], watchURLs: [URL]) {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now)!]
        var files: [(URL, Date)] = []
        var watchURLs: [URL] = []
        let manager = FileManager.default
        for day in days {
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
        let selected = Array(files.sorted { $0.1 > $1.1 }.prefix(maxFiles).map(\.0))
        cursors = cursors.filter { selected.contains($0.key) }
        for file in selected {
            guard let attributes = try? manager.attributesOfItem(atPath: file.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            var cursor = cursors[file]
            if cursor == nil || cursor!.offset > size || cursor!.identity != identity {
                var activity = SessionActivity(id: file.lastPathComponent)
                if let header = try? handle.read(upToCount: 65536), let end = header.firstIndex(of: 10) {
                    activity.consume(header.prefix(upTo: end))
                }
                cursor = Cursor(offset: 0, fragment: Data(), activity: activity, identity: identity)
            }
            guard var current = cursor else { continue }
            var dropPartial = false
            let budget = current.offset == 0 ? startupBytes : maxBytes
            if size - current.offset > UInt64(budget) {
                current.offset = size - UInt64(budget)
                current.fragment.removeAll()
                current.activity = SessionActivity(id: current.activity.id, project: current.activity.project)
                dropPartial = true
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
                cursors[file] = current
            } catch { continue }
        }
        return (cursors.values.map(\.activity).sorted { ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast) },
                Array(Set(watchURLs + selected)))
    }
}
