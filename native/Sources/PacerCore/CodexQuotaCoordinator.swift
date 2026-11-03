import Foundation

public protocol CodexQuotaConnection: Sendable {
    func readQuota() async throws -> QuotaSnapshot
    func currentAccountScope() async -> String?
    func shutdown() async
    func executableSelection() async -> CodexExecutableResolver.Candidate?
    nonisolated func invalidateSource()
}
extension CodexQuotaConnection {
    public func executableSelection() async -> CodexExecutableResolver.Candidate? { nil }
    public nonisolated func invalidateSource() {}
}
extension CodexClient: CodexQuotaConnection {
    public nonisolated func shutdown() async { await shutdown(deadline: ShutdownDeadline()) }
}

public struct CodexQuotaServices: Sendable {
    public let makeClient: @Sendable (URL, String) async throws -> any CodexQuotaConnection
    public let history: QuotaHistoryStore?
    public init(makeClient: @escaping @Sendable (URL, String) async throws -> any CodexQuotaConnection, history: QuotaHistoryStore?) { self.makeClient = makeClient; self.history = history }


}

public struct CodexQuotaState: Sendable {
    public let context: UInt64
    public let snapshot: QuotaSnapshot?
    public let history: QuotaCycleHistory
    public let error: String?
    public let warning: String?
    public let refreshing: Bool
    public let failure: CodexQuotaFailure?
    public let lastAttempt: Date?
    public let failureCount: Int
    public let successCount: UInt64
    public let executable: CodexExecutableResolver.Candidate?
}

/// Stable, non-identifying fields for connection diagnostics. Localized error
/// text remains separate so clients do not parse prose to determine a failure.
public struct CodexQuotaFailure: Codable, Equatable, Sendable {
    public let kind: String
    public let method: String?
    public let code: Int?
    public init(kind: String, method: String? = nil, code: Int? = nil) {
        self.kind = kind
        self.method = ["initialize", "account/read", "account/rateLimits/read"].contains(method ?? "") ? method : nil
        self.code = code
    }
    public init(_ error: Error) {
        guard let error = error as? CodexClientError else { self.init(kind: "unavailable"); return }
        switch error {
        case .missingExecutable, .executableNotFound: self.init(kind: "executable")
        case .launchFailed: self.init(kind: "launch")
        case .processExited(let status, _): self.init(kind: "processExit", code: status.map(Int.init))
        case .timeout(let method, _): self.init(kind: "timeout", method: method)
        case .invalidReply(let method, _): self.init(kind: "protocol", method: method)
        case .invalidResponse: self.init(kind: "protocol")
        case .server(let method, let code, _): self.init(kind: "server", method: method, code: code)
        case .accountMismatch: self.init(kind: "accountMismatch")
        case .notLoggedIn: self.init(kind: "signedOut")
        case .unsupportedAccount: self.init(kind: "unsupportedAccount")
        case .disconnected: self.init(kind: "disconnected")
        }
    }
}

/// Quota work is independent of activity collection. A changed source revokes
/// the previous generation before any process shutdown or cache operation awaits.
public actor CodexQuotaCoordinator {
    private let services: CodexQuotaServices
    private let now: @Sendable () -> Date
    private let output: @Sendable (CodexQuotaState) async -> Void
    private var home: URL?
    private var customPath = ""
    private var enabled = false
    private var context: UInt64 = 0, revision: UInt64 = 0
    private var snapshot: QuotaSnapshot?
    private var history = QuotaCycleHistory()
    private var error: String?, warning: String?
    private var failure: CodexQuotaFailure?
    private var client: (any CodexQuotaConnection)?
    private var work: Task<Void, Never>?
    private var workID: UUID?
    private var lastAttempt: Date?
    private var failures = 0
    private var successes: UInt64 = 0
    private var executable: CodexExecutableResolver.Candidate?
    private let generation = QuotaWorkGeneration()
    private var epoch: UInt64 = 0
    private var pendingSeed: CodexQuotaState?

    public init(services: CodexQuotaServices, seed: CodexQuotaState? = nil, now: @escaping @Sendable () -> Date = { Date() },
         output: @escaping @Sendable (CodexQuotaState) async -> Void) {
        self.services = services; self.now = now; self.output = output
        lastAttempt = seed?.lastAttempt; failures = seed?.failureCount ?? 0
        pendingSeed = seed
    }

    public func configure(home: URL, customPath: String, enabled: Bool, context: UInt64) async {
        self.context = context
        guard self.home != home || self.customPath != customPath || self.enabled != enabled else {
            await emit(); return
        }
        revision += 1
        let seed = self.home == nil ? pendingSeed : nil; pendingSeed = nil
        generation.invalidate(); epoch = generation.capture()
        let previous = client
        work?.cancel(); work = nil; workID = nil; client = nil
        self.home = home; self.customPath = customPath; self.enabled = enabled
        snapshot = seed?.snapshot; history = seed?.history ?? QuotaCycleHistory()
        error = seed?.error; warning = seed?.warning; failure = seed?.failure; executable = seed?.executable
        lastAttempt = seed?.lastAttempt; failures = seed?.failureCount ?? 0; successes = seed?.successCount ?? 0
        await emit()
        await close(previous)
    }

    public static func refreshInterval(expanded: Bool, failures: Int) -> TimeInterval {
        ProviderQuotaRefreshPolicy.interval(expanded: expanded, failures: failures)
    }

    public func refreshIfDue(expanded: Bool, force: Bool = false, expansion: Bool = false) {
        guard enabled, generation.contains(epoch), let home, work == nil else { return }
        guard ProviderQuotaRefreshPolicy.isDue(lastAttempt: lastAttempt, expanded: expanded, failures: failures, now: now(), force: force, expansion: expansion) else { return }
        lastAttempt = now()
        let identifier = UUID(), current = revision, path = customPath
        workID = identifier
        work = Task { [weak self] in
            guard let self else { return }
            await self.read(home: home, customPath: path, revision: current, identifier: identifier)
        }
    }

    public func currentState() -> CodexQuotaState {
        .init(context: context, snapshot: snapshot, history: history, error: error, warning: warning,
            refreshing: work != nil, failure: failure, lastAttempt: lastAttempt, failureCount: failures, successCount: successes, executable: executable)
    }
    public func waitForRefresh() async { await work?.value }
    private func emit() async { await output(currentState()) }
    private func current(_ value: UInt64, _ identifier: UUID) -> Bool {
        enabled && generation.contains(epoch) && revision == value && workID == identifier && !Task.isCancelled
    }

    private func read(home: URL, customPath: String, revision: UInt64, identifier: UUID) async {
        await emit()
        guard current(revision, identifier) else { return }
        do {
            if client == nil {
                executable = nil
                let created = try await services.makeClient(home, customPath)
                guard current(revision, identifier) else { await close(created); return }
                client = created
                generation.onInvalidate { created.invalidateSource() }
                let selection = await created.executableSelection()
                guard current(revision, identifier) else { return }; executable = selection
            }
            guard current(revision, identifier), let connection = client else { return }
            let reading = try await connection.readQuota()
            guard current(revision, identifier) else { return }
            if history.accountScope != reading.accountScope {
                snapshot = nil; history = QuotaCycleHistory(); warning = nil
                await emit()
                guard current(revision, identifier) else { return }
                if let scope = reading.accountScope {
                    let restored = await services.history?.restore(home: home, accountScope: scope, now: now())
                    guard current(revision, identifier) else { return }
                    history = restored?.1 ?? QuotaCycleHistory()
                } else { history = QuotaCycleHistory() }
            }
            snapshot = reading; history.record(reading)
            error = reading.windows.isEmpty ? L10n.text("quota.no_windows") : nil
            failure = reading.windows.isEmpty ? .init(kind: "noWindows") : nil
            failures = 0
            successes &+= 1
            if reading.accountScope == nil { warning = L10n.text("quota.no_identity") }
            else if let store = services.history {
                let saved = await store.save(home: home, snapshot: reading, history: history, now: now())
                guard current(revision, identifier) else { return }
                warning = saved ? nil : L10n.text("quota.history_unsaved")
            } else { warning = nil }
        } catch {
            guard current(revision, identifier) else { return }
            let previous = client
            let scope = await previous?.currentAccountScope()
            guard current(revision, identifier) else { return }
            if scope == nil { snapshot = nil; history = QuotaCycleHistory(); warning = nil }
            else if let scope, snapshot?.accountScope != scope {
                snapshot = nil; history = QuotaCycleHistory(); warning = nil
                await emit()
                guard current(revision, identifier) else { return }
                let restored = await services.history?.restore(home: home, accountScope: scope, now: now())
                guard current(revision, identifier) else { return }
                snapshot = restored?.0; history = restored?.1 ?? QuotaCycleHistory(); warning = nil
            }
            self.error = CodexDiagnosticText.description(of: error)
            failure = .init(error)
            failures = min(4, failures + 1)
            client = nil
            await emit()
            guard current(revision, identifier) else { return }
            await close(previous)
            guard current(revision, identifier) else { return }
        }
        guard current(revision, identifier) else { return }
        work = nil; workID = nil
        await emit()
    }

    private func close(_ previous: (any CodexQuotaConnection)?, reading: Task<Void, Never>? = nil) async {
        let history = services.history, date = now()
        await ShutdownDeadline().perform([
            { await previous?.shutdown() }, { await reading?.value },
            { _ = await history?.flush(at: date) }
        ])
    }
    public nonisolated func invalidateSource() { generation.invalidate() }
    public func stop() async {
        invalidateSource()
        revision += 1; enabled = false
        let previous = client, reading = work
        work?.cancel(); work = nil; workID = nil; client = nil
        await close(previous, reading: reading)
    }
}
