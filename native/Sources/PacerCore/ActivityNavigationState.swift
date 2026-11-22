import Foundation

/// One captured open. A later result can acknowledge only these endings and
/// the same observed descendant chains, in the same reader scope.
public struct ActivityNavigationOperation: Sendable {
    public struct Descendant: Sendable {
        public let activity: SessionActivity
        public let token: CompletionInbox.AcknowledgmentToken
        public let source: CompletionInbox.SourceToken
        public let ancestors: [SessionActivity]
    }
    public struct Result: Sendable {
        public let accepted: Bool
        public let removed: [SessionActivity]
        public let failure: String?
    }
    public let id: UUID
    public let activity: SessionActivity
    public let target: SessionActivity
    public let version: UInt64
    public let source: CompletionInbox.SourceToken
    public let acknowledgment: CompletionInbox.AcknowledgmentToken?
    public let descendants: [Descendant]
    public let scope: String?

    public init(activity: SessionActivity, target: SessionActivity, version: UInt64,
                activities: [SessionActivity], inbox: CompletionInbox, scope: String? = nil, requests: [PendingAttentionRequest] = [],
                group: ActivityTaskGroup? = nil) {
        id = UUID(); self.activity = activity; self.target = target; self.version = version; self.scope = scope
        source = inbox.sourceToken(for: activity)
        let token = inbox.acknowledgment(for: activity)
        let group = group ?? token.flatMap { _ in Self.group(containing: activity, in: activities) }
        let canClearUnconfirmed = group?.canClearUnconfirmed(requests: requests) == true
        acknowledgment = activity.phase == .unknown && !canClearUnconfirmed ? nil : token
        if acknowledgment != nil, let group, activity.parentThreadID == nil, Self.sameLifecycle(group.primary, activity) {
            descendants = Self.descendants(for: activity, group: group, inbox: inbox, includeUnconfirmed: canClearUnconfirmed)
        } else { descendants = [] }
    }
    private static func group(containing activity: SessionActivity, in activities: [SessionActivity]) -> ActivityTaskGroup? {
        let id = activity.canonicalized().id
        return ActivityTaskGroup.make(activities).first { $0.members.contains { $0.id == id } }
    }
    public static func sameLifecycle(_ left: SessionActivity, _ right: SessionActivity) -> Bool {
        left.canonicalized().id == right.canonicalized().id && left.provider == right.provider && left.sourceHostID == right.sourceHostID &&
            left.parentThreadID == right.parentThreadID && left.turnID == right.turnID && left.turnStartedAt == right.turnStartedAt &&
            left.phase == right.phase && left.phaseChangedAt == right.phaseChangedAt && left.turnFailed == right.turnFailed
    }
    private static func descendants(for parent: SessionActivity, group: ActivityTaskGroup, inbox: CompletionInbox, includeUnconfirmed: Bool) -> [Descendant] {
        func eligible(_ member: SessionActivity) -> Bool {
            [.completed, .interrupted].contains(member.phase) || (includeUnconfirmed && inbox.isClearableUnconfirmed(member))
        }
        let source = inbox.sourceToken(for: parent)
        let members = Dictionary(group.members.map { ($0.canonicalized().id, $0) }, uniquingKeysWith: { _, latest in latest })
        return group.members.compactMap { child in
            guard child.id != parent.id, !child.isInternalReview, child.provider == parent.provider, child.sourceHostID == parent.sourceHostID,
                  eligible(child), child.phase == .unknown || (child.turnID != nil && child.turnStartedAt != nil),
                  let token = inbox.acknowledgment(for: child), inbox.sourceToken(for: child) == source else { return nil }
            var current = child, ancestors: [SessionActivity] = [], seen = Set<String>()
            for _ in 0..<64 {
                guard seen.insert(current.id).inserted, let parentSession = current.parentThreadID,
                      let ancestor = members[current.provider.activityID(sessionID: parentSession, sourceHostID: current.sourceHostID)],
                      ancestor.provider == parent.provider, ancestor.sourceHostID == parent.sourceHostID,
                      eligible(ancestor) else { return nil }
                ancestors.append(ancestor)
                if ancestor.id == parent.id { return Descendant(activity: child, token: token, source: source, ancestors: ancestors) }
                current = ancestor
            }
            return nil
        }
    }
    public func isCurrent(version: UInt64, active: Bool, inbox: CompletionInbox, scope: String? = nil) -> Bool {
        active && self.version == version && inbox.isCurrentSource(source) && (activity.claudeCloud == nil || self.scope == scope)
    }
    public func complete(_ outcome: ActivityOpenOutcome, version: UInt64, active: Bool, activities: inout [SessionActivity],
                         inbox: inout CompletionInbox, remoteSourceIDs: Set<String> = [], scope: String? = nil, requests: [PendingAttentionRequest] = []) -> Result {
        guard isCurrent(version: version, active: active, inbox: inbox, scope: scope) else {
            return .init(accepted: false, removed: [], failure: nil)
        }
        if case .failed(let failure) = outcome { return .init(accepted: true, removed: [], failure: failure) }
        guard outcome == .openedConversation else { return .init(accepted: true, removed: [], failure: nil) }
        if activity.parentThreadID != nil, activity.provider == .claude || activity.launchedByEmbeddingApp {
            guard let current = activities.first(where: { $0.canonicalized().id == activity.canonicalized().id }),
                  Self.sameLifecycle(current, activity),
                  let currentTarget = ActivityNavigationTarget.resolve(current, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs),
                  currentTarget.canonicalized().id == target.canonicalized().id else {
                return .init(accepted: false, removed: [], failure: nil)
            }
        }
        var removed: [SessionActivity] = []
        let checksUnconfirmed = acknowledgment != nil && (activity.phase == .unknown || descendants.contains { $0.activity.phase == .unknown })
        let currentGroup = checksUnconfirmed ? Self.group(containing: activity, in: activities) : nil
        let canClearUnconfirmed = currentGroup?.canClearUnconfirmed(requests: requests) == true
        if activity.phase == .unknown, !canClearUnconfirmed || currentGroup?.members.contains(where: { Self.sameLifecycle($0, activity) }) != true {
            return .init(accepted: true, removed: [], failure: nil)
        }
        if acknowledgment.map({ inbox.dismiss(activity, acknowledging: $0) }) == true {
            removed.append(activity)
            let current = Dictionary(activities.map { ($0.canonicalized().id, $0) }, uniquingKeysWith: { _, latest in latest })
            for descendant in descendants {
                guard descendant.activity.phase != .unknown || canClearUnconfirmed, inbox.isCurrentSource(descendant.source),
                      let child = current[descendant.activity.canonicalized().id], Self.sameLifecycle(child, descendant.activity),
                      descendant.ancestors.allSatisfy({ ancestor in current[ancestor.canonicalized().id].map { Self.sameLifecycle($0, ancestor) } ?? false }),
                      inbox.dismiss(descendant.activity, acknowledging: descendant.token) else { continue }
                removed.append(descendant.activity)
            }
            activities.removeAll { value in removed.contains { Self.sameLifecycle(value, $0) } }
        }
        return .init(accepted: true, removed: removed, failure: nil)
    }
}

/// Hosts run the opener and schedule the published monotonic expiry. Core
/// owns single-flight, captured acknowledgments and replacement error tokens.
public struct ActivityNavigationState: Sendable {
    /// Use the same high-resolution monotonic domain as deadline scheduling.
    /// ProcessInfo.systemUptime is quantized on Windows and can still precede
    /// a short error deadline when its timer has already fired.
    public static var monotonicNow: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    public struct Failure: Equatable, Sendable {
        public let id: UUID
        public let message: String
        public let deadline: TimeInterval
    }
    private var operations: [String: ActivityNavigationOperation] = [:]
    public private(set) var failure: Failure?
    public var openingActivityIDs: Set<String> { Set(operations.keys) }
    public init() {}
    public mutating func begin(activity: SessionActivity, target: SessionActivity, version: UInt64, activities: [SessionActivity],
                               inbox: CompletionInbox, active: Bool, scope: String? = nil, requests: [PendingAttentionRequest] = []) -> ActivityNavigationOperation? {
        guard active, operations[activity.id] == nil else { return nil }
        let operation = ActivityNavigationOperation(activity: activity, target: target, version: version, activities: activities, inbox: inbox, scope: scope, requests: requests)
        operations[activity.id] = operation; failure = nil
        return operation
    }
    public func owns(_ operation: ActivityNavigationOperation) -> Bool { operations[operation.activity.id]?.id == operation.id }
    public mutating func abandon(_ operation: ActivityNavigationOperation) {
        if owns(operation) { operations.removeValue(forKey: operation.activity.id) }
    }
    public mutating func cancel(provider: AgentProvider? = nil) {
        operations = operations.filter { provider != nil && $0.value.activity.provider != provider }
        failure = nil
    }
    public mutating func complete(_ operation: ActivityNavigationOperation, outcome: ActivityOpenOutcome, version: UInt64, active: Bool,
                                  activities: inout [SessionActivity], inbox: inout CompletionInbox, remoteSourceIDs: Set<String> = [],
                                  scope: String? = nil, now: TimeInterval, errorDuration: TimeInterval = TaskRowInteraction.navigationErrorDuration,
                                  requests: [PendingAttentionRequest] = []) -> ActivityNavigationOperation.Result? {
        guard owns(operation) else { return nil }
        abandon(operation)
        let result = operation.complete(outcome, version: version, active: active, activities: &activities, inbox: &inbox,
            remoteSourceIDs: remoteSourceIDs, scope: scope, requests: requests)
        if let message = result.failure { showFailure(message, now: now, duration: errorDuration) }
        return result
    }
    @discardableResult public mutating func showFailure(_ message: String, now: TimeInterval,
                                                        duration: TimeInterval = TaskRowInteraction.navigationErrorDuration) -> Failure {
        let duration = duration.isFinite ? max(0, duration) : TaskRowInteraction.navigationErrorDuration
        let value = Failure(id: UUID(), message: message, deadline: now + duration)
        failure = value; return value
    }
    public mutating func clearFailure() { failure = nil }
    @discardableResult public mutating func expireFailure(_ id: UUID, now: TimeInterval) -> Bool {
        guard let failure, failure.id == id, now >= failure.deadline else { return false }
        self.failure = nil; return true
    }
}
