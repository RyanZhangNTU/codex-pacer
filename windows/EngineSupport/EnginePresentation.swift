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
    /// Whether Mark All Read has anything to clear: an unread ending or an unconfirmed task.
    let canMarkRead: Bool

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
        canMarkRead = !value.readableCompletions.isEmpty
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
    /// Codex for Claude, on a Claude task: how many runs are still running ("Codex 2"),
    /// and the run lines when the list shows them: every running run, then the most
    /// recent ended ones. Absent without runs.
    var delegatedText: String? = nil
    var delegations: [EngineTaskRow]? = nil
    /// The older ended runs, folded into one line above the others ("2 more finished").
    var delegationsFolded: String? = nil
    /// On a run's row: the Claude task it opens, and whether Stop shows.
    var parentID: String? = nil
    var modeTag: String? = nil
    var canStop: Bool? = nil
    /// The run's hover card: label and value pairs.
    var detailLines: [[String]]? = nil
    /// Its subagents as dots (`attention`, `running`, `failed`, `completed`, in that
    /// order), every one; a row draws the first 8 (5 in a one-line row) and "+n" for
    /// the rest. And what they read aloud. Absent without subagents.
    var subagentDots: [String]? = nil
    var subagentDotsText: String? = nil
    /// Its subagent lines while the task works, and the rest folded into one line under them.
    var subagentLines: [EngineSubagentLine]? = nil
    var subagentsFolded: String? = nil

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
        if value.delegatedCount > 0 { delegatedText = value.delegatedCountText }
        if !value.delegations.isEmpty { delegations = value.delegations.map(EngineTaskRow.init) }
        delegationsFolded = value.foldedDelegations?.text
        if !value.subagentDotStates.isEmpty {
            subagentDots = value.subagentDotStates.map(\.rawValue); subagentDotsText = value.subagentDotsAccessibility
        }
        if !value.subagentLines.isEmpty { subagentLines = value.subagentLines.map(EngineSubagentLine.init) }
        subagentsFolded = value.foldedSubagents?.text
        if let link = value.delegation {
            modeTag = value.modeTag
            parentID = link.parentID; canStop = value.canStopDelegation
            detailLines = value.delegationDetail.map { [$0.label, $0.value] }
        }
    }
    static func symbol(_ activity: SessionActivity, attention: PendingAttentionRequest.Kind?) -> String {
        symbol(TaskSymbol.symbol(for: activity, attention: attention))
    }
    /// Legacy glyph identifiers remain on the engine wire; WPF maps them.
    static func symbol(_ kind: TaskSymbol) -> String {
        switch kind {
        case .thinking: return "sparkle"
        case .tool: return "terminal"
        case .responding: return "ellipsis.bubble"
        case .starting: return "hourglass"
        case .working: return "cloud"
        case .coordinating: return "arrow.triangle.branch"
        case .background: return "moon.zzz"
        case .approval: return "hand.raised"
        case .input: return "questionmark.bubble"
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
    /// The only active task's reported estimate while it works; the badge draws it in place of the orbit.
    let progressFraction: Double?
    let progressLongStep: Bool?
    let progressStale: Bool?
    /// Several running tasks, in the task list's order, for the average and segment rings.
    let progressTasks: [EngineTaskShare]?
    let progressAverage: Double?
    let progressAverageStale: Bool?
    let progressAverageProvider: String?
    let progressReported: Int?
    let progressSegments: Bool?
    /// Codex for Claude runs working for the active Claude tasks; absent without any.
    /// The badge draws them in Codex's color and names them with `delegatedText`.
    var delegatedRunning: Int? = nil
    var delegatedText: String? = nil

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
        if value.delegatedRunning > 0 {
            delegatedRunning = value.delegatedRunning; delegatedText = L10n.text("delegation.badge", value.delegatedRunning)
        }
        if case .symbol(let glyph) = value.core { coreSymbol = glyph } else { coreSymbol = nil }
        progressFraction = value.progress?.fraction
        // Waiting for background work holds the light like a long step: the request goes on, the agent does not.
        progressLongStep = value.progress.map { [.longStep, .waiting].contains($0.mode) }
        progressStale = value.progress?.stale
        let several = value.tasks.count > 1
        progressTasks = several ? value.tasks.map(EngineTaskShare.init) : nil
        progressAverage = several ? value.averageProgress : nil
        progressAverageStale = several && value.averageProgress != nil ? value.averageStale : nil
        progressAverageProvider = several ? value.averageProvider?.rawValue : nil
        progressReported = several ? value.reportedCount : nil
        progressSegments = several ? value.showsSegments : nil
    }
}

struct EngineTaskShare: Codable, Equatable {
    let provider: String
    let fraction: Double?
    let stale: Bool
    /// Codex for Claude runs working for this task; absent without any.
    var helpers: Int? = nil
    init(_ value: HeaderActivity.TaskShare) {
        provider = value.provider.rawValue; fraction = value.fraction; stale = value.stale
        if value.helpers > 0 { helpers = value.helpers }
    }
}

/// One subagent line under its task: its own row for the icon, ring and label,
/// its state, its speed while it writes, and its time or how it ended.
struct EngineSubagentLine: Codable, Equatable {
    let row: EngineTaskRow
    let state: String
    let rateText: String?
    let rateIsFresh: Bool
    let detail: String
    let accessibilityText: String
    var typeTag: String? = nil
    var nameTag: String? = nil
    var title: String? = nil
    var model: String? = nil
    var statusText: String? = nil
    var time: String? = nil
    init(_ value: ActivityTaskRowPresentation.SubagentLine) {
        row = EngineTaskRow(value.row); state = value.state.rawValue; rateText = value.rateText
        typeTag = value.typeTag; nameTag = value.nameTag; title = value.title; model = value.model
        statusText = value.statusText; time = value.time
        rateIsFresh = value.rateIsFresh; detail = value.detail; accessibilityText = value.accessibilityText
    }
}
