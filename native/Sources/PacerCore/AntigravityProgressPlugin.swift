import Foundation

/// Plugin directories may contain user files. Removal must fail on a nonempty
/// directory, and validation must reject links (including hard-linked files).
package protocol ProgressPluginStorage: ClaudeHookStorage {
    func names(in directory: URL) throws -> Set<String>
    func removeEmptyDirectory(_ directory: URL) throws
}

package enum ProgressPluginRemovalError: Error { case inUse }

package struct AntigravityProgressPlugin {
    static let folder = "codex-pacer"
    package static let server = folder + "_" + CodexProgressEvidence.server
    static let toolTarget = server + "/" + CodexProgressEvidence.tool
    static let rule = Data((ProgressPrompt.ask(tool: "`call_mcp_tool` with ServerName `" + server +
        "`, ToolName `report_progress` and Arguments `{\"percent\": N}`", deferred: false) + "\n").utf8)
    static let manifest = Data("{\"name\":\"codex-pacer\"}\n".utf8)

    let target: LocalHarnessProgressSetup.Target
    let storage: any ProgressPluginStorage

    private var plugins: URL { target.home.appendingPathComponent("plugins", isDirectory: true) }
    private var plugin: URL { plugins.appendingPathComponent(Self.folder, isDirectory: true) }
    private var rules: URL { plugin.appendingPathComponent("rules", isDirectory: true) }
    private var flag: URL { LocalHarnessProgressSetup.flag(target.home) }
    private var state: URL { flag.deletingLastPathComponent() }
    private var journal: URL { state.appendingPathComponent("plugin-install.json") }
    private typealias State = LocalHarnessProgressSetup.State

    /// Written before the plugin. During an interrupted command update either
    /// command's exact configuration can be present. The manifest is published last.
    private struct Install: Codable, Equatable {
        var command: CodexProgressCommand
        var previous: CodexProgressCommand?
        var added: Date
        var reported = false
    }
    private enum Issue: Error { case conflict }
    private func bytes(_ url: URL) throws -> Data? {
        try storage.validate(url)
        guard storage.exists(url) else { return nil }
        guard !storage.isDirectory(url) else { throw Issue.conflict }
        return try storage.read(url)
    }
    private func directory(_ url: URL, create: Bool = false) throws {
        try storage.validate(url)
        if storage.exists(url) {
            guard storage.isDirectory(url) else { throw Issue.conflict }
        } else if create {
            try storage.createDirectory(url, permissions: 0o700)
        }
    }
    private func replace(_ url: URL, _ value: Data) throws {
        try storage.replace(url, with: value, permissions: 0o600)
    }
    private func record() throws -> Install? {
        guard let data = try bytes(journal) else { return nil }
        guard data.count <= 32_768, let value = try? JSONDecoder().decode(Install.self, from: data) else { throw Issue.conflict }
        return value
    }
    var recordedCommand: CodexProgressCommand? { try? record()?.command }
    private func configuration(_ command: CodexProgressCommand) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["mcpServers": [CodexProgressEvidence.server:
            ["command": command.executable, "args": command.arguments] as [String: Any]]], options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }
    /// Project the plugin switch and the effective grant from the same bounded read.
    private func connection(old: Install?, checkOnly: Bool) throws -> LocalHarnessProgressConnection? {
        if old == nil && storage.exists(plugin) { throw Issue.conflict }
        guard let data = try bytes(target.home.appendingPathComponent("config.json")) else { return nil }
        guard let fields = try? JSONFieldView.document(data, maximumBytes: 2 * 1024 * 1024).fields(["plugins", "userSettings"])
        else { throw Issue.conflict }
        if let setting = try fields["plugins"]?.fields([Self.folder])[Self.folder]?.fields(["enabled"])["enabled"] {
            guard let enabled = setting.boolean() else { throw Issue.conflict }
            if !enabled {
                try revoke(checkOnly: checkOnly)
                return .disabled
            }
        }
        // A partial or unfamiliar grant list gives no permission evidence.
        return try? Self.progressGrant(in: fields["userSettings"])
    }

    private static func progressGrant(in settings: JSONFieldView?) throws -> LocalHarnessProgressConnection? {
        guard let grants = try settings?.fields(["globalPermissionGrants"])["globalPermissionGrants"]?.fields(["allow", "deny"]) else { return nil }
        func matches(_ list: JSONFieldView?) throws -> Bool {
            var found = false
            try list?.forEachElement { entry in
                guard entry.isString else { throw JSONFieldView.Failure.malformed }
                // Each accepted literal is shorter than the decoding limit, so a longer target cannot match.
                switch entry.string(limit: 64) {
                case "mcp(\(toolTarget))", "mcp(\(server)/*)", "mcp(*)": found = true
                default: break
                }
            }
            return found
        }
        if try matches(grants["deny"]) { return .needsTrust }
        return try matches(grants["allow"]) ? .trusted : nil
    }

    private func validateRoots() throws {
        guard let profile = target.pluginProfile else { throw Issue.conflict }
        for url in [profile, target.home.deletingLastPathComponent(), target.home, state, plugins] { try directory(url) }
    }

    /// Avoid preparing the Windows runtime for a foreign plugin or a plugin
    /// the user has turned off. The write pass repeats all ownership checks.
    func preflight(checkOnly: Bool = false) -> LocalHarnessProgressSetup.State? {
        do {
            try validateRoots()
            if try connection(old: record(), checkOnly: checkOnly) == .disabled { return .init(.configured, connection: .disabled) }
            return nil
        } catch {
            if !checkOnly { try? revoke() }
            return .init(.conflict)
        }
    }

    func revoke(checkOnly: Bool = false) throws {
        if let contents = try bytes(flag) {
            guard try record() != nil, contents == LocalHarnessProgressSetup.on else { throw Issue.conflict }
            if !checkOnly { try storage.remove(flag) }
        }
    }

    func sync(command: CodexProgressCommand, reportAt: Date? = nil, checkOnly: Bool = false, uninstalling: Bool = false,
              owns: (String, [String], URL) -> Bool = { _, _, _ in false }) -> LocalHarnessProgressSetup.State? {
        do {
            try validateRoots()
            let old = try record()
            if !target.enabled {
                guard let old else {
                    try directory(plugin)
                    return !uninstalling && storage.exists(plugin) ? .init(.conflict) : nil
                }
                if uninstalling && old.command != command && !owns(old.command.executable, old.command.arguments, target.home) { return nil }
                try revoke(checkOnly: checkOnly)
                return try remove(old, checkOnly: checkOnly)
            }
            let connection = try connection(old: old, checkOnly: checkOnly)
            if connection == .disabled { return .init(.configured, connection: .disabled) }
            guard LocalHarnessProgressSetup.validPath(command.executable) else { return .init(.failed) }
            if let existing = try bytes(flag), old == nil || existing != LocalHarnessProgressSetup.on { throw Issue.conflict }
            try directory(plugin); try directory(rules)
            if try extras() { throw Issue.conflict }
            let files = try managedFiles(command, old: old)
            var needsRepair = false
            for file in files {
                if let data = try bytes(file.url) {
                    guard file.owned.contains(data) else { throw Issue.conflict }
                } else { needsRepair = true }
            }
            if checkOnly { return .init(.configured) }
            for url in [target.home.deletingLastPathComponent(), target.home, state, plugins] { try directory(url, create: true) }
            var install = old ?? Install(command: command, added: Date())
            if install.command != command || (old != nil && (needsRepair || !storage.exists(flag))) {
                let currentConfig = try bytes(plugin.appendingPathComponent("mcp_config.json"))
                let previous = try [old?.command, old?.previous].compactMap { $0 }.first { try configuration($0) == currentConfig }
                install = Install(command: command, previous: previous, added: Date())
            }
            if install != old { try replace(journal, JSONEncoder().encode(install)) }
            for url in [plugin, rules] { try directory(url, create: true) }
            for file in files {
                let data = try bytes(file.url)
                if let data, !file.owned.contains(data) { throw Issue.conflict }
                if data != file.expected { try replace(file.url, file.expected) }
            }
            let pending = install
            install.previous = nil
            if let reportAt, reportAt > install.added { install.reported = true }
            if install != pending { try replace(journal, JSONEncoder().encode(install)) }
            if try bytes(flag) == nil { try replace(flag, LocalHarnessProgressSetup.on) }
            return .init(.configured, connection: connection, reported: install.reported, addedAt: install.added)
        } catch Issue.conflict, ClaudeHookInstaller.Failure.unsafePath {
            if target.enabled && !checkOnly { try? revoke() }
            return .init(.conflict)
        } catch ProgressPluginRemovalError.inUse where !target.enabled {
            return .init(.removalPending)
        } catch {
            if target.enabled && !checkOnly { try? revoke() }
            return .init(.failed)
        }
    }

    private struct File {
        let url: URL
        let expected: Data
        let owned: [Data]
    }
    private func managedFiles(_ command: CodexProgressCommand, old: Install?) throws -> [File] {
        let config = try configuration(command)
        let known = try [old?.command, old?.previous].compactMap { $0 }.map(configuration)
        return [File(url: plugin.appendingPathComponent("mcp_config.json"), expected: config, owned: known),
                File(url: rules.appendingPathComponent("AGENTS.md"), expected: Self.rule, owned: [Self.rule]),
                File(url: plugin.appendingPathComponent("plugin.json"), expected: Self.manifest, owned: [Self.manifest])]
    }
    private func extras() throws -> Bool {
        if storage.exists(plugin), try !storage.names(in: plugin).isSubset(of: ["plugin.json", "mcp_config.json", "rules"]) { return true }
        if storage.exists(rules), try !storage.names(in: rules).isSubset(of: ["AGENTS.md"]) { return true }
        return false
    }
    /// Antigravity creates these only after loading the plugin. An unrelated
    /// entry or an unsafe path leaves that entire cache directory alone.
    private func removeGeneratedCaches() throws {
        let dataHome = target.home.deletingLastPathComponent().appendingPathComponent("antigravity", isDirectory: true)
        let schema = CodexProgressEvidence.tool + ".json", notes = "instructions.md"
        for (path, schemas) in [("plugin_data/" + Self.folder, false), ("mcp/" + Self.server, true)] {
            let folder = dataHome.appendingPathComponent(path, isDirectory: true)
            guard storage.isDirectory(folder), let names = try? storage.names(in: folder) else { continue }
            // 2.35.2 also keeps the server's instructions beside the tool's schema.
            if schemas && names.contains(schema) && names.isSubset(of: [schema, notes]) {
                let file = folder.appendingPathComponent(schema), instructions = folder.appendingPathComponent(notes)
                guard let data = try? bytes(file), Self.isProgressSchema(data) else { continue }
                if names.contains(notes) {
                    guard let text = (try? bytes(instructions)).flatMap({ String(data: $0, encoding: .utf8) }),
                          text.trimmingCharacters(in: .whitespacesAndNewlines) == ProgressPrompt.toolDescription else { continue }
                    try storage.remove(instructions)
                }
                try storage.remove(file)
            } else if !names.isEmpty { continue }
            try storage.removeEmptyDirectory(folder)
        }
    }

    private static func isProgressSchema(_ data: Data) -> Bool {
        guard let tool = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              tool["name"] == nil || tool["name"] as? String == CodexProgressEvidence.tool else { return false }
        let schema = (tool["inputSchema"] ?? tool["input_schema"] ?? tool["parameters"] ?? tool) as? [String: Any]
        guard let properties = schema?["properties"] as? [String: Any],
              Set(properties.keys) == ["percent"], let percent = properties["percent"] as? [String: Any] else { return false }
        return (percent["type"] as? String)?.lowercased() == "integer"
    }

    private func remove(_ old: Install, checkOnly: Bool) throws -> State? {
        try directory(plugin); try directory(rules)
        var conflict = try extras()
        for file in try managedFiles(old.command, old: old).reversed() {
            guard let data = try bytes(file.url) else { continue }
            guard file.owned.contains(data) else { conflict = true; continue }
            if !checkOnly { try storage.remove(file.url) }
        }
        if !checkOnly {
            for url in [rules, plugin] where storage.exists(url) {
                if try storage.names(in: url).isEmpty { try storage.removeEmptyDirectory(url) }
            }
            if !conflict {
                try removeGeneratedCaches()
                try storage.remove(journal)
                if try storage.names(in: state).isEmpty { try storage.removeEmptyDirectory(state) }
            }
        }
        return conflict ? State(.conflict) : nil
    }
}
