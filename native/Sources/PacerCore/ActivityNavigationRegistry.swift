import Foundation

public struct ActivityNavigationLink: Codable, Equatable, Sendable {
    public let activityID: String, provider: String, context: String
    public init(activityID: String, provider: String, context: String) {
        self.activityID = activityID; self.provider = provider; self.context = context
    }
}

/// Opaque links stay stable across rate/clock updates. Every source, turn,
/// grouping or ending change revokes the old link before it can acknowledge.
public struct ActivityNavigationRegistry: Sendable {
    public struct Member: Equatable, Sendable {
        public let id: String, thread: String?, parent: String?, turn: String?
        public let started: Date?, phase: ActivityPhase
        public let ending: String?
        public let source: CompletionInbox.SourceToken
    }
    public struct Ending: Sendable {
        public let activity: SessionActivity, token: CompletionInbox.AcknowledgmentToken
    }
    public struct Entry: Sendable {
        public let link: ActivityNavigationLink, target: SessionActivity
        public let members: [Member], endings: [Ending], cloudContext: String?
        public let activity: SessionActivity
        public let capture: ActivityNavigationOperation
    }
    public private(set) var entries: [String: Entry] = [:]
    /// Ending digests from the previous update; unchanged endings are not rehashed on every publish.
    private var endingDigests: [[String]: String] = [:]
    public var links: [ActivityNavigationLink] { entries.values.map(\.link).sorted { $0.activityID < $1.activityID } }

    private var currentActivities: [SessionActivity] = []
    public init() {}

    public mutating func update(activities: [SessionActivity], requests: [PendingAttentionRequest], inbox: CompletionInbox,
                         cloudContext: String?, remoteSourceIDs: Set<String> = [], canOpen: (SessionActivity) -> Bool) {
        currentActivities = activities
        let pending = Set(requests.map { $0.activity.id })
        var next: [String: Entry] = [:], digests: [[String]: String] = [:]
        func endingDigest(_ value: SessionActivity) -> String? {
            guard [.completed, .interrupted].contains(value.phase) else { return nil }
            let fields = [value.phase.rawValue, value.turnFailed ? "failed" : "ok", value.phaseChangedAt.map { String($0.timeIntervalSince1970) } ?? "",
                          value.claudeCloud?.completionMark.map { String($0.timeIntervalSince1970) } ?? ""]
            let digest = digests[fields] ?? endingDigests[fields] ?? CompletionDismissalStore.digest(fields)
            digests[fields] = digest
            return digest
        }
        for group in ActivityTaskGroup.make(activities).prefix(1024) {
            let primary = group.primary
            guard !primary.isInternalReview, !primary.isIgnoredCodexSession,
                  let target = primary.claudeCloud != nil ? primary : ActivityNavigationTarget.resolve(primary, activities: activities, inbox: inbox, remoteSourceIDs: remoteSourceIDs),
                  canOpen(target) else { continue }
            let members = group.members.sorted { $0.id < $1.id }.map {
                Member(id: $0.id, thread: $0.threadID, parent: $0.parentThreadID, turn: $0.turnID,
                       started: $0.turnStartedAt, phase: $0.phase, ending: endingDigest($0),
                       source: inbox.sourceToken(for: $0))
            }
            let ids = Set(group.members.map { $0.canonicalized().id })
            let endings: [Ending] = group.isRunning || group.isWaiting || group.members.contains(where: { pending.contains($0.id) }) ? [] :
                inbox.unreadActivities.filter { ids.contains($0.canonicalized().id) }.sorted { $0.id < $1.id }.compactMap {
                    guard let token = inbox.acknowledgment(for: $0) else { return nil }; return Ending(activity: $0, token: token)
                }
            let scope = primary.claudeCloud == nil ? nil : cloudContext
            let previous = entries[primary.id]
            let same = previous.map { $0.members == members && $0.endings.map(\.token) == endings.map(\.token) &&
                $0.target.threadID == target.threadID && $0.target.codexOrigin == target.codexOrigin && $0.cloudContext == scope } ?? false
            let link = same ? previous!.link : ActivityNavigationLink(activityID: primary.id, provider: primary.provider.rawValue, context: UUID().uuidString)
            let capture = same ? previous!.capture : ActivityNavigationOperation(activity: primary, target: target, version: 0, activities: activities, inbox: inbox, scope: scope)
            next[primary.id] = .init(link: link, target: target, members: members, endings: endings, cloudContext: scope, activity: primary, capture: capture)
        }
        entries = next; endingDigests = digests
    }
    public func entry(context: String) -> Entry? { entries.values.first { $0.link.context == context } }
    public mutating func invalidate() { entries.removeAll() }
    public mutating func acknowledge(context: String, inbox: inout CompletionInbox) -> Bool {
        guard let entry = entry(context: context), entry.members.allSatisfy({ inbox.isCurrentSource($0.source) }) else { return false }
        return entry.capture.complete(.openedConversation, version: 0, active: true, activities: &currentActivities, inbox: &inbox, scope: entry.cloudContext).accepted
    }
}
