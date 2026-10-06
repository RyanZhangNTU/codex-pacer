import Foundation
import CryptoKit
import Darwin

public enum CodexClientError: Error, LocalizedError {
    case missingExecutable, disconnected, invalidResponse, accountMismatch, notLoggedIn
    case executableNotFound(String)
    case launchFailed(path: String, reason: String)
    case processExited(status: Int32?, detail: String)
    case timeout(method: String, seconds: TimeInterval)
    case invalidReply(method: String, reason: String)
    case server(method: String, code: Int?, message: String)
    case unsupportedAccount(String)
    public var errorDescription: String? {
        switch self {
        case .missingExecutable: return L10n.text("cli.missing")
        case .executableNotFound(let reason): return CodexDiagnosticText.sanitized(reason)
        case .launchFailed(let path, let reason):
            return L10n.text("cli.launch_failed", path, CodexDiagnosticText.sanitized(reason))
        case .disconnected: return L10n.text("cli.disconnected")
        case .processExited(let status, let detail):
            let code = status.map { L10n.text("cli.exit_code", String($0)) } ?? ""
            let reason = detail.isEmpty ? L10n.text("cli.no_stderr") : CodexDiagnosticText.sanitized(detail)
            let lower = reason.lowercased()
            let recovery = lower.contains("node") && (lower.contains("not found") || lower.contains("no such file"))
                ? L10n.text("cli.missing_node")
                : lower.contains("unrecognized") || lower.contains("unexpected argument") || lower.contains("unknown subcommand")
                    ? L10n.text("cli.unsupported_server")
                    : L10n.text("cli.test_recovery")
            return L10n.text("cli.process_exited", L10n.text(status == nil ? "cli.closed" : "cli.exited"), code, reason, recovery)
        case .timeout(let method, let seconds):
            return L10n.text("cli.timeout", CodexDiagnosticText.stage(method), seconds, method)
        case .invalidResponse: return L10n.text("cli.invalid_response")
        case .invalidReply(let method, let reason):
            return L10n.text("cli.invalid_reply", CodexDiagnosticText.stage(method), method, CodexDiagnosticText.sanitized(reason))
        case .accountMismatch:
            return L10n.text("cli.account_mismatch")
        case .notLoggedIn:
            return L10n.text("cli.not_signed_in")
        case .unsupportedAccount(let kind):
            return L10n.text("cli.unsupported_account", kind)
        case .server(let method, let code, let message):
            let number = code.map { L10n.text("cli.error_code", String($0)) } ?? ""
            let reason = CodexDiagnosticText.sanitized(message)
            let recovery: String
            if code == -32601 {
                recovery = L10n.text("cli.unsupported_method")
            } else if reason.lowercased().contains("unauthorized") || reason.contains("401") {
                recovery = L10n.text("cli.expired_auth")
            } else {
                recovery = L10n.text("cli.retry_recovery")
            }
            return L10n.text("cli.server_failed", CodexDiagnosticText.stage(method), method, number,
                reason.isEmpty ? L10n.text("cli.no_detail") : reason, recovery)
        }
    }
}

/// A dedicated read-only app-server connection. It never starts or resumes a turn.
public actor CodexClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var errorCollector: ProcessErrorCollector?
    private var pipeReader: PipeChunkReader?
    private var readTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var buffer = Data()
    private var nextID = 1
    private var generation = 0
    private var ready = false
    private var quotaTask: Task<QuotaSnapshot, Error>?
    private var verifiedAccountScope: String?
    private var authFingerprint: String?
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    private let executable: URL
    private let arguments: [String]
    private let home: URL
    private let requestTimeout: TimeInterval
    private let inheritedEnvironment: [String: String]

    public init(executable: URL, home: URL, arguments: [String] = ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"], timeout: TimeInterval = 12,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.arguments = arguments
        self.home = home
        self.requestTimeout = timeout
        self.inheritedEnvironment = environment
    }

    public static func findExecutable(customPath: String = "") -> URL? {
        CodexExecutableResolver.discover(customPath: customPath).selected?.url
    }

    public func readQuota() async throws -> QuotaSnapshot {
        if let quotaTask { return try await quotaTask.value }
        let task = Task { try await fetchQuota() }
        quotaTask = task
        defer { quotaTask = nil }
        return try await task.value
    }
    public func currentAccountScope() -> String? { verifiedAccountScope }
    public func shutdown() async {
        disconnect()
        // Allow the bounded child-termination fallback to run before application exit.
        try? await Task.sleep(nanoseconds: 650_000_000)
    }

    private func fetchQuota() async throws -> QuotaSnapshot {
        do {
            verifiedAccountScope = nil
            let fingerprint = Self.authenticationFingerprint(home: home)
            if fingerprint != authFingerprint { disconnect(); authFingerprint = fingerprint }
            if !ready {
                try start()
                _ = try await request("initialize", params: ["clientInfo": ["name": "codex-pacer-island", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"], "capabilities": ["experimentalApi": true]])
                try write(["method": "initialized", "params": [:]])
                ready = true
            }
            let account = try await request("account/read", params: ["refreshToken": false])
            guard let accountResponse = try JSONSerialization.jsonObject(with: account) as? [String: Any] else {
                throw CodexClientError.invalidReply(method: "account/read", reason: L10n.text("cli.account_not_object"))
            }
            if accountResponse["account"] is NSNull {
                if accountResponse["requiresOpenaiAuth"] as? Bool == false {
                    throw CodexClientError.unsupportedAccount(L10n.text("cli.no_openai_auth"))
                }
                throw CodexClientError.notLoggedIn
            }
            if let identity = accountResponse["account"] as? [String: Any], let kind = identity["type"] as? String {
                switch kind.lowercased() {
                case "apikey": throw CodexClientError.unsupportedAccount(L10n.text("cli.api_key_auth"))
                case "amazonbedrock": throw CodexClientError.unsupportedAccount(L10n.text("cli.bedrock_auth"))
                default: break
                }
            }
            var verifiedID: String?
            if let routing = accountResponse["workspaceRouting"] as? [String: Any],
               let accountID = routing["chatgptAccountId"] as? String, !accountID.isEmpty {
                verifiedID = accountID
                let plan = (accountResponse["account"] as? [String: Any])?["planType"] as? String ?? ""
                let key = accountID + "|" + (routing["backendOrigin"] as? String ?? "") + "|" + plan
                verifiedAccountScope = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let data = try await request("account/rateLimits/read", params: ["excludeResetCreditDetails": false])
            if let usage = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let responseID = usage["accountId"] as? String, let verifiedID, responseID != verifiedID {
                verifiedAccountScope = nil
                throw CodexClientError.accountMismatch
            }
            let decoded: QuotaSnapshot
            do { decoded = try QuotaSnapshot.decode(data) }
            catch {
                throw CodexClientError.invalidReply(method: "account/rateLimits/read",
                    reason: CodexDiagnosticText.description(of: error))
            }
            var snapshot = decoded
            snapshot.accountScope = verifiedAccountScope
            return snapshot
        } catch {
            disconnect()
            throw error
        }
    }
    private static func authenticationFingerprint(home: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path) else { return nil }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(attrs[.systemFileNumber] ?? "")|\(modified)|\(attrs[.size] ?? "")"
    }

    public func disconnect() { disconnect(reason: .disconnected) }

    private func disconnect(reason: CodexClientError) {
        generation += 1
        ready = false
        pipeReader?.stop()
        pipeReader = nil
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        errorCollector?.stop()
        errorCollector = nil
        streamContinuation?.finish()
        streamContinuation = nil
        readTask?.cancel()
        readTask = nil
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        input = nil
        output = nil
        errorOutput = nil
        if let child = process {
            child.terminationHandler = nil
            if child.isRunning {
                child.terminate()
                // Reap only our own child; a stuck process must not outlive the app.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
        buffer.removeAll()
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: reason)
        }
    }

    private func start() throws {
        guard process == nil else { return }
        guard CodexExecutableResolver.isExecutableFile(executable) else {
            throw CodexClientError.executableNotFound(L10n.text("cli.missing_at_start", executable.path))
        }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        var environment = CodexExecutableResolver.launchEnvironment(for: executable, inherited: inheritedEnvironment)
        environment["CODEX_HOME"] = home.path
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let collector = ProcessErrorCollector(handle: stderr.fileHandleForReading)
        errorOutput = stderr.fileHandleForReading
        errorCollector = collector
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if !collector.drain() { handle.readabilityHandler = nil }
        }
        generation += 1
        let currentGeneration = generation
        let reader = PipeChunkReader(descriptor: stdout.fileHandleForReading.fileDescriptor)
        pipeReader = reader
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        streamContinuation = channel.continuation
        readTask = Task { [weak self] in
            for await data in channel.stream {
                guard !Task.isCancelled else { return }
                await self?.receive(data, generation: currentGeneration)
            }
            await self?.closed(generation: currentGeneration)
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] _ in
            // One POSIX read returns the available pipe bytes. Foundation's
            // read(upToCount:) can wait for the requested size on a live pipe.
            guard let data = reader.read() else { return }
            if !data.isEmpty {
                if case .dropped = channel.continuation.yield(data) {
                    channel.continuation.finish()
                    Task { await self?.closed(generation: currentGeneration) }
                }
            } else {
                channel.continuation.finish()
            }
        }
        // EOF drains the ordered stream before closing pending requests.
        do { try child.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            child.terminationHandler = nil
            throw CodexClientError.launchFailed(path: executable.path, reason: CodexDiagnosticText.description(of: error))
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private func request(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self, requestTimeout] in
                do { try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000)) }
                catch { return }
                await self?.expired(id)
            }
            pending[id] = Pending(method: method, continuation: continuation, timeout: timeout)
            do { try write(["id": id, "method": method, "params": params]) }
            catch {
                let entry = pending.removeValue(forKey: id)
                entry?.timeout.cancel()
                entry?.continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard let input else { throw CodexClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        guard !data.isEmpty else { disconnect(); return }
        buffer.append(data)
        // Account responses are small. Bound malformed/no-newline input.
        guard buffer.count <= 4 * 1024 * 1024 else {
            disconnect(reason: .invalidReply(method: pending.values.first?.method ?? "app-server", reason: L10n.text("cli.too_large")))
            return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                disconnect(reason: .invalidReply(method: pending.values.first?.method ?? "app-server",
                    reason: L10n.text("cli.not_json")))
                return
            }
            guard let id = message["id"] as? Int,
                  let entry = pending.removeValue(forKey: id) else { continue }
            entry.timeout.cancel()
            if let failure = message["error"] {
                let fields = failure as? [String: Any] ?? [:]
                let reason = fields["message"] as? String ?? (failure as? String) ?? L10n.text("cli.error_no_message")
                entry.continuation.resume(throwing: CodexClientError.server(method: entry.method,
                    code: fields["code"] as? Int, message: CodexDiagnosticText.sanitized(reason)))
            } else if let result = message["result"], JSONSerialization.isValidJSONObject(result),
                      let encoded = try? JSONSerialization.data(withJSONObject: result) {
                entry.continuation.resume(returning: encoded)
            } else {
                entry.continuation.resume(throwing: CodexClientError.invalidReply(method: entry.method,
                    reason: L10n.text("cli.missing_result")))
            }
        }
    }

    private func expired(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: CodexClientError.timeout(method: entry.method, seconds: requestTimeout))
        disconnect()
    }
    private func closed(generation: Int) async {
        guard generation == self.generation else { return }
        // Pipe EOF can arrive just before Foundation records the exit status.
        for _ in 0..<5 where process?.isRunning == true {
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard generation == self.generation else { return }
        }
        let status = process.flatMap { $0.isRunning ? nil : $0.terminationStatus }
        let detail = errorCollector?.message() ?? ""
        disconnect(reason: .processExited(status: status, detail: detail))
    }
}

/// stderr is collected synchronously in a bounded buffer, so EOF cannot outrun its diagnostics.
private final class ProcessErrorCollector: @unchecked Sendable {
    private let reader: PipeChunkReader
    private let lock = NSLock()
    private var tail = Data()
    init(handle: FileHandle) { reader = PipeChunkReader(descriptor: handle.fileDescriptor) }
    @discardableResult func drain() -> Bool {
        for _ in 0..<4 {
            guard let data = reader.read() else { return true }
            guard !data.isEmpty else { return false }
            lock.lock()
            tail.append(data)
            if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            lock.unlock()
        }
        return true
    }
    func message() -> String {
        drain()
        lock.lock(); defer { lock.unlock() }
        let sanitized = CodexDiagnosticText.sanitized(String(decoding: tail, as: UTF8.self), limit: 32768)
        return sanitized.count > 1200 ? L10n.text("diagnostic.older_omitted", String(sanitized.suffix(1200))) : sanitized
    }
    func stop() { reader.stop() }
}

/// Synchronizes cancellation with callbacks, so an old callback cannot consume
/// bytes from a newly opened pipe that reused the same descriptor number.
final class PipeChunkReader: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var active = true
    init(descriptor: Int32) {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }
    func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(descriptor, &bytes, 65536)
        if count > 0 { return Data(bytes.prefix(count)) }
        return count == 0 ? Data() : nil
    }
    func stop() { lock.lock(); active = false; lock.unlock() }

    /// Pause the OS reader after one chunk. The actor rearms it after consuming
    /// that chunk, so a large fallback cannot overrun the bounded AsyncStream.
    func pausingHandler(_ continuation: AsyncStream<Data>.Continuation) -> @Sendable (FileHandle) -> Void {
        { [self] handle in
            guard let data = read() else { return }
            handle.readabilityHandler = nil
            if data.isEmpty { continuation.finish() }
            else if case .dropped = continuation.yield(data) { continuation.finish() }
        }
    }
}
