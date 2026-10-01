import Foundation

public enum ActivityPhase: String, Codable, Sendable {
    case running, waitingForInput, completed, interrupted, unknown
    public var label: String {
        switch self {
        case .running: return "正在处理任务"
        case .waitingForInput: return "等待你的回复"
        case .completed: return "空闲"
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
        case .thinking: return "思考中"
        case .tool: return "正在执行工具"
        case .responding: return "输出回复"
        }
    }
}

public struct SessionActivity: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceHost: String?
    public let sourceHostID: String?
    public private(set) var title: String?
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
    public private(set) var lastObserved: Date?
    public private(set) var phaseChangedAt: Date?
    public private(set) var stage: ActivityStage = .starting
    public private(set) var modelName: String?
    public private(set) var isInternalReview = false
    private var waitingCallID: String?
    private var toolCalls: Set<String> = []
    private var outputRate = OutputRate()

    public init(id: String, project: String = "本地任务", sourceHost: String? = nil, sourceHostID: String? = nil) {
        self.id = id
        self.sourceHost = sourceHost
        self.sourceHostID = sourceHostID
        self.project = project
        threadID = UUID(uuidString: String((id as NSString).deletingPathExtension.suffix(36)))?.uuidString.lowercased()
    }

    mutating func updateTitle(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed?.isEmpty == false ? String(trimmed!.prefix(240)) : nil
    }

    public func observedPhase(at now: Date = Date()) -> ActivityPhase {
        if [.completed, .interrupted].contains(phase) { return phase }
        guard lastObserved != nil else { return .unknown }
        // A long tool call or sparse counter reports do not end an observed turn.
        return phase
    }
    public func tokensPerSecond(at now: Date) -> Double? {
        observedPhase(at: now) == .running ? outputRate.tokensPerSecond(at: now) : nil
    }
    public func outputEstimate(at now: Date) -> OutputEstimate? {
        phase == .running ? outputRate.estimate(at: now) : nil
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
            if let title = payload["title"] as? String { updateTitle(title) }
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let role = (subagent?["other"] as? String)?.lowercased()
            let threadSource = (payload["thread_source"] as? String)?.lowercased()
            isInternalReview = isInternalReview || ["guardian", "auto_review", "autoreview"].contains(role ?? "") ||
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

    private mutating func beginTurn(_ id: String?, at date: Date) {
        turnID = id
        phase = .running
        stage = .starting
        lastObserved = date
        waitingCallID = nil
        toolCalls.removeAll()
        outputRate.startTurn(at: date)
        phaseChangedAt = date
    }

    /// Retain provenance while rejecting lifecycle/rate assumptions across a gap.
    mutating func markDiscontinuity() {
        phase = .unknown
        turnID = nil
        lastObserved = nil
        phaseChangedAt = nil
        waitingCallID = nil
        toolCalls.removeAll()
        outputRate = OutputRate()
    }

    mutating func markUnconfirmed() {
        phase = .unknown
        outputRate.finishTurn()
    }

    private mutating func observeWork(at date: Date) {
        if [.completed, .interrupted, .unknown].contains(phase) {
            // Fresh reasoning/calls prove activity, but do not identify a turn.
            beginTurn(phase == .unknown ? turnID : nil, at: date)
        }
    }

    private mutating func consumeResponse(_ payload: [String: Any], kind: String?, at date: Date) {
        switch kind {
        case "function_call", "custom_tool_call":
            guard let callID = payload["call_id"] as? String else { return }
            observeWork(at: date)
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
            observeWork(at: date)
            if phase == .running && toolCalls.isEmpty { stage = .thinking }
        case "message":
            if payload["role"] as? String == "assistant", payload["phase"] as? String == "commentary" {
                observeWork(at: date)
            }
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
        let indexed = SessionIndex.entries(home: home)
        for entry in indexed {
            let file = entry.url
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if !files.contains(where: { $0.0 == file }) { files.append((file, date)) }
            watchURLs.append(file.deletingLastPathComponent())
        }
        for (file, cursor) in cursors where [.running, .waitingForInput].contains(cursor.activity.phase) && !files.contains(where: { $0.0 == file }) {
            files.append((file, cursor.activity.lastObserved ?? .distantPast))
        }
        // Reviews must not consume the user-task discovery slots.
        var selected = cursors.filter { [.running, .waitingForInput].contains($0.value.activity.phase) }.map(\.key)
        let candidates = Array(files.sorted { $0.1 > $1.1 }.prefix(256).map(\.0))
        metadata = metadata.filter { candidates.contains($0.key) }
        for file in candidates {
            guard selected.count < maxFiles else { break }
            let identity = ((try? manager.attributesOfItem(atPath: file.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if metadata[file]?.identity != identity {
                var activity = SessionActivity(id: file.lastPathComponent)
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
        cursors = cursors.filter { selected.contains($0.key) }
        for file in selected {
            guard let attributes = try? manager.attributesOfItem(atPath: file.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            var cursor = cursors[file]
            if cursor == nil || cursor!.offset > size || cursor!.identity != identity {
                var activity = metadata[file]?.activity ?? SessionActivity(id: file.lastPathComponent)
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
                if let entry = indexed.first(where: { $0.url == file }) { current.activity.updateTitle(entry.title) }
                if cursors[file] == nil, [.running, .waitingForInput].contains(current.activity.phase),
                   now.timeIntervalSince(current.activity.lastObserved ?? .distantPast) > 900 { current.activity.markUnconfirmed() }
                if current.activity.isInternalReview {
                    metadata[file] = (identity, current.activity)
                    cursors.removeValue(forKey: file)
                } else { cursors[file] = current }
            } catch { continue }
        }
        return (cursors.values.map(\.activity).filter { !$0.isInternalReview }.sorted { ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast) },
                Array(Set(watchURLs + selected)))
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
