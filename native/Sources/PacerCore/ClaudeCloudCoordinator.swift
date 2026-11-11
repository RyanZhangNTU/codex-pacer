import Foundation

public protocol ClaudeCloudConnection: Sendable {
    func start(expanded: Bool, update: @escaping ClaudeCloudProjectMonitor.Update) async
    func setExpanded(_ value: Bool) async
    func refresh() async
    func suspend() async
    func shutdown() async
}
extension ClaudeCloudProjectMonitor: ClaudeCloudConnection {}

public struct ClaudeCloudServices: Sendable {
    public struct Input: Sendable {
        public let home: URL, organization: String, context: String
        public let localSessions: ClaudeCloudProjectMonitor.LocalSessions
        public let observedScope: @Sendable (String?) async -> Bool
        public let changedScope: @Sendable () async -> Void
    }
    public let makeClient: @Sendable (Input) async throws -> any ClaudeCloudConnection
    public init(makeClient: @escaping @Sendable (Input) async throws -> any ClaudeCloudConnection) { self.makeClient = makeClient }
}

public struct ClaudeCloudState: Sendable {
    public let context: UInt64, purgeRevision: UInt64
    public let connectionContext: String
    public let enabled: Bool, webAvailable: Bool
    public let activities: [SessionActivity], attention: [PendingAttentionRequest]
    public let status: RuntimeStreamStatus?
    public let verifiedScope: String?
    public let scopeVerified: Bool
}

/// A disabled view may keep unread endings. A subsequently verified different
/// account, including sign-out, must revoke them even if the client was rebuilt.
public struct ClaudeCloudHistoryBinding: Sendable {
    private var known = false
    private var scope: String?
    public init() {}
    public mutating func observe(_ state: ClaudeCloudState) -> Bool {
        guard state.scopeVerified else { return false }
        let changed = known && scope != state.verifiedScope
        known = true; scope = state.verifiedScope
        return changed
    }
}

/// The original monitor owns polling and streaming rules. This owner revokes
/// old source callbacks before awaiting shutdown or starting another account.
public actor ClaudeCloudCoordinator {
    private let services: ClaudeCloudServices
    private let localSessions: ClaudeCloudProjectMonitor.LocalSessions
    private let output: @Sendable (ClaudeCloudState) async -> Void
    private var home: URL?, organization = ""
    private var enabled = false, webAvailable = false, expanded = false, published = false
    private var context: UInt64 = 0, revision: UInt64 = 0, purgeRevision: UInt64 = 0
    private var connectionContext = UUID().uuidString, lastScope: String?
    private var client: (any ClaudeCloudConnection)?
    private var scopeBinding: UUID?
    private var starting: Task<Void, Never>?
    private var suspending: Task<Bool, Never>?
    private var activities: [SessionActivity] = [], attention: [PendingAttentionRequest] = []
    private var status: RuntimeStreamStatus?
    private let generation = QuotaWorkGeneration()
    private var epoch: UInt64 = 0
    private var paused = false
    private var scopeVerified = false

    public init(services: ClaudeCloudServices, localSessions: @escaping ClaudeCloudProjectMonitor.LocalSessions = { [] },
         output: @escaping @Sendable (ClaudeCloudState) async -> Void) {
        self.services = services; self.localSessions = localSessions; self.output = output
    }
    public func configure(home: URL, organization: String, enabled: Bool, webAvailable: Bool,
                   context: UInt64, reset: Bool = false) async {
        self.context = context; published = false
        let sourceChanged = self.home != home || self.organization != organization || reset
        let changed = sourceChanged || self.enabled != enabled || self.webAvailable != webAvailable
        self.home = home; self.organization = organization; self.enabled = enabled; self.webAvailable = webAvailable
        if sourceChanged { purgeRevision &+= 1; lastScope = nil; scopeVerified = false }
        if changed { await invalidate() } else { await emit() }
    }
    private func invalidate() async {
        revision &+= 1; connectionContext = UUID().uuidString
        generation.invalidate(); epoch = generation.capture(); paused = false
        starting?.cancel(); starting = nil
        scopeBinding = nil; suspending = nil
        let previous = client; client = nil
        activities = []; attention = []; status = nil
        await emit(); await ShutdownDeadline().perform([{ await previous?.shutdown() }])
    }
    public func currentState() -> ClaudeCloudState {
        .init(context: context, purgeRevision: purgeRevision, connectionContext: connectionContext,
              enabled: enabled, webAvailable: webAvailable, activities: activities, attention: attention, status: status,
              verifiedScope: lastScope, scopeVerified: scopeVerified)
    }
    private func emit() async { await output(currentState()) }
    private func current(_ expected: UInt64) -> Bool { generation.contains(epoch) && !paused && revision == expected && enabled && webAvailable && !Task.isCancelled }

    /// Called after the engine publishes the binding, so the host can authorize
    /// a cookie request from this context even during initialization/configuration.
    public func startAfterPublication() { published = true; startIfNeeded() }
    private func startIfNeeded() {
        guard !paused, generation.contains(epoch), published, enabled, webAvailable, home != nil, client == nil, starting == nil else { return }
        let expected = revision
        starting = Task { [weak self] in await self?.start(expected) }
    }
    private func start(_ expected: UInt64) async {
        guard current(expected), let home else { return }
        let binding = UUID()
        scopeBinding = binding
        // Account checks belong to the client. Its data callback changes on
        // wake, but the same client still owns the account.
        let input = ClaudeCloudServices.Input(home: home, organization: organization, context: connectionContext, localSessions: localSessions,
            observedScope: { [weak self] scope in await self?.observeScope(scope, binding: binding) ?? false },
            changedScope: { [weak self] in await self?.scopeChanged(binding: binding) })
        do {
            let created = try await services.makeClient(input)
            guard current(expected) else { await ShutdownDeadline().perform([{ await created.shutdown() }]); return }
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
    private func observeScope(_ scope: String?, binding: UUID) async -> Bool {
        let expected = revision
        guard scopeBinding == binding, current(expected) else { return false }
        scopeVerified = true
        if lastScope != scope {
            lastScope = scope; purgeRevision &+= 1
            activities = []; attention = []; status = nil
            await emit()
        }
        return scopeBinding == binding && current(expected)
    }
    private func scopeChanged(binding: UUID) async {
        guard scopeBinding == binding, current(revision) else { return }
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
    public func setExpanded(_ value: Bool) async {
        expanded = value
        guard !paused, enabled, generation.contains(epoch) else { return }
        await client?.setExpanded(value)
    }
    public func refresh() async {
        guard !paused, enabled, generation.contains(epoch) else { return }
        await client?.refresh(); startIfNeeded()
    }
    public nonisolated func invalidateSource() { generation.invalidate() }
    public func suspend() async {
        guard !paused else { return }
        invalidateSource(); paused = true; revision &+= 1
        starting?.cancel(); starting = nil
        guard let client else { scopeBinding = nil; return }
        if suspending == nil {
            suspending = Task { await ShutdownDeadline().perform([{ await client.suspend() }]) }
        }
        _ = await suspending?.value
    }
    public func resume(context: UInt64) {
        self.context = context
        guard paused else { return }
        paused = false; epoch = generation.capture()
        let expected = revision
        if let client {
            starting = Task { [weak self] in await self?.restart(client, revision: expected) }
        } else { startIfNeeded() }
    }
    private func restart(_ client: any ClaudeCloudConnection, revision: UInt64) async {
        let suspended = await suspending?.value ?? true
        guard current(revision) else { return }
        suspending = nil
        if !suspended {
            // A stalled client can still finish its suspension later. Give
            // the replacement a new binding so that work cannot stop it.
            await invalidate()
            startIfNeeded()
            return
        }
        await client.start(expanded: expanded) { [weak self] values, status, attention in
            await self?.receive(values, status: status, attention: attention, revision: revision)
        }
        if self.revision == revision { starting = nil }
    }
    public func stop() async { invalidateSource(); enabled = false; published = false; await invalidate() }
    public func waitUntilStarted() async { await starting?.value }
}

/// Bounded observed local IDs exclude a cloud session already collected here.
/// This contains IDs only, never transcript text or authentication data.
public final class ClaudeCloudLocalSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()
    public init() {}
    public func update(_ activities: [SessionActivity]) {
        let ids = activities.filter { $0.provider == .claude && $0.claudeCloud == nil }.prefix(4096).compactMap(\.threadID)
        lock.lock(); values = Set(ids.map(ClaudeCloudProjectState.bareID)); lock.unlock()
    }
    public func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return values }
}
