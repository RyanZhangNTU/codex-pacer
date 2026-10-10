import Foundation

/// Installation is an explicit Settings action. Existing hooks, environment
/// variables and a user's status-line renderer are preserved and reversible.
public enum ClaudeHookInstaller {
    public struct Status: Equatable, Sendable {
        public let hooksConfigured: Bool
        public let telemetryConfigured: Bool
        public let statusLineConfigured: Bool
        public let telemetryConflict: Bool
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
    private static let events = ["SessionStart", "UserPromptSubmit", "MessageDisplay", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Stop", "StopFailure", "SessionEnd", "Notification", "SubagentStart", "SubagentStop", "Elicitation", "ElicitationResult"]
    private static let environment: [String: String] = [
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1", "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:4319/v1/traces",
        "OTEL_TRACES_EXPORT_INTERVAL": "1000"
    ]
    public static func status(home: URL) -> Bool { details(home: home).hooksConfigured }
    public static func details(home: URL) -> Status {
        let value = (try? settings(home: home).value) ?? [:], hooks = value["hooks"] as? [String: [[String: Any]]] ?? [:]
        let command = hookCommand(home: home)
        let script = home.appendingPathComponent("pacer/hook.py")
        let scriptAvailable = (try? safe(script)) != nil && FileManager.default.isReadableFile(atPath: script.path)
        let configured = scriptAvailable && events.allSatisfy { event in hooks[event]?.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { $0["type"] as? String == "command" && $0["command"] as? String == command } == true
        } == true }
        let env = value["env"] as? [String: String] ?? [:]
        let telemetry = environment.allSatisfy { env[$0.key] == $0.value }
        let conflict = environment.contains { env[$0.key] != nil && env[$0.key] != $0.value } ||
            telemetryConflict(env)
        let line = value["statusLine"] as? [String: Any]
        return Status(hooksConfigured: configured, telemetryConfigured: telemetry, statusLineConfigured: line?["command"] as? String == statusLineCommand(home: home), telemetryConflict: conflict)
    }
    @discardableResult public static func install(home: URL) throws -> Status {
        try safe(home)
        let existing = try settings(home: home), directory = home.appendingPathComponent("pacer"), manifestURL = directory.appendingPathComponent("installation.json")
        try safe(directory); try safe(manifestURL)
        var value = existing.value
        if value["hooks"] != nil && !(value["hooks"] is [String: Any]) { throw Failure.invalidSettings }
        var hooks = value["hooks"] as? [String: Any] ?? [:]
        let command = hookCommand(home: home)
        for event in events {
            if hooks[event] != nil && !(hooks[event] is [[String: Any]]) { throw Failure.invalidSettings }
            var groups = hooks[event] as? [[String: Any]] ?? []
            if !groups.contains(where: { ($0["hooks"] as? [[String: Any]])?.contains { $0["type"] as? String == "command" && $0["command"] as? String == command } == true }) {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            }
            hooks[event] = groups
        }
        value["hooks"] = hooks
        if value["env"] != nil && !(value["env"] is [String: String]) { throw Failure.invalidSettings }
        var env = value["env"] as? [String: String] ?? [:]
        let conflict = environment.contains { env[$0.key] != nil && env[$0.key] != $0.value } ||
            telemetryConflict(env)
        var manifest = (try? readObject(manifestURL)) ?? [:]
        var added = manifest["addedEnvironment"] as? [String: String] ?? [:]
        if !conflict { for (key, setting) in environment where env[key] == nil { env[key] = setting; added[key] = setting }; value["env"] = env }
        manifest["addedEnvironment"] = added
        let previousLine = value["statusLine"]
        if (previousLine as? [String: Any])?["command"] as? String != statusLineCommand(home: home) {
            if let previousLine, !(previousLine is [String: Any]) { throw Failure.invalidSettings }
            manifest["previousStatusLine"] = previousLine ?? NSNull()
            var wrapper = previousLine as? [String: Any] ?? [:]
            wrapper["type"] = "command"; wrapper["command"] = statusLineCommand(home: home)
            value["statusLine"] = wrapper
        }
        manifest["version"] = 1
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try safe(directory); try safe(home.appendingPathComponent("settings.json")); try safe(manifestURL)
        guard let resource = Bundle.module.url(forResource: "claude_hook", withExtension: "py") else { throw Failure.invalidSettings }
        let script = directory.appendingPathComponent("hook.py"); try safe(script)
        let scriptData = try Data(contentsOf: resource); try scriptData.write(to: script, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard try settings(home: home).bytes == existing.bytes else { throw Failure.changedSettings }
        let previousManifest = try? Data(contentsOf: manifestURL)
        try write(manifest, to: manifestURL)
        do { try write(value, to: home.appendingPathComponent("settings.json")) }
        catch {
            if let previousManifest { try? previousManifest.write(to: manifestURL, options: [.atomic]) }
            else { try? FileManager.default.removeItem(at: manifestURL) }
            throw error
        }
        return details(home: home)
    }
    public static func uninstall(home: URL) throws {
        try safe(home)
        let existing = try settings(home: home), directory = home.appendingPathComponent("pacer"), manifestURL = directory.appendingPathComponent("installation.json")
        guard let manifest = try? readObject(manifestURL) else { return }
        var value = existing.value, hooks = value["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let remaining = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                var group = group; let kept = entries.filter { $0["type"] as? String != "command" || $0["command"] as? String != hookCommand(home: home) }
                if kept.isEmpty { return nil }; group["hooks"] = kept; return group
            }
            if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
        }
        if hooks.isEmpty { value.removeValue(forKey: "hooks") } else { value["hooks"] = hooks }
        var env = value["env"] as? [String: String] ?? [:]
        for (key, setting) in manifest["addedEnvironment"] as? [String: String] ?? [:] where env[key] == setting { env.removeValue(forKey: key) }
        if env.isEmpty { value.removeValue(forKey: "env") } else { value["env"] = env }
        if (value["statusLine"] as? [String: Any])?["command"] as? String == statusLineCommand(home: home) {
            if let previous = manifest["previousStatusLine"], !(previous is NSNull) { value["statusLine"] = previous } else { value.removeValue(forKey: "statusLine") }
        }
        guard try settings(home: home).bytes == existing.bytes else { throw Failure.changedSettings }
        try write(value, to: home.appendingPathComponent("settings.json"))
        // Keep the sanitized spool/metadata for late accounting. Only settings
        // entries owned by Pacer are removed; no transcript is touched.
        try? FileManager.default.removeItem(at: manifestURL)
    }
    private static func hookCommand(home: URL) -> String { "python3 " + quote(home.appendingPathComponent("pacer/hook.py").path) + " hook " + quote(home.path) }
    private static func telemetryConflict(_ env: [String: String]) -> Bool {
        if ["OTEL_EXPORTER_OTLP_TRACES_HEADERS", "OTEL_EXPORTER_OTLP_HEADERS"].contains(where: { env[$0]?.isEmpty == false }) { return true }
        if let endpoint = env["OTEL_EXPORTER_OTLP_ENDPOINT"], !["http://127.0.0.1:4319", "http://127.0.0.1:4319/v1/traces"].contains(endpoint) { return true }
        if let protocolName = env["OTEL_EXPORTER_OTLP_PROTOCOL"], protocolName != "http/json" { return true }
        return false
    }
    private static func statusLineCommand(home: URL) -> String { "python3 " + quote(home.appendingPathComponent("pacer/hook.py").path) + " statusline " + quote(home.path) }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func settings(home: URL) throws -> (value: [String: Any], bytes: Data?) {
        let file = home.appendingPathComponent("settings.json"); try safe(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return ([:], nil) }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidSettings }
        return (value, bytes)
    }
    private static func readObject(_ file: URL) throws -> [String: Any] {
        try safe(file); let bytes = try Data(contentsOf: file)
        guard bytes.count <= 2 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidSettings }; return value
    }
    private static func safe(_ file: URL) throws {
        guard !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsafePath }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) {
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink, (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.unsafePath }
        }
    }
    private static func write(_ value: [String: Any], to file: URL) throws {
        try safe(file); let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try data.write(to: file, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
