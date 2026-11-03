import Foundation
import PacerCore
import PacerMacSupport

/// Discovery and process creation stay in the Mac adapter. Core owns attempts,
/// account verification, history, cancellation and the returned selection.
struct MacCodexQuotaConnection: CodexQuotaConnection {
    let client: CodexClient
    let selection: CodexExecutableResolver.Candidate
    func readQuota() async throws -> QuotaSnapshot { try await client.readQuota() }
    func currentAccountScope() async -> String? { await client.currentAccountScope() }
    func executableSelection() async -> CodexExecutableResolver.Candidate? { selection }
    func shutdown() async { await client.shutdown(deadline: ShutdownDeadline()) }
}

struct MacClaudeQuotaConnection: ClaudeQuotaConnection {
    let read: @Sendable () async throws -> QuotaSnapshot
    let scope: @Sendable () async -> String?
    let source: @Sendable () async -> ClaudeQuotaSource?
    let retry: @Sendable () async -> Date?
    let choices: @Sendable () async -> [ClaudeWebOrganization]
    let close: @Sendable () async -> Void
    func readQuota() async throws -> QuotaSnapshot { try await read() }
    func currentAccountScope() async -> String? { await scope() }
    func currentSource() async -> ClaudeQuotaSource? { await source() }
    func nextRetryAt() async -> Date? { await retry() }
    func organizations() async -> [ClaudeWebOrganization] { await choices() }
    func shutdown() async { await close() }
}

/// MainActor samples the host's credential service before scheduling a read.
/// Core can then inspect that immutable input without calling UI-bound code.
final class MacDeepSeekCredentialInput: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    init(_ key: String?) { self.key = key }
    func read() -> String? { lock.lock(); defer { lock.unlock() }; return key }
    func update(_ key: String?) { lock.lock(); self.key = key; lock.unlock() }
}

actor MacClaudeCloudClients {
    private var prepared: ClaudeCloudProjectMonitor?
    private let factory: @MainActor () -> ClaudeCloudProjectMonitor
    init(prepared: ClaudeCloudProjectMonitor, factory: @escaping @MainActor () -> ClaudeCloudProjectMonitor) {
        self.prepared = prepared; self.factory = factory
    }
    func make(_ input: ClaudeCloudServices.Input) async -> ClaudeCloudProjectMonitor {
        let client: ClaudeCloudProjectMonitor
        if let prepared { client = prepared; self.prepared = nil }
        else { client = await factory() }
        await client.setScopeObserver(input.observedScope)
        return client
    }
}
