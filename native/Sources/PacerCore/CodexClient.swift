import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// A dedicated app-server connection. It never starts or resumes a turn.
/// Only local progress setup uses the versioned config write below.
public actor CodexClient {
    private var process: (any ChildProcessConnection)?
    private var closingProcesses: [any ChildProcessConnection] = []
    private var closingReaders: [ShutdownSignal] = []
    private var readerFinished: ShutdownSignal?
    private nonisolated let shutdownRequested = ShutdownSignal()
    private nonisolated let ownedChildren = OwnedChildProcesses()
    private let processes: any ChildProcessLauncher
    private let executables: any ExecutablePlatform
    private let files: any PlatformFileSystem
    private let clientVersion: String
    private var readTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var buffer = Data()
    private var nextID = 1
    private var generation = 0
    private var ready = false
    private var legacyRateLimitGeneration: Int?
    private var quotaTask: Task<QuotaSnapshot, Error>?
    private var verifiedAccountScope: String?
    /// The last verified account and the auth file it was verified under.
    private var lastVerified: (scope: String, fingerprint: String)?
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

    public init(executable: URL, home: URL, arguments: [String] = ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"], timeout: TimeInterval = ProviderQuotaRefreshPolicy.replyTimeout,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                processes: any ChildProcessLauncher, executables: any ExecutablePlatform,
                files: any PlatformFileSystem, clientVersion: String = "development") {
        self.processes = processes; self.executables = executables; self.files = files; self.clientVersion = clientVersion
        self.executable = executable
        self.arguments = arguments
        self.home = home
        self.requestTimeout = timeout
        self.inheritedEnvironment = environment
    }

    public func readQuota() async throws -> QuotaSnapshot {
        guard !shutdownRequested.isFinished else { throw CodexClientError.disconnected }
        if let quotaTask { return try await quotaTask.value }
        let task = Task { try await fetchQuota() }
        quotaTask = task
        defer { quotaTask = nil }
        return try await task.value
    }
    public func currentAccountScope() -> String? { verifiedAccountScope }
    public func usesLegacyRateLimitRequest() -> Bool { legacyRateLimitGeneration == generation }
    public nonisolated func shutdown(deadline: ShutdownDeadline = ShutdownDeadline()) async {
        shutdownRequested.finish()
        let completed = await deadline.perform([{ await self.finishShutdown(deadline: deadline) }])
        if !completed { ownedChildren.terminate() }
    }
    private func finishShutdown(deadline: ShutdownDeadline) async {
        quotaTask?.cancel()
        disconnect()
        let children = closingProcesses
        let readers = closingReaders
        closingProcesses.removeAll(); closingReaders.removeAll()
        await deadline.finish(readers: readers, children: children)
    }

    private func fetchQuota() async throws -> QuotaSnapshot {
        do {
            verifiedAccountScope = nil
            try await prepareReadConnection()
            let account = try await request("account/read", params: ["refreshToken": false])
            guard let accountResponse = try JSONSerialization.jsonObject(with: account) as? [String: Any] else {
                throw CodexClientError.invalidReply(method: "account/read", reason: L10n.text("cli.account_not_object"))
            }
            lastVerified = nil
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
                let scope = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                verifiedAccountScope = scope
                lastVerified = authFingerprint.map { (scope, $0) }
            }
            let data: Data
            let connection = generation
            let legacy = legacyRateLimitGeneration == connection
            do {
                data = try await request("account/rateLimits/read",
                    params: legacy ? nil : ["excludeResetCreditDetails": false])
            } catch CodexClientError.server(_, code: -32600, let message)
                where !legacy && Self.rejectsParamObject(message) {
                // Legacy CLIs type this method's params as unit. Retry that schema mismatch
                // once with params omitted and keep that shape for this connection only:
                // a disconnect during the retry advances the generation, so it cannot leak.
                data = try await request("account/rateLimits/read", params: nil)
                legacyRateLimitGeneration = connection
            }
            if let usage = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let responseID = usage["accountId"] as? String, let verifiedID, responseID != verifiedID {
                verifiedAccountScope = nil; lastVerified = nil
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
            // A slow reply, even to account/read on a fresh connection, keeps the account
            // verified before it while the auth file is unchanged, so callers can keep
            // that account's last reading. Any other failure stays unverified.
            if case CodexClientError.timeout = error, verifiedAccountScope == nil, let lastVerified,
               lastVerified.fingerprint == Self.authenticationFingerprint(home: home, files: files) {
                verifiedAccountScope = lastVerified.scope
            }
            disconnect()
            throw error
        }
    }
    private func prepareReadConnection() async throws {
        guard !shutdownRequested.isFinished, !Task.isCancelled else { throw CodexClientError.disconnected }
        let fingerprint = Self.authenticationFingerprint(home: home, files: files)
        if fingerprint != authFingerprint { disconnect(); authFingerprint = fingerprint }
        if !ready {
            try start()
            _ = try await request("initialize", params: ["clientInfo": ["name": "codex-pacer-island", "version": clientVersion], "capabilities": ["experimentalApi": true]])
            try write(["method": "initialized", "params": [:]])
            ready = true
        }
    }

    func setProgressReporter(_ wanted: CodexProgressCommand?, checkOnly: Bool,
                             owns: @Sendable (CodexProgressCommand) -> Bool) async throws -> CodexProgressSetupStatus {
        try await prepareReadConnection()
        let data = try await request("config/read", params: ["includeLayers": true])
        let path = home.appendingPathComponent("config.toml").standardizedFileURL
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = reply["layers"] as? [[String: Any]], let user = layers.firstIndex(where: { layer in
                  guard let name = layer["name"] as? [String: Any], name["type"] as? String == "user", let file = name["file"] as? String else { return false }
                  return URL(fileURLWithPath: file).standardizedFileURL == path
              }), let version = layers[user]["version"] as? String, !version.isEmpty,
              let config = layers[user]["config"] as? [String: Any] else { return .failed }
        let name = CodexProgressEvidence.server
        if wanted != nil, layers.indices.contains(where: { index in
            let layer = layers[index]
            guard index != user, !(layer["disabledReason"] is String),
                  let other = layer["config"] as? [String: Any] else { return false }
            return (other["mcp_servers"] as? [String: Any])?[name] != nil
        }) { return .conflict }
        if let value = (config["mcp_servers"] as? [String: Any])?[name] {
            guard let existing = CodexProgressCommand(ownedEntry: value), owns(existing) else { return wanted == nil ? .ready : .conflict }
            // An entry Pacer wrote before the current settings is rewritten in place.
            if wanted?.isRegistered(by: value) == true { return .ready }
        } else if wanted == nil { return .ready }
        guard !checkOnly else { return .ready }
        try Task.checkCancellation()
        let edit: [String: Any] = ["keyPath": "mcp_servers." + name, "value": wanted.map { $0.value as Any } ?? NSNull(), "mergeStrategy": "replace"]
        _ = try await request("config/batchWrite", params: ["edits": [edit], "filePath": path.path, "expectedVersion": version])
        return .ready
    }

    /// Configure only the marketplace that points at Pacer's owned source.
    package func setDurableProgressPlugin(market: String, plugin: String, source: URL,
                                          enabled: Bool, cachedManifestMatches: Bool, checkOnly: Bool = false,
                                          pathsMatch: ((String, URL) -> Bool)? = nil) async throws -> Bool {
        try await prepareReadConnection()
        let id = plugin + "@" + market
        let manifest = source.appendingPathComponent(".agents/plugins/marketplace.json")
        let configPath = home.appendingPathComponent("config.toml")
        func matches(_ actual: String?, _ expected: URL) -> Bool {
            guard let actual else { return false }
            return pathsMatch?(actual, expected) ?? Self.samePath(actual, expected)
        }
        let bytes = try await request("config/read", params: ["includeLayers": true])
        let fields = try JSONFieldView.document(bytes).fields(["layers"])
        guard let layers = fields["layers"], layers.isArray else { throw CodexClientError.invalidResponse }
        var foundUser = false, owned = false, configured = false
        for layer in try layers.elements(maximumCount: 32) {
            let fields = try layer.fields(["name", "config", "disabledReason"])
            if fields["disabledReason"]?.string() != nil { continue }
            let name = try fields["name"]?.fields(["type", "file"])
            let config = try fields["config"]?.fields(["marketplaces", "plugins"])
            let marketEntry = try config?["marketplaces"]?.fields([market])[market]
            let pluginEntry = try config?["plugins"]?.fields([id])[id]
            let user = name?["type"]?.string() == "user" && matches(name?["file"]?.string(limit: 4096), configPath)
            if !user {
                guard marketEntry == nil, pluginEntry == nil else { throw CodexClientError.invalidResponse }
                continue
            }
            foundUser = true
            if let marketEntry {
                let entry = try marketEntry.fields(["source_type", "source"])
                guard entry["source_type"]?.string() == "local",
                      matches(entry["source"]?.string(limit: 4096), source) else { throw CodexClientError.invalidResponse }
                owned = true
            }
            configured = pluginEntry != nil
        }
        guard foundUser, !configured || owned else { throw CodexClientError.invalidResponse }
        if checkOnly { return false }
        if !enabled {
            guard owned else { return false }
            if configured { _ = try await request("plugin/uninstall", params: ["pluginId": id]) }
            _ = try await request("marketplace/remove", params: ["marketplaceName": market])
            return true
        }
        if !owned {
            let added = try await request("marketplace/add", params: ["source": source.path])
            let reply = try JSONFieldView.document(added).fields(["marketplaceName", "installedRoot"])
            guard reply["marketplaceName"]?.string() == market,
                  matches(reply["installedRoot"]?.string(limit: 4096), source) else { throw CodexClientError.invalidResponse }
        }
        if configured {
            if cachedManifestMatches, try await durablePluginIsEnabled(id: id, market: market, manifest: manifest, pathsMatch: matches) { return false }
            _ = try await request("plugin/uninstall", params: ["pluginId": id])
        }
        _ = try await request("plugin/install", params: ["pluginName": plugin, "marketplacePath": manifest.path])
        guard try await durablePluginIsEnabled(id: id, market: market, manifest: manifest, pathsMatch: matches) else { throw CodexClientError.invalidResponse }
        return true
    }

    private static func samePath(_ actual: String?, _ expected: URL) -> Bool {
        guard let actual, actual.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: actual).standardizedFileURL.resolvingSymlinksInPath().path ==
            expected.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func durablePluginIsEnabled(id: String, market: String, manifest: URL, pathsMatch: (String?, URL) -> Bool) async throws -> Bool {
        let bytes = try await request("plugin/installed", params: [:])
        let fields = try JSONFieldView.document(bytes).fields(["marketplaces"])
        guard let values = fields["marketplaces"], values.isArray else { throw CodexClientError.invalidResponse }
        for value in try values.elements(maximumCount: 128) {
            let row = try value.fields(["name", "path", "plugins"])
            guard row["name"]?.string() == market, pathsMatch(row["path"]?.string(limit: 4096), manifest),
                  let plugins = row["plugins"], plugins.isArray else { continue }
            for value in try plugins.elements(maximumCount: 512) {
                let plugin = try value.fields(["id", "installed", "enabled"])
                if plugin["id"]?.string() == id { return plugin["installed"]?.boolean() == true && plugin["enabled"]?.boolean() == true }
            }
        }
        return false
    }
    /// Short-lived authorization for the paired-device metadata GET only.
    /// No authentication material is cached by the catalog or exposed to UI.
    func remoteControlCatalogAuthorization() async throws -> RemoteControlCatalogAuthorization {
        do {
            try await prepareReadConnection()
            let account = try await request("account/read", params: ["refreshToken": false])
            let auth = try await request("getAuthStatus", params: ["includeToken": true, "refreshToken": false])
            return try RemoteControlCatalogAuthorization(account: account, auth: auth)
        } catch { disconnect(); throw error }
    }

    /// Reuse the Desktop profile's current login for the first-party Durable
    /// catalog. The bearer travels only in the TLS WebSocket handshake.
    package func durableCatalogCredentials() async throws -> (request: URLRequest, scope: String) {
        let auth = try await remoteControlCatalogAuthorization()
        guard auth.backendOrigin.host == "chatgpt.com", !auth.isFedRAMP else { throw CodexClientError.invalidResponse }
        var request = URLRequest(url: URL(string: "wss://codex-cloud-backend.chatgpt.com/")!, timeoutInterval: 8)
        request.setValue("codex-app-server, codex-client.desktop, openai-bearer." + auth.token,
                         forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        let scope = CompletionDismissalStore.digest(["durable-account-v1", auth.accountID, auth.accountUserIDs[0]])
        return (request, scope)
    }
    package static func authenticationFingerprint(home: URL, files: any PlatformFileSystem) -> String? {
        guard let metadata = files.metadata(home.appendingPathComponent("auth.json")) else { return nil }
        return "\(metadata.identity)|\(metadata.modified.timeIntervalSince1970)|\(metadata.size)"
    }
    /// Serde's unit-params mismatch, not its distinct unit variant/struct errors.
    private static func rejectsParamObject(_ message: String) -> Bool {
        message.range(of: #"invalid type: map, expected unit(?! (?:variant|struct))"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    public func disconnect() { disconnect(reason: .disconnected) }

    private func disconnect(reason: CodexClientError) {
        generation += 1
        ready = false
        streamContinuation?.finish()
        streamContinuation = nil
        readTask?.cancel()
        readTask = nil
        closingReaders.removeAll { $0.isFinished }
        if let readerFinished { closingReaders.append(readerFinished); self.readerFinished = nil }
        closingProcesses.removeAll { $0.exited.isFinished && $0.ioClosed.isFinished }
        if let child = process {
            child.close()
            closingProcesses.append(child)
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
        guard executables.isExecutableFile(executable) else {
            throw CodexClientError.executableNotFound(L10n.text("cli.missing_at_start", executable.path))
        }
        var environment = executables.launchEnvironment(for: executable, inherited: inheritedEnvironment,
            userHome: FileManager.default.homeDirectoryForCurrentUser)
        environment["CODEX_HOME"] = home.path
        generation += 1
        let currentGeneration = generation
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let finished = ShutdownSignal()
        let overflow = ShutdownSignal()
        readerFinished = finished
        streamContinuation = channel.continuation
        readTask = Task { [weak self] in
            defer { finished.finish() }
            for await data in channel.stream {
                guard !Task.isCancelled else { return }
                if overflow.isFinished {
                    await self?.inputOverflow(generation: currentGeneration)
                    return
                }
                await self?.receive(data, generation: currentGeneration)
            }
            await self?.closed(generation: currentGeneration)
        }
        process = try processes.launch(.init(executable: executable, arguments: arguments, environment: environment),
            output: { data in
                if case .dropped = channel.continuation.yield(data) { overflow.finish(); channel.continuation.finish() }
            }, ended: { channel.continuation.finish() })
        if let process {
            ownedChildren.add(process)
            if shutdownRequested.isFinished {
                process.close(); process.terminateImmediately()
                throw CodexClientError.disconnected
            }
        }
    }

    private func request(_ method: String, params: [String: Any]?) async throws -> Data {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self, requestTimeout] in
                do { try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000)) }
                catch { return }
                await self?.expired(id)
            }
            pending[id] = Pending(method: method, continuation: continuation, timeout: timeout)
            var message: [String: Any] = ["id": id, "method": method]
            if let params { message["params"] = params }
            do { try write(message) }
            catch {
                let entry = pending.removeValue(forKey: id)
                entry?.timeout.cancel()
                entry?.continuation.resume(throwing: error)
            }
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard let process else { throw CodexClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
        data.append(10)
        try process.write(data)
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

    private func inputOverflow(generation: Int) {
        guard generation == self.generation else { return }
        disconnect(reason: .invalidReply(method: pending.values.first?.method ?? "app-server", reason: L10n.text("cli.too_large")))
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
        let status = process?.terminationStatus
        let detail = process?.errorMessage() ?? ""
        disconnect(reason: .processExited(status: status, detail: detail))
    }
}
