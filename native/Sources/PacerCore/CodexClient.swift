import Foundation

public enum CodexClientError: Error, LocalizedError {
    case missingExecutable, disconnected, timeout, invalidResponse, server(String)
    public var errorDescription: String? {
        switch self {
        case .missingExecutable: return "找不到 Codex CLI。请安装 Codex，或在设置中选择可执行文件。"
        case .disconnected: return "Codex 连接已断开，请重新刷新。"
        case .timeout: return "额度查询超时，请稍后刷新。"
        case .invalidResponse: return "Codex 返回的数据无法识别，请检查 CLI 版本。"
        case .server: return "额度暂不可用。请确认当前 Codex 账户已登录，再刷新。"
        }
    }
}

/// A dedicated read-only app-server connection. It never starts or resumes a turn.
public actor CodexClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var generation = 0
    private var ready = false
    private var quotaTask: Task<QuotaSnapshot, Error>?
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    private let executable: URL
    private let arguments: [String]
    private let home: URL
    private let requestTimeout: TimeInterval

    public init(executable: URL, home: URL, arguments: [String] = ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"], timeout: TimeInterval = 12) {
        self.executable = executable
        self.arguments = arguments
        self.home = home
        self.requestTimeout = timeout
    }

    public static func findExecutable(customPath: String = "") -> URL? {
        let manager = FileManager.default
        let path = (customPath as NSString).expandingTildeInPath
        if !path.isEmpty {
            return manager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first { manager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func readQuota() async throws -> QuotaSnapshot {
        if let quotaTask { return try await quotaTask.value }
        let task = Task { try await fetchQuota() }
        quotaTask = task
        defer { quotaTask = nil }
        return try await task.value
    }

    private func fetchQuota() async throws -> QuotaSnapshot {
        do {
            if !ready {
                try start()
                _ = try await request("initialize", params: ["clientInfo": ["name": "codex-pacer-island", "version": "2.0.0-preview.1"]])
                try write(["method": "initialized", "params": [:]])
                ready = true
            }
            let data = try await request("account/rateLimits/read")
            return try QuotaSnapshot.decode(data)
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        generation += 1
        ready = false
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
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
            request.continuation.resume(throwing: CodexClientError.disconnected)
        }
    }

    private func start() throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodexClientError.missingExecutable }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        generation += 1
        let currentGeneration = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data, generation: currentGeneration) }
        }
        child.terminationHandler = { [weak self] _ in
            Task { await self?.closed(generation: currentGeneration) }
        }
        do { try child.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            child.terminationHandler = nil
            throw CodexClientError.missingExecutable
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
            pending[id] = Pending(continuation: continuation, timeout: timeout)
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
        guard buffer.count <= 4 * 1024 * 1024 else { disconnect(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? Int,
                  let entry = pending.removeValue(forKey: id) else { continue }
            entry.timeout.cancel()
            if message["error"] != nil {
                // Avoid forwarding server messages that may contain private account details.
                entry.continuation.resume(throwing: CodexClientError.server("request_failed"))
            } else if let result = message["result"], JSONSerialization.isValidJSONObject(result),
                      let encoded = try? JSONSerialization.data(withJSONObject: result) {
                entry.continuation.resume(returning: encoded)
            } else {
                entry.continuation.resume(throwing: CodexClientError.invalidResponse)
            }
        }
    }

    private func expired(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: CodexClientError.timeout)
        disconnect()
    }
    private func closed(generation: Int) {
        if generation == self.generation { disconnect() }
    }
}
