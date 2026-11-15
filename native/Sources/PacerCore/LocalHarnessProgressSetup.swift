import Foundation

package enum LocalHarnessProgressStatus: String, Codable, Sendable {
    case settingUp, configured, missingHome, conflict, failed
}

package enum LocalHarnessProgressConnection: String, Codable, Sendable {
    /// `retrust`: the app trusted an earlier copy of the tool, and a Pacer
    /// update changed its command, so the app asks again.
    case needsTrust, retrust, trusted, disabled, toolDisabled, missing, unknown
}

/// Installs one owned stdio server in a local Harness's user MCP file.
package enum LocalHarnessProgressSetup {
    package struct State: Sendable {
        package let setup: LocalHarnessProgressStatus
        package let connection: LocalHarnessProgressConnection?
        /// The app has reported progress through the tool at least once.
        package var reported: Bool
        /// When Pacer last wrote its entry. The app reads its MCP file when it
        /// starts, so an app running since before then can't list the tool yet.
        package var addedAt: Date?

        package init(_ setup: LocalHarnessProgressStatus, connection: LocalHarnessProgressConnection? = nil, reported: Bool = false, addedAt: Date? = nil) {
            self.setup = setup; self.connection = connection; self.reported = reported; self.addedAt = addedAt
        }
    }

    package typealias ConnectionReader = @Sendable (URL, String, [String], any ClaudeHookStorage) -> LocalHarnessProgressConnection

    package struct Target: Equatable, Sendable {
        let home: URL
        let configFile: String
        let ruleDirectory: String?
        let reporter: String
        let enabled: Bool

        package init(home: URL, configFile: String, reporter: String, enabled: Bool, ruleDirectory: String? = nil) {
            self.home = home; self.configFile = configFile; self.reporter = reporter; self.enabled = enabled; self.ruleDirectory = ruleDirectory
        }
    }

    static let on = Data("on\n".utf8)
    package static let managedArgument = "--pacer-progress-flag"
    private static let limit = 256 * 1024
    private static let server = CodexProgressEvidence.server
    private static func progressRule(_ guidance: String) -> Data {
        Data(("""
        ---
        description: Report task progress to Codex Pacer
        alwaysApply: true
        ---

        \(guidance)
        """ + "\n").utf8)
    }
    package static let rule = progressRule(ProgressPrompt.ask(tool: "`mcp__pacer_progress__report_progress`"))
    /// Earlier rules Pacer wrote, replaced by the current one.
    private static let previousRules = [
        progressRule("For a multi-step task that uses tools, use ToolSearch to find `mcp__pacer_progress__report_progress` and report your current estimate before starting the work. Report again at milestones and before long waits. Pass an integer from 0 to 100. Skip short replies that need no tools. If the tool is unavailable, continue the task."),
        progressRule("For multi-step tasks, call `mcp__pacer_progress__report_progress` with a percentage from 0 to 100 at the first tool batch, at milestones, and before long waits. Search for `pacer_progress` if it is deferred. Skip short replies and continue if the tool is unavailable.")
    ]

    private static func directory(_ home: URL) -> URL { home.appendingPathComponent("pacer-progress", isDirectory: true) }
    package static func flag(_ home: URL) -> URL { directory(home).appendingPathComponent("enabled") }
    /// Kept in Pacer's own folder once the app reports progress, so the card
    /// stays collapsed across restarts and after the ring is turned back on.
    package static func reportedMarker(_ home: URL) -> URL { directory(home).appendingPathComponent("reported") }

    package static func addedMarker(_ home: URL) -> URL { directory(home).appendingPathComponent("added") }

    package static func addedAt(_ home: URL, storage: any ClaudeHookStorage) -> Date? {
        let marker = addedMarker(home)
        guard (try? storage.validate(marker)) != nil, storage.exists(marker), let data = try? storage.read(marker), data.count <= 32,
              let seconds = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    package static func reported(_ home: URL, storage: any ClaudeHookStorage) -> Bool {
        let marker = reportedMarker(home)
        guard (try? storage.validate(marker)) != nil, storage.exists(marker) else { return false }
        return (try? storage.read(marker)) == on
    }

    /// Records the first report. Only writes inside a folder Pacer already made.
    @discardableResult package static func markReported(_ home: URL, storage: any ClaudeHookStorage) -> Bool {
        let folder = directory(home), marker = reportedMarker(home)
        do {
            try storage.validate(folder); try storage.validate(marker)
            guard storage.isDirectory(folder) else { return false }
            if try storage.exists(marker) && storage.read(marker) == on { return true }
            try storage.replace(marker, with: on, permissions: 0o600)
            return true
        } catch { return false }
    }

    package static func sync(_ ticket: ProgressSetupQueue<Target>.Ticket, storage: any ClaudeHookStorage,
                             connection: ConnectionReader? = nil, inspectOnly: Bool = false,
                             prepare: (@Sendable (URL) async -> CodexProgressCommand?)? = nil,
                             owns: @Sendable (String, [String], URL) -> Bool = { _, _, _ in false }) async -> State? {
        await ticket.waitForPrevious()
        let setup: LocalHarnessProgressStatus? = inspectOnly ? .configured : await configure(ticket, storage: storage, prepare: prepare, owns: owns)
        guard let setup else { return nil }
        let status = setup == .configured ? connection.map { inspect(ticket.target, storage: storage, connection: $0, owns: owns) } : nil
        let home = ticket.target.home
        return State(setup, connection: status, reported: setup == .configured && reported(home, storage: storage),
                     addedAt: setup == .configured ? addedAt(home, storage: storage) : nil)
    }

    private static func configure(_ ticket: ProgressSetupQueue<Target>.Ticket, storage: any ClaudeHookStorage,
                                  prepare: (@Sendable (URL) async -> CodexProgressCommand?)?,
                                  owns: @Sendable (String, [String], URL) -> Bool) async -> LocalHarnessProgressStatus? {
        let target = ticket.target
        if let previous = ticket.previous, previous.home != target.home,
           let issue = apply(.init(home: previous.home, configFile: previous.configFile, reporter: previous.reporter, enabled: false,
                                  ruleDirectory: previous.ruleDirectory), storage: storage, owns: owns) {
            return issue
        }
        guard target.enabled, let prepare else { return apply(target, storage: storage, owns: owns) }
        if let issue = apply(target, storage: storage, checkOnly: true, owns: owns), issue != .configured { return issue }
        guard let prepared = await prepare(target.home), owns(prepared.executable, prepared.arguments, target.home) else { return .failed }
        return apply(target, storage: storage, prepared: prepared, owns: owns)
    }

    package static func apply(_ target: Target, storage: any ClaudeHookStorage, checkOnly: Bool = false,
                              prepared: CodexProgressCommand? = nil,
                              matchNativeReporter: Bool = false,
                              owns preparedReporter: (String, [String], URL) -> Bool = { _, _, _ in false }) -> LocalHarnessProgressStatus? {
        let directory = directory(target.home), flag = flag(target.home)
        guard target.enabled || storage.exists(directory) else { return nil }
        guard !target.configFile.isEmpty, !target.configFile.contains("/"), !target.configFile.contains("\\"),
              target.configFile.hasSuffix(".json"), validPath(target.reporter) else { return .failed }
        let config = target.home.appendingPathComponent(target.configFile)
        let rules = target.ruleDirectory.map { target.home.appendingPathComponent($0, isDirectory: true) }
        let ruleFile = rules?.appendingPathComponent("codex-pacer-progress.mdc")
        let nativeArguments = [TaskProgressReporter.localHarnessArgument, managedArgument, flag.path]
        let command = prepared?.executable ?? target.reporter, arguments = prepared?.arguments ?? nativeArguments
        let entry: [String: Any] = ["type": "stdio", "command": command, "args": arguments]
        do {
            for path in [target.home, directory, flag, config] { try storage.validate(path) }
            guard storage.isDirectory(target.home) else { return target.enabled ? .missingHome : nil }
            if storage.exists(flag) {
                guard try storage.read(flag) == on else { return .conflict }
                // A reporter already running in the Harness also checks this file.
                if !target.enabled && !checkOnly && !matchNativeReporter { try storage.remove(flag) }
            }
            func editRule(verifyOnly: Bool = false) throws -> Bool {
                guard let rules, let ruleFile else { return true }
                try storage.validate(rules); try storage.validate(ruleFile)
                let original = try storage.exists(ruleFile) ? storage.read(ruleFile) : nil
                guard original == nil || original == rule || previousRules.contains(where: { $0 == original }) else { return false }
                if checkOnly || verifyOnly { return true }
                if target.enabled, original != rule {
                    if !storage.isDirectory(rules) { try storage.createDirectory(rules, permissions: 0o700) }
                    try storage.replace(ruleFile, with: rule, permissions: 0o600)
                } else if !target.enabled, original != nil {
                    try storage.remove(ruleFile)
                }
                return true
            }
            if !target.enabled && !matchNativeReporter, try !editRule() { return .conflict }
            if target.enabled, try !editRule(verifyOnly: true) { return .conflict }
            func readConfig() throws -> Data? {
                try storage.validate(config)
                return try storage.exists(config) ? storage.read(config) : nil
            }
            let original = try readConfig()
            var root: [String: Any] = [:]
            if let original {
                guard original.count <= limit, let object = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return .conflict }
                root = object
            }
            guard var servers = (root["mcpServers"] ?? [String: Any]()) as? [String: Any] else { return .conflict }
            let previous = servers[server]
            if let previous {
                let object = previous as? [String: Any]
                let oldCommand = object?["command"] as? String ?? "", oldArgs = object?["args"] as? [String] ?? []
                let native = oldArgs == nativeArguments && validPath(oldCommand)
                if native && matchNativeReporter && URL(fileURLWithPath: oldCommand).standardizedFileURL.path.caseInsensitiveCompare(
                    URL(fileURLWithPath: target.reporter).standardizedFileURL.path) != .orderedSame { return nil }
                let owned = native || preparedReporter(oldCommand, oldArgs, target.home)
                if !owned || reporterEntry(object) == nil {
                    return target.enabled || owned ? .conflict : nil
                }
            }
            if !target.enabled && !checkOnly && matchNativeReporter && storage.exists(flag) { try storage.remove(flag) }
            // Uninstalling leaves nothing of Pacer's in the app's folder.
            if !target.enabled && !checkOnly && matchNativeReporter {
                for marker in [reportedMarker(target.home), addedMarker(target.home)] {
                    try storage.validate(marker)
                    if storage.exists(marker) { try storage.remove(marker) }
                }
            }
            if matchNativeReporter, try !editRule() { return .conflict }
            if !target.enabled && previous == nil { return nil }
            if checkOnly { return target.enabled ? .configured : nil }
            if target.enabled, !storage.isDirectory(directory) { try storage.createDirectory(directory, permissions: 0o700) }
            let current = previous as? [String: Any]
            func stampAdded() throws {
                let added = addedMarker(target.home)
                try storage.validate(added)
                try storage.replace(added, with: Data((String(Int(Date().timeIntervalSince1970)) + "\n").utf8), permissions: 0o600)
            }
            if !target.enabled || current?["command"] as? String != command || current?["args"] as? [String] != arguments {
                if target.enabled {
                    var updated = entry
                    updated["disabled"] = current?["disabled"]
                    servers[server] = updated
                } else { servers.removeValue(forKey: server) }
                root["mcpServers"] = servers
                let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
                guard data.count <= limit, try readConfig() == original else { return .conflict }
                try storage.replace(config, with: data, permissions: 0o600)
                if target.enabled { try stampAdded() }
            }
            // An entry from a Pacer that kept no time counts as added now, so an
            // app that may not list it yet is asked to reopen rather than missed.
            if target.enabled, !storage.exists(addedMarker(target.home)) { try stampAdded() }
            if target.enabled, !storage.exists(flag) { try storage.replace(flag, with: on, permissions: 0o600) }
            if target.enabled, try !editRule() { return .conflict }
            return target.enabled ? .configured : nil
        } catch { return .failed }
    }

    /// WorkBuddy can add a disabled flag to an otherwise unchanged entry.
    /// Reject all other additions, which can change how the command runs.
    private static func reporterEntry(_ object: [String: Any]?) -> (command: String, arguments: [String], disabled: Bool)? {
        guard let object, Set(object.keys).isSubset(of: ["type", "command", "args", "disabled"]),
              object["type"] as? String == "stdio", let command = object["command"] as? String,
              let arguments = object["args"] as? [String] else { return nil }
        if let disabled = object["disabled"] {
            guard let bytes = try? JSONSerialization.data(withJSONObject: disabled, options: [.fragmentsAllowed]),
                  (try? JSONFieldView.document(bytes, maximumBytes: 5))?.boolean() != nil else { return nil }
        }
        return (command, arguments, object["disabled"] as? Bool == true)
    }

    /// Read the exact managed entry and its approval without preparing a runtime or editing settings.
    static func inspect(_ target: Target, storage: any ClaudeHookStorage, connection: ConnectionReader,
                        owns: (String, [String], URL) -> Bool = { _, _, _ in false }) -> LocalHarnessProgressConnection {
        let config = target.home.appendingPathComponent(target.configFile)
        let flag = flag(target.home)
        do {
            for path in [target.home, directory(target.home), flag, config] { try storage.validate(path) }
            guard storage.exists(config), storage.exists(flag) else { return .missing }
            guard try storage.read(flag) == on else { return .unknown }
            let bytes = try storage.read(config)
            guard bytes.count <= limit, let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let servers = (root["mcpServers"] ?? [String: Any]()) as? [String: Any] else { return .unknown }
            guard let entry = servers[server] else { return .missing }
            guard let reporter = reporterEntry(entry as? [String: Any]) else { return .unknown }
            let native = reporter.command == target.reporter &&
                reporter.arguments == [TaskProgressReporter.localHarnessArgument, managedArgument, flag.path]
            guard native || owns(reporter.command, reporter.arguments, target.home) else { return .unknown }
            if reporter.disabled { return .disabled }
            let state = connection(target.home, reporter.command, reporter.arguments, storage)
            return try storage.read(config) == bytes && storage.read(flag) == on ? state : .unknown
        } catch { return .unknown }
    }

    static func validPath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && (value.hasPrefix("/") || (value.utf8.first.map { (65...90).contains($0) || (97...122).contains($0) } == true
                 && [":\\", ":/"].contains(String(value.dropFirst().prefix(2)))))
    }
}
