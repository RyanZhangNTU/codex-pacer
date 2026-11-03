import Foundation

struct EngineActivityLink: Codable, Equatable, Sendable {
    let activityID: String, provider: String, context: String
}

struct EngineNavigationPlan: Codable, Equatable, Sendable {
    let context: String, provider: String, kind: String
    let url: String?, webURL: String?
    let pid: UInt32?, started: UInt64?
    init(context: String, provider: AgentProvider, url: URL, webURL: URL? = nil) {
        self.context = context; self.provider = provider.rawValue; kind = "application"
        self.url = url.absoluteString; self.webURL = webURL?.absoluteString; pid = nil; started = nil
    }
    init(context: String, provider: AgentProvider, pid: UInt32, started: UInt64) {
        self.context = context; self.provider = provider.rawValue; kind = "host"
        url = nil; webURL = nil; self.pid = pid; self.started = started
    }
    init(demoContext: String, provider: AgentProvider) {
        context = demoContext; self.provider = provider.rawValue; kind = "demo"
        url = nil; webURL = nil; pid = nil; started = nil
    }
}

struct ActivityNavigationServices: Sendable {
    struct Input: Sendable {
        let context: String, activity: SessionActivity, home: URL, transcript: URL?
    }
    let resolve: @Sendable (Input) async throws -> EngineNavigationPlan
    static let demo = Self { .init(demoContext: $0.context, provider: $0.activity.provider) }
    static let live = Self { input in
        #if os(Windows)
        return try await Task.detached(priority: .userInitiated) { try WindowsActivityNavigation.resolve(input) }.value
        #else
        throw ActivityNavigationError.unavailable
        #endif
    }
}

enum ActivityNavigationError: Error { case unavailable, missingClaudeHost, missingCodexHost }

/// Opaque links stay stable across rate/clock updates. Every source, turn,
/// grouping or ending change revokes the old link before it can acknowledge.
struct ActivityNavigationRegistry {
    struct Member: Equatable {
        let id: String, thread: String?, parent: String?, turn: String?
        let started: Date?, phase: ActivityPhase
        let ending: String?
        let source: CompletionInbox.SourceToken
    }
    struct Ending {
        let activity: SessionActivity, token: CompletionInbox.AcknowledgmentToken
    }
    struct Entry {
        let link: EngineActivityLink, target: SessionActivity
        let members: [Member], endings: [Ending], cloudContext: String?
    }
    private(set) var entries: [String: Entry] = [:]
    var links: [EngineActivityLink] { entries.values.map(\.link).sorted { $0.activityID < $1.activityID } }

    mutating func update(activities: [SessionActivity], requests: [PendingAttentionRequest], inbox: CompletionInbox,
                         cloudContext: String?, canOpen: (SessionActivity) -> Bool) {
        let pending = Set(requests.map { $0.activity.id })
        var next: [String: Entry] = [:]
        for group in ActivityTaskGroup.make(activities).prefix(1024) {
            let primary = group.primary
            guard !primary.isInternalReview, !primary.isIgnoredCodexSession,
                  let target = primary.claudeCloud != nil ? primary : ActivityNavigationTarget.resolve(primary, activities: activities, inbox: inbox),
                  canOpen(target) else { continue }
            let members = group.members.sorted { $0.id < $1.id }.map {
                Member(id: $0.id, thread: $0.threadID, parent: $0.parentThreadID, turn: $0.turnID,
                       started: $0.turnStartedAt, phase: $0.phase,
                       ending: [.completed, .interrupted].contains($0.phase) ? CompletionDismissalStore.digest([
                           $0.phase.rawValue, $0.turnFailed ? "failed" : "ok", $0.phaseChangedAt.map { String($0.timeIntervalSince1970) } ?? "",
                           $0.claudeCloud?.completionMark.map { String($0.timeIntervalSince1970) } ?? ""]) : nil,
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
            let link = same ? previous!.link : EngineActivityLink(activityID: primary.id, provider: primary.provider.rawValue, context: UUID().uuidString)
            next[primary.id] = .init(link: link, target: target, members: members, endings: endings, cloudContext: scope)
        }
        entries = next
    }
    func entry(context: String) -> Entry? { entries.values.first { $0.link.context == context } }
    mutating func invalidate() { entries.removeAll() }
    func acknowledge(context: String, inbox: inout CompletionInbox) -> Bool {
        guard let entry = entry(context: context), entry.members.allSatisfy({ inbox.isCurrentSource($0.source) }) else { return false }
        for ending in entry.endings { _ = inbox.dismiss(ending.activity, acknowledging: ending.token) }
        return true
    }
}
