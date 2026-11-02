import Foundation
import CryptoKit

/// Installs Pacer's additive Claude hooks on an SSH host. The island runs it
/// automatically for reachable hosts that already have Claude (see
/// `ClaudeRemoteAutoSetup`); Settings can also retry it. It never creates a
/// Claude home in automatic mode and rewrites nothing that is already current.
public actor ClaudeRemoteSetup {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidTarget, unavailableResources, connectionFailed, invalidSettings
        case unsafePath, changedSettings, setupFailed, timedOut, cancelled, invalidResponse, missingHome

        public var errorDescription: String? {
            switch self {
            case .invalidTarget: return "Choose a valid configured SSH alias for Claude monitoring."
            case .unavailableResources: return "The Claude monitoring setup resources are unavailable."
            case .connectionFailed: return "Could not connect to the SSH host using its existing authentication and known host key."
            case .invalidSettings: return "Remote Claude settings must contain valid JSON; existing settings were preserved."
            case .unsafePath: return "Remote Claude monitoring cannot use symlinks or files owned by another user."
            case .changedSettings: return "Remote Claude settings changed during setup; retry after the other edit finishes."
            case .setupFailed: return "Could not configure remote Claude monitoring. Check the host's Python 3.6 or newer and configuration permissions."
            case .timedOut: return "Remote Claude monitoring setup timed out."
            case .cancelled: return "Remote Claude monitoring setup was cancelled."
            case .invalidResponse: return "The remote Claude monitoring setup response could not be read."
            case .missingHome: return "Claude is not installed for this SSH user; monitoring was not added."
            }
        }
    }

    private let executable: URL
    private let timeout: TimeInterval
    private let makeOperation: @Sendable (URL, [String]) -> any ClaudeRemoteSetupOperation
    private var operations: [UUID: any ClaudeRemoteSetupOperation] = [:]

    public init(executable: URL, timeout: TimeInterval = 15,
                makeOperation: @escaping @Sendable (URL, [String]) -> any ClaudeRemoteSetupOperation) {
        self.executable = executable
        self.timeout = timeout.isFinite ? min(15, max(0.05, timeout)) : 15
        self.makeOperation = makeOperation
    }

    /// `requireHome` is set for automatic setup so a host without Claude is skipped.
    @discardableResult public func install(target: RemoteActivityTarget, requireHome: Bool = false) async throws -> ClaudeHookInstaller.Status {
        let arguments = try Self.arguments(target: target, requireHome: requireHome)
        let identifier = UUID()
        let operation = makeOperation(executable, arguments)
        operations[identifier] = operation
        defer { operations.removeValue(forKey: identifier); operation.close() }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw Failure.cancelled }
            try operation.start()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                if Task.isCancelled { throw Failure.cancelled }
                if let failure = operation.failure { throw failure }
                if let result = try operation.result() { return try Self.status(data: result.data, exitStatus: result.exitStatus) }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    operation.abort(.timedOut)
                    throw Failure.timedOut
                }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { throw Failure.cancelled }
            }
        } onCancel: {
            operation.abort(.cancelled)
        }
    }

    /// Quit and a discarded Settings action close only this actor's subprocesses.
    public func shutdown() {
        for operation in operations.values { operation.abort(.cancelled) }
        operations.removeAll()
    }

    static func arguments(target: RemoteActivityTarget, requireHome: Bool = false) throws -> [String] {
        guard let arguments = target.sshArguments() else { throw Failure.invalidTarget }
        let (installer, hook) = try resources()
        // Remote collectors use the default Claude home. Never reuse a Codex
        // target's home field or put a local/remote private path into this command.
        var request: [String: Any] = ["home": "~/.claude", "hook": hook.base64EncodedString()]
        if requireHome { request["requireHome"] = true }
        let payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(installer.base64EncodedString())\").decode())' \(payload.base64EncodedString())"
        return arguments + [command]
    }

    /// Identifies the shipped installer and hook. A host configured with an
    /// older digest is brought current automatically after an update.
    public static func adapterDigest() throws -> String {
        let (installer, hook) = try resources()
        var bytes = installer; bytes.append(0); bytes.append(hook)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func resources() throws -> (installer: Data, hook: Data) {
        guard let installerURL = Bundle.module.url(forResource: "claude_remote_setup", withExtension: "py"),
              let hookURL = Bundle.module.url(forResource: "claude_hook", withExtension: "py"),
              let installer = try? Data(contentsOf: installerURL), !installer.isEmpty,
              let hook = try? Data(contentsOf: hookURL), !hook.isEmpty else { throw Failure.unavailableResources }
        return (installer, hook)
    }

    static func status(data: Data, exitStatus: Int32) throws -> ClaudeHookInstaller.Status {
        guard data.count <= 4096 else { throw Failure.invalidResponse }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw exitStatus == 0 ? Failure.invalidResponse : Failure.connectionFailed
        }
        if let error = value["error"] as? String {
            switch error {
            case "invalidSettings": throw Failure.invalidSettings
            case "unsafePath": throw Failure.unsafePath
            case "changedSettings": throw Failure.changedSettings
            case "missingHome": throw Failure.missingHome
            default: throw Failure.setupFailed
            }
        }
        guard exitStatus == 0 else { throw Failure.connectionFailed }
        let keys = ["hooksConfigured", "telemetryConfigured", "statusLineConfigured", "telemetryConflict"]
        let fields = try? JSONFieldView.document(data).fields(Set(keys))
        guard Set(value.keys) == Set(keys),
              let hooks = fields?["hooksConfigured"]?.boolean(), let telemetry = fields?["telemetryConfigured"]?.boolean(),
              let line = fields?["statusLineConfigured"]?.boolean(), let conflict = fields?["telemetryConflict"]?.boolean() else { throw Failure.invalidResponse }
        return ClaudeHookInstaller.Status(hooksConfigured: hooks, telemetryConfigured: telemetry, statusLineConfigured: line, telemetryConflict: conflict)
    }
}

public protocol ClaudeRemoteSetupOperation: Sendable {
    var failure: ClaudeRemoteSetup.Failure? { get }
    func start() throws
    func result() throws -> (data: Data, exitStatus: Int32)?
    func abort(_ failure: ClaudeRemoteSetup.Failure)
    func close()
}
