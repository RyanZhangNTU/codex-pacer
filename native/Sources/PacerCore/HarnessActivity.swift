import Foundation

/// A provider's bounded projection after reconciling its own logs and streams.
public struct HarnessActivity: Equatable, Sendable {
    public var activities: [SessionActivity]
    public var requests: [PendingAttentionRequest]
    public var status: HarnessSourceStatus?
    package var scope: String?
    package var conversationURLs: [String: URL] = [:]
    package var usage: HarnessUsage?

    public init(activities: [SessionActivity] = [], requests: [PendingAttentionRequest] = [], status: HarnessSourceStatus? = nil) {
        self.activities = activities
        self.requests = requests
        self.status = status
    }
}

/// A provider's own units, separate from quota windows and currency.
public struct HarnessUsage: Codable, Equatable, Sendable {
    public let contextUsed: Int?
    public let contextCapacity: Int?
    public let sessionCredits: Double?
    public let measuredAt: Date
}

public enum HarnessSourceStatus: String, Equatable, Sendable {
    case ready, missing, incompatible, unavailable
}

/// A module can use several transports behind one activity adapter.
package struct HarnessActivityAdapter<Run: Sendable>: Sendable {
    package enum StopReason: Equatable, Sendable { case reset, sleep, shutdown }
    package typealias Stop = @Sendable (ShutdownDeadline, StopReason, (any LocalHarnessMonitor)?) async -> Void
    package struct SnapshotContext: Sendable {
        package let observedAt: Date
        package let discover: Bool
        package init(observedAt: Date, discover: Bool) {
            self.observedAt = observedAt; self.discover = discover
        }
    }

    package let start: Run
    package let reset: Run
    package let discoverRoutes: Run?
    package let refresh: (@Sendable () async -> Void)?
    package let updatePolicy: @Sendable (ActivityRefreshPolicy, Bool) async -> Void
    package let stop: Stop
    package var collect: (@Sendable (SnapshotContext) async -> Void)?

    package init(start: Run, reset: Run, discoverRoutes: Run? = nil, refresh: (@Sendable () async -> Void)? = nil,
                 updatePolicy: @escaping @Sendable (ActivityRefreshPolicy, Bool) async -> Void,
                 stop: @escaping Stop, collect: (@Sendable (SnapshotContext) async -> Void)? = nil) {
        self.start = start; self.reset = reset; self.discoverRoutes = discoverRoutes
        self.refresh = refresh; self.updatePolicy = updatePolicy; self.stop = stop; self.collect = collect
    }

    package static func local(start: Run, reset: Run, monitor: @escaping @Sendable () async -> (any LocalHarnessMonitor)?) -> Self {
        .init(start: start, reset: reset, refresh: { await monitor()?.refresh() },
              updatePolicy: { policy, _ in await monitor()?.updatePolicy(policy) },
              stop: { _, _, detached in await detached?.stop() })
    }
}

/// The hosts register their I/O closures once. Settings, refresh, and cleanup
/// dispatch through the same table for every provider.
package struct HarnessActivityAdapters<Run: Sendable>: Sendable {
    package typealias Adapter = HarnessActivityAdapter<Run>
    private let adapters: [AgentProvider: Adapter]

    package init(_ builtIn: [AgentProvider: Adapter], local: [LocalHarnessDefinition], makeLocal: (AgentProvider) -> Adapter) {
        var entries = builtIn
        for definition in local {
            let provider = definition.descriptor.id
            if entries[provider] == nil { entries[provider] = makeLocal(provider) }
        }
        adapters = entries
    }

    package subscript(provider: AgentProvider) -> Adapter? { adapters[provider] }

    package func cleanup(_ reason: Adapter.StopReason, deadline: ShutdownDeadline, detached: LocalHarnessMonitors)
        -> [ApplicationLifecycleCoordinator.Cleanup] {
        adapters.map { provider, adapter in
            let monitor = detached[provider], stop = adapter.stop
            return { await stop(deadline, reason, monitor) }
        }
    }
}

package struct LocalHarnessDefinition: Sendable {
    package let descriptor: HarnessDescriptor
    package let platforms: Set<HarnessPlatform>
    package let home: String
    package let dataFile: String
    package let windowsExecutables: [String]
    package var macApplicationNames: [String] = []
    package var macBundleIdentifiers: Set<String> = []
    package var macSigningOrganization: String?
    package var conversationScheme: String?
    package var progressConfigFile: String?
    package var progressRuleDirectory: String?
    package var progressConnection: LocalHarnessProgressSetup.ConnectionReader?
    let makeMonitor: @Sendable (LocalHarnessIO) -> any LocalHarnessMonitor

    package func defaultHome(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        userHome.appendingPathComponent(home, isDirectory: true)
    }

    package var homeEnvironmentKey: String { descriptor.id.rawValue.uppercased() + "_CONFIG_DIR" }
    package func resolveHome(override: String?, isAbsolute: (String) -> Bool) -> URL {
        guard let override, override.utf8.count <= 32 * 1024, isAbsolute(override),
              !override.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return defaultHome() }
        return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
}

package enum HarnessPlatform: Sendable, Hashable { case windows, macOS }

package struct LocalHarnessIO: Sendable {
    let files: any PlatformFileSystem
    let events: any ActivityFileEvents
    let now: @Sendable () -> Date

    package init(files: any PlatformFileSystem, events: any ActivityFileEvents, now: @escaping @Sendable () -> Date) {
        self.files = files; self.events = events; self.now = now
    }
}

package protocol LocalHarnessMonitor: Sendable {
    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping @Sendable (HarnessActivity) async -> Void) async
    func refresh() async
    func updatePolicy(_ policy: ActivityRefreshPolicy) async
    func stop() async
}

/// Converts complete local observations to ordered updates. A full projection
/// can be replayed for just this source if its consumer detects a gap.
package struct HarnessActivityFeed: Sendable {
    private let provider: AgentProvider
    private let generation: UInt64
    private let homeScope: String
    private var previous: HarnessActivity?
    private var sequence: UInt64 = 0

    package init(provider: AgentProvider, home: URL, generation: UInt64) {
        self.provider = provider
        self.generation = generation
        homeScope = CompletionDismissalStore.digest(["harness-home", provider.rawValue, home.standardizedFileURL.path])
    }

    package mutating func publish(_ value: HarnessActivity, replay: Bool = false) -> HarnessActivityBatch {
        sequence &+= 1
        let source = HarnessSourceKey(provider: provider, stream: "local", scope: value.scope ?? homeScope)
        let change: HarnessActivityBatch.Change
        if let previous, previous.scope == value.scope {
            if replay { change = .snapshot(value) }
            else {
                let rows = Dictionary(previous.activities.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
                let requests = Dictionary(previous.requests.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
                change = .delta(.init(
                    activities: value.activities.filter { rows[$0.id] != $0 },
                    removedActivityIDs: Set(rows.keys).subtracting(value.activities.map(\.id)),
                    requests: value.requests.filter { requests[$0.id] != $0 },
                    removedRequestIDs: Set(requests.keys).subtracting(value.requests.map(\.id)),
                    status: value.status, conversationURLs: value.conversationURLs == previous.conversationURLs ? nil : value.conversationURLs,
                    usage: value.usage == previous.usage ? .unchanged : .replace(value.usage)
                ))
            }
        } else { change = .baseline(value) }
        previous = value
        return .init(source: source, generation: generation, sequence: sequence, change: change)
    }
}

/// The host supplies platform I/O once. Each registered monitor owns only its source.
package struct LocalHarnessMonitors: Sendable {
    package let definitions: [LocalHarnessDefinition]
    private let byID: [AgentProvider: LocalHarnessDefinition]
    private let io: LocalHarnessIO
    private let budget: HarnessWatchBudget
    private var monitors: [AgentProvider: any LocalHarnessMonitor] = [:]

    package init(platform: HarnessPlatform, io: LocalHarnessIO, registered: [LocalHarnessDefinition] = HarnessRegistry.localHarnesses) {
        var seen = Set<AgentProvider>()
        definitions = registered.filter {
            $0.platforms.contains(platform) && !HarnessRegistry.legacyIDs.contains($0.descriptor.id) && seen.insert($0.descriptor.id).inserted
        }
        byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.descriptor.id, $0) })
        self.io = io
        budget = HarnessWatchBudget(maximum: 512, perProvider: min(36, max(1, 512 / max(1, definitions.count))))
    }

    package func definition(for id: AgentProvider) -> LocalHarnessDefinition? { byID[id] }
    package subscript(id: AgentProvider) -> (any LocalHarnessMonitor)? { monitors[id] }

    package mutating func monitor(for definition: LocalHarnessDefinition) -> any LocalHarnessMonitor {
        let id = definition.descriptor.id
        if let monitor = monitors[id] { return monitor }
        let events = HarnessWatchBudget.Events(provider: id, underlying: io.events, budget: budget)
        let monitor = definition.makeMonitor(.init(files: io.files, events: events, now: io.now))
        monitors[id] = monitor
        return monitor
    }

    package mutating func remove(_ id: AgentProvider) -> (any LocalHarnessMonitor)? { monitors.removeValue(forKey: id) }

    /// Keep registration and the shared handle budget while retiring the
    /// monitors. A resume can then create fresh instances while these stop.
    package mutating func detach() -> LocalHarnessMonitors {
        let old = self
        monitors.removeAll()
        return old
    }

}

/// Gives every registered local monitor its share of the platform watcher
/// handles, including Windows' buffer and macOS's descriptor for each watch.
package final class HarnessWatchBudget: @unchecked Sendable {
    package struct Events: ActivityFileEvents {
        let provider: AgentProvider
        let underlying: any ActivityFileEvents
        let budget: HarnessWatchBudget

        public func watch(_ url: URL, isDirectory: Bool,
                          changed: @escaping @Sendable (ActivityFileEvent) -> Void) -> (any ActivityFileWatch)? {
            guard budget.reserve(provider) else { return nil }
            guard let watch = underlying.watch(url, isDirectory: isDirectory, changed: changed) else {
                budget.release(provider); return nil
            }
            return Lease(provider: provider, watch: watch, budget: budget)
        }
    }

    private final class Lease: ActivityFileWatch, @unchecked Sendable {
        private let provider: AgentProvider
        private let budget: HarnessWatchBudget
        private let lock = NSLock()
        private var watch: (any ActivityFileWatch)?

        init(provider: AgentProvider, watch: any ActivityFileWatch, budget: HarnessWatchBudget) {
            self.provider = provider; self.watch = watch; self.budget = budget
        }
        func stop() {
            lock.lock(); let current = watch; watch = nil; lock.unlock()
            if let current { current.stop(); budget.release(provider) }
        }
        deinit { stop() }
    }

    private let maximum: Int
    private let perProvider: Int
    private let lock = NSLock()
    private var counts: [AgentProvider: Int] = [:]
    private var total = 0

    package init(maximum: Int, perProvider: Int) {
        self.maximum = maximum; self.perProvider = perProvider
    }
    private func reserve(_ provider: AgentProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard total < maximum, counts[provider, default: 0] < perProvider else { return false }
        counts[provider, default: 0] += 1; total += 1
        return true
    }
    private func release(_ provider: AgentProvider) {
        lock.lock(); defer { lock.unlock() }
        let remaining = counts[provider, default: 0] - 1
        counts[provider] = remaining > 0 ? remaining : nil
        total -= 1
    }
}

/// Both hosts use the same source ordering, scope changes and recovery rules.
/// Hosts decide when to redraw and which paths and file events to supply.
package struct HarnessActivitySources: Sendable {
    package struct Update: Sendable {
        package let activity: HarnessActivity
        package let scopeChanged: Bool
        package let needsSourceBinding: Bool
    }
    private struct Binding: Sendable {
        var feed: HarnessActivityFeed
        var source: HarnessSourceKey?
        var activity: HarnessActivity?
    }
    private var bindings: [AgentProvider: Binding] = [:]
    private var observations: [AgentProvider: HarnessActivity] = [:]
    private var store = HarnessActivityStore()

    package init() {}
    package subscript(provider: AgentProvider) -> HarnessActivity? { bindings[provider]?.activity ?? observations[provider] }
    /// Host collectors already reconcile their native inputs and supply a full
    /// observation. Use their lifecycle evidence and existing source limits.
    package mutating func replace(_ provider: AgentProvider, with snapshot: HarnessActivity) {
        observations[provider] = snapshot
    }
    package func isBound(_ provider: AgentProvider) -> Bool { bindings[provider] != nil }

    package mutating func bind(_ provider: AgentProvider, home: URL, generation: UInt64) {
        store.bind(provider, generation: generation)
        bindings[provider] = Binding(feed: .init(provider: provider, home: home, generation: generation))
    }

    package mutating func receive(_ provider: AgentProvider, snapshot: HarnessActivity) -> Update? {
        guard var binding = bindings[provider] else { return nil }
        let batch = binding.feed.publish(snapshot)
        let result = store.accept(batch)
        guard result == .accepted ||
            (result == .needsSnapshot && store.accept(binding.feed.publish(snapshot, replay: true)) == .accepted) else { return nil }
        let changed = binding.source.map { $0 != batch.source } ?? false
        let needsSourceBinding = binding.source == nil || changed
        if let previous = binding.source, changed { store.retire(previous) }
        guard let activity = store.snapshot(for: batch.source) else { return nil }
        binding.source = batch.source
        binding.activity = activity
        bindings[provider] = binding
        return Update(activity: activity, scopeChanged: changed, needsSourceBinding: needsSourceBinding)
    }

    package mutating func remove(_ provider: AgentProvider) {
        store.remove(provider)
        bindings.removeValue(forKey: provider)
        observations.removeValue(forKey: provider)
    }

    package mutating func detachLocalBindings() {
        store.removeAll()
        bindings.removeAll()
    }
}

/// Limit the number of generic rows sent to a host while preserving the full
/// shared state. Give each provider one slot before giving any a second.
package enum HarnessRowBudget {
    package static func select(activities: [SessionActivity], maximum: Int) -> Set<String> {
        guard maximum > 0 else { return [] }
        let grouped = Dictionary(grouping: activities, by: \.provider).mapValues { rows in
            rows.sorted {
                let l = priority($0), r = priority($1)
                if l != r { return l < r }
                let a = $0.lastObserved ?? .distantPast, b = $1.lastObserved ?? .distantPast
                return a != b ? a > b : $0.id < $1.id
            }
        }
        let providers = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        var selected = Set<String>(), index = 0
        while selected.count < maximum {
            var found = false
            for provider in providers {
                guard let rows = grouped[provider], rows.indices.contains(index) else { continue }
                found = true
                selected.insert(rows[index].id)
                if selected.count == maximum { return selected }
            }
            if !found { break }
            index += 1
        }
        return selected
    }

    private static func priority(_ activity: SessionActivity) -> Int {
        switch activity.phase {
        case .waitingForInput: 0
        case .running: 1
        case .completed, .interrupted: 2
        default: 3
        }
    }
}
