import Foundation

/// Applications are opaque host facts. Core retains them while referenced and
/// owns scan cadence, cancellation identity and the single pending retry.
public struct HostApplicationTrackingState<Application: Equatable & Sendable>: Sendable {
    public struct Scan: Equatable, Sendable {
        public let id: UUID
        public let provider: AgentProvider
        public let version: UInt64
        fileprivate let generations: [String: UUID]
        public var sessions: Set<String> { Set(generations.keys) }
    }
    public struct Retry: Equatable, Sendable {
        public let id: UUID
        public let provider: AgentProvider
        public let version: UInt64
        public let deadline: Date
        public let delay: TimeInterval
    }
    public enum Decision: Sendable { case idle, cancelRetry, scan(Scan), retry(Retry) }
    public struct Completion: Sendable { public let owned: Bool; public let accepted: Bool; public let changed: Bool }
    private struct Session: Sendable {
        let generation = UUID()
        var launch: Date?
        var firstAttempt: Date?
        var attempts = 0
        var confirmed = false

        mutating func observeLaunch(_ date: Date) {
            // A first launch record can arrive late from history. A scan that
            // began after that launch already had a chance to see its holder.
            if launch != nil || firstAttempt.map({ date > $0 }) == true {
                self = Session(launch: date)
            } else {
                launch = date
            }
        }

        func nextAttempt(retryWhileRunning: Bool) -> Date? {
            guard !confirmed else { return nil }
            if attempts == 0 { return .distantPast }
            guard retryWhileRunning, let firstAttempt else { return nil }
            switch attempts {
            case 1: return firstAttempt.addingTimeInterval(2)
            case 2: return firstAttempt.addingTimeInterval(10)
            default: return nil
            }
        }
    }
    private struct Reference {
        var launch: Date?
        var running = false
    }
    private struct ProviderState: Sendable {
        var sessions: [String: Session] = [:]
        var scannedAt = Date.distantPast
        var scan: Scan?
        var retry: Retry?
    }
    private var providers: [AgentProvider: ProviderState] = [:]
    public private(set) var applications: [AgentProvider: [String: Application]] = [:]
    public init() {}
    private static func target(for activity: SessionActivity, activities: [SessionActivity], inbox: CompletionInbox,
                               remoteSourceIDs: Set<String>) -> SessionActivity? {
        guard activity.sourceHostID == nil, activity.provider == .claude || activity.launchedByEmbeddingApp else { return nil }
        return ActivityNavigationTarget.resolve(activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs)
    }
    public func application(for activity: SessionActivity, activities: [SessionActivity], inbox: CompletionInbox, remoteSourceIDs: Set<String> = []) -> Application? {
        guard let target = Self.target(for: activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs),
              let session = target.threadID?.lowercased() else { return nil }
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
                                 remoteSourceIDs: Set<String> = [], version: UInt64, now: Date, active: Bool, demo: Bool) -> Decision {
        var state = providers[provider] ?? ProviderState()
        defer { providers[provider] = state }
        var referenced: [String: Reference] = [:]
        for activity in references where activity.provider == provider && activity.sourceHostID == nil && !activity.isIgnoredCodexSession {
            guard let target = Self.target(for: activity, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs),
                  let session = target.threadID?.lowercased() else { continue }
            var reference = referenced[session] ?? Reference()
            if let launch = target.hostLaunchAt, launch > (reference.launch ?? .distantPast) { reference.launch = launch }
            if activity.phase == .running || activity.phase == .waitingForInput { reference.running = true }
            referenced[session] = reference
        }
        if state.sessions.keys.contains(where: { referenced[$0] == nil }) {
            state.sessions = state.sessions.filter { referenced[$0.key] != nil }
        }
        if applications[provider]?.keys.contains(where: { referenced[$0] == nil }) == true {
            applications[provider] = applications[provider]?.filter { referenced[$0.key] != nil }
        }
        let earliestScan = state.scannedAt.addingTimeInterval(2)
        var ready: [String: UUID] = [:]
        var nextDeadline: Date?
        for (id, reference) in referenced {
            if state.sessions[id] == nil { state.sessions[id] = Session(launch: reference.launch) }
            if let launch = reference.launch, launch > (state.sessions[id]?.launch ?? .distantPast) {
                state.sessions[id]?.observeLaunch(launch)
            }
            guard let session = state.sessions[id], let attempt = session.nextAttempt(retryWhileRunning: reference.running) else { continue }
            let deadline = max(earliestScan, attempt)
            if deadline <= now { ready[id] = session.generation }
            else { nextDeadline = min(nextDeadline ?? deadline, deadline) }
        }
        guard active, !demo, state.scan == nil, !ready.isEmpty || nextDeadline != nil else {
            guard state.retry != nil else { return .idle }
            state.retry = nil
            return .cancelRetry
        }
        if !ready.isEmpty {
            for id in ready.keys where state.sessions[id]?.attempts == 0 { state.sessions[id]?.firstAttempt = now }
            state.scannedAt = now
            state.retry = nil
            let scan = Scan(id: UUID(), provider: provider, version: version, generations: ready)
            state.scan = scan
            return .scan(scan)
        }
        guard let deadline = nextDeadline, state.retry?.deadline != deadline || state.retry?.version != version else { return .idle }
        let retry = Retry(id: UUID(), provider: provider, version: version, deadline: deadline, delay: deadline.timeIntervalSince(now))
        state.retry = retry
        return .retry(retry)
    }
    public mutating func finishRetry(_ retry: Retry, version: UInt64, active: Bool, cancelled: Bool = false) -> Bool {
        guard providers[retry.provider]?.retry?.id == retry.id else { return false }
        providers[retry.provider]?.retry = nil
        return !cancelled && active && retry.version == version
    }
    public mutating func complete(_ scan: Scan, found: [String: Application], version: UInt64, active: Bool, cancelled: Bool = false) -> Completion {
        guard var state = providers[scan.provider], state.scan?.id == scan.id else { return .init(owned: false, accepted: false, changed: false) }
        state.scan = nil
        guard !cancelled, active, scan.version == version else {
            providers[scan.provider] = state
            return .init(owned: true, accepted: false, changed: false)
        }
        let current = scan.generations.filter { state.sessions[$0.key]?.generation == $0.value }
        for id in current.keys { state.sessions[id]?.attempts += 1 }
        providers[scan.provider] = state
        let changed = record(found.filter { current[$0.key.lowercased()] != nil }, provider: scan.provider)
        return .init(owned: true, accepted: true, changed: changed)
    }
    @discardableResult public mutating func record(_ found: [String: Application], provider: AgentProvider) -> Bool {
        guard !found.isEmpty else { return false }
        var next = applications[provider] ?? [:]
        for (session, application) in found {
            let id = session.lowercased()
            next[id] = application
            providers[provider, default: ProviderState()].sessions[id, default: Session()].confirmed = true
        }
        guard next != applications[provider] else { return false }
        applications[provider] = next; return true
    }
    public mutating func cancel(provider: AgentProvider? = nil, clearApplications: Bool = false) {
        for key in AgentProvider.allCases where provider == nil || key == provider {
            if clearApplications {
                providers[key] = nil
                applications[key] = [:]
            } else {
                providers[key]?.scan = nil
                providers[key]?.retry = nil
                providers[key]?.scannedAt = .distantPast
            }
        }
    }
}
