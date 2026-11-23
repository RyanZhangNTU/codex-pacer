import Foundation

/// Codex for Claude. Claude Code's `/pacer:codex` skill runs Codex through
/// Pacer's runner (`claude_codex_runner.py`, installed as
/// `<Claude home>/pacer/codex/runner.py`). The runner files every run under
/// the Claude session that started it, in `runs/<session>/<run>/meta.json`:
/// identifiers, times, parameters and status, never the brief or Codex's
/// output. Pacer reads that ledger to show each run under its Claude task,
/// and Pacer's Claude hook starts the runner's cleanup when a turn ends with
/// no background work left; what it deletes follows `Settings.records`. Executor threads carry `originator` as their
/// Codex client name, so a thread whose ledger entry is gone never shows on
/// its own.
public enum ClaudeCodexDelegation {
    public static let originator = "Codex Pacer"
    public static func root(home: URL) -> URL { home.appendingPathComponent("pacer/codex", isDirectory: true) }
    public static func configURL(home: URL) -> URL { root(home: home).appendingPathComponent("config.json") }
    public static func runnerURL(home: URL) -> URL { root(home: home).appendingPathComponent("runner.py") }
    public static func runsURL(home: URL) -> URL { root(home: home).appendingPathComponent("runs", isDirectory: true) }
    /// The least Codex quota left, which the runner checks against `Settings.quotaFloor`.
    public static func quotaURL(home: URL) -> URL { root(home: home).appendingPathComponent("quota.json") }
    /// The skill inside Pacer's Claude plugin (`pacer@pacer`), named `pacer:codex` in Claude.
    public static func skillURL(home: URL) -> URL { home.appendingPathComponent("pacer/plugin/pacer/skills/codex/SKILL.md") }
    /// The user-level skill this feature replaces, from before Pacer managed it.
    public static func legacySkillURL(home: URL) -> URL { home.appendingPathComponent("skills/codex", isDirectory: true) }

    /// Settings → Collaboration for Claude → Codex, as the runner reads them
    /// from `config.json`. Nil model, effort and fast mode follow the user's
    /// Codex configuration; Claude can name them for one run, and can lower
    /// file access for one run but never raise it.
    public struct Settings: Codable, Equatable, Sendable {
        /// When Claude uses Codex: when the user asks for it, or only through `/pacer:codex`.
        public enum Trigger: String, Codable, Sendable, CaseIterable { case ask, command }
        /// How long the Codex threads Pacer starts stay: until Claude's turn
        /// ends, `recordsHours` after the run, or in Codex's history.
        public enum Records: String, Codable, Sendable, CaseIterable { case turn, timed, keep }
        /// The most a run may change: Codex's sandbox, project writes with or
        /// without network, or full access.
        public enum Sandbox: String, Codable, Sendable, CaseIterable {
            case readOnly = "read-only", workspaceWrite = "workspace-write"
            case workspaceWriteNetwork = "workspace-write-network", fullAccess = "danger-full-access"
        }
        public var codex: String?
        public var model: String?
        public var effort: String?
        public var fast: Bool?
        public var trigger: Trigger
        public var records: Records
        public var recordsHours: Int
        public var sandbox: Sandbox
        /// Writing runs start in their own Codex worktree.
        public var worktree: Bool
        /// The user's standing instructions, added to every brief.
        public var instructions: String?
        /// Codex's memories are read and written.
        public var memory: Bool
        public var maxConcurrent: Int
        /// Percent of Codex quota left below which runs don't start; nil never holds them back.
        public var quotaFloor: Int?
        public static let recordsHourChoices = [2, 6, 12, 24, 48, 72, 168]
        public static let concurrencyChoices = [1, 2, 3, 4]
        public static let quotaFloorChoices = [10, 20]
        public static let instructionsLimit = 4000

        public init(codex: String? = nil, model: String? = nil, effort: String? = nil, fast: Bool? = nil, trigger: Trigger = .ask,
                    records: Records = .turn, recordsHours: Int = 24, sandbox: Sandbox = .workspaceWriteNetwork, worktree: Bool = false,
                    instructions: String? = nil, memory: Bool = false, maxConcurrent: Int = 3, quotaFloor: Int? = nil) {
            self.codex = codex; self.model = model; self.effort = effort; self.fast = fast; self.trigger = trigger; self.records = records
            self.recordsHours = Self.recordsHourChoices.contains(recordsHours) ? recordsHours : 24
            self.sandbox = sandbox; self.worktree = worktree; self.memory = memory
            let text = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.instructions = text.isEmpty ? nil : String(text.prefix(Self.instructionsLimit))
            self.maxConcurrent = Self.concurrencyChoices.contains(maxConcurrent) ? maxConcurrent : 3
            self.quotaFloor = quotaFloor.flatMap { Self.quotaFloorChoices.contains($0) ? $0 : nil }
        }

        private enum CodingKeys: String, CodingKey {
            case codex, model, effort, fast, trigger, records, recordsHours, sandbox, worktree, instructions, memory, maxConcurrent, quotaFloor
        }
        /// Missing or unknown values fall back to the defaults, so a file from
        /// an earlier build still reads.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
            self.init(codex: value(.codex, String.self), model: value(.model, String.self), effort: value(.effort, String.self),
                      fast: value(.fast, Bool.self), trigger: value(.trigger, String.self).flatMap(Trigger.init) ?? .ask,
                      records: value(.records, String.self).flatMap(Records.init) ?? .turn, recordsHours: value(.recordsHours, Int.self) ?? 24,
                      sandbox: value(.sandbox, String.self).flatMap(Sandbox.init) ?? .workspaceWriteNetwork,
                      worktree: value(.worktree, Bool.self) ?? false, instructions: value(.instructions, String.self),
                      memory: value(.memory, Bool.self) ?? false, maxConcurrent: value(.maxConcurrent, Int.self) ?? 3,
                      quotaFloor: value(.quotaFloor, Int.self))
        }
        public func data() -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return (try? encoder.encode(self)) ?? Data("{}".utf8)
        }
    }

    /// Writes the least Codex quota left (percent, any window) for the
    /// runner's quota floor, or removes it with nil. Only once the feature's
    /// folder exists; never follows a symbolic link.
    @discardableResult
    public static func writeQuota(remainingPercent: Double?, home: URL, at date: Date = Date(), fileManager: FileManager = .default) -> Bool {
        let root = root(home: home), file = quotaURL(home: home)
        guard (try? fileManager.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType == .typeDirectory else { return false }
        if let type = (try? fileManager.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType, type != .typeRegular { return false }
        guard let remainingPercent, remainingPercent.isFinite else {
            return !fileManager.fileExists(atPath: file.path) || (try? fileManager.removeItem(at: file)) != nil
        }
        let value: [String: Any] = ["remainingPercent": (min(100, max(0, remainingPercent)) * 10).rounded() / 10,
                                    "at": (date.timeIntervalSince1970 * 1000).rounded() / 1000]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Writes the settings, the feature's switch, or removes them with nil.
    /// Writes nothing until Pacer's hook folder exists and never follows a
    /// symbolic link. Returns whether the file now matches.
    @discardableResult
    public static func apply(_ settings: Settings?, home: URL, fileManager: FileManager = .default) -> Bool {
        let folder = home.appendingPathComponent("pacer"), root = root(home: home), file = configURL(home: home)
        func kind(_ url: URL) -> FileAttributeType? { (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType }
        guard let settings else {
            // The quota reading only serves runs; it goes with the switch.
            let quota = quotaURL(home: home)
            if kind(quota) == .typeRegular { try? fileManager.removeItem(at: quota) }
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
        public var fast: Bool? = nil
        /// Known once the run has ended.
        public var usage: Usage? = nil
        public var commands: Int? = nil
        public var changedFiles: Int? = nil
        /// Why a run did not finish: `login`, `quota`, `model`, `timeout`, `stopped` or `other`.
        public var reason: String? = nil
        /// The Claude task this run belongs to.
        public var parentID: String { AgentProvider.claude.activityID(sessionID: session) }
    }
    public struct Usage: Equatable, Sendable {
        public let input: Int
        public let cached: Int
        public let output: Int
        public init(input: Int, cached: Int, output: Int) { self.input = input; self.cached = cached; self.output = output }
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
        func count(_ raw: Any?) -> Int? { (raw as? Int).flatMap { $0 >= 0 ? $0 : nil } }
        var run = Run(session: session, thread: thread(value["thread"]),
            childThreads: ((value["childThreads"] as? [Any]) ?? []).prefix(32).compactMap(thread),
            mode: (value["mode"] as? String).flatMap(Mode.init) ?? .task,
            label: label?.isEmpty == false ? label : nil,
            write: value["write"] as? Bool == true, worktree: value["worktree"] is String,
            status: (value["status"] as? String).flatMap(Status.init) ?? .running,
            created: created, ended: date(value["ended"]), directory: directory)
        run.fast = value["fast"] as? Bool
        if let usage = value["usage"] as? [String: Any], let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]) {
            run.usage = Usage(input: input, cached: count(usage["cached_input_tokens"]) ?? 0, output: output)
        }
        run.commands = count(value["commands"]); run.changedFiles = count(value["changedFiles"])
        run.reason = (value["reason"] as? String).map { String($0.prefix(24)) }
        return run
    }

    /// The link for every Codex thread a run started, keyed by its activity ID.
    public static func links(_ runs: [Run]) -> [String: CodexDelegationLink] {
        var links: [String: CodexDelegationLink] = [:]
        for run in runs {
            guard let thread = run.thread else { continue }
            var link = CodexDelegationLink(parentID: run.parentID, label: run.label, mode: run.mode, write: run.write,
                worktree: run.worktree, status: run.status, started: run.created, directory: run.directory)
            link.ended = run.ended; link.fast = run.fast; link.usage = run.usage; link.commands = run.commands; link.changedFiles = run.changedFiles
            // A resumed thread has several runs; the latest describes it.
            for id in [thread] + run.childThreads {
                let key = AgentProvider.codex.activityID(sessionID: id)
                if let existing = links[key], existing.started > link.started { continue }
                links[key] = link
            }
        }
        return links
    }

    /// Token counts as people read them: 940, 2.2K, 52K, 4.2M.
    public static func compactCount(_ value: Int) -> String {
        func short(_ number: Double, _ unit: String) -> String {
            number < 10 ? String(format: "%.1f", (number * 10).rounded(.down) / 10) + unit : String(Int(number.rounded(.down))) + unit
        }
        if value >= 1_000_000 { return short(Double(value) / 1_000_000, "M") }
        if value >= 1_000 { return short(Double(value) / 1_000, "K") }
        return String(max(0, value))
    }

    /// Asks a running job's runner to stop it. The runner stops Codex and
    /// tells Claude the user stopped it in Pacer.
    public static func requestStop(directory: URL) -> Bool {
        (try? Data("pacer".utf8).write(to: directory.appendingPathComponent("stop"))) != nil
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
    /// The skill Claude loads, with the runner command written in. With the
    /// `command` trigger Claude can't start it by itself; only `/pacer:codex` does.
    public static func skill(command: String, trigger: Settings.Trigger = .ask) -> Data? {
        guard let url = L10n.sharedResourceBundle.url(forResource: "claude_codex_skill", withExtension: "md"),
              let template = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let invocation = trigger == .command ? "disable-model-invocation: true\n" : ""
        // A Windows checkout may carry CRLF; the skill's header is written with LF either way.
        return Data(template.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "{{INVOCATION}}", with: invocation)
            .replacingOccurrences(of: "{{RUN}}", with: command).utf8)
    }
    /// The settings the host last wrote, if any.
    public static func settings(_ data: Data?) -> Settings? { data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } }
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
    public var ended: Date? = nil
    public var fast: Bool? = nil
    public var usage: ClaudeCodexDelegation.Usage? = nil
    public var commands: Int? = nil
    public var changedFiles: Int? = nil
    public init(parentID: String, label: String?, mode: ClaudeCodexDelegation.Mode, write: Bool, worktree: Bool,
                status: ClaudeCodexDelegation.Status, started: Date, directory: URL) {
        self.parentID = parentID; self.label = label; self.mode = mode; self.write = write; self.worktree = worktree
        self.status = status; self.started = started; self.directory = directory
    }
}
