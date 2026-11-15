import Foundation

/// WorkBuddy's agent process logs each change of a task's run state, e.g.
/// `[SessionRunStateMachine] transition | sessionId=<id> | event=MODEL_STREAM_STARTED | from=model_requesting | to=model_streaming | …`.
/// Its transcript holds a model response only once the response ends, so a
/// model that thinks for minutes before its first step (WorkBuddy's HY models
/// do: 2.5 to 3 minutes, seen 11/15) left the task with no live state. Pacer
/// reads only these lines' session, event, state, whether they name a tool,
/// and time; nothing else in the logs.
///
/// Each process writes `logs/<date>/<date>-<time>__<hash>.log` in WorkBuddy's
/// home, one task each, with its local time first on every line in its
/// system's language, e.g. `[2026年11月15日 下午10:05:20.514]`. A process
/// started before midnight keeps writing in the previous day's folder.
struct WorkBuddyRunLog {
    enum Stage: Equatable {
        /// The run is being set up, before its first model request.
        case starting
        /// A model request is out, streaming its thinking or text, or just ended.
        case model
        /// The model writes a tool call, or the tool runs.
        case tool
        /// A tool waits for the user's permission.
        case permission
        /// The agent stopped; the transcript says how.
        case ended
    }
    struct State: Equatable { let stage: Stage; let at: Date }

    private(set) var sessions: [String: State] = [:]
    private var cursors: [String: Cursor] = [:]
    private var followed: [URL] = []
    private var listedAt: Date?

    private struct Cursor { var identity: String; var offset: UInt64 }

    static let marker = Data("[SessionRunStateMachine] transition | ".utf8)
    /// How much of a log's end to read first, or after a burst: a process
    /// writes about a megabyte, mostly as it starts.
    static let tail = 512 * 1024
    static let followedFiles = 8
    static let relistInterval: TimeInterval = 5
    private static let sessionLimit = 64

    /// Reads what the newest agent logs appended since the last call; true when
    /// a session's stage changed. The folders are listed again at most every
    /// five seconds; a task's process starts its log as it starts.
    @discardableResult
    mutating func read(home: URL, files: any PlatformFileSystem, now: Date, within: TimeInterval) -> Bool {
        if listedAt.map({ now.timeIntervalSince($0) >= Self.relistInterval || $0 > now }) ?? true {
            listedAt = now
            followed = Self.recentLogs(home: home, files: files, now: now, within: within)
            let paths = Set(followed.map(\.path))
            cursors = cursors.filter { paths.contains($0.key) }
        }
        var changed = false
        for file in followed {
            guard let metadata = files.metadata(file), metadata.isRegularFile else { cursors.removeValue(forKey: file.path); continue }
            var cursor = cursors[file.path] ?? Cursor(identity: "", offset: 0)
            var partial = false
            if cursor.identity != metadata.identity || cursor.offset > metadata.size {
                cursor = Cursor(identity: metadata.identity, offset: 0)
            }
            if metadata.size - cursor.offset > UInt64(Self.tail) {
                cursor.offset = metadata.size - UInt64(Self.tail); partial = true
            }
            defer { cursors[file.path] = cursor }
            guard metadata.size > cursor.offset,
                  let data = try? files.read(file, offset: cursor.offset, maximumBytes: Int(metadata.size - cursor.offset)),
                  let end = data.lastIndex(of: 10) else { continue }
            var start = data.startIndex
            if partial, let first = data.firstIndex(of: 10) { start = first + 1 }
            cursor.offset += UInt64(end + 1 - data.startIndex)
            var search = start
            while search < end, let found = data.range(of: Self.marker, in: search..<end) {
                let lineStart = data[start..<found.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? start
                let lineEnd = data[found.upperBound..<end].firstIndex(of: 10) ?? end
                search = lineEnd
                guard lineEnd - lineStart <= 2048, let entry = Self.parse(data[lineStart..<lineEnd]) else { continue }
                changed = apply(entry.session, State(stage: entry.stage, at: entry.at ?? metadata.modified)) || changed
            }
        }
        return changed
    }

    private mutating func apply(_ session: String, _ state: State) -> Bool {
        if let previous = sessions[session], previous.at > state.at { return false }
        let changed = sessions[session]?.stage != state.stage
        sessions[session] = state
        if sessions.count > Self.sessionLimit,
           let oldest = sessions.min(by: { $0.value.at < $1.value.at })?.key { sessions.removeValue(forKey: oldest) }
        return changed
    }

    /// The agent logs in today's and yesterday's folders written within
    /// `within`, newest first.
    static func recentLogs(home: URL, files: any PlatformFileSystem, now: Date, within: TimeInterval) -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = localZone
        formatter.dateFormat = "yyyy-MM-dd"
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        var found: [(url: URL, modified: Date)] = []
        for day in [now, now.addingTimeInterval(-86_400)] {
            let folder = logs.appendingPathComponent(formatter.string(from: day), isDirectory: true)
            guard files.metadata(folder)?.isDirectory == true, let entries = try? files.entries(in: folder) else { continue }
            for url in entries.prefix(512) where isAgentLog(url.lastPathComponent) {
                guard let metadata = files.metadata(url), metadata.isRegularFile,
                      now.timeIntervalSince(metadata.modified) <= within else { continue }
                found.append((url, metadata.modified))
            }
        }
        return found.sorted { $0.modified > $1.modified }.prefix(followedFiles).map(\.url)
    }

    /// The computer's time zone, as the logs' times and folders use. On
    /// Windows, Foundation's `TimeZone.current` is GMT; the engine sets the
    /// default zone from the host's offset, which `Calendar.current` follows.
    static var localZone: TimeZone { Calendar.current.timeZone }

    /// `2026-11-15-22-05-19__<32 hex digits>.log`; the app's own logs have other names.
    static func isAgentLog(_ name: String) -> Bool {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard name.hasSuffix(".log"), parts.count == 3, parts[1].isEmpty else { return false }
        let stamp = parts[0], hash = parts[2].dropLast(4)
        return stamp.count == 19 && stamp.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) &&
            hash.count == 32 && hash.allSatisfy({ $0.isHexDigit })
    }

    static func parse(_ line: Data) -> (session: String, stage: Stage, at: Date?)? {
        let text = String(decoding: line, as: UTF8.self)
        guard let marker = text.range(of: "[SessionRunStateMachine] transition | ") else { return nil }
        var fields: [Substring: Substring] = [:]
        for part in text[marker.upperBound...].split(separator: "|").prefix(16) {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[Substring(pair[0])] = Substring(pair[1]) }
        }
        guard let id = fields["sessionId"].map(String.init), Foundation.UUID(uuidString: id) != nil,
              let stage = stage(event: fields["event"].map(String.init) ?? "", to: fields["to"].map(String.init) ?? "",
                                writingTool: fields["streamingToolName"] != nil) else { return nil }
        return (id.lowercased(), stage, time(text[..<marker.lowerBound]))
    }

    static func stage(event: String, to: String, writingTool: Bool) -> Stage? {
        switch event {
        case "RUN_PREPARING", "RUN_ACCEPTED", "AGENT_STARTED": return .starting
        case "MODEL_STREAM_STARTED": return writingTool ? .tool : .model
        case "MODEL_REQUEST_STARTED", "MODEL_RESPONSE_DONE", "TOOL_ENDED": return .model
        case "TOOL_STARTED": return .tool
        case "WAITING_FOR_PERMISSION": return .permission
        case "AGENT_ENDED": return .ended
        default:
            // A newer event is read by the state it leads to.
            if to == "idle" { return .ended }
            if to.hasPrefix("waiting") { return .permission }
            if to.contains("tool") { return .tool }
            if to.hasPrefix("model") || to == "agent_running" { return .model }
            if to == "preparing" || to == "pending" { return .starting }
            return nil
        }
    }

    /// The local time in the line's first brackets: Chinese
    /// (`2026年11月15日 下午10:05:20.514`), or ISO 8601.
    static func time(_ prefix: Substring) -> Date? {
        guard prefix.first == "[", let close = prefix.prefix(48).firstIndex(of: "]") else { return nil }
        let inner = prefix[prefix.index(after: prefix.startIndex)..<close]
        if let year = inner.firstIndex(of: "年"), let month = inner.firstIndex(of: "月"), let day = inner.firstIndex(of: "日"),
           year < month, month < day {
            var clock = inner[inner.index(after: day)...].trimmingCharacters(in: .whitespaces)[...]
            var afternoon: Bool?
            if clock.hasPrefix("上午") { afternoon = false; clock = clock.dropFirst(2) }
            else if clock.hasPrefix("下午") { afternoon = true; clock = clock.dropFirst(2) }
            let parts = clock.split(separator: ":")
            guard parts.count == 3, let y = Int(inner[..<year]), let m = Int(inner[inner.index(after: year)..<month]),
                  let d = Int(inner[inner.index(after: month)..<day]), var hour = Int(parts[0]), let minute = Int(parts[1]),
                  let seconds = Double(parts[2]), (0...23).contains(hour), (0...59).contains(minute), (0..<61).contains(seconds) else { return nil }
            if let afternoon { hour = hour % 12 + (afternoon ? 12 : 0) }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = localZone
            let whole = Int(seconds)
            guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute, second: whole)) else { return nil }
            return date.addingTimeInterval(seconds - Double(whole))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: String(inner)) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(inner))
    }
}
