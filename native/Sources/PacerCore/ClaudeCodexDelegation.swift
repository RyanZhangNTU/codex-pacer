import Foundation

/// Codex for Claude. Claude Code's `/pacer:codex` skill runs Codex through
/// Pacer's runner (`claude_codex_runner.py`, installed as
/// `<Claude home>/pacer/codex/runner.py`). The runner files every run under
/// the Claude session that started it, in `runs/<session>/<run>/meta.json`:
/// identifiers, times, parameters and status, never the brief or Codex's
/// output. Pacer reads that ledger to show each run under its Claude task,
/// and Pacer's Claude hook starts the runner's cleanup when a turn ends with
/// no background work left. Executor threads carry `originator` as their
/// Codex client name, so a thread whose ledger entry is gone never shows on
/// its own.
public enum ClaudeCodexDelegation {
    public static let originator = "Codex Pacer"
    public static func root(home: URL) -> URL { home.appendingPathComponent("pacer/codex", isDirectory: true) }
    public static func configURL(home: URL) -> URL { root(home: home).appendingPathComponent("config.json") }
    public static func runnerURL(home: URL) -> URL { root(home: home).appendingPathComponent("runner.py") }
    public static func runsURL(home: URL) -> URL { root(home: home).appendingPathComponent("runs", isDirectory: true) }
    public static func statsURL(home: URL) -> URL { root(home: home).appendingPathComponent("stats.jsonl") }
    /// The skill inside Pacer's Claude plugin (`pacer@pacer`), named `pacer:codex` in Claude.
    public static func skillURL(home: URL) -> URL { home.appendingPathComponent("pacer/plugin/pacer/skills/codex/SKILL.md") }
    /// The user-level skill this feature replaces, from before Pacer managed it.
    public static func legacySkillURL(home: URL) -> URL { home.appendingPathComponent("skills/codex", isDirectory: true) }

    /// What the runner applies when Claude leaves an option out. Nil model,
    /// effort and fast mode follow the user's Codex configuration.
    public struct Settings: Codable, Equatable, Sendable {
        public enum Sandbox: String, Codable, Sendable, CaseIterable { case readOnly = "read-only", workspaceWrite = "workspace-write" }
        public var codex: String?
        public var model: String?
        public var effort: String?
        public var fast: Bool?
        public var sandbox: Sandbox
        public var timeoutMinutes: Int
        public var maxConcurrent: Int
        public static let timeoutChoices = [15, 30, 60, 120, 240]
        public static let concurrencyChoices = [1, 2, 3, 4, 6]
        public init(codex: String? = nil, model: String? = nil, effort: String? = nil, fast: Bool? = nil,
                    sandbox: Sandbox = .readOnly, timeoutMinutes: Int = 60, maxConcurrent: Int = 3) {
            self.codex = codex; self.model = model; self.effort = effort; self.fast = fast; self.sandbox = sandbox
            self.timeoutMinutes = Self.timeoutChoices.contains(timeoutMinutes) ? timeoutMinutes : 60
            self.maxConcurrent = Self.concurrencyChoices.contains(maxConcurrent) ? maxConcurrent : 3
        }
        public func data() -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return (try? encoder.encode(self)) ?? Data("{}".utf8)
        }
    }

    /// Writes the settings, the feature's switch, or removes them with nil.
    /// Writes nothing until Pacer's hook folder exists and never follows a
    /// symbolic link. Returns whether the file now matches.
    @discardableResult
    public static func apply(_ settings: Settings?, home: URL, fileManager: FileManager = .default) -> Bool {
        let folder = home.appendingPathComponent("pacer"), root = root(home: home), file = configURL(home: home)
        func kind(_ url: URL) -> FileAttributeType? { (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType }
        guard let settings else {
            guard kind(file) != nil else { return true }
            return kind(file) == .typeRegular && (try? fileManager.removeItem(at: file)) != nil
        }
        guard kind(folder) == .typeDirectory else { return false }
        if kind(root) == nil { try? fileManager.createDirectory(at: root, withIntermediateDirectories: false) }
        guard kind(root) == .typeDirectory, [nil, .typeRegular].contains(kind(file)) else { return false }
        let data = settings.data()
        if fileManager.contents(atPath: file.path) == data { return true }
        return (try? data.write(to: file, options: .atomic)) != nil
    }
    public static func isOn(home: URL, fileManager: FileManager = .default) -> Bool { fileManager.fileExists(atPath: configURL(home: home).path) }

    public enum Mode: String, Sendable { case task, resume, review }
    public enum Status: String, Sendable {
        case running, ok, failed, timedOut, stopped
        public var finished: Bool { self != .running }
    }

    /// One ledger entry.
    public struct Run: Equatable, Sendable {
        public let session: String
        public let thread: String?
        public let childThreads: [String]
        public let mode: Mode
        public let label: String?
        public let write: Bool
        public let worktree: Bool
        public let status: Status
        public let created: Date
        public let ended: Date?
        public let directory: URL
        /// The Claude task this run belongs to.
        public var parentID: String { AgentProvider.claude.activityID(sessionID: session) }
    }

    /// Every readable ledger entry under `home`. A run still starting (no
    /// thread yet) is listed without one.
    public static func runs(home: URL, fileManager: FileManager = .default) -> [Run] {
        let root = runsURL(home: home)
        guard let sessions = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [Run] = []
        for session in sessions.prefix(256) {
            guard let id = AgentProvider.claude.validatedSessionID(session.lastPathComponent),
                  let entries = try? fileManager.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) else { continue }
            for entry in entries.prefix(256) {
                let file = entry.appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: file), data.count < 1 << 20,
                      let run = run(data, session: id, directory: entry) else { continue }
                result.append(run)
            }
        }
        return result.sorted { $0.created == $1.created ? $0.directory.path < $1.directory.path : $0.created < $1.created }
    }

    static func run(_ data: Data, session: String, directory: URL) -> Run? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func thread(_ raw: Any?) -> String? { (raw as? String).flatMap(AgentProvider.codex.validatedSessionID) }
        func date(_ raw: Any?) -> Date? {
            guard let seconds = raw as? Double, seconds.isFinite, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let created = date(value["created"]) else { return nil }
        let label = (value["label"] as? String).map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60)) }
        return Run(session: session, thread: thread(value["thread"]),
            childThreads: ((value["childThreads"] as? [Any]) ?? []).prefix(32).compactMap(thread),
            mode: (value["mode"] as? String).flatMap(Mode.init) ?? .task,
            label: label?.isEmpty == false ? label : nil,
            write: value["write"] as? Bool == true, worktree: value["worktree"] is String,
            status: (value["status"] as? String).flatMap(Status.init) ?? .running,
            created: created, ended: date(value["ended"]), directory: directory)
    }

    /// The link for every Codex thread a run started, keyed by its activity ID.
    public static func links(_ runs: [Run]) -> [String: CodexDelegationLink] {
        var links: [String: CodexDelegationLink] = [:]
        for run in runs {
            guard let thread = run.thread else { continue }
            let link = CodexDelegationLink(parentID: run.parentID, label: run.label, mode: run.mode, write: run.write,
                worktree: run.worktree, status: run.status, started: run.created, directory: run.directory)
            // A resumed thread has several runs; the latest describes it.
            for id in [thread] + run.childThreads {
                let key = AgentProvider.codex.activityID(sessionID: id)
                if let existing = links[key], existing.started > link.started { continue }
                links[key] = link
            }
        }
        return links
    }

    /// Asks a running job's runner to stop it. The runner stops Codex and
    /// tells Claude the user stopped it in Pacer.
    public static func requestStop(directory: URL) -> Bool {
        (try? Data("pacer".utf8).write(to: directory.appendingPathComponent("stop"))) != nil
    }

    /// Runs, time and tokens over the last week, from the runner's stats file.
    public struct Summary: Equatable, Sendable {
        public var runs = 0
        public var failures = 0
        public var seconds: Double = 0
        public var tokens = 0
        public init() {}
    }
    public static func summary(home: URL, since: Date) -> Summary {
        var summary = Summary()
        guard let data = try? Data(contentsOf: statsURL(home: home)), data.count < 4 << 20,
              let text = String(data: data, encoding: .utf8) else { return summary }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = value["at"] as? Double, Date(timeIntervalSince1970: at) >= since else { continue }
            summary.runs += 1
            if value["status"] as? String != "ok" { summary.failures += 1 }
            summary.seconds += max(0, value["seconds"] as? Double ?? 0)
            summary.tokens += max(0, value["input"] as? Int ?? 0) + max(0, value["output"] as? Int ?? 0)
        }
        return summary
    }

    /// The user-level skill this feature replaces is the folder Pacer's earlier
    /// guide installed: a `codex` skill whose runner is `codex-run.mjs`.
    public static func hasLegacySkill(home: URL, fileManager: FileManager = .default) -> Bool {
        let folder = legacySkillURL(home: home)
        return fileManager.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path)
            && fileManager.fileExists(atPath: folder.appendingPathComponent("scripts/codex-run.mjs").path)
    }

    /// The runner command Claude types in its Bash tool (Git Bash on Windows):
    /// forward slashes, and double quotes only around a part that needs them.
    public static func command(python: String, home: URL) -> String {
        func shell(_ value: String) -> String {
            var path = value.replacingOccurrences(of: "\\", with: "/")
            if path.range(of: #"^/[A-Za-z]:/"#, options: .regularExpression) != nil { path.removeFirst() }
            return path.range(of: #"^[\p{L}\p{M}\p{N}_./:~+-]+\z"#, options: .regularExpression) != nil ? path : "\"" + path + "\""
        }
        return [shell(python), "-S", shell(runnerURL(home: home).path)].joined(separator: " ")
    }
    /// The skill Claude loads, with the runner command written in.
    public static func skill(command: String) -> Data? {
        guard let url = L10n.sharedResourceBundle.url(forResource: "claude_codex_skill", withExtension: "md"),
              let template = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Data(template.replacingOccurrences(of: "{{RUN}}", with: command).utf8)
    }
    public static func runnerScript() -> Data? {
        L10n.sharedResourceBundle.url(forResource: "claude_codex_runner", withExtension: "py").flatMap { try? Data(contentsOf: $0) }
    }
}

/// How a Codex activity belongs to the Claude task that started it.
public struct CodexDelegationLink: Equatable, Sendable {
    public let parentID: String
    public let label: String?
    public let mode: ClaudeCodexDelegation.Mode
    public let write: Bool
    public let worktree: Bool
    public let status: ClaudeCodexDelegation.Status
    public let started: Date
    public let directory: URL
    public init(parentID: String, label: String?, mode: ClaudeCodexDelegation.Mode, write: Bool, worktree: Bool,
                status: ClaudeCodexDelegation.Status, started: Date, directory: URL) {
        self.parentID = parentID; self.label = label; self.mode = mode; self.write = write; self.worktree = worktree
        self.status = status; self.started = started; self.directory = directory
    }
}
