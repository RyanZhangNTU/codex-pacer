import Foundation

public enum TaskSymbol: String, Sendable {
    /// `background`: the turn stopped while its background work runs; it resumes on the wake.
    case thinking, tool, responding, starting, working, coordinating, background, approval, input, completed, interrupted, failed, unknown
    public static func symbol(for activity: SessionActivity, attention: PendingAttentionRequest.Kind? = nil,
                              groupIsRunning: Bool = false) -> Self {
        if let attention { return attention == .approval ? .approval : .input }
        if groupIsRunning && activity.phase != .running { return .thinking }
        switch activity.phase {
        case .waitingForInput: return activity.waitingForApproval ? .approval : .input
        case .completed: return .completed
        case .interrupted: return activity.turnFailed ? .failed : .interrupted
        case .unknown: return .unknown
        case .running:
            if activity.currentBackgroundWait != nil { return .background }
            switch activity.stage {
            case .thinking: return .thinking
            case .tool: return .tool
            case .responding: return .responding
            case .starting: return .starting
            case .working: return .working
            case .coordinating: return .coordinating
            }
        }
    }
}

/// Glyph identifiers are supplied by the host. The state and count are shared.
public struct HeaderActivity: Equatable, Sendable {
    public enum Core: Equatable, Sendable { case idle, symbol(String), count(Int) }
    public enum Ending: Equatable, Sendable {
        case completed(AgentProvider), interrupted, failed
        public var kind: TaskSymbol {
            switch self { case .completed: return .completed; case .interrupted: return .interrupted; case .failed: return .failed }
        }
    }
    public var core: Core
    public var activeCount: Int
    public var orbit: [AgentProvider: Int]
    public var attention: PendingAttentionRequest.Kind?
    public var ending: Ending?
    public init(core: Core, activeCount: Int, orbit: [AgentProvider: Int], attention: PendingAttentionRequest.Kind? = nil, ending: Ending? = nil) {
        self.core = core; self.activeCount = activeCount; self.orbit = orbit; self.attention = attention; self.ending = ending
    }
    public var endingIsCore: Bool { ending != nil && activeCount == 0 && attention == nil }
    public var showsEndingMark: Bool { ending != nil && !endingIsCore }
    public static func countText(_ count: Int) -> String { count > 99 ? "99+" : String(count) }
    public var activeCountText: String { Self.countText(activeCount) }
}

/// The shipping Mac wording is used by elapsed turns and countdowns.
public enum CompactDuration {
    public static func text(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return L10n.text("dashboard.countdown_soon") }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return L10n.text("dashboard.countdown_days", days, hours) }
        if hours > 0 { return L10n.text("dashboard.countdown_hours", hours, minutes) }
        return L10n.text("dashboard.countdown_minutes", minutes)
    }
}

public struct TaskHostLabel: Equatable, Sendable {
    public let name: String
    public let isClaudeDesktop: Bool
    public init(name: String, isClaudeDesktop: Bool = false) { self.name = name; self.isClaudeDesktop = isClaudeDesktop }
}
public struct TaskPresentationOptions: Equatable, Sendable {
    public var hideProjects: Bool
    public var hostApplications: [String: TaskHostLabel]
    public var sourceNames: [String: String]
    public var showsDeepSeekTurnCost: Bool
    /// Providers whose rows draw the self-reported progress ring.
    public var progressRingProviders: Set<AgentProvider>
    public init(hideProjects: Bool = false, hostApplications: [String: TaskHostLabel] = [:], sourceNames: [String: String] = [:],
                showsDeepSeekTurnCost: Bool = true, progressRingProviders: Set<AgentProvider> = []) {
        self.hideProjects = hideProjects; self.hostApplications = hostApplications; self.sourceNames = sourceNames
        self.showsDeepSeekTurnCost = showsDeepSeekTurnCost; self.progressRingProviders = progressRingProviders
    }
}

public struct ActivityTaskRowPresentation: Sendable {
    public let activity: SessionActivity
    public let phase: ActivityPhase
    public let title: String
    public let status: String
    public let symbol: TaskSymbol
    public let attention: PendingAttentionRequest.Kind?
    public let unread: Bool
    public let dimmed: Bool
    public let subagents: Int
    public let rate: OutputEstimate?
    public let model: String
    public let effort: String?
    public let turnTime: String?
    public let source: String?
    public let sourceLabel: String?
    public let sourceKind: String?
    public let ratePlaceholder: String?
    public let cost: String?
    public let peakCost: Bool
    public let progressRing: TaskProgressRing?
    public var rateText: String? { rate.map { String(format: "%.1f", $0.value) } }
    public var subagentText: String { String(subagents) }
    public init(activity: SessionActivity, group: ActivityTaskGroup? = nil, attention: PendingAttentionRequest.Kind? = nil,
                unread: Bool, options: TaskPresentationOptions = .init(), at now: Date) {
        self.activity = activity; self.attention = attention; self.unread = unread
        phase = group?.isRunning == true ? .running : group?.isWaiting == true ? .waitingForInput : activity.observedPhase(at: now)
        title = Self.title(activity, hideProjects: options.hideProjects)
        var text = phase == .completed ? activity.endingLabel : activity.detail(at: now)
        if group?.isRunning == true, activity.phase != .running, !activity.turnFailed { text = L10n.text("activity.running_long") }
        if let attention {
            if phase != .running { text = attention.label }
            else {
                switch activity.phase == .running ? activity.stage : nil {
                case .tool?: text = attention.label + " · " + L10n.text("activity.tool_compact")
                case .responding?: text = attention.label + " · " + L10n.text("activity.responding_compact")
                default: text = attention.label + " · " + text
                }
            }
        }
        status = text
        symbol = TaskSymbol.symbol(for: activity, attention: attention, groupIsRunning: group?.isRunning == true)
        dimmed = Self.isDimmed(phase: phase, unread: unread, attention: attention != nil, failed: activity.turnFailed)
        subagents = (group?.runningSubagentCount ?? 0) + (phase == .running ? activity.claudeCloud?.additionalWorkers ?? 0 : 0)
        rate = group?.displayedRate(at: now) ?? activity.displayedOutputEstimate(at: now)
        model = activity.modelName.map { Self.shortened(ModelDisplay.name($0), limit: 22) } ?? activity.provider.displayName
        effort = activity.modelName == nil ? nil : activity.reasoningEffort.flatMap { ModelDisplay.effortLabel($0) }
        turnTime = Self.turnTimeText(activity, phase: phase, now: now)
        source = Self.sourceName(activity, options: options)
        sourceLabel = source.map { Self.middleTruncated($0, limit: 16) }
        sourceKind = activity.claudeCloud != nil ? "cloud" : activity.sourceHostID != nil ? "server" : source == nil ? nil : "application"
        ratePlaceholder = activity.claudeCloud == nil ? L10n.text("performance.awaiting_usage") : nil
        cost = activity.provider == .deepseek && options.showsDeepSeekTurnCost ? activity.turnCost.map(DeepSeekWallet.turnAmount) : nil
        peakCost = (activity.turnPeakCost ?? 0) >= 0.005
        progressRing = TaskProgressRing.make(activity, phase: phase, enabled: options.progressRingProviders.contains(activity.provider), at: now)
    }
    public static func title(_ activity: SessionActivity, hideProjects: Bool) -> String {
        hideProjects ? L10n.text("activity.hidden_name") : activity.title ?? activity.project
    }
    public static func sourceName(_ activity: SessionActivity, options: TaskPresentationOptions) -> String? {
        if let cloud = activity.claudeCloud { return options.hideProjects ? L10n.text("connections.kind.claude_cloud") : cloud.projectName }
        if activity.sourceHostID == nil, activity.provider == .claude || activity.launchedByEmbeddingApp {
            return options.hostApplications[activity.id].flatMap { activity.provider == .claude && $0.isClaudeDesktop ? nil : $0.name }
        }
        if activity.provider == .codex, let host = activity.sourceHostID, host.hasPrefix("remote-control:") {
            return options.sourceNames[host] ?? activity.sourceHost
        }
        return activity.sourceHost
    }
    public static func turnTimeText(_ activity: SessionActivity, phase: ActivityPhase, now: Date) -> String? {
        guard let start = activity.turnStartedAt else { return nil }
        if phase == .running { return start <= now ? CompactDuration.text(now.timeIntervalSince(start)) : nil }
        guard [.completed, .interrupted].contains(phase), [.completed, .interrupted].contains(activity.phase),
              let end = activity.phaseChangedAt, end >= start else { return nil }
        return CompactDuration.text(end.timeIntervalSince(start))
    }
    public static func isDimmed(phase: ActivityPhase, unread: Bool, attention: Bool, failed: Bool) -> Bool {
        !unread && !attention && !failed && [.completed, .interrupted].contains(phase)
    }
    public static func shortened(_ text: String, limit: Int) -> String { text.count > limit ? String(text.prefix(limit - 1)) + "…" : text }
    public static func middleTruncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return String(text.prefix(half)) + "…" + String(text.suffix(limit - 1 - half))
    }
}

public struct ActivityTaskPresentation: Sendable {
    public let groups: [ActivityTaskGroup]
    public let overview: ActivityOverview
    public let visibleActivities: [SessionActivity]
    public let rows: [ActivityTaskRowPresentation]
    public let pagination: TaskPagination
    public let pendingCompletions: [SessionActivity]
    public let readableCompletions: [SessionActivity]
    public let requests: [PendingAttentionRequest]
    public var taskCountText: String { String(rows.count) }
    public init(activities: [SessionActivity], requests: [PendingAttentionRequest], inbox: CompletionInbox,
                groups: [ActivityTaskGroup]? = nil, overview: ActivityOverview? = nil,
                options: TaskPresentationOptions = .init(), at now: Date) {
        let groups = groups ?? ActivityTaskGroup.make(activities)
        self.groups = groups; self.requests = requests
        self.overview = overview ?? ActivityOverview(groups: groups, at: now)
        func attention(_ activity: SessionActivity) -> PendingAttentionRequest.Kind? { Self.attentionKind(activity, groups: groups, requests: requests) }
        var displayed = groups.filter {
            $0.isRunning || $0.isWaiting || [.completed, .interrupted].contains($0.primary.phase) ||
                now.timeIntervalSince($0.primary.lastObserved ?? .distantPast) < 900
        }.map(\.primary)
        let known = Set(groups.flatMap { $0.members.map(\.id) }), roots = Set(groups.filter { !$0.isRunning }.map { $0.primary.id })
        var ids = Set(displayed.map(\.id))
        for request in requests where !known.contains(request.activity.id) && ids.insert(request.activity.id).inserted { displayed.append(request.activity) }
        displayed.sort {
            let lhs = attention($0) != nil ? 0 : Self.priority($0.observedPhase(at: now))
            let rhs = attention($1) != nil ? 0 : Self.priority($1.observedPhase(at: now))
            if lhs != rhs { return lhs < rhs }
            let left = $0.phaseChangedAt ?? .distantPast, right = $1.phaseChangedAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        visibleActivities = displayed
        rows = displayed.map { activity in
            let group = groups.first { $0.primary.id == activity.canonicalized().id }
            return ActivityTaskRowPresentation(activity: activity, group: group, attention: attention(activity),
                unread: group?.isRunning != true && inbox.isUnread(activity), options: options, at: now)
        }
        pagination = TaskPagination(itemCount: displayed.count)
        pendingCompletions = inbox.unreadActivities.filter { roots.contains($0.id) }
        let readable = Set(groups.filter { !$0.isRunning && !$0.isWaiting && attention($0.primary) == nil }.flatMap { $0.members.map(\.id) })
        readableCompletions = inbox.unreadActivities.filter { readable.contains($0.id) }
    }
    public func attentionKind(for activity: SessionActivity) -> PendingAttentionRequest.Kind? { Self.attentionKind(activity, groups: groups, requests: requests) }
    public static func attentionKind(_ activity: SessionActivity, groups: [ActivityTaskGroup], requests: [PendingAttentionRequest]) -> PendingAttentionRequest.Kind? {
        let group = groups.first { $0.primary.id == activity.canonicalized().id }
        let ids = Set(group?.members.map(\.id) ?? [activity.id]), matching = requests.filter { ids.contains($0.activity.id) }
        if matching.contains(where: { $0.kind == .approval }) { return .approval }
        if matching.contains(where: { $0.kind == .decision }) { return .decision }
        if !matching.isEmpty { return .input }
        let waiting = group?.members.first { $0.phase == .waitingForInput } ?? (activity.phase == .waitingForInput ? activity : nil)
        return waiting.map { $0.waitingForApproval ? .approval : .input }
    }
    private static func priority(_ phase: ActivityPhase) -> Int {
        switch phase { case .waitingForInput: return 0; case .running: return 1; case .interrupted: return 2; case .completed: return 3; case .unknown: return 4 }
    }
    public func header(singleTask: CompactBarPresentation.SingleTask = .stage, symbol: (TaskSymbol) -> String) -> HeaderActivity {
        let active = overview.running.count + overview.waiting.count
        let attention = requests.first?.kind ?? overview.waiting.first.map { $0.waitingForApproval ? .approval : .input }
        let ending = pendingCompletions.first.map { completed -> HeaderActivity.Ending in
            completed.turnFailed ? .failed : completed.phase == .interrupted ? .interrupted : .completed(completed.provider)
        }
        var orbit: [AgentProvider: Int] = [:]
        for task in overview.running { orbit[task.provider, default: 0] += 1 }
        let prompt = attention.map { symbol($0 == .approval ? .approval : .input) }
        let core: HeaderActivity.Core
        if active == 0 { core = (prompt ?? ending.map { symbol($0.kind) }).map(HeaderActivity.Core.symbol) ?? .idle }
        else if active == 1, singleTask == .stage, let glyph = prompt ?? overview.running.max(by: {
            let left = $0.lastObserved ?? .distantPast, right = $1.lastObserved ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }).map({ activity in symbol(TaskSymbol.symbol(for: activity, groupIsRunning: groups.first { $0.primary.id == activity.id }?.isRunning == true)) }) {
            core = .symbol(glyph)
        } else { core = .count(active) }
        return HeaderActivity(core: core, activeCount: active, orbit: orbit, attention: attention, ending: ending)
    }
}
