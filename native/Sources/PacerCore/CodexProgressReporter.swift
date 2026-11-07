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

/// Orders the enabled flag between a switch that was turned off and a setup
/// still waiting for Codex. Turning off revokes the flag at once, so connected
/// reporters stop even if the host quits before the registration is removed,
/// and an older setup can no longer write the flag back.
public final class CodexProgressSwitchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    public init() {}

    /// Starts a setup request. Earlier requests can no longer enable reporting.
    public func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return current
    }

    /// Starts a request and removes the enabled flag from `homes` before any
    /// setup still in flight can finish.
    public func revoke(_ homes: [URL], storage: any ClaudeHookStorage) -> Int {
        lock.lock(); defer { lock.unlock() }
        current += 1
        for home in homes { CodexProgressSetup.removeFlag(home: home, storage: storage) }
        return current
    }

    /// Starts the request for a switch change. Reporting stops at once in a
    /// profile the switch leaves: turned off, or replaced by another home.
    public func change(home: URL, wanted: Bool, previous: URL?, storage: any ClaudeHookStorage) -> Int {
        var homes = wanted ? [] : [home]
        if let previous, previous != home { homes.append(previous) }
        return homes.isEmpty ? begin() : revoke(homes, storage: storage)
    }

    /// Runs `write` only while `request` is the latest one.
    func enable(_ request: Int, _ write: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard request == current else { return false }
        try write()
        return true
    }
}

public enum CodexProgressSetup {
    public struct Target: Equatable, Sendable {
        public let home: URL
        public let executable: String
        public let enabled: Bool
        public init(home: URL, executable: String, enabled: Bool) { self.home = home; self.executable = executable; self.enabled = enabled }
    }
    static let on = Data("on\n".utf8)
    static func folder(_ home: URL) -> URL { home.appendingPathComponent("pacer/codex-progress", isDirectory: true) }
    private static func native(_ home: URL) -> URL { folder(home).appendingPathComponent("native", isDirectory: true) }
    static func flag(_ home: URL) -> URL { native(home).appendingPathComponent("enabled") }

    public static func wasConfigured(in home: URL) -> Bool {
        FileManager.default.fileExists(atPath: native(home).path)
    }

    /// Removes this profile's enabled flag when it is Pacer's, with the same
    /// path checks as setup. Reporters already connected stop accepting estimates.
    static func removeFlag(home: URL, storage: any ClaudeHookStorage) {
        let flag = flag(home)
        do {
            for path in [home, home.appendingPathComponent("pacer"), folder(home), native(home), flag] { try storage.validate(path) }
            if storage.exists(flag), try storage.read(flag) == on { try storage.remove(flag) }
        } catch {}
    }

    /// Same owned-file checks as the local Claude setup. The profile must
    /// already exist, and a failed setup can never enable a cached server.
    /// With a `gate`, the flag is written only while `request` is its latest.
    public static func apply(home: URL, reporter: CodexProgressCommand?, storage: any ClaudeHookStorage, checkOnly: Bool = false,
                             gate: CodexProgressSwitchGate? = nil, request: Int = 0,
                             owns: @Sendable (CodexProgressCommand) -> Bool,
                             client: @Sendable () -> CodexClient?) async -> CodexProgressSetupStatus? {
        do {
            let enabled = reporter != nil
            let folder = folder(home), directory = native(home), flag = flag(home)
            let config = home.appendingPathComponent("config.toml")
            for path in [home, home.appendingPathComponent("pacer"), folder, directory, flag] { try storage.validate(path) }
            guard storage.isDirectory(home) else { return enabled ? .failed : nil }
            if storage.exists(flag), try storage.read(flag) != on { return .failed }
            guard enabled || storage.exists(directory) else { return nil }
            if !checkOnly, !enabled, storage.exists(flag) { try storage.remove(flag) }
            try storage.validate(config)
            guard enabled || storage.exists(config) else { return nil }
            guard let client = client() else { return .missingCLI }
            // Record that this profile may contain a registration before the
            // RPC, so a later disable can clean up after an interrupted setup.
            if !checkOnly, enabled, !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
            let status: CodexProgressSetupStatus
            do {
                status = try await client.setProgressReporter(reporter, checkOnly: checkOnly, owns: owns)
            } catch {
                await client.shutdown()
                throw error
            }
            await client.shutdown()
            if status != .ready {
                if !checkOnly, storage.exists(flag), try storage.read(flag) == on { try storage.remove(flag) }
                return status
            }
            if !checkOnly, enabled, !storage.exists(flag) {
                let write = { try storage.replace(flag, with: on, permissions: 0o600) }
                // The switch was turned off meanwhile and revoked reporting: keep it off.
                if let gate { guard try gate.enable(request, write) else { return nil } } else { try write() }
            }
            return enabled ? .ready : nil
        } catch { return .failed }
    }
}

public struct CodexProgressCommand: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    private static let owner = ["PACER_CODEX_PROGRESS_OWNER": "codex-pacer-progress-v2"]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable.path; self.arguments = arguments
    }

    public static func native(executable: URL, home: URL) -> Self {
        .init(executable: executable, arguments: [CodexProgressReporter.argument, home.path])
    }

    public func isNative(named name: String, home: URL) -> Bool {
        URL(fileURLWithPath: executable).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame &&
            arguments == [CodexProgressReporter.argument, home.path]
    }

    var value: [String: Any] { ["command": executable, "args": arguments, "env": Self.owner] }

    init?(ownedEntry: Any) {
        guard let entry = ownedEntry as? [String: Any], entry.count == 3, entry["env"] as? [String: String] == Self.owner,
              let command = entry["command"] as? String, !command.isEmpty, let arguments = entry["args"] as? [String] else { return nil }
        executable = command; self.arguments = arguments
    }
}
