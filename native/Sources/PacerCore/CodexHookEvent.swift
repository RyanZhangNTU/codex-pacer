import Foundation

/// One row that Pacer's Codex hook (`codex_hook.py`) appends to the spool.
/// Rows carry identifiers, event kinds and transcript paths only: prompts,
/// tool input and output and assistant messages never leave the hook.
public struct CodexHookEvent: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case userPromptSubmit = "UserPromptSubmit", stop = "Stop", interrupt = "Interrupt"
        case permissionRequest = "PermissionRequest", subagentStart = "SubagentStart", subagentStop = "SubagentStop"
        case preCompact = "PreCompact", postCompact = "PostCompact"
        case sessionEnd = "SessionEnd"

        public var isCompaction: Bool { self == .preCompact || self == .postCompact }
        public static let coreEvents = allCases.filter { !$0.isCompaction }
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
    /// turn then. Only names and modification dates are read. Rollouts of
    /// `excludingThreads` (lowercased IDs) are skipped: their changes are explained.
    public static func latestRollout(home: URL, now: Date = Date(), excludingThreads: Set<String> = []) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        var latest: Date?
        for offset in [0, -1] {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now),
                  let entries = try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("sessions/" + formatter.string(from: day)),
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in entries.prefix(4096) where file.pathExtension == "jsonl" {
                if !excludingThreads.isEmpty, let thread = CodexRolloutName.threadID(of: file), excludingThreads.contains(thread) { continue }
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { latest = max(latest ?? date, date) }
            }
        }
        return latest
    }

    /// A transcript path from the spool, accepted only for a rollout file in
    /// this Codex home's `sessions` or `archived_sessions` tree. A home on a
    /// Windows drive or share follows Windows' names; any other keeps POSIX
    /// rules, case included. The home decides, so Core needs no platform branch.
    public static func transcript(_ path: String?, home: URL) -> URL? {
        guard let path else { return nil }
        if windowsComponents(home.standardizedFileURL.path) != nil { return windowsTranscript(path, home: home) }
        guard path.hasPrefix("/") || path.dropFirst().hasPrefix(":\\") || path.dropFirst().hasPrefix(":/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "jsonl", !url.pathComponents.contains("..") else { return nil }
        let base = home.standardizedFileURL.pathComponents
        let parts = url.pathComponents
        guard parts.count > base.count + 1, Array(parts.prefix(base.count)) == base else { return nil }
        return ["sessions", "archived_sessions"].contains(parts[base.count]) ? url : nil
    }

    /// Windows names one file in several spellings: with an extended-length
    /// `\\?\` prefix, with either slash, and in any letter case, since NTFS
    /// compares names through its simple uppercase table. The rollout keeps the
    /// home's own spelling, so every spelling follows the same file. Anything
    /// Windows would read differently is refused: `..`, streams, device and
    /// relative paths.
    static func windowsTranscript(_ path: String, home: URL) -> URL? {
        guard let parts = windowsComponents(path), let base = windowsComponents(home.standardizedFileURL.path),
              parts.count > base.count + 1, zip(base, parts).allSatisfy({ folded($0) == folded($1) }),
              ["sessions", "archived_sessions"].contains(where: { folded($0) == folded(parts[base.count]) }),
              let name = parts.last, name.count > 6, folded(String(name.suffix(6))) == folded(".jsonl") else { return nil }
        let tail = parts.dropFirst(base.count)
        var url = home.standardizedFileURL
        for (index, part) in tail.enumerated() { url.appendPathComponent(part, isDirectory: index < tail.count - 1) }
        return url
    }

    /// The root (`C:` or `\\server\share`) and the names of an absolute Windows
    /// path, as Codex or Foundation (`/C:/...`) spells it; nil for anything else.
    static func windowsComponents(_ value: String) -> [String]? {
        var path = value.replacingOccurrences(of: "/", with: "\\")
        if path.hasPrefix(#"\\?\UNC\"#) { path = #"\\"# + path.dropFirst(8) }
        else if path.hasPrefix(#"\\?\"#) { path.removeFirst(4) }
        else if path.hasPrefix("\\"), !path.hasPrefix(#"\\"#), path.dropFirst(2).hasPrefix(":") { path.removeFirst() }
        var parts: [String], rest: ArraySlice<Substring>
        if path.hasPrefix(#"\\"#) {
            let names = path.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
            guard names.count >= 2, !names[0].isEmpty, !names[1].isEmpty, names[0] != "?", names[0] != "." else { return nil }
            parts = [#"\\"# + String(names[0]) + "\\" + String(names[1])]; rest = names.dropFirst(2)
        } else {
            let names = path.split(separator: "\\", omittingEmptySubsequences: false)
            guard let drive = names.first, drive.count == 2, drive.last == ":",
                  let letter = drive.unicodeScalars.first, letter.isASCII, CharacterSet.letters.contains(letter) else { return nil }
            parts = [String(drive)]; rest = names.dropFirst()
        }
        for name in rest where !name.isEmpty && name != "." {
            guard name != "..", !name.contains(":") else { return nil }
            parts.append(String(name))
        }
        return parts
    }

    static func sameWindowsSpelling(_ first: URL, _ second: URL) -> Bool {
        windowsComponents(first.path) != nil && folded(first.path) == folded(second.path)
    }

    /// A name as NTFS compares it: each scalar through its single-scalar uppercase form.
    private static func folded(_ value: String) -> [Unicode.Scalar] {
        value.unicodeScalars.map { scalar in
            let upper = scalar.properties.uppercaseMapping.unicodeScalars
            return upper.count == 1 ? upper.first! : scalar
        }
    }
}

private extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) || ("0"..."9").contains(self) }
}
