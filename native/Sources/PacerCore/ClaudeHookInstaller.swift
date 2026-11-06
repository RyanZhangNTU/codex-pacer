import Foundation

/// Pacer keeps its hooks current while the Claude module is on, like Codex
/// needs no setup step. Existing hooks, environment variables and a user's
/// status-line renderer are preserved and reversible.
public protocol ClaudeHookStorage: Sendable {
    func validate(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func isReadable(_ url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    func createDirectory(_ url: URL, permissions: UInt16) throws
    func replace(_ url: URL, with data: Data, permissions: UInt16) throws
    func remove(_ url: URL) throws
}

public struct ClaudeHookInstaller {
    public enum CommandKind: Equatable, Sendable { case hook, statusLine }
    private let storage: any ClaudeHookStorage
    private let python: String
    private let serialize: @Sendable ([String]) -> String
    private let helperScript: Data?
    private let additionalOwnedCommand: @Sendable (String, URL, CommandKind) -> Bool
    public init(storage: any ClaudeHookStorage, python: String, serialize: @escaping @Sendable ([String]) -> String,
                helperScript: Data? = nil,
                additionalOwnedCommand: @escaping @Sendable (String, URL, CommandKind) -> Bool = { _, _, _ in false }) {
        self.storage = storage; self.python = python; self.serialize = serialize
        self.helperScript = helperScript; self.additionalOwnedCommand = additionalOwnedCommand
    }
    public enum EnsureResult: Equatable, Sendable { case current, installed, missingHome, failed }
    public struct Status: Equatable, Sendable {
        public let hooksConfigured: Bool
        public let telemetryConfigured: Bool
        public let statusLineConfigured: Bool
        public let telemetryConflict: Bool
        /// Owned entries or the installed adapter predate this version.
        public var updateAvailable = false
    }
    public enum Failure: Error, LocalizedError {
        case invalidSettings, unsafePath, changedSettings
        public var errorDescription: String? {
            switch self {
            case .invalidSettings: return "Claude settings must contain a valid JSON object; existing settings were preserved."
            case .unsafePath: return "Claude monitoring cannot use a symlink or a directory owned by another user."
            case .changedSettings: return "Claude settings changed during setup; retry after the other edit finishes."
            }
        }
    }
    private let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Stop", "StopFailure", "SessionEnd", "Notification", "SubagentStart", "SubagentStop", "Elicitation", "ElicitationResult"]
    /// Claude holds each displayed batch until its hooks return. Numeric OTLP
    /// spans already report TTFT, so the display observer is registered only
    /// without Pacer telemetry, and then runs in the background.
    private let displayEvent = "MessageDisplay"
    private let environment: [String: String] = [
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1", "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:4319/v1/traces",
        "OTEL_TRACES_EXPORT_INTERVAL": "1000"
    ]
    public func status(home: URL) -> Bool { details(home: home).hooksConfigured }
    /// Never creates a Claude home and writes nothing when already current. An
    /// update is applied in place first, so optional entries the user removed
    /// stay removed; missing required hooks are installed again.
    public func ensureInstalled(home: URL) -> EnsureResult {
        guard storage.isDirectory(home) else { return .missingHome }
        let status = details(home: home)
        if status.hooksConfigured && !status.updateAvailable { return .current }
        if status.hooksConfigured, migrate(home: home), !details(home: home).updateAvailable { return .installed }
        return (try? install(home: home)) != nil ? .installed : .failed
    }
    public func details(home: URL) -> Status {
        let value = (try? settings(home: home).value) ?? [:], hooks = value["hooks"] as? [String: [[String: Any]]] ?? [:]
        let script = home.appendingPathComponent("pacer/hook.py")
        let scriptAvailable = (try? safe(script)) != nil && storage.isReadable(script)
        let configured = scriptAvailable && events.allSatisfy { event in hooks[event]?.contains { containsOwned($0, home: home) } == true }
        let env = value["env"] as? [String: String] ?? [:]
        let telemetry = environment.allSatisfy { env[$0.key] == $0.value }
        let conflict = environment.contains { env[$0.key] != nil && env[$0.key] != $0.value } ||
            telemetryConflict(env)
        let lineCommand = (value["statusLine"] as? [String: Any])?["command"] as? String
        var status = Status(hooksConfigured: configured, telemetryConfigured: telemetry,
            statusLineConfigured: ownsStatusLine(lineCommand, home: home),
            telemetryConflict: conflict)
        status.updateAvailable = configured && (migrated(value, home: home) != nil || installedScriptOutdated(home: home) ||
            progressMode(home: home) == .tool && pluginOutdated(home: home))
        return status
    }
    @discardableResult public func install(home: URL) throws -> Status {
        try safe(home)
        let existing = try settings(home: home), directory = home.appendingPathComponent("pacer"), manifestURL = directory.appendingPathComponent("installation.json")
        try safe(directory); try safe(manifestURL)
        var value = existing.value
        if value["hooks"] != nil && !(value["hooks"] is [String: Any]) { throw Failure.invalidSettings }
        var hooks = value["hooks"] as? [String: Any] ?? [:]
        for event in events + [displayEvent] where hooks[event] != nil && !(hooks[event] is [[String: Any]]) { throw Failure.invalidSettings }
        for event in events { hooks[event] = ensureOwned(hooks[event] as? [[String: Any]] ?? [], home: home, background: false) }
        if value["env"] != nil && !(value["env"] is [String: String]) { throw Failure.invalidSettings }
        var env = value["env"] as? [String: String] ?? [:]
        let conflict = environment.contains { env[$0.key] != nil && env[$0.key] != $0.value } ||
            telemetryConflict(env)
        var manifest = (try? readObject(manifestURL)) ?? [:]
        var added = manifest["addedEnvironment"] as? [String: String] ?? [:]
        if !conflict { for (key, setting) in environment where env[key] == nil { env[key] = setting; added[key] = setting }; value["env"] = env }
        manifest["addedEnvironment"] = added
        setDisplayObserver(&hooks, wanted: !environment.allSatisfy { env[$0.key] == $0.value } || progressMode(home: home) == .marker, home: home)
        value["hooks"] = hooks
        let wantsPlugin = progressMode(home: home) == .tool
        setPlugin(&value, wanted: wantsPlugin, home: home)
        let previousLine = value["statusLine"]
        if let previousLine, !(previousLine is [String: Any]) { throw Failure.invalidSettings }
        let previousCommand = (previousLine as? [String: Any])?["command"] as? String
        if previousCommand != statusLineCommand(home: home) && ownsStatusLine(previousCommand, home: home) {
            var line = previousLine as? [String: Any] ?? [:]; line["command"] = statusLineCommand(home: home); value["statusLine"] = line
        } else if previousCommand != statusLineCommand(home: home) {
            manifest["previousStatusLine"] = previousLine ?? NSNull()
            var wrapper = previousLine as? [String: Any] ?? [:]
            wrapper["type"] = "command"; wrapper["command"] = statusLineCommand(home: home)
            value["statusLine"] = wrapper
        }
        manifest["version"] = 1
        try storage.createDirectory(directory, permissions: 0o700)
        try safe(directory); try safe(home.appendingPathComponent("settings.json")); try safe(manifestURL)
        try writeScript(home: home)
        if wantsPlugin { try writePlugin(home: home) }
        guard try settings(home: home).bytes == existing.bytes else { throw Failure.changedSettings }
        let previousManifest = try? storage.read(manifestURL)
        try write(manifest, to: manifestURL)
        do { try write(value, to: home.appendingPathComponent("settings.json")) }
        catch {
            if let previousManifest { try? storage.replace(manifestURL, with: previousManifest, permissions: 0o600) }
            else { try? storage.remove(manifestURL) }
            throw error
        }
        return details(home: home)
    }
    /// Upgrade an existing installation in place: refresh Pacer's adapter and
    /// rewrite only Pacer-owned entries. Nothing the user removed is re-added.
    @discardableResult public func migrate(home: URL) -> Bool {
        let manifestURL = home.appendingPathComponent("pacer/installation.json")
        guard (try? safe(home)) != nil, (try? safe(manifestURL)) != nil, storage.exists(manifestURL),
              let existing = try? settings(home: home) else { return false }
        var changed = false
        if installedScriptOutdated(home: home), (try? writeScript(home: home)) != nil { changed = true }
        if progressMode(home: home) == .tool, pluginOutdated(home: home) {
            guard (try? writePlugin(home: home)) != nil else { return changed }
            changed = true
        }
        guard let updated = migrated(existing.value, home: home) else { return changed }
        guard (try? settings(home: home).bytes) == existing.bytes,
              (try? write(updated, to: home.appendingPathComponent("settings.json"))) != nil else { return changed }
        return true
    }
    public func uninstall(home: URL) throws {
        try safe(home)
        let existing = try settings(home: home), directory = home.appendingPathComponent("pacer"), manifestURL = directory.appendingPathComponent("installation.json")
        guard let manifest = try? readObject(manifestURL) else { return }
        var value = existing.value, hooks = value["hooks"] as? [String: Any] ?? [:]
        for event in events + [displayEvent] {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let remaining = removingOwned(groups, home: home)
            if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
        }
        if hooks.isEmpty { value.removeValue(forKey: "hooks") } else { value["hooks"] = hooks }
        setPlugin(&value, wanted: false, home: home)
        var env = value["env"] as? [String: String] ?? [:]
        for (key, setting) in manifest["addedEnvironment"] as? [String: String] ?? [:] where env[key] == setting { env.removeValue(forKey: key) }
        if env.isEmpty { value.removeValue(forKey: "env") } else { value["env"] = env }
        let lineCommand = (value["statusLine"] as? [String: Any])?["command"] as? String
        if ownsStatusLine(lineCommand, home: home) {
            if let previous = manifest["previousStatusLine"], !(previous is NSNull) { value["statusLine"] = previous } else { value.removeValue(forKey: "statusLine") }
        }
        guard try settings(home: home).bytes == existing.bytes else { throw Failure.changedSettings }
        try write(value, to: home.appendingPathComponent("settings.json"))
        // Keep the sanitized spool/metadata for late accounting. Only settings
        // entries owned by Pacer are removed; no transcript is touched.
        try? storage.remove(manifestURL)
    }
    /// Settings with only Pacer-owned entries brought current, or nil when
    /// nothing differs. Missing events, environment or wrappers stay absent.
    private func migrated(_ value: [String: Any], home: URL) -> [String: Any]? {
        guard var hooks = value["hooks"] as? [String: Any] else { return nil }
        var result = value
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]], groups.contains(where: { containsOwned($0, home: home) }) else { continue }
            hooks[event] = ensureOwned(groups, home: home, background: false)
        }
        let env = value["env"] as? [String: String] ?? [:]
        let mode = progressMode(home: home)
        let wantsDisplay = !environment.allSatisfy { env[$0.key] == $0.value } || mode == .marker
        if let groups = hooks[displayEvent] as? [[String: Any]], groups.contains(where: { containsOwned($0, home: home) }) {
            setDisplayObserver(&hooks, wanted: wantsDisplay, home: home)
        } else if mode == .marker {
            // Leading markers are read from each message's first displayed
            // lines: that switch adds the background observer and removing it drops it.
            setDisplayObserver(&hooks, wanted: true, home: home)
        }
        result["hooks"] = hooks
        setPlugin(&result, wanted: mode == .tool, home: home)
        if var line = value["statusLine"] as? [String: Any], line["command"] as? String != statusLineCommand(home: home),
           ownsStatusLine(line["command"] as? String, home: home) {
            line["command"] = statusLineCommand(home: home); result["statusLine"] = line
        }
        return NSDictionary(dictionary: result).isEqual(to: value) ? nil : result
    }
    private func ownedEntry(home: URL, background: Bool) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": hookCommand(home: home), "timeout": 5]
        if background { entry["async"] = true }
        return entry
    }
    private func owned(_ entry: [String: Any], home: URL) -> Bool {
        guard entry["type"] as? String == "command", let command = entry["command"] as? String else { return false }
        return command == hookCommand(home: home) || command == legacyHookCommand(home: home) || additionalOwnedCommand(command, home, .hook)
    }
    private func ownsStatusLine(_ command: String?, home: URL) -> Bool {
        guard let command else { return false }
        return command == statusLineCommand(home: home) || command == legacyStatusLineCommand(home: home) || additionalOwnedCommand(command, home, .statusLine)
    }
    private func containsOwned(_ group: [String: Any], home: URL) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { owned($0, home: home) } == true
    }
    /// Exactly one current owned entry, kept where an older one already was.
    private func ensureOwned(_ groups: [[String: Any]], home: URL, background: Bool) -> [[String: Any]] {
        var placed = false
        var result = groups.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]], entries.contains(where: { owned($0, home: home) }) else { return group }
            var group = group
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard owned(entry, home: home) else { return entry }
                defer { placed = true }
                return placed ? nil : ownedEntry(home: home, background: background)
            }
            if kept.isEmpty { return nil }
            group["hooks"] = kept; return group
        }
        if !placed { result.append(["hooks": [ownedEntry(home: home, background: background)]]) }
        return result
    }
    private func removingOwned(_ groups: [[String: Any]], home: URL) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            var group = group; let kept = entries.filter { !owned($0, home: home) }
            if kept.isEmpty { return nil }; group["hooks"] = kept; return group
        }
    }
    /// How the progress ring asks for estimates: its switch file holds `tool`
    /// (Pacer's plugin tool) or another word (a leading marker in each message).
    private enum ProgressMode { case marker, tool }
    private func progressMode(home: URL) -> ProgressMode? {
        let flag = ClaudeProgressRingSwitch.flagURL(home: home)
        guard storage.exists(flag) else { return nil }
        let text = (try? storage.read(flag)).map { String(decoding: $0.prefix(16), as: UTF8.self) } ?? ""
        return text.split(whereSeparator: \.isWhitespace).first == "tool" ? .tool : .marker
    }
    /// Pacer's Claude Code plugin is a local marketplace in Pacer's hook folder
    /// whose one plugin serves `report_progress`. While the ring asks for the
    /// tool, settings list that marketplace, enable the plugin and pre-approve
    /// its one tool; otherwise exactly those entries are removed.
    public static let progressTool = "mcp__plugin_pacer_pacer__report_progress"
    private static let marketplace = "pacer", pluginKey = "pacer@pacer"
    private func pluginRoot(home: URL) -> URL { home.appendingPathComponent("pacer/plugin") }
    private func setPlugin(_ value: inout [String: Any], wanted: Bool, home: URL) {
        guard value["extraKnownMarketplaces"] == nil || value["extraKnownMarketplaces"] is [String: Any],
              value["enabledPlugins"] == nil || value["enabledPlugins"] is [String: Any],
              value["permissions"] == nil || value["permissions"] is [String: Any] else { return }
        var markets = value["extraKnownMarketplaces"] as? [String: Any] ?? [:], enabled = value["enabledPlugins"] as? [String: Any] ?? [:]
        var permissions = value["permissions"] as? [String: Any] ?? [:]
        guard permissions["allow"] == nil || permissions["allow"] is [String] else { return }
        var allow = permissions["allow"] as? [String] ?? []
        let source: [String: Any] = ["source": ["source": "directory", "path": pluginRoot(home: home).path]]
        let ours = (markets[Self.marketplace] as? [String: Any]).map { NSDictionary(dictionary: $0).isEqual(to: source) } ?? false
        if wanted {
            markets[Self.marketplace] = source; enabled[Self.pluginKey] = true
            if !allow.contains(Self.progressTool) { allow.append(Self.progressTool) }
        } else {
            guard ours || enabled[Self.pluginKey] != nil || allow.contains(Self.progressTool) else { return }
            if ours { markets.removeValue(forKey: Self.marketplace) }
            if ours { enabled.removeValue(forKey: Self.pluginKey) }
            allow.removeAll { $0 == Self.progressTool }
        }
        func place(_ key: String, _ dictionary: [String: Any], in target: inout [String: Any]) {
            if dictionary.isEmpty { target.removeValue(forKey: key) } else { target[key] = dictionary }
        }
        place("extraKnownMarketplaces", markets, in: &value); place("enabledPlugins", enabled, in: &value)
        if allow.isEmpty { permissions.removeValue(forKey: "allow") } else { permissions["allow"] = allow }
        place("permissions", permissions, in: &value)
    }
    private func pluginFiles(home: URL) -> [(url: URL, data: Data)]? {
        guard let resource = L10n.sharedResourceBundle.url(forResource: "claude_progress_mcp", withExtension: "py"),
              let server = try? Data(contentsOf: resource) else { return nil }
        let root = pluginRoot(home: home), plugin = root.appendingPathComponent("pacer"), script = plugin.appendingPathComponent("progress_mcp.py")
        let catalog: [String: Any] = ["name": Self.marketplace, "owner": ["name": "Codex Pacer"],
            "plugins": [["name": "pacer", "source": "./pacer", "description": "Reports progress to Pacer's progress ring."]]]
        let manifest: [String: Any] = ["name": "pacer", "version": "1.0.0", "description": "Reports progress to Pacer's progress ring.",
            "mcpServers": ["pacer": ["command": python, "args": ["-S", script.path, "--home", home.path]]]]
        guard let catalogData = try? JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys]),
              let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return [(root.appendingPathComponent(".claude-plugin/marketplace.json"), catalogData),
                (plugin.appendingPathComponent(".claude-plugin/plugin.json"), manifestData), (script, server)]
    }
    private func writePlugin(home: URL) throws {
        guard let files = pluginFiles(home: home) else { throw Failure.invalidSettings }
        let root = pluginRoot(home: home), plugin = root.appendingPathComponent("pacer")
        for folder in [root, root.appendingPathComponent(".claude-plugin"), plugin, plugin.appendingPathComponent(".claude-plugin")] {
            try safe(folder); if !storage.isDirectory(folder) { try storage.createDirectory(folder, permissions: 0o700) }
        }
        for file in files where (try? storage.read(file.url)) != file.data { try safe(file.url); try storage.replace(file.url, with: file.data, permissions: 0o600) }
    }
    private func pluginOutdated(home: URL) -> Bool {
        guard let files = pluginFiles(home: home) else { return false }
        return files.contains { (try? storage.read($0.url)) != $0.data }
    }
    private func setDisplayObserver(_ hooks: inout [String: Any], wanted: Bool, home: URL) {
        let groups = hooks[displayEvent] as? [[String: Any]] ?? []
        let updated = wanted ? ensureOwned(groups, home: home, background: true) : removingOwned(groups, home: home)
        if updated.isEmpty { hooks.removeValue(forKey: displayEvent) } else { hooks[displayEvent] = updated }
    }
    private func writeScript(home: URL) throws {
        if let helperScript {
            let script = home.appendingPathComponent("pacer/hook.py"); try safe(script)
            try storage.replace(script, with: helperScript, permissions: 0o700)
            return
        }
        guard let resource = Bundle.module.url(forResource: "claude_hook", withExtension: "py") else { throw Failure.invalidSettings }
        let script = home.appendingPathComponent("pacer/hook.py"); try safe(script)
        let scriptData = try Data(contentsOf: resource); try storage.replace(script, with: scriptData, permissions: 0o700)
    }
    private func installedScriptOutdated(home: URL) -> Bool {
        let script = home.appendingPathComponent("pacer/hook.py")
        if let helperScript {
            guard (try? safe(script)) != nil, let installed = try? storage.read(script) else { return false }
            return helperScript != installed
        }
        guard let resource = Bundle.module.url(forResource: "claude_hook", withExtension: "py"),
              (try? safe(script)) != nil, let installed = try? storage.read(script) else { return false }
        return (try? Data(contentsOf: resource)) != installed
    }
    /// The adapter uses only the standard library, so `-S` skips site-packages
    /// startup. Avoid `-E`/`-I`: macOS's bundled Python then loses its bytecode
    /// cache and recompiles imported modules on every hook.
    private func hookCommand(home: URL) -> String { serialize([python, "-S", home.appendingPathComponent("pacer/hook.py").path, "hook", home.path]) }
    private func legacyHookCommand(home: URL) -> String { serialize([python, home.appendingPathComponent("pacer/hook.py").path, "hook", home.path]) }
    private func telemetryConflict(_ env: [String: String]) -> Bool {
        if ["OTEL_EXPORTER_OTLP_TRACES_HEADERS", "OTEL_EXPORTER_OTLP_HEADERS"].contains(where: { env[$0]?.isEmpty == false }) { return true }
        if let endpoint = env["OTEL_EXPORTER_OTLP_ENDPOINT"], !["http://127.0.0.1:4319", "http://127.0.0.1:4319/v1/traces"].contains(endpoint) { return true }
        if let protocolName = env["OTEL_EXPORTER_OTLP_PROTOCOL"], protocolName != "http/json" { return true }
        return false
    }
    private func statusLineCommand(home: URL) -> String { serialize([python, "-S", home.appendingPathComponent("pacer/hook.py").path, "statusline", home.path]) }
    private func legacyStatusLineCommand(home: URL) -> String { serialize([python, home.appendingPathComponent("pacer/hook.py").path, "statusline", home.path]) }
    private func settings(home: URL) throws -> (value: [String: Any], bytes: Data?) {
        let file = home.appendingPathComponent("settings.json"); try safe(file)
        guard storage.exists(file) else { return ([:], nil) }
        let bytes = try storage.read(file)
        guard bytes.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidSettings }
        return (value, bytes)
    }
    private func readObject(_ file: URL) throws -> [String: Any] {
        try safe(file); let bytes = try storage.read(file)
        guard bytes.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidSettings }; return value
    }
    private func safe(_ file: URL) throws {
        guard !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsafePath }
        try storage.validate(file)
    }
    private func write(_ value: [String: Any], to file: URL) throws {
        try safe(file); let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try storage.replace(file, with: data, permissions: 0o600)
    }
}
