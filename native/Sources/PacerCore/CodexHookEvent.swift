import Foundation

/// One row that Pacer's Codex hook (`codex_hook.py`) appends to the spool.
/// Rows carry identifiers, event kinds and transcript paths only: prompts,
/// tool input and output and assistant messages never leave the hook.
public struct CodexHookEvent: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case userPromptSubmit = "UserPromptSubmit", stop = "Stop", interrupt = "Interrupt"
        case permissionRequest = "PermissionRequest", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
        case sessionEnd = "SessionEnd"
    }
    /// What a permission request asks for, from the hook's `tool_name`:
    /// `Bash` is a command, `mcp__server__tool` an MCP tool, anything else a file change.
    public enum Approval: String, Sendable { case exec, mcp, file }

    public static let version = 1
    public let hook: Int
    public let at: Date
    public let kind: Kind
    /// The root thread (Codex's `session_id`); a subagent row names its child in `agent`.
    public let thread: String
    public let turn: String?
    public let agent: String?
    public let agentType: String?
    public let transcript: String?
    public let agentTranscript: String?
    public let approval: Approval?
    public let reason: String?

    public init(hook: Int, at: Date, kind: Kind, thread: String, turn: String? = nil, agent: String? = nil, agentType: String? = nil,
                transcript: String? = nil, agentTranscript: String? = nil, approval: Approval? = nil, reason: String? = nil) {
        self.hook = hook; self.at = at; self.kind = kind; self.thread = thread; self.turn = turn; self.agent = agent
        self.agentType = agentType; self.transcript = transcript; self.agentTranscript = agentTranscript
        self.approval = approval; self.reason = reason
    }

    /// Decodes one spool line, or nil for anything malformed, unknown or oversized.
    public static func decode(_ line: Data) -> CodexHookEvent? {
        guard line.count <= 8 * 1024, let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              row["v"] as? Int == version, let hook = row["hook"] as? Int, hook > 0,
              let at = row["at"] as? Double, at.isFinite, at > 0,
              let kind = (row["event"] as? String).flatMap(Kind.init(rawValue:)),
              let thread = identifier(row["thread"]) else { return nil }
        func optional(_ key: String) -> String?? {
            switch row[key] {
            case nil, is NSNull: return .some(nil)
            case let value: return identifier(value).map { .some($0) } ?? nil
            }
        }
        func path(_ key: String) -> String?? {
            switch row[key] {
            case nil, is NSNull: return .some(nil)
            case let value as String where value.utf8.count <= 4096 && !value.isEmpty: return .some(value)
            default: return nil
            }
        }
        guard let turn = optional("turn"), let agent = optional("agent"), let agentType = optional("agentType"),
              let reason = optional("reason"), let transcript = path("transcript"), let agentTranscript = path("agentTranscript") else { return nil }
        let approval: Approval?
        switch row["approval"] {
        case nil, is NSNull: approval = nil
        case let value as String: guard let parsed = Approval(rawValue: value) else { return nil }; approval = parsed
        default: return nil
        }
        return CodexHookEvent(hook: hook, at: Date(timeIntervalSince1970: at), kind: kind, thread: thread, turn: turn, agent: agent,
                              agentType: agentType, transcript: transcript, agentTranscript: agentTranscript, approval: approval, reason: reason)
    }

    /// The hook's identifier grammar: `^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$`.
    static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, (1...256).contains(value.utf8.count), let first = value.unicodeScalars.first,
              first.isASCIIAlphanumeric,
              value.unicodeScalars.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "." || $0 == "_" || $0 == "-" }) else { return nil }
        return value
    }
}

/// Where the hook writes and how the spool rotates.
public enum CodexHookSpool {
    /// A spool over this size is renamed to `previous` under the lock before the next append.
    public static let maximumBytes = 2 * 1024 * 1024
    public static func folder(home: URL) -> URL { home.appendingPathComponent("pacer/hooks", isDirectory: true) }
    public static func current(home: URL) -> URL { folder(home: home).appendingPathComponent("events.jsonl") }
    public static func previous(home: URL) -> URL { folder(home: home).appendingPathComponent("events.previous.jsonl") }
    public static func lock(home: URL) -> URL { folder(home: home).appendingPathComponent("events.lock") }

    /// The newest rollout change in today's or yesterday's session folder: Codex ran a
    /// turn then. Only names and modification dates are read.
    public static func latestRollout(home: URL, now: Date = Date()) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        var latest: Date?
        for offset in [0, -1] {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now),
                  let entries = try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("sessions/" + formatter.string(from: day)),
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in entries.prefix(4096) where file.pathExtension == "jsonl" {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { latest = max(latest ?? date, date) }
            }
        }
        return latest
    }

    /// A transcript path from the spool, accepted only for a rollout file in
    /// this Codex home's `sessions` or `archived_sessions` tree.
    public static func transcript(_ path: String?, home: URL) -> URL? {
        guard let path, path.hasPrefix("/") || path.dropFirst().hasPrefix(":\\") || path.dropFirst().hasPrefix(":/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "jsonl", !url.pathComponents.contains("..") else { return nil }
        let base = home.standardizedFileURL.pathComponents
        let parts = url.pathComponents
        guard parts.count > base.count + 1, Array(parts.prefix(base.count)) == base else { return nil }
        return ["sessions", "archived_sessions"].contains(parts[base.count]) ? url : nil
    }
}

private extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) || ("0"..."9").contains(self) }
}
