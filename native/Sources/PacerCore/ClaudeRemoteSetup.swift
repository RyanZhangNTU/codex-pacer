import Foundation
import CoreFoundation
import Darwin

/// Settings calls this actor only after an explicit setup click. Discovery and
/// monitoring never install configuration on a remote host.
public actor ClaudeRemoteSetup {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidTarget, unavailableResources, connectionFailed, invalidSettings
        case unsafePath, changedSettings, setupFailed, timedOut, cancelled, invalidResponse

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
            }
        }
    }

    private let executable: URL
    private let timeout: TimeInterval
    private var operations: [UUID: ClaudeRemoteSetupOperation] = [:]

    public init() {
        executable = URL(fileURLWithPath: "/usr/bin/ssh")
        timeout = 15
    }

    // The test executable receives the same SSH arguments, without contacting a
    // host or changing its home directory.
    init(executable: URL, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = min(15, max(0.05, timeout))
    }

    @discardableResult public func install(target: RemoteActivityTarget) async throws -> ClaudeHookInstaller.Status {
        let arguments = try Self.arguments(target: target)
        let identifier = UUID()
        let operation = ClaudeRemoteSetupOperation(executable: executable, arguments: arguments)
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

    static func arguments(target: RemoteActivityTarget) throws -> [String] {
        guard target.alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil else { throw Failure.invalidTarget }
        let (installer, hook) = try resources()
        // Remote collectors use the default Claude home. Never reuse a Codex
        // target's home field or put a local/remote private path into this command.
        let payload = try JSONSerialization.data(withJSONObject: ["home": "~/.claude", "hook": hook.base64EncodedString()], options: [.sortedKeys])
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"\(installer.base64EncodedString())\").decode())' \(payload.base64EncodedString())"
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", target.alias, command]
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
            default: throw Failure.setupFailed
            }
        }
        guard exitStatus == 0 else { throw Failure.connectionFailed }
        let keys = ["hooksConfigured", "telemetryConfigured", "statusLineConfigured", "telemetryConflict"]
        guard Set(value.keys) == Set(keys), keys.allSatisfy({ key in
            guard let number = value[key] as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }),
              let hooks = value["hooksConfigured"] as? Bool, let telemetry = value["telemetryConfigured"] as? Bool,
              let line = value["statusLineConfigured"] as? Bool, let conflict = value["telemetryConflict"] as? Bool else { throw Failure.invalidResponse }
        return ClaudeHookInstaller.Status(hooksConfigured: hooks, telemetryConfigured: telemetry, statusLineConfigured: line, telemetryConflict: conflict)
    }
}

/// Nonblocking output keeps the actor responsive to cancellation, shutdown and
/// the fixed timeout even when an SSH peer never closes its output pipe.
private final class ClaudeRemoteSetupOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var bytes = Data()
    private var eof = false
    private var started = false
    private var closed = false
    private var stopped: ClaudeRemoteSetup.Failure?
    private var stopping = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    var failure: ClaudeRemoteSetup.Failure? {
        lock.lock(); defer { lock.unlock() }; return stopped
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if let stopped { throw stopped }
        do { try process.run() }
        catch { throw ClaudeRemoteSetup.Failure.connectionFailed }
        started = true
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            stopLocked(.setupFailed); throw ClaudeRemoteSetup.Failure.setupFailed
        }
    }

    func result() throws -> (data: Data, exitStatus: Int32)? {
        lock.lock(); defer { lock.unlock() }
        if let stopped { throw stopped }
        guard started, !closed else { throw ClaudeRemoteSetup.Failure.cancelled }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !eof {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress!, $0.count)
            }
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                if bytes.count > 4096 { stopLocked(.invalidResponse); throw ClaudeRemoteSetup.Failure.invalidResponse }
            } else if count == 0 { eof = true }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { stopLocked(.invalidResponse); throw ClaudeRemoteSetup.Failure.invalidResponse }
        }
        guard !process.isRunning, eof else { return nil }
        return (bytes, process.terminationStatus)
    }

    func abort(_ failure: ClaudeRemoteSetup.Failure) {
        lock.lock(); defer { lock.unlock() }; stopLocked(failure)
    }

    private func stopLocked(_ failure: ClaudeRemoteSetup.Failure) {
        if stopped == nil { stopped = failure }
        if started, process.isRunning, !stopping {
            stopping = true
            process.terminate()
            // A peer ignoring EOF/SIGTERM cannot leave Pacer's SSH process
            // alive. This targets the exact Process created by this operation.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [self] in
                lock.lock(); defer { lock.unlock() }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        closeLocked()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if started, process.isRunning { stopLocked(.cancelled) }
        else { closeLocked() }
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    }
}
