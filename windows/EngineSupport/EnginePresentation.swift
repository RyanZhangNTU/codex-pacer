import Foundation
import PacerCore

/// Bounded display metadata. The host never reconstructs provider lifecycle,
/// task families or rate estimates from strings or from raw event payloads.
struct EnginePresentation: Codable, Equatable {
    let rows: [EngineTaskRow]
    let taskCountText: String
    let pageSize: Int
    let rowCapacity: Int
    let pageCount: Int
    let header: EngineHeader

    init(activities: [SessionActivity], requests: [PendingAttentionRequest], inbox: CompletionInbox,
         hideProjects: Bool, at now: Date, showsDeepSeekTurnCost: Bool = true, progressRingProviders: Set<AgentProvider> = []) {
        self.init(ActivityTaskPresentation(activities: activities, requests: requests, inbox: inbox,
            options: .init(hideProjects: hideProjects, showsDeepSeekTurnCost: showsDeepSeekTurnCost, progressRingProviders: progressRingProviders), at: now))
    }
    init(_ value: ActivityTaskPresentation) {
        rows = value.rows.map(EngineTaskRow.init)
        taskCountText = value.taskCountText
        pageSize = value.pagination.pageSize; rowCapacity = value.pagination.rowCapacity; pageCount = value.pagination.pageCount
        header = EngineHeader(value.header(symbol: EngineTaskRow.symbol), endingProvider: value.pendingCompletions.first?.provider)
    }

}

struct EngineTaskRow: Codable, Equatable {
    let id: String
    let provider: String
    let title: String
    let status: String
    let source: String?
    let sourceLabel: String?
    let sourceKind: String?
    let phase: String
    let symbol: String
    let attention: String?
    let model: String
    let effort: String?
    let tokensPerSecond: Double?
    let rateText: String?
    let subagentText: String
    let rateIsFresh: Bool
    let ratePlaceholder: String?
    let turnTime: String?
    let subagents: Int
    let unread: Bool
    let failed: Bool
    let dimmed: Bool
    let cost: String?
    let peakCost: Bool
    /// Optional protocol-1 additions: absent when the progress ring is off.
    /// `pending` draws the dashed ring; `reported` draws `progressFraction`.
    let progressState: String?
    /// The request's lifecycle mode (`TaskProgressRing.Mode`), which sets the ring's style.
    let progressMode: String?
    let progressFraction: Double?
    let progressStale: Bool?
    let progressText: String?

    init(group: ActivityTaskGroup, attention: PendingAttentionRequest.Kind?, inbox: CompletionInbox,
         hideProjects: Bool, at now: Date, showsDeepSeekTurnCost: Bool = true) {
        self.init(ActivityTaskRowPresentation(activity: group.primary, group: group, attention: attention,
            unread: !group.isRunning && inbox.isUnread(group.primary),
            options: .init(hideProjects: hideProjects, showsDeepSeekTurnCost: showsDeepSeekTurnCost), at: now))
    }
    init(_ value: ActivityTaskRowPresentation) {
        id = value.activity.id; provider = value.activity.provider.rawValue; title = value.title; status = value.status
        source = value.source; sourceLabel = value.sourceLabel; sourceKind = value.sourceKind
        phase = value.phase.rawValue; symbol = Self.symbol(value.symbol); attention = value.attention?.rawValue
        model = value.model; effort = value.effort; tokensPerSecond = value.rate?.value; rateIsFresh = value.rate?.isFresh == true
        rateText = value.rateText; subagentText = value.subagentText
        ratePlaceholder = value.ratePlaceholder; turnTime = value.turnTime; subagents = value.subagents
        unread = value.unread; failed = value.activity.turnFailed; dimmed = value.dimmed; cost = value.cost; peakCost = value.peakCost
        progressState = value.progressRing?.state.rawValue; progressMode = value.progressRing?.mode.rawValue
        progressFraction = value.progressRing?.fraction
        progressStale = value.progressRing?.stale; progressText = value.progressRing?.accessibilityText
    }
    static func symbol(_ activity: SessionActivity, attention: PendingAttentionRequest.Kind?) -> String {
        symbol(TaskSymbol.symbol(for: activity, attention: attention))
    }
    /// Legacy glyph identifiers remain on the engine wire; WPF maps them.
    static func symbol(_ kind: TaskSymbol) -> String {
        switch kind {
        case .thinking: return "sparkle"
        case .tool: return "terminal"
        case .responding: return "text.bubble"
        case .starting: return "hourglass"
        case .working: return "cloud"
        case .coordinating: return "arrow.triangle.branch"
        case .background: return "zzz"
        case .approval: return "hand.raised"
        case .input: return "ellipsis.bubble"
        case .completed: return "checkmark.circle"
        case .interrupted: return "pause.circle"
        case .failed: return "xmark.circle"
        case .unknown: return "moon"
        }
    }
    static func duration(_ seconds: TimeInterval) -> String { CompactDuration.text(seconds) }

}

struct EngineHeader: Codable, Equatable {
    let activeCount: Int
    let activeCountText: String
    let coreSymbol: String?
    let orbit: [String: Int]
    let attention: String?
    let ending: String?
    let endingProvider: String?
    let endingIsCore: Bool

    init(groups: [ActivityTaskGroup], requests: [PendingAttentionRequest], inbox: CompletionInbox, at now: Date) {
        self.init(ActivityTaskPresentation(activities: groups.flatMap(\.members), requests: requests, inbox: inbox,
            groups: groups, at: now))
    }
    init(_ value: ActivityTaskPresentation) {
        self.init(value.header(symbol: EngineTaskRow.symbol), endingProvider: value.pendingCompletions.first?.provider)
    }
    init(_ value: HeaderActivity, endingProvider suppliedProvider: AgentProvider? = nil) {
        activeCount = value.activeCount; activeCountText = value.activeCountText; attention = value.attention?.rawValue
        orbit = Dictionary(uniqueKeysWithValues: value.orbit.map { ($0.key.rawValue, $0.value) })
        ending = value.ending.map { EngineTaskRow.symbol($0.kind) }
        if case .completed(let provider)? = value.ending { endingProvider = provider.rawValue }
        else { endingProvider = suppliedProvider?.rawValue }
        endingIsCore = value.endingIsCore
        if case .symbol(let glyph) = value.core { coreSymbol = glyph } else { coreSymbol = nil }
    }
}
