import Foundation

package struct HarnessSourceKey: Hashable, Sendable {
    package let provider: AgentProvider
    package let stream: String
    package let scope: String

    package init(provider: AgentProvider, stream: String, scope: String) {
        self.provider = provider
        self.stream = stream
        self.scope = scope
    }
}

/// A full observation can repair a gap. A delta must follow the last accepted
/// sequence, so a missed removal cannot silently leave a task on screen.
package struct HarnessActivityBatch: Sendable {
    package enum Change: Sendable {
        case baseline(HarnessActivity)
        case snapshot(HarnessActivity)
        case delta(HarnessActivityDelta)
        case health(HarnessSourceStatus)
    }

    package let source: HarnessSourceKey
    package let generation: UInt64
    package let sequence: UInt64
    package let change: Change

    package init(source: HarnessSourceKey, generation: UInt64, sequence: UInt64, change: Change) {
        self.source = source
        self.generation = generation
        self.sequence = sequence
        self.change = change
    }
}

package struct HarnessActivityDelta: Sendable {
    package enum UsageChange: Sendable { case unchanged, replace(HarnessUsage?) }
    package var activities: [SessionActivity] = []
    package var removedActivityIDs: Set<String> = []
    package var requests: [PendingAttentionRequest] = []
    package var removedRequestIDs: Set<String> = []
    package var status: HarnessSourceStatus?
    package var conversationURLs: [String: URL]?
    package var usage: UsageChange = .unchanged
}

package struct HarnessActivityStore: Sendable {
    package enum Result: Equatable { case accepted, stale, needsSnapshot, invalid }
    private struct State: Sendable {
        var sequence: UInt64
        var activity: HarnessActivity
    }
    private var generations: [AgentProvider: UInt64] = [:]
    private var sources: [HarnessSourceKey: State] = [:]
    private var retired: [HarnessSourceKey: UInt64] = [:]
    private var unconfirmed: Set<HarnessSourceKey> = []
    private static let maximumSources = 512
    private static let maximumRowsPerSource = 512

    package init() {}

    package mutating func bind(_ provider: AgentProvider, generation: UInt64) {
        guard generations[provider] != generation else { return }
        remove(provider)
        generations[provider] = generation
    }

    package mutating func remove(_ provider: AgentProvider) {
        generations.removeValue(forKey: provider)
        sources = sources.filter { $0.key.provider != provider }
        retired = retired.filter { $0.key.provider != provider }
        unconfirmed = unconfirmed.filter { $0.provider != provider }
    }

    package mutating func removeAll() {
        generations.removeAll()
        sources.removeAll()
        retired.removeAll()
        unconfirmed.removeAll()
    }

    package mutating func retire(_ key: HarnessSourceKey) {
        if let old = sources.removeValue(forKey: key) { retired[key] = old.sequence }
        unconfirmed.remove(key)
    }

    package mutating func accept(_ batch: HarnessActivityBatch) -> Result {
        let key = batch.source
        guard generations[key.provider] == batch.generation, batch.sequence > 0 else { return .stale }
        guard !key.stream.isEmpty, key.stream.utf8.count <= 128, !key.scope.isEmpty, key.scope.utf8.count <= 128 else { return .invalid }
        let old = sources[key]
        if batch.sequence <= (old?.sequence ?? retired[key] ?? 0) { return .stale }
        if old == nil, retired[key] == nil, sources.count + retired.count >= Self.maximumSources { return .invalid }

        var activity: HarnessActivity
        switch batch.change {
        case .baseline(var value):
            for index in value.activities.indices { value.activities[index].suppressHistoricalCompletionNotifications() }
            value.requests = value.requests.map { $0.suppressingNotice() }
            activity = value
        case .snapshot(let value):
            guard old != nil else { return .needsSnapshot }
            activity = value
        case .delta(let delta):
            guard let old, !unconfirmed.contains(key), batch.sequence - old.sequence == 1 else {
                if old != nil { unconfirmed.insert(key) }
                return .needsSnapshot
            }
            guard delta.removedActivityIDs.count <= Self.maximumRowsPerSource,
                  delta.removedRequestIDs.count <= Self.maximumRowsPerSource,
                  Self.valid(activities: delta.activities, requests: delta.requests, provider: key.provider) else { return .invalid }
            activity = old.activity
            activity.activities = Self.applying(delta.activities, to: activity.activities, removing: delta.removedActivityIDs)
            activity.requests = Self.applying(delta.requests, to: activity.requests, removing: delta.removedRequestIDs)
            if let status = delta.status { activity.status = status }
            if let urls = delta.conversationURLs { activity.conversationURLs = urls }
            if case .replace(let usage) = delta.usage { activity.usage = usage }
        case .health(let status):
            guard let old, !unconfirmed.contains(key), batch.sequence - old.sequence == 1 else {
                if old != nil { unconfirmed.insert(key) }
                return .needsSnapshot
            }
            activity = old.activity
            activity.status = status
        }
        guard Self.valid(activities: activity.activities, requests: activity.requests, provider: key.provider) else { return .invalid }
        switch batch.change {
        case .baseline, .snapshot:
            activity.activities.sort { $0.id < $1.id }
            activity.requests.sort { $0.id < $1.id }
        case .delta, .health: break
        }
        sources[key] = State(sequence: batch.sequence, activity: activity)
        retired.removeValue(forKey: key)
        unconfirmed.remove(key)
        return .accepted
    }

    package func snapshots() -> [HarnessSourceKey: HarnessActivity] { sources.mapValues(\.activity) }
    package func snapshot(for source: HarnessSourceKey) -> HarnessActivity? { sources[source]?.activity }

    package func projection(for provider: AgentProvider) -> HarnessActivity? {
        let ordered = sources.filter { $0.key.provider == provider }.sorted {
            ($0.key.stream, $0.key.scope) < ($1.key.stream, $1.key.scope)
        }.map { $0.value.activity }
        guard !ordered.isEmpty else { return nil }
        let rows = Dictionary(ordered.flatMap(\.activities).map { ($0.id, $0) }) { current, next in
            let currentAt = current.phaseChangedAt ?? current.lastObserved ?? .distantPast
            let nextAt = next.phaseChangedAt ?? next.lastObserved ?? .distantPast
            return nextAt > currentAt ? next : current
        }
        let requests = Dictionary(ordered.flatMap(\.requests).map { ($0.id, $0) }) { current, next in
            next.detectedAt > current.detectedAt ? next : current
        }
        let statuses = ordered.compactMap(\.status)
        var value = HarnessActivity(activities: rows.values.sorted { $0.id < $1.id }, requests: requests.values.sorted { $0.id < $1.id },
                                    status: statuses.contains(.ready) ? .ready : statuses.first)
        value.conversationURLs = ordered.reduce(into: [:]) { urls, source in
            urls.merge(source.conversationURLs) { current, _ in current }
        }
        value.scope = ordered.count == 1 ? ordered.first?.scope : nil
        value.usage = ordered.compactMap(\.usage).max { $0.measuredAt < $1.measuredAt }
        return value
    }

    private static func valid(activities: [SessionActivity], requests: [PendingAttentionRequest], provider: AgentProvider) -> Bool {
        activities.count <= maximumRowsPerSource && requests.count <= maximumRowsPerSource &&
            activities.allSatisfy { $0.provider == provider } && requests.allSatisfy { $0.provider == provider } &&
            Set(activities.map(\.id)).count == activities.count && Set(requests.map(\.id)).count == requests.count
    }

    private static func applying<Row: Identifiable>(_ changes: [Row], to previous: [Row], removing: Set<String>) -> [Row] where Row.ID == String {
        var rows = Dictionary(uniqueKeysWithValues: previous.lazy.filter { !removing.contains($0.id) }.map { ($0.id, $0) })
        for row in changes { rows[row.id] = row }
        return rows.values.sorted { $0.id < $1.id }
    }
}
