import Foundation

/// Applications are opaque host facts. Core retains them while referenced and
/// owns scan cadence, cancellation identity and the single pending retry.
public struct HostApplicationTrackingState<Application: Equatable & Sendable>: Sendable {
    public struct Scan: Equatable, Sendable {
        public let id: UUID
        public let provider: AgentProvider
        public let version: UInt64
        public let sessions: Set<String>
    }
    public struct Retry: Equatable, Sendable {
        public let id: UUID
        public let provider: AgentProvider
        public let version: UInt64
        public let deadline: Date
        public let delay: TimeInterval
    }
    public enum Decision: Sendable { case idle, scan(Scan), retry(Retry) }
    public struct Completion: Sendable { public let owned: Bool; public let accepted: Bool; public let changed: Bool }
    private struct ProviderState: Sendable {
        var attempts: Set<String> = []
        var scannedAt = Date.distantPast
        var scan: Scan?
        var retry: Retry?
    }
    private var providers: [AgentProvider: ProviderState] = [:]
    public private(set) var applications: [AgentProvider: [String: Application]] = [:]
    public init() {}
    private static func session(for activity: SessionActivity, activities: [SessionActivity], inbox: CompletionInbox, remoteSourceIDs: Set<String>) -> String? {
        guard activity.sourceHostID == nil, activity.provider == .claude || activity.launchedByEmbeddingApp else { return nil }
        return ActivityNavigationTarget.resolve(activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs)?.threadID?.lowercased()
    }
    public func application(for activity: SessionActivity, activities: [SessionActivity], inbox: CompletionInbox, remoteSourceIDs: Set<String> = []) -> Application? {
        guard let session = Self.session(for: activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs) else { return nil }
        return applications[activity.provider]?[session]
    }
    public func labels(for values: [SessionActivity], activities: [SessionActivity], inbox: CompletionInbox, remoteSourceIDs: Set<String> = [],
                       label: (Application) -> TaskHostLabel) -> [String: TaskHostLabel] {
        var result: [String: TaskHostLabel] = [:]
        for activity in values {
            if let application = application(for: activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs) {
                let value = label(application); result[activity.id] = value; result[activity.canonicalized().id] = value
            }
        }
        return result
    }

    public mutating func prepare(provider: AgentProvider, references: [SessionActivity], activities: [SessionActivity], inbox: CompletionInbox,
                                 remoteSourceIDs: Set<String> = [], version: UInt64, now: Date, active: Bool, demo: Bool,
                                 refreshRunning: Bool = true) -> Decision {
        var state = providers[provider] ?? ProviderState()
        defer { providers[provider] = state }
        var referenced = Set<String>(), wanted = Set<String>()
        for activity in references where activity.provider == provider && activity.sourceHostID == nil && !activity.isIgnoredCodexSession {
            guard let session = Self.session(for: activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs) else { continue }
            referenced.insert(session)
            if !state.attempts.contains(session) || (refreshRunning && ![.completed, .interrupted].contains(activity.phase)) { wanted.insert(session) }
        }
        state.attempts.formIntersection(referenced)
        if applications[provider]?.keys.contains(where: { !referenced.contains($0) }) == true {
            applications[provider] = applications[provider]?.filter { referenced.contains($0.key) }
        }
        guard active, !demo, !wanted.isEmpty, state.scan == nil else { return .idle }
        let wait = 2 - now.timeIntervalSince(state.scannedAt)
        if wait > 0 {
            guard state.retry == nil, !wanted.isSubset(of: state.attempts) else { return .idle }
            let retry = Retry(id: UUID(), provider: provider, version: version, deadline: now.addingTimeInterval(wait), delay: wait)
            state.retry = retry; return .retry(retry)
        }
        state.scannedAt = now; state.attempts.formUnion(wanted)
        let scan = Scan(id: UUID(), provider: provider, version: version, sessions: wanted)
        state.scan = scan; return .scan(scan)
    }
    public mutating func finishRetry(_ retry: Retry, version: UInt64, active: Bool, cancelled: Bool = false) -> Bool {
        guard providers[retry.provider]?.retry?.id == retry.id else { return false }
        providers[retry.provider]?.retry = nil
        return !cancelled && active && retry.version == version
    }
    public mutating func complete(_ scan: Scan, found: [String: Application], version: UInt64, active: Bool, cancelled: Bool = false) -> Completion {
        guard providers[scan.provider]?.scan?.id == scan.id else { return .init(owned: false, accepted: false, changed: false) }
        providers[scan.provider]?.scan = nil
        guard !cancelled, active, scan.version == version else { return .init(owned: true, accepted: false, changed: false) }
        return .init(owned: true, accepted: true, changed: record(found.filter { scan.sessions.contains($0.key.lowercased()) }, provider: scan.provider))
    }
    @discardableResult public mutating func record(_ found: [String: Application], provider: AgentProvider) -> Bool {
        var next = applications[provider] ?? [:]
        for (session, application) in found { next[session.lowercased()] = application }
        guard next != applications[provider] else { return false }
        applications[provider] = next; return true
    }
    public mutating func cancel(provider: AgentProvider? = nil, clearApplications: Bool = false) {
        for key in AgentProvider.allCases where provider == nil || key == provider {
            providers[key] = ProviderState()
            if clearApplications { applications[key] = [:] }
        }
    }
}
