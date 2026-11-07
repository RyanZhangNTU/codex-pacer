import Foundation

/// The stdio server runs in a separate Pacer process owned by Codex. It keeps
/// no turn state. The successful tool result is the evidence Pacer observes.
public struct CodexProgressReporter {
    public static let argument = "--codex-progress-mcp"
    private static let limit = 1024 * 1024
    private static let instructions = "Report your best estimate of how much of the user's current request is done. Call this tool with your first useful tool batch, after meaningful progress, and before a long wait. Use an integer from 0 to 100 and revise it downward when needed. Skip reports for short replies that need no tools."
    private let flag: URL
    private var pending = Data()

    public init(home: URL) { flag = CodexProgressSetup.flag(home) }

    public mutating func receive(_ bytes: Data) throws -> [Data] {
        var replies: [Data] = []
        for byte in bytes {
            if byte == 10 {
                if let reply = response(pending) {
                    replies.append(try JSONSerialization.data(withJSONObject: reply) + Data([10]))
                }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.limit else { throw CocoaError(.fileReadTooLarge) }
                pending.append(byte)
            }
        }
        return replies
    }

    private var enabled: Bool {
        guard let facts = try? FileManager.default.attributesOfItem(atPath: flag.path),
              facts[.type] as? FileAttributeType == .typeRegular,
              (facts[.size] as? NSNumber)?.intValue == CodexProgressSetup.on.count,
              let input = try? FileHandle(forReadingFrom: flag) else { return false }
        defer { try? input.close() }
        return (try? input.read(upToCount: CodexProgressSetup.on.count + 1)) == CodexProgressSetup.on
    }

    private func response(_ data: Data) -> [String: Any]? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let id = message["id"],
              id is String || id is NSNumber, let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            let protocolVersion = params["protocolVersion"] as? String ?? ""
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            var result: [String: Any] = ["protocolVersion": supported.contains(protocolVersion) ? protocolVersion : "2025-06-18",
                "capabilities": ["tools": [String: String]()],
                "serverInfo": ["name": CodexProgressEvidence.server, "version": "2.0.0"]]
            if enabled { result["instructions"] = Self.instructions }
            reply["result"] = result
        case "ping": reply["result"] = [String: String]()
        case "tools/list":
            let tool: [String: Any] = ["name": CodexProgressEvidence.tool, "description": Self.instructions,
                "inputSchema": ["type": "object", "properties": ["percent": ["type": "integer", "minimum": 0, "maximum": 100]],
                                "required": ["percent"], "additionalProperties": false],
                "annotations": ["readOnlyHint": true, "openWorldHint": false]]
            reply["result"] = ["tools": enabled ? [tool] : []]
        case "tools/call":
            let active = enabled
            let valid = active && params["name"] as? String == CodexProgressEvidence.tool &&
                CodexProgressEvidence.percent(params["arguments"] as? [String: Any]) != nil
            let text = valid ? CodexProgressEvidence.acknowledgment : active ? "Expected an integer from 0 to 100." : "Pacer task progress is disabled."
            reply["result"] = ["content": [["type": "text", "text": text]], "isError": !valid]
        default: reply["error"] = ["code": -32601, "message": "Method not found"]
        }
        return reply
    }
}

public enum CodexProgressSetupStatus: String, Codable, Sendable {
    case settingUp, ready, missingCLI, conflict, failed
}

public enum CodexProgressSetup {
    static let on = Data("on\n".utf8)
    static func folder(_ home: URL) -> URL { home.appendingPathComponent("pacer/codex-progress", isDirectory: true) }
    private static func native(_ home: URL) -> URL { folder(home).appendingPathComponent("native", isDirectory: true) }
    static func flag(_ home: URL) -> URL { native(home).appendingPathComponent("enabled") }

    public static func wasConfigured(in home: URL) -> Bool {
        FileManager.default.fileExists(atPath: native(home).path) ||
            FileManager.default.fileExists(atPath: folder(home).appendingPathComponent("installation.json").path)
    }

    /// Same owned-file checks as the local Claude setup. The profile must
    /// already exist, and a failed setup can never enable a cached server.
    public static func apply(enabled: Bool, home: URL, reporter: URL, storage: any ClaudeHookStorage,
                             client: @Sendable () -> CodexClient?) async -> CodexProgressSetupStatus? {
        do {
            let folder = folder(home), directory = native(home), flag = flag(home)
            let config = home.appendingPathComponent("config.toml")
            for path in [home, home.appendingPathComponent("pacer"), folder, directory, flag, config] { try storage.validate(path) }
            guard storage.isDirectory(home) else { return enabled ? .failed : nil }
            let legacy = try CodexProgressLegacy(home: home, storage: storage)
            if storage.exists(flag), try storage.read(flag) != on { return .failed }
            guard enabled || storage.exists(directory) || legacy != nil else { return nil }
            if !enabled, storage.exists(flag) { try storage.remove(flag) }
            if legacy != nil { _ = CodexProgressRingSwitch.apply(enabled: false, home: home) }
            guard let client = client() else { return .missingCLI }
            // Record that this profile may contain a registration before the
            // RPC, so a later disable can clean up after an interrupted setup.
            if enabled, !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
            let status: CodexProgressSetupStatus
            do {
                status = try await client.setProgressReporter(reporter: reporter, enabled: enabled, legacy: legacy?.command)
            } catch {
                await client.shutdown()
                throw error
            }
            await client.shutdown()
            if status != .ready {
                if storage.exists(flag), try storage.read(flag) == on { try storage.remove(flag) }
                return status
            }
            try legacy?.removeHooks(home: home, storage: storage)
            if enabled, !storage.exists(flag) { try storage.replace(flag, with: on, permissions: 0o600) }
            return enabled ? .ready : nil
        } catch { return .failed }
    }
}

/// A beta install used a script and prompt hooks. Its exact registered
/// command and hook groups are the only legacy entries we can migrate.
private struct CodexProgressLegacy {
    let command: CodexProgressCommand
    let groups: [String: Any]

    init?(home: URL, storage: any ClaudeHookStorage) throws {
        let folder = CodexProgressSetup.folder(home), ledger = folder.appendingPathComponent("installation.json")
        try storage.validate(ledger)
        guard storage.exists(ledger) else { return nil }
        let data = try storage.read(ledger)
        guard data.count <= 64 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["owner"] as? String == "codex-pacer-progress-v1", value["removed"] as? Bool != true,
              let server = value["server"] as? [String: Any], let transport = server["transport"] as? [String: Any],
              let executable = transport["command"] as? String, let arguments = transport["args"] as? [String],
              arguments.count == 2, arguments[0] == "-S",
              URL(fileURLWithPath: arguments[1]).standardizedFileURL == folder.appendingPathComponent("reporter.py").standardizedFileURL,
              let groups = value["groups"] as? [String: Any] else { return nil }
        command = .init(executable: executable, arguments: arguments)
        self.groups = groups
    }

    func removeHooks(home: URL, storage: any ClaudeHookStorage) throws {
        let path = home.appendingPathComponent("hooks.json")
        try storage.validate(path)
        guard storage.exists(path) else { return }
        let before = try storage.read(path)
        guard before.count <= 1024 * 1024, var config = try JSONSerialization.jsonObject(with: before) as? [String: Any],
              var hooks = config["hooks"] as? [String: Any] else { return }
        var changed = false
        for event in ["UserPromptSubmit", "SessionStart"] {
            guard let group = groups[event] as? NSDictionary, var rows = hooks[event] as? [[String: Any]],
                  let index = rows.firstIndex(where: { group.isEqual(to: $0) }) else { continue }
            rows.remove(at: index)
            hooks[event] = rows.isEmpty ? nil : rows
            changed = true
        }
        guard changed else { return }
        config["hooks"] = hooks
        guard try storage.read(path) == before else { throw CocoaError(.fileWriteUnknown) }
        try storage.replace(path, with: JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) + Data([10]), permissions: 0o600)
    }
}

struct CodexProgressCommand: Sendable {
    let executable: String
    let arguments: [String]
    var value: [String: Any] { ["command": executable, "args": arguments] }

    static func registration(reporter: URL, home: URL) -> [String: Any] {
        let command = Self(executable: reporter.path, arguments: [CodexProgressReporter.argument, home.path])
        return command.value.merging(["env": ["PACER_CODEX_PROGRESS_OWNER": "codex-pacer-progress-v2"]]) { old, _ in old }
    }

    static func owns(_ existing: [String: Any], registration: [String: Any], legacy: Self?) -> Bool {
        if let legacy, NSDictionary(dictionary: existing).isEqual(to: legacy.value) { return true }
        guard let path = existing["command"] as? String, let expected = registration["command"] as? String,
              URL(fileURLWithPath: path).lastPathComponent.caseInsensitiveCompare(URL(fileURLWithPath: expected).lastPathComponent) == .orderedSame else { return false }
        var current = registration; current["command"] = path
        return NSDictionary(dictionary: current).isEqual(to: existing)
    }
}
