import Foundation

protocol ClaudeQuotaConnection: CodexQuotaConnection {
    func organizations() async -> [ClaudeWebOrganization]
    func currentSource() async -> ClaudeQuotaSource?
    func nextRetryAt() async -> Date?
}
extension ClaudeWebQuotaClient: ClaudeQuotaConnection {}

struct ClaudeQuotaServices: Sendable {
    let makeClient: @Sendable (URL, String, String) async throws -> any ClaudeQuotaConnection
    let history: QuotaHistoryStore?
}

struct ClaudeQuotaState: Sendable {
    let context: UInt64
    let connectionContext: String
    let enabled: Bool, webAvailable: Bool, refreshing: Bool
    let snapshot: QuotaSnapshot?
    let history: QuotaCycleHistory
    let error: String?, warning: String?, failure: ClaudeQuotaError?
    let source: ClaudeQuotaSource?
    let organizations: [ClaudeWebOrganization]
}

/// Keeps the native web client's verified identity and Retry-After state across
/// transient errors. A changed source revokes its binding before awaiting I/O.
actor ClaudeQuotaMonitor {
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

    init(services: ClaudeQuotaServices, now: @escaping @Sendable () -> Date = { Date() },
         output: @escaping @Sendable (ClaudeQuotaState) async -> Void) {
        self.services = services; self.now = now; self.output = output
    }
    func configure(home: URL, organization: String, enabled: Bool, context: UInt64, reset: Bool = false) async {
        self.context = context
        guard self.home != home || selection != organization || self.enabled != enabled || reset else { await emit(); return }
        self.home = home; selection = organization; self.enabled = enabled
        await invalidate()
    }
    func setWebAvailable(_ value: Bool) async {
        guard webAvailable != value else { return }
        webAvailable = value; await invalidate()
    }
    private func invalidate() async {
        revision += 1; connectionContext = UUID().uuidString
        let previous = client
        work?.cancel(); work = nil; workID = nil; client = nil
        snapshot = nil; history = .init(); error = nil; warning = nil; failure = nil; source = nil; organizations = []
        lastAttempt = nil; failures = 0
        await emit()
        let history = services.history, date = now()
        await ShutdownDeadline().perform([{ await previous?.shutdown() }, { _ = await history?.flush(at: date) }])
    }
    @discardableResult
    func refreshIfDue(expanded: Bool, force: Bool = false, expansion: Bool = false) async -> Bool {
        guard enabled, webAvailable, let home, work == nil else { return false }
        let currentRevision = revision, retry = await client?.nextRetryAt()
        guard enabled, webAvailable, revision == currentRevision, work == nil, retry.map({ $0 <= now() }) ?? true else { return false }
        let elapsed = lastAttempt.map { now().timeIntervalSince($0) } ?? .infinity
        guard force || (expansion && elapsed > 30) || elapsed >= ProviderQuotaRefreshPolicy.interval(expanded: expanded, failures: failures) else { return false }
        lastAttempt = now()
        let id = UUID(), organization = selection, binding = connectionContext
        workID = id
        work = Task { [weak self] in
            guard let self else { return }
            await self.read(home: home, organization: organization, binding: binding, revision: currentRevision, id: id)
        }
        return true
    }
    func currentState() -> ClaudeQuotaState {
        .init(context: context, connectionContext: connectionContext, enabled: enabled, webAvailable: webAvailable, refreshing: work != nil,
            snapshot: snapshot, history: history, error: error, warning: warning, failure: failure, source: source, organizations: organizations)
    }
    func waitForRefresh() async { await work?.value }
    private func emit() async { await output(currentState()) }
    private func current(_ revision: UInt64, _ id: UUID) -> Bool {
        enabled && webAvailable && self.revision == revision && workID == id && !Task.isCancelled
    }
    private func read(home: URL, organization: String, binding: String, revision: UInt64, id: UUID) async {
        await emit(); guard current(revision, id) else { return }
        do {
            if client == nil {
                let created = try await services.makeClient(home, organization, binding)
                guard current(revision, id) else { await created.shutdown(); return }
                client = created
            }
            guard let connection = client, current(revision, id) else { return }
            let reading = try await connection.readQuota()
            guard current(revision, id) else { return }
            if history.accountScope != reading.accountScope {
                if let scope = reading.accountScope {
                    let restored = await services.history?.restore(home: home, accountScope: scope, now: now())
                    guard current(revision, id) else { return }; history = restored?.1 ?? .init()
                } else { history = .init() }
            }
            snapshot = reading; history.record(reading); failures = 0; failure = nil; error = nil; warning = nil
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
            else if let scope, snapshot?.accountScope != scope {
                let restored = await services.history?.restore(home: home, accountScope: scope, now: now())
                guard current(revision, id) else { return }; snapshot = restored?.0; history = restored?.1 ?? .init(); warning = nil
            }
            failure = (error as? ClaudeQuotaError) ?? .connectionFailed; self.error = failure?.localizedDescription
            failures = min(4, failures + 1)
        }
        guard current(revision, id) else { return }
        let choices = await client?.organizations() ?? [], readSource = await client?.currentSource()
        guard current(revision, id) else { return }
        organizations = choices; source = readSource
        work = nil; workID = nil; await emit()
    }
    func stop() async {
        enabled = false; await invalidate()
    }
}
