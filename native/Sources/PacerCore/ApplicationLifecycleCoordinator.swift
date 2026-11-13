import Foundation

/// Hosts supply source identities and execute these actions through their IO
/// ports. Configuration differences, versions and business order live here.
public struct ApplicationLifecycleCoordinator: Sendable {
    public enum Phase: Equatable, Sendable { case cold, running, sleeping, stopped }
    public struct Configuration: Equatable, Sendable {
        public let enabled: Set<AgentProvider>
        public let sources: [AgentProvider: String]
        public let hasDemoSnapshot: Bool
        public init(enabled: Set<AgentProvider> = Set(HarnessRegistry.legacyIDs), sources: [AgentProvider: String] = [:], hasDemoSnapshot: Bool = false) {
            self.enabled = enabled; self.sources = sources; self.hasDemoSnapshot = hasDemoSnapshot
        }
    }
    public enum Action: Equatable, Sendable {
        case quota(AgentProvider, force: Bool, active: Bool = false)
        case activity(AgentProvider), discoverActivityRoutes(AgentProvider)
        case applications, clock, displayExpiry, pruneActivities, pruneHistory
        case resetSource(AgentProvider), updateActivityPolicy, cloud, balanceBinding, refilter
        case removeClaudeHooks, retryHostTracking, stopWatches, cancelHostTracking, cancelRemoteSetup
        case suspendSources, stopSources, demoSnapshot
    }
    public struct Plan: Sendable {
        public let actions: [Action]
        public let changedProviders: Set<AgentProvider>
        init(_ actions: [Action], changed: Set<AgentProvider> = []) { self.actions = actions; changedProviders = changed }
    }
    public struct Tick: Sendable {
        public let now: Date
        public let expanded: Bool
        public let codexConnected: Bool
        public let lastCodexDiscovery: Date
        public let lastRemoteDiscovery: Date
        public let lastClaudeDiscovery: Date
        public let deepseekRunning: Bool
        public init(now: Date, expanded: Bool, codexConnected: Bool, lastCodexDiscovery: Date, lastRemoteDiscovery: Date,
                    lastClaudeDiscovery: Date, deepseekRunning: Bool) {
            self.now = now; self.expanded = expanded; self.codexConnected = codexConnected
            self.lastCodexDiscovery = lastCodexDiscovery; self.lastRemoteDiscovery = lastRemoteDiscovery
            self.lastClaudeDiscovery = lastClaudeDiscovery; self.deepseekRunning = deepseekRunning
        }
    }
    public enum Resource: CaseIterable, Hashable, Sendable {
        case codexProgressFlag, codexQuota, claudeQuota, cloud, claudeActivity, deepseekActivity, remoteSetup, realtime
        case balance, web, claudeWeb, watches, reader, harnesses
    }
    public typealias Cleanup = @Sendable () async -> Void
    public private(set) var phase = Phase.cold
    public private(set) var configuration: Configuration
    public private(set) var revision: UInt64 = 0
    public var work = ApplicationWorkRegistry()
    private var versions: [AgentProvider: UInt64] = [:]
    private let demo: Bool
    private var started = false
    public init(demo: Bool = false, configuration: Configuration = .init()) {
        self.demo = demo; self.configuration = configuration
    }
    public var isSleeping: Bool { phase == .sleeping }
    public var isStopped: Bool { phase == .stopped }
    /// Cold models can accept observed fixtures before their host starts IO.
    public var acceptsObservedWork: Bool { !isSleeping && !isStopped }
    public func version(_ provider: AgentProvider) -> UInt64 { versions[provider, default: 0] }
    public func owns(_ ticket: ApplicationWorkRegistry.Ticket) -> Bool {
        work.owns(ticket) && acceptsObservedWork && ticket.version == (ticket.key.provider.map(version) ?? revision)
    }
    public mutating func invalidateSources(_ providers: Set<AgentProvider>) {
        guard !providers.isEmpty else { return }
        revision &+= 1
        // A batch read spans providers; it cannot retain its coalescing slot
        // after any constituent source changes.
        work.cancel(.init(.activity))
        for provider in providers {
            versions[provider, default: 0] &+= 1
            work.cancel(provider: provider)
        }
    }
    public mutating func seed(_ configuration: Configuration) { if phase == .cold, !started { self.configuration = configuration } }
    public mutating func start() -> Plan {
        guard !started, !isStopped else { return Plan([]) }
        started = true; phase = .running
        return Plan((demo ? [] : quotaActions(force: true) + activityActions()) +
            [.applications, .clock, .displayExpiry])
    }
    public mutating func settings(_ next: Configuration, explicitlyDisablesClaude: Bool = false, forceReset: Set<AgentProvider> = []) -> Plan {
        let old = configuration
        let configured = old.enabled.union(next.enabled).union(old.sources.keys).union(next.sources.keys)
        let changed = Set(configured.filter {
            old.enabled.contains($0) != next.enabled.contains($0) || old.sources[$0] != next.sources[$0]
        }).union(forceReset)
        configuration = next
        if next.hasDemoSnapshot { return Plan([.pruneActivities, .demoSnapshot, .applications]) }
        invalidateSources(changed)
        var actions: [Action] = [.pruneActivities]
        if !demo, old.enabled.contains(.claude), !next.enabled.contains(.claude), explicitlyDisablesClaude { actions.append(.removeClaudeHooks) }
        actions += changed.contains(.codex) ? [.resetSource(.codex)] : [.updateActivityPolicy, .discoverActivityRoutes(.codex)]
        actions += changed.contains(.claude) ? [.resetSource(.claude)] : [.activity(.claude)]
        actions.append(.cloud)
        actions += changed.contains(.deepseek) ? [.resetSource(.deepseek)] : [.activity(.deepseek)]
        actions += Self.activityOrder(changed.subtracting(HarnessRegistry.legacyIDs)).map(Action.resetSource)
        actions += [.balanceBinding, .refilter, .applications]
        return Plan(actions, changed: changed)
    }
    public func tick(_ input: Tick) -> Plan {
        var actions: [Action] = [.pruneActivities, .pruneHistory]
        guard acceptsObservedWork, !demo else { return Plan(actions) }
        actions += [AgentProvider.codex, .claude].filter { configuration.enabled.contains($0) }.map { .quota($0, force: false) }
        if configuration.enabled.contains(.codex), input.now.timeIntervalSince(input.lastCodexDiscovery) >= (input.codexConnected ? 120 : 60) {
            actions.append(.activity(.codex))
        }
        if configuration.enabled.contains(.codex), input.now.timeIntervalSince(input.lastRemoteDiscovery) >= 30 { actions.append(.discoverActivityRoutes(.codex)) }
        if configuration.enabled.contains(.claude), input.now.timeIntervalSince(input.lastClaudeDiscovery) >= 30 { actions.append(.discoverActivityRoutes(.claude)) }
        if configuration.enabled.contains(.deepseek) { actions.append(.quota(.deepseek, force: false, active: input.expanded || input.deepseekRunning)) }
        return Plan(actions)
    }
    public mutating func prepareForSleep() -> Plan {
        guard !isStopped, !isSleeping else { return Plan([]) }
        phase = .sleeping; invalidateSources(configuration.enabled.union(configuration.sources.keys)); work.cancel()
        return Plan([.stopWatches, .cancelHostTracking, .cancelRemoteSetup, .suspendSources])
    }
    public mutating func resume() -> Plan {
        guard !isStopped else { return Plan([]) }
        phase = .running
        return Plan([.displayExpiry, .retryHostTracking] + quotaActions(force: true) +
            activityActions())
    }
    public mutating func shutdown() -> Plan {
        guard !isStopped else { return Plan([]) }
        phase = .stopped; invalidateSources(configuration.enabled.union(configuration.sources.keys)); work.cancel()
        return Plan([.stopWatches, .cancelHostTracking, .cancelRemoteSetup, .stopSources])
    }
    private func quotaActions(force: Bool) -> [Action] {
        HarnessRegistry.descriptors.filter { $0.hasQuotaDisplay && configuration.enabled.contains($0.id) }.map { .quota($0.id, force: force) }
    }
    private func activityActions() -> [Action] {
        (configuration.enabled.contains(.codex) ? [.activity(.codex), .discoverActivityRoutes(.codex)] : []) +
            Self.activityOrder(configuration.enabled.subtracting([.codex])).map(Action.activity)
    }
    private static func activityOrder(_ providers: Set<AgentProvider>) -> [AgentProvider] {
        let legacy = HarnessRegistry.legacyIDs
        return legacy.filter(providers.contains) + providers.subtracting(legacy).sorted { $0.rawValue < $1.rawValue }
    }
    @discardableResult public static func cleanup(_ operations: [Resource: Cleanup], activity: [Cleanup] = [],
                                                   deadline: ShutdownDeadline = ShutdownDeadline()) async -> Bool {
        await deadline.perform(Resource.allCases.compactMap { operations[$0] } + activity)
    }
}
