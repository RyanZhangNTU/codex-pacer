import Foundation

public protocol ClaudeQuotaConnection: CodexQuotaConnection {
    func organizations() async -> [ClaudeWebOrganization]
    func currentSource() async -> ClaudeQuotaSource?
    func nextRetryAt() async -> Date?
}
extension ClaudeWebQuotaClient: ClaudeQuotaConnection {}
extension ClaudeQuotaClient: ClaudeQuotaConnection {
    public func organizations() async -> [ClaudeWebOrganization] { [] }
}

public struct ClaudeQuotaServices: Sendable {
    public let makeClient: @Sendable (URL, String, String) async throws -> any ClaudeQuotaConnection
    public let history: QuotaHistoryStore?
    public init(makeClient: @escaping @Sendable (URL, String, String) async throws -> any ClaudeQuotaConnection, history: QuotaHistoryStore?) { self.makeClient = makeClient; self.history = history }
}

public struct ClaudeQuotaState: Sendable {
    public let context: UInt64
    public let connectionContext: String
    public let enabled: Bool, webAvailable: Bool, refreshing: Bool
    public let snapshot: QuotaSnapshot?
    public let history: QuotaCycleHistory
    public let error: String?, warning: String?, failure: ClaudeQuotaError?
    public let source: ClaudeQuotaSource?
    public let organizations: [ClaudeWebOrganization]
    public let lastAttempt: Date?
    public let failureCount: Int
    public let successCount: UInt64
}

/// Keeps the native web client's verified identity and Retry-After state across
/// transient errors. A changed source revokes its binding before awaiting I/O.
public actor ClaudeQuotaCoordinator {
    private let services: ClaudeQuotaServices
    private let now: @Sendable () -> Date
    private let output: @Sendable (ClaudeQuotaState) async -> Void
    private var home: URL?, selection = ""
    private var enabled = false, webAvailable = false
    private var context: UInt64 = 0, revision: UInt64 = 0
    private var connectionContext = UUID().uuidString
    private var client: (any ClaudeQuotaConnection)?
    private var work: Task<Void, Never>?, workID: UUID?
    private var lastAttempt: Date?, failures = 0
    private var snapshot: QuotaSnapshot?, history = QuotaCycleHistory()
    private var error: String?, warning: String?, failure: ClaudeQuotaError?, source: ClaudeQuotaSource?
    private var organizations: [ClaudeWebOrganization] = []
    private var successes: UInt64 = 0
    private let generation = QuotaWorkGeneration()
    private var epoch: UInt64 = 0
    private var pendingSeed: ClaudeQuotaState?

    public init(services: ClaudeQuotaServices, seed: ClaudeQuotaState? = nil, webAvailable: Bool = false, now: @escaping @Sendable () -> Date = { Date() },
         output: @escaping @Sendable (ClaudeQuotaState) async -> Void) {
        self.services = services; self.now = now; self.output = output
        lastAttempt = seed?.lastAttempt; failures = seed?.failureCount ?? 0
        pendingSeed = seed; self.webAvailable = webAvailable
    }
    public func configure(home: URL, organization: String, enabled: Bool, context: UInt64, reset: Bool = false) async {
        self.context = context
        guard self.home != home || selection != organization || self.enabled != enabled || reset else { await emit(); return }
        let seed = self.home == nil ? pendingSeed : nil; pendingSeed = nil
        self.home = home; selection = organization; self.enabled = enabled
        await invalidate(seed: seed)
    }
    public func setWebAvailable(_ value: Bool) async {
        guard webAvailable != value else { return }
        webAvailable = value; await invalidate()
    }
    private func invalidate(seed: ClaudeQuotaState? = nil) async {
        revision += 1; connectionContext = UUID().uuidString
        generation.invalidate(); epoch = generation.capture()
        let previous = client
        let pending = work
        work?.cancel(); work = nil; workID = nil; client = nil
        snapshot = seed?.snapshot; history = seed?.history ?? .init(); error = seed?.error; warning = seed?.warning
        failure = seed?.failure; source = seed?.source; organizations = seed?.organizations ?? []
        lastAttempt = seed?.lastAttempt; failures = seed?.failureCount ?? 0; successes = seed?.successCount ?? 0
        await emit()
        let history = services.history, date = now()
        await ShutdownDeadline().perform([{ await previous?.shutdown() }, { await pending?.value }, { _ = await history?.flush(at: date) }])
    }
    @discardableResult
    public func refreshIfDue(expanded: Bool, force: Bool = false, expansion: Bool = false) async -> Bool {
        guard enabled, webAvailable, generation.contains(epoch), let home, work == nil else { return false }
        let currentRevision = revision, retry = await client?.nextRetryAt()
        guard enabled, webAvailable, generation.contains(epoch), revision == currentRevision, work == nil, retry.map({ $0 <= now() }) ?? true else { return false }
        guard ProviderQuotaRefreshPolicy.isDue(lastAttempt: lastAttempt, expanded: expanded, failures: failures, now: now(), force: force, expansion: expansion) else { return false }
        lastAttempt = now()
        let id = UUID(), organization = selection, binding = connectionContext
        workID = id
        work = Task { [weak self] in
            guard let self else { return }
            await self.read(home: home, organization: organization, binding: binding, revision: currentRevision, id: id)
        }
        return true
    }
    public func currentState() -> ClaudeQuotaState {
        .init(context: context, connectionContext: connectionContext, enabled: enabled, webAvailable: webAvailable, refreshing: work != nil,
            snapshot: snapshot, history: history, error: error, warning: warning, failure: failure, source: source, organizations: organizations,
            lastAttempt: lastAttempt, failureCount: failures, successCount: successes)
    }
    public func waitForRefresh() async { await work?.value }
    private func emit() async { await output(currentState()) }
    private func current(_ revision: UInt64, _ id: UUID) -> Bool {
        enabled && webAvailable && generation.contains(epoch) && self.revision == revision && workID == id && !Task.isCancelled
    }
    private func read(home: URL, organization: String, binding: String, revision: UInt64, id: UUID) async {
        await emit(); guard current(revision, id) else { return }
        do {
            if client == nil {
                let created = try await services.makeClient(home, organization, binding)
                guard current(revision, id) else { await ShutdownDeadline().perform([{ await created.shutdown() }]); return }
                client = created
                generation.onInvalidate { created.invalidateSource() }
            }
            guard let connection = client, current(revision, id) else { return }
            let reading = try await connection.readQuota()
            guard current(revision, id) else { return }
            if history.accountScope != reading.accountScope {
                snapshot = nil; history = .init(); source = nil; warning = nil
                await emit()
                guard current(revision, id) else { return }
                if let scope = reading.accountScope {
                    let restored = await services.history?.restore(home: home, accountScope: scope, now: now())
                    guard current(revision, id) else { return }; history = restored?.1 ?? .init()
                } else { history = .init() }
            }
            snapshot = reading; history.record(reading); failures = 0; failure = nil; error = nil; warning = nil
            error = reading.windows.isEmpty ? L10n.text("quota.no_windows") : nil
            successes &+= 1
            if reading.accountScope == nil { warning = L10n.text("quota.no_identity") }
            else if let store = services.history {
                let saved = await store.save(home: home, snapshot: reading, history: history, now: now())
                guard current(revision, id) else { return }; warning = saved ? nil : L10n.text("quota.history_unsaved")
            }
        } catch {
            guard current(revision, id) else { return }
            let scope = await client?.currentAccountScope()
            guard current(revision, id) else { return }
            if scope == nil { snapshot = nil; history = .init(); warning = nil }
            else if snapshot?.accountScope != scope { snapshot = nil; history = .init(); warning = nil; source = nil }
            failure = (error as? ClaudeQuotaError) ?? .connectionFailed; self.error = failure?.localizedDescription
            failures = min(4, failures + 1)
            await emit()
            guard current(revision, id) else { return }
        }
        guard current(revision, id) else { return }
        let choices = await client?.organizations() ?? [], readSource = await client?.currentSource()
        guard current(revision, id) else { return }
        organizations = choices; source = snapshot == nil ? nil : readSource
        work = nil; workID = nil; await emit()
    }
    public func stop() async {
        invalidateSource()
        enabled = false; await invalidate()
    }
    public nonisolated func invalidateSource() { generation.invalidate() }
}
