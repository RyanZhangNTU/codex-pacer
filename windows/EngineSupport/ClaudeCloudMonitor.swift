import Foundation

protocol ClaudeCloudConnection: Sendable {
    func start(expanded: Bool, update: @escaping ClaudeCloudProjectMonitor.Update) async
    func setExpanded(_ value: Bool) async
    func refresh() async
    func shutdown() async
}

struct ClaudeCloudServices: Sendable {
    struct Input: Sendable {
        let home: URL, organization: String, context: String
        let localSessions: ClaudeCloudProjectMonitor.LocalSessions
        let observedScope: @Sendable (String?) async -> Bool
        let changedScope: @Sendable () async -> Void
    }
    let makeClient: @Sendable (Input) async throws -> any ClaudeCloudConnection
}

struct ClaudeCloudState: Sendable {
    let context: UInt64, purgeRevision: UInt64
    let connectionContext: String
    let enabled: Bool, webAvailable: Bool
    let activities: [SessionActivity], attention: [PendingAttentionRequest]
    let status: RuntimeStreamStatus?
}

/// The original monitor owns polling and streaming rules. This owner revokes
/// old source callbacks before awaiting shutdown or starting another account.
actor ClaudeCloudMonitor {
    private let services: ClaudeCloudServices
    private let localSessions: ClaudeCloudProjectMonitor.LocalSessions
    private let output: @Sendable (ClaudeCloudState) async -> Void
    private var home: URL?, organization = ""
    private var enabled = false, webAvailable = false, expanded = false, published = false
    private var context: UInt64 = 0, revision: UInt64 = 0, purgeRevision: UInt64 = 0
    private var connectionContext = UUID().uuidString, lastScope: String?
    private var client: (any ClaudeCloudConnection)?
    private var starting: Task<Void, Never>?
    private var activities: [SessionActivity] = [], attention: [PendingAttentionRequest] = []
    private var status: RuntimeStreamStatus?

    init(services: ClaudeCloudServices, localSessions: @escaping ClaudeCloudProjectMonitor.LocalSessions = { [] },
         output: @escaping @Sendable (ClaudeCloudState) async -> Void) {
        self.services = services; self.localSessions = localSessions; self.output = output
    }
    func configure(home: URL, organization: String, enabled: Bool, webAvailable: Bool,
                   context: UInt64, reset: Bool = false) async {
        self.context = context; published = false
        let sourceChanged = self.home != home || self.organization != organization || reset
        let changed = sourceChanged || self.enabled != enabled || self.webAvailable != webAvailable
        self.home = home; self.organization = organization; self.enabled = enabled; self.webAvailable = webAvailable
        if sourceChanged { purgeRevision &+= 1; lastScope = nil }
        if changed { await invalidate() } else { await emit() }
    }
    private func invalidate() async {
        revision &+= 1; connectionContext = UUID().uuidString
        starting?.cancel(); starting = nil
        let previous = client; client = nil
        activities = []; attention = []; status = nil
        await emit(); await ShutdownDeadline().perform([{ await previous?.shutdown() }])
    }
    func currentState() -> ClaudeCloudState {
        .init(context: context, purgeRevision: purgeRevision, connectionContext: connectionContext,
              enabled: enabled, webAvailable: webAvailable, activities: activities, attention: attention, status: status)
    }
    private func emit() async { await output(currentState()) }
    private func current(_ expected: UInt64) -> Bool { revision == expected && enabled && webAvailable && !Task.isCancelled }

    /// Called after the engine publishes the binding, so the host can authorize
    /// a cookie request from this context even during initialization/configuration.
    func startAfterPublication() { published = true; startIfNeeded() }
    private func startIfNeeded() {
        guard published, enabled, webAvailable, home != nil, client == nil, starting == nil else { return }
        let expected = revision
        starting = Task { [weak self] in await self?.start(expected) }
    }
    private func start(_ expected: UInt64) async {
        guard current(expected), let home else { return }
        let input = ClaudeCloudServices.Input(home: home, organization: organization, context: connectionContext, localSessions: localSessions,
            observedScope: { [weak self] scope in await self?.observeScope(scope, revision: expected) ?? false },
            changedScope: { [weak self] in await self?.scopeChanged(revision: expected) })
        do {
            let created = try await services.makeClient(input)
            guard current(expected) else { await created.shutdown(); return }
            client = created
            await created.start(expanded: expanded) { [weak self] values, status, attention in
                await self?.receive(values, status: status, attention: attention, revision: expected)
            }
        } catch {
            guard current(expected) else { return }
            var unavailable = RuntimeStreamStatus(); unavailable.connected = false; status = unavailable
            await emit()
        }
        if revision == expected { starting = nil }
    }
    private func observeScope(_ scope: String?, revision: UInt64) async -> Bool {
        guard current(revision) else { return false }
        if lastScope != scope {
            lastScope = scope; purgeRevision &+= 1
            activities = []; attention = []; status = nil
            await emit()
        }
        return current(revision)
    }
    private func scopeChanged(revision: UInt64) async {
        guard current(revision) else { return }
        // This client never accepts the new cookie. A new context first clears
        // the old graph, then binds a new monitor to the newly observed session.
        purgeRevision &+= 1; lastScope = nil
        await invalidate(); startIfNeeded()
    }
    private func receive(_ values: [SessionActivity], status: RuntimeStreamStatus?, attention: [PendingAttentionRequest], revision: UInt64) async {
        guard current(revision) else { return }
        activities = values; self.attention = attention; self.status = status
        await emit()
    }
    func setExpanded(_ value: Bool) async {
        expanded = value; await client?.setExpanded(value)
    }
    func refresh() async { await client?.refresh(); startIfNeeded() }
    func stop() async { enabled = false; published = false; await invalidate() }
    func waitUntilStarted() async { await starting?.value }
}

/// Bounded observed local IDs exclude a cloud session already collected here.
/// This contains IDs only, never transcript text or authentication data.
final class ClaudeCloudLocalSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()
    func update(_ activities: [SessionActivity]) {
        let ids = activities.filter { $0.provider == .claude && $0.claudeCloud == nil }.prefix(4096).compactMap(\.threadID)
        lock.lock(); values = Set(ids.map(ClaudeCloudProjectState.bareID)); lock.unlock()
    }
    func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return values }
}
