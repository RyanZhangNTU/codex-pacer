import Foundation

/// Opt-in diagnostic counters contain numbers only. Protocol bodies, account
/// scopes, paths, credentials and localized server errors are never recorded.
final class QuotaReadDiagnostics: @unchecked Sendable {
    static let shared = QuotaReadDiagnostics()
    private let lock = NSLock()
    private var attempts = ["codex": 0, "claude": 0, "deepseek": 0]
    private var successes = ["codex": 0, "claude": 0, "deepseek": 0]
    private var failures = ["codex": 0, "claude": 0, "deepseek": 0]
    private var connections = ["codex": 0, "claude": 0]
    func created(_ provider: String) { lock.lock(); connections[provider, default: 0] += 1; lock.unlock() }
    func started(_ provider: String) { lock.lock(); attempts[provider, default: 0] += 1; lock.unlock() }
    func finished(_ provider: String, success: Bool) {
        lock.lock()
        if success { successes[provider, default: 0] += 1 } else { failures[provider, default: 0] += 1 }
        lock.unlock()
    }
    func report() {
        lock.lock(); let values: [String: Any] = ["type": "quotaReadDiagnostics", "attempts": attempts, "successes": successes, "failures": failures, "connections": connections]; lock.unlock()
        guard let bytes = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) else { return }
        try? FileHandle.standardError.write(contentsOf: bytes + Data([10]))
    }
}

private struct DiagnosticCodexQuota: CodexQuotaConnection {
    let client: any CodexQuotaConnection
    func readQuota() async throws -> QuotaSnapshot {
        QuotaReadDiagnostics.shared.started("codex")
        do { let value = try await client.readQuota(); QuotaReadDiagnostics.shared.finished("codex", success: true); return value }
        catch { QuotaReadDiagnostics.shared.finished("codex", success: false); throw error }
    }
    func currentAccountScope() async -> String? { await client.currentAccountScope() }
    func shutdown() async { await client.shutdown() }
    func invalidateSource() { client.invalidateSource() }
}

private struct DiagnosticClaudeQuota: ClaudeQuotaConnection {
    let client: ClaudeQuotaClient
    func readQuota() async throws -> QuotaSnapshot {
        QuotaReadDiagnostics.shared.started("claude")
        do { let value = try await client.readQuota(); QuotaReadDiagnostics.shared.finished("claude", success: true); return value }
        catch { QuotaReadDiagnostics.shared.finished("claude", success: false); throw error }
    }
    func currentAccountScope() async -> String? { await client.currentAccountScope() }
    func currentSource() async -> ClaudeQuotaSource? { await client.currentSource() }
    func nextRetryAt() async -> Date? { await client.nextRetryAt() }
    func organizations() async -> [ClaudeWebOrganization] { [] }
    func shutdown() async { await client.shutdown() }
}

extension CodexQuotaServices {
    static var readOnlyDiagnostics: Self {
        let make = Self.live.makeClient
        return .init(makeClient: {
            QuotaReadDiagnostics.shared.created("codex")
            return DiagnosticCodexQuota(client: try await make($0, $1))
        }, history: nil)
    }
}

extension ClaudeQuotaServices {
    static var readOnlyDiagnostics: Self {
        .init(makeClient: { home, _, _ in
            QuotaReadDiagnostics.shared.created("claude")
            let files = WindowsFileSystem(), userHome = FileManager.default.homeDirectoryForCurrentUser
            let client = ClaudeQuotaClient(statusLineURL: home.appendingPathComponent("pacer/claude-statusline.json"), files: files,
                credentialProvider: { nil }, identityProvider: {
                    ClaudeCredentialStore.identity(userHome: userHome, home: home, files: files).map { ($0.scope, $0.organizationID) }
                }, transport: { _ in throw ClaudeQuotaError.unavailable }, now: { Date() })
            return DiagnosticClaudeQuota(client: client)
        }, history: nil)
    }
}

extension DeepSeekBalanceServices {
    static var readOnlyDiagnostics: Self { Self.live.forReadOnlyDiagnostics() }
    func forReadOnlyDiagnostics() -> Self {
        var value = self
        let read = value.readAPI
        value.readAPI = { key in
            QuotaReadDiagnostics.shared.started("deepseek")
            do { let balance = try await read(key); QuotaReadDiagnostics.shared.finished("deepseek", success: true); return balance }
            catch { QuotaReadDiagnostics.shared.finished("deepseek", success: false); throw error }
        }
        value.saveKey = { _ in false }; value.removeKey = { false }
        value.loadHistory = { .init() }; value.saveHistory = { _, _ in }; value.fingerprint = { _, _ in nil }
        return value
    }
}
