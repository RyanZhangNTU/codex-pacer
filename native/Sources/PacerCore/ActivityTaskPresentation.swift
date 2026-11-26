import Foundation

public enum TaskSymbol: String, Sendable {
    /// `background`: the turn stopped while its background work runs; it resumes on the wake.
    case thinking, tool, responding, starting, working, coordinating, background, approval, input, completed, interrupted, failed, unknown
    public static func symbol(for activity: SessionActivity, attention: PendingAttentionRequest.Kind? = nil,
                              groupIsRunning: Bool = false) -> Self {
        if let attention { return attention == .approval ? .approval : .input }
        if activity.codexGoalPause != nil, !groupIsRunning { return .interrupted }
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
    /// The only active task's reported estimate while it works or waits for
    /// its background work; the badge draws it in place of the orbit.
    public var progress: TaskProgressRing?
    /// One running task, in the task list's order, for the multi-task rings.
    public struct TaskShare: Equatable, Sendable {
        public let provider: AgentProvider
        /// The estimate the task reported while working or waiting for its
        /// background work; nil without one.
        public let fraction: Double?
        /// The estimate has not changed for `TaskProgressRing.staleInterval`.
        public let stale: Bool
        /// Codex for Claude runs working for this task.
        public var helpers = 0
        public init(provider: AgentProvider, fraction: Double?, stale: Bool = false, helpers: Int = 0) {
            self.provider = provider; self.fraction = fraction.map { min(1, max(0, $0)) }; self.stale = stale; self.helpers = max(0, helpers)
        }
    }
    /// Every running task: a task waiting for the user turns the badge amber
    /// instead, and finished ones have left the ring. The average counts all.
    private var running: [TaskShare]
    /// The running tasks the rings list, at most `taskLimit`.
    public var tasks: [TaskShare] {
        get { Array(running.prefix(Self.taskLimit)) }
        set { running = newValue }
    }
    /// Rings with more tasks than this show the average instead of segments.
    public static let segmentLimit = 4
    public static let taskLimit = 12
    public init(core: Core, activeCount: Int, orbit: [AgentProvider: Int], attention: PendingAttentionRequest.Kind? = nil, ending: Ending? = nil,
                progress: TaskProgressRing? = nil, tasks: [TaskShare] = []) {
        self.core = core; self.activeCount = activeCount; self.orbit = orbit; self.attention = attention; self.ending = ending
        self.progress = progress; self.running = tasks
    }
    private var reported: [TaskShare] { running.filter { $0.fraction != nil } }
    /// How many running tasks reported an estimate.
    public var reportedCount: Int { reported.count }
    /// The mean of the reported estimates; nil when no running task reported one.
    public var averageProgress: Double? {
        let values = reported.compactMap(\.fraction)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    /// The average fades only when every estimate behind it is old.
    public var averageStale: Bool { !reported.isEmpty && reported.allSatisfy(\.stale) }
    /// The one provider behind the average, or nil for a mix drawn in white.
    public var averageProvider: AgentProvider? {
        let providers = Set(reported.map(\.provider))
        return providers.count == 1 ? providers.first : nil
    }
    /// Segments need several tasks, at most `segmentLimit`, and one estimate.
    public var showsSegments: Bool { (2...Self.segmentLimit).contains(running.count) && !reported.isEmpty }
    /// What the badge's ring draws while several tasks run.
    public enum MultiTaskRing: Equatable, Sendable { case services, average, segments }
    /// The ring for several running tasks, or nil for one task or a request,
    /// which keep their own rings. Tasks without an estimate never count
    /// toward the average; a segment of one breathes instead. With no
    /// estimate at all the ring shows the services, and segments for more
    /// than `segmentLimit` tasks give way to the average.
    public func multiTaskRing(_ choice: CompactComponentOptions.MultiRing) -> MultiTaskRing? {
        guard activeCount > 1, attention == nil else { return nil }
        guard choice != .service, !reported.isEmpty else { return .services }
        return choice == .segments && showsSegments ? .segments : .average
    }
    /// Codex for Claude runs working for the active Claude tasks. Their comets
    /// circle the badge's ring in Codex's color: beside the services' comets,
    /// or in the stretch an estimate has not reached.
    public var delegatedRunning = 0
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

    /// The collapsed bar's countdown: two units without spaces, e.g. "1h30m".
    public static func compact(_ seconds: TimeInterval, language: AppLanguage = L10n.language) -> String {
        guard seconds.isFinite, seconds >= 60 else { return L10n.text("dashboard.countdown_soon", language: language) }
        let days = Int(seconds) / 86400, hours = Int(seconds) % 86400 / 3600, minutes = Int(seconds) % 3600 / 60
        if days > 0 { return L10n.text("compact.countdown_days", days, hours, language: language) }
        if hours > 0 { return L10n.text("compact.countdown_hours", hours, minutes, language: language) }
        return L10n.text("compact.countdown_minutes", minutes, language: language)
    }

    /// At most four characters for the strip: "45m", "1.5h", "46h", "3d".
    public static func short(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "<1m" }
        let hours = seconds / 3600
        if hours < 1 { return "\(Int(seconds / 60))m" }
        if hours < 10 {
            let tenths = (hours * 10).rounded(.down) / 10
            return tenths == tenths.rounded(.down) ? "\(Int(tenths))h" : String(format: "%.1fh", tenths)
        }
        if hours < 100 { return "\(Int(hours))h" }
        return "\(Int(hours / 24))d"
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
    /// Modules whose rows leave out the credits each turn used.
    public var hiddenTurnCredits: Set<AgentProvider> = []
    /// Providers whose rows draw the self-reported progress ring.
    public var progressRingProviders: Set<AgentProvider>
    /// Rows on one page of the expanded panel's task list.
    public var pageSize: Int
    /// Codex for Claude runs show as rows under their Claude task; without
    /// this, the task shows only how many there are.
    public var showsDelegationRows: Bool
    public init(hideProjects: Bool = false, hostApplications: [String: TaskHostLabel] = [:], sourceNames: [String: String] = [:],
                showsDeepSeekTurnCost: Bool = true, progressRingProviders: Set<AgentProvider> = [], pageSize: Int = 3,
                showsDelegationRows: Bool = true) {
        self.hideProjects = hideProjects; self.hostApplications = hostApplications; self.sourceNames = sourceNames
        self.showsDeepSeekTurnCost = showsDeepSeekTurnCost; self.progressRingProviders = progressRingProviders
        self.pageSize = ExpandedPanelOptions.pageSizes.contains(pageSize) ? pageSize : 3
        self.showsDelegationRows = showsDelegationRows
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
    public var costAccessibility: String? {
        guard let cost else { return nil }
        if case .estimatedYuan? = activity.turnCharge { return L10n.text("deepseek.turn_cost_accessibility", cost) }
        return cost
    }
    public let progressRing: TaskProgressRing?
    /// Set on a Codex for Claude run's row: its ledger entry.
    public let delegation: CodexDelegationLink?
    /// The Codex for Claude runs of this Claude task still running.
    public let delegatedCount: Int
    /// Its run lines, oldest first, when `TaskPresentationOptions.showsDelegationRows` is on:
    /// every running run, then the most recent ended ones, `delegationLineLimit` lines in all.
    public let delegations: [ActivityTaskRowPresentation]
    /// The older ended runs folded into one line above them.
    public let foldedDelegations: FoldedDelegations?
    /// One dot per subagent of the current turn, oldest first, at most `subagentDotLimit`.
    public let subagentDots: [SubagentDot]
    /// Subagents beyond the dots.
    public let subagentDotsMore: Int
    /// Its subagents' lines while the task works: running and waiting ones first,
    /// then the most recently ended, `subagentLineLimit` in all.
    public let subagentLines: [SubagentLine]
    /// The other subagents of the turn, folded into one line under them.
    public let foldedSubagents: FoldedSubagents?
    public static let subagentLineLimit = 3, subagentDotLimit = 8
    public var delegatedCountText: String { L10n.text("delegation.badge", delegatedCount) }
    /// How many run lines a Claude task shows; running runs always show, up to the runs allowed at once.
    public static let delegationLineLimit = 3
    public struct FoldedDelegations: Equatable, Sendable {
        public let ended: Int
        /// Failed or timed out, and stopped; a stopped run was stopped on purpose, so it is no failure.
        public let failed: Int, stopped: Int
        public var text: String {
            if failed > 0 { return L10n.text("delegation.folded_failed", ended, failed) }
            return L10n.text(stopped > 0 ? "delegation.folded_ended" : "delegation.folded", ended)
        }
    }
    public enum SubagentDot: String, Sendable, Equatable {
        case running, attention, completed, failed
    }
    /// One subagent under its task: its icon and label from its own row, then
    /// its live speed and time, or how it ended.
    public struct SubagentLine: Sendable {
        public enum State: String, Sendable, Equatable { case running, approval, input, completed, failed, stopped, unknown }
        public let row: ActivityTaskRowPresentation
        public let state: State
        /// Only while it writes; a finished or tool-bound subagent shows none.
        public let rateText: String?
        public let rateIsFresh: Bool
        /// Its time while it runs; otherwise its state and how long it took.
        public let detail: String
        public var dot: SubagentDot {
            switch state {
            case .running: return .running
            case .approval, .input: return .attention
            case .failed: return .failed
            case .completed, .stopped, .unknown: return .completed
            }
        }
        public var isActive: Bool { [.running, .approval, .input].contains(state) }
        public var accessibilityText: String { [row.title, rateText.map { $0 + " t/s" }, detail].compactMap { $0 }.joined(separator: ", ") }
    }
    public struct FoldedSubagents: Equatable, Sendable {
        public let active: Int, ended: Int, failed: Int
        public var text: String {
            if active > 0 { return L10n.text("subagent.folded_more", active + ended) }
            if failed > 0 { return L10n.text("delegation.folded_failed", ended, failed) }
            return L10n.text("delegation.folded", ended)
        }
    }
    /// What a task's dots read aloud.
    public var subagentDotsAccessibility: String {
        let total = subagentDots.count + subagentDotsMore
        return L10n.text("subagent.dots_accessibility", total, subagentDots.filter { $0 == .running }.count)
    }
    /// The subagents a task shows: those of its current turn, and any still at work from before.
    static func subagentMembers(_ group: ActivityTaskGroup?) -> [SessionActivity] {
        guard let group else { return [] }
        let start = group.primary.turnStartedAt ?? .distantPast
        return group.members.filter { member in
            member.id != group.primary.id && !member.isCodexDelegation && !member.isInternalReview &&
                ([.running, .waitingForInput].contains(member.phase) || (member.turnStartedAt ?? .distantPast) >= start)
        }.sorted { ($0.turnStartedAt ?? .distantFuture, $0.id) < ($1.turnStartedAt ?? .distantFuture, $1.id) }
    }
    static func subagentLine(_ child: SessionActivity, options: TaskPresentationOptions, at now: Date) -> SubagentLine {
        let row = ActivityTaskRowPresentation(activity: child, unread: false, options: options, at: now)
        let state: SubagentLine.State
        switch child.phase {
        case .running: state = .running
        case .waitingForInput: state = child.waitingForApproval ? .approval : .input
        case .completed: state = .completed
        case .interrupted: state = child.turnFailed ? .failed : .stopped
        case .unknown: state = .unknown
        }
        let live = state == .running ? child.displayedOutputEstimate(at: now).flatMap { child.contributesLiveRate($0) ? $0 : nil } : nil
        let detail: String
        switch state {
        case .running: detail = row.turnTime ?? ""
        case .approval: detail = PendingAttentionRequest.Kind.approval.label
        case .input: detail = PendingAttentionRequest.Kind.input.label
        case .completed, .failed, .stopped, .unknown:
            let word = L10n.text("subagent." + state.rawValue)
            detail = row.turnTime.map { word + " · " + $0 } ?? word
        }
        return SubagentLine(row: row, state: state, rateText: live.map { String(format: "%.1f", $0.value) },
                            rateIsFresh: live?.isFresh == true, detail: detail)
    }
    /// A run is running while its ledger says so and Codex has not ended its thread.
    static func isRunningDelegation(_ activity: SessionActivity) -> Bool {
        activity.codexDelegation?.status == .running && ![.completed, .interrupted].contains(activity.phase)
    }
    /// Every running run and the most recent ended ones, up to `delegationLineLimit`, oldest first.
    static func shownDelegations(_ runs: [SessionActivity]) -> [SessionActivity] {
        let running = Set(runs.filter(isRunningDelegation).map(\.id))
        let recent = Set(runs.filter { !running.contains($0.id) }.suffix(max(0, delegationLineLimit - running.count)).map(\.id))
        return runs.filter { running.contains($0.id) || recent.contains($0.id) }
    }
    /// A run the user can stop from its row.
    public var canStopDelegation: Bool { delegation?.status == .running && phase == .running }
    /// What a run's hover card lists: mode and access, model, start and time,
    /// Codex's own estimate, and once it ended, how and with how much work.
    /// The run's row itself shows only its label, speed, time and model.
    public let delegationDetail: [DelegationDetailLine]
    public struct DelegationDetailLine: Equatable, Sendable {
        public let label: String
        public let value: String
    }
    public var rateText: String? { rate.map { String(format: "%.1f", $0.value) } }
    public var subagentText: String { String(subagents) }
    public init(activity: SessionActivity, group: ActivityTaskGroup? = nil, attention: PendingAttentionRequest.Kind? = nil,
                unread: Bool, options: TaskPresentationOptions = .init(), at now: Date) {
        self.activity = activity; self.attention = attention; self.unread = unread
        delegation = activity.codexDelegation
        let delegated = group?.delegations ?? []
        delegatedCount = delegated.filter(Self.isRunningDelegation).count
        if options.showsDelegationRows {
            let shown = Self.shownDelegations(delegated), ids = Set(shown.map(\.id))
            delegations = shown.map { ActivityTaskRowPresentation(activity: $0, unread: false, options: options, at: now) }
            let folded = delegated.filter { !ids.contains($0.id) }
            foldedDelegations = folded.isEmpty ? nil : FoldedDelegations(ended: folded.count,
                failed: folded.filter { [.failed, .timedOut].contains($0.codexDelegation?.status) }.count,
                stopped: folded.filter { $0.codexDelegation?.status == .stopped }.count)
        } else { delegations = []; foldedDelegations = nil }
        let children = Self.subagentMembers(group).map { Self.subagentLine($0, options: options, at: now) }
        subagentDots = Array(children.map(\.dot).prefix(Self.subagentDotLimit))
        subagentDotsMore = max(0, children.count - Self.subagentDotLimit)
        if group?.isRunning == true || group?.isWaiting == true {
            let active = children.filter(\.isActive), ended = children.filter { !$0.isActive }
            let shownActive = Array(active.prefix(Self.subagentLineLimit))
            // The most recently ended, in the order they started.
            let recent = Set(ended.suffix(max(0, Self.subagentLineLimit - shownActive.count)).map(\.row.activity.id))
            let lines = shownActive + ended.filter { recent.contains($0.row.activity.id) }, shown = Set(lines.map(\.row.activity.id))
            subagentLines = lines
            let hidden = children.filter { !shown.contains($0.row.activity.id) }
            foldedSubagents = hidden.isEmpty ? nil : FoldedSubagents(active: hidden.filter(\.isActive).count,
                ended: hidden.filter { !$0.isActive }.count, failed: hidden.filter { $0.state == .failed }.count)
        } else { subagentLines = []; foldedSubagents = nil }
        phase = group?.isRunning == true ? .running : group?.isWaiting == true ? .waitingForInput : activity.observedPhase(at: now)
        title = Self.title(activity, hideProjects: options.hideProjects)
        var text = phase == .completed ? activity.endingLabel : activity.detail(at: now)
        if let link = activity.codexDelegation { text = Self.delegationStatus(link, title: title, phase: phase, detail: text) }
        if group?.isRunning == true, activity.phase != .running, !activity.turnFailed {
            text = L10n.text(children.contains { $0.state == .running } ? "subagent.waiting_parent" : "activity.running_long")
        }
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
        model = activity.modelName.map { Self.shortened(ModelDisplay.name($0, provider: activity.provider), limit: 22) } ?? activity.provider.displayName
        effort = activity.modelName == nil ? nil : activity.reasoningEffort.flatMap { ModelDisplay.effortLabel($0) }
        turnTime = Self.turnTimeText(activity, phase: phase, now: now)
        source = Self.sourceName(activity, options: options)
        sourceLabel = source.map { Self.middleTruncated($0, limit: 16) }
        sourceKind = activity.claudeCloud != nil ? "cloud" : activity.sourceHostID != nil ? "server" : source == nil ? nil : "application"
        ratePlaceholder = activity.claudeCloud == nil && HarnessRegistry.descriptor(for: activity.provider)?.hasRateDisplay == true
            ? L10n.text("performance.awaiting_usage") : nil
        switch activity.turnCharge {
        case .estimatedYuan(let total, let peak) where options.showsDeepSeekTurnCost:
            cost = DeepSeekWallet.turnAmount(total)
            peakCost = peak >= 0.005
        case .credits(let amount) where !options.hiddenTurnCredits.contains(activity.provider):
            cost = Self.creditAmount(amount)
            peakCost = false
        default:
            cost = nil
            peakCost = false
        }
        progressRing = TaskProgressRing.make(activity, phase: phase, enabled: options.progressRingProviders.contains(activity.provider), at: now,
            hasAttention: attention != nil, waitingForDependents: group?.isRunning == true && [.completed, .interrupted].contains(activity.phase))
        if let link = activity.codexDelegation {
            delegationDetail = Self.delegationDetail(link, activity: activity, phase: phase, model: model, effort: effort, at: now)
        } else { delegationDetail = [] }
    }
    static func delegationDetail(_ link: CodexDelegationLink, activity: SessionActivity, phase: ActivityPhase,
                                 model: String, effort: String?, at now: Date) -> [DelegationDetailLine] {
        func line(_ key: String, _ value: String) -> DelegationDetailLine { .init(label: L10n.text("delegation.detail." + key), value: value) }
        let access = L10n.text(link.worktree ? "delegation.worktree" : link.write ? "delegation.write" : "delegation.read_only")
        var lines = [line("mode", modeText(link.mode) + " · " + access)]
        let speed = link.fast.map { L10n.text($0 ? "delegation.detail.fast" : "delegation.detail.standard") }
        lines.append(line("model", ([model] + [effort, speed].compactMap { $0 }).joined(separator: " · ")))
        let clock = L10n.format(link.started, Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let finished = phase != .running && link.status.finished
        let end = finished ? (link.ended ?? activity.phaseChangedAt ?? link.started) : now
        let elapsed = max(0, end.timeIntervalSince(link.started))
        lines.append(line("started", clock + " · " + L10n.text(finished ? "delegation.detail.took" : "delegation.detail.running_for")
            + " " + CompactDuration.text(elapsed)))
        if !finished, let report = activity.currentProgress { lines.append(line("progress", L10n.text("delegation.detail.progress_value", report.percent))) }
        if finished {
            lines.append(line("result", L10n.text("delegation.status." + link.status.rawValue)))
            var work: [String] = []
            if let commands = link.commands { work.append(L10n.text("delegation.detail.commands", commands)) }
            if let files = link.changedFiles { work.append(L10n.text("delegation.detail.files", files)) }
            if !work.isEmpty { lines.append(line("work", work.joined(separator: " · "))) }
            if let usage = link.usage {
                let cached = usage.input > 0 ? Int((Double(usage.cached) / Double(usage.input) * 100).rounded()) : 0
                lines.append(line("tokens", L10n.text("delegation.detail.in") + " " + ClaudeCodexDelegation.compactCount(usage.input)
                    + " (" + L10n.text("delegation.detail.cached", cached) + ") · " + L10n.text("delegation.detail.out") + " "
                    + ClaudeCodexDelegation.compactCount(usage.output)))
            }
        }
        return lines
    }
    public static func title(_ activity: SessionActivity, hideProjects: Bool) -> String {
        if let link = activity.codexDelegation { return hideProjects ? modeText(link.mode) : delegationTitle(link) }
        return activity.observedSessionLabel ?? (hideProjects ? L10n.text("activity.hidden_name") : activity.title ?? activity.project)
    }
    /// Claude's label for the run, or its mode. Codex's own thread title would
    /// be the start of Claude's brief.
    public static func delegationTitle(_ link: CodexDelegationLink) -> String { link.label ?? modeText(link.mode) }
    static func modeText(_ mode: ClaudeCodexDelegation.Mode) -> String { L10n.text("delegation.mode." + mode.rawValue) }
    /// Mode, access and what the run is doing; a finished run says how it ended.
    static func delegationStatus(_ link: CodexDelegationLink, title: String, phase: ActivityPhase, detail: String) -> String {
        let access = L10n.text(link.worktree ? "delegation.worktree" : link.write ? "delegation.write" : "delegation.read_only")
        let state: String
        switch phase == .running ? .running : link.status {
        case .running: state = detail
        case .ok: state = L10n.text("delegation.status.ok")
        case .failed: state = L10n.text("delegation.status.failed")
        case .timedOut: state = L10n.text("delegation.status.timedOut")
        case .stopped: state = L10n.text("delegation.status.stopped")
        }
        // A plain task says nothing about its mode; a review or follow-up does, unless its title already is the mode.
        let mode = modeText(link.mode)
        let parts = title == mode || link.mode == .task ? [access, state] : [mode, access, state]
        return parts.joined(separator: " · ")
    }
    private static func creditAmount(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<0.01 " + L10n.text("harness.credit_unit") }
        let hundredths = Int((value * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        let amount: String
        switch fraction {
        case 0: amount = String(whole)
        case 1...9: amount = "\(whole).0\(fraction)"
        case 10, 20, 30, 40, 50, 60, 70, 80, 90: amount = "\(whole).\(fraction / 10)"
        default: amount = "\(whole).\(fraction)"
        }
        let unit = hundredths == 100 ? "harness.credit_unit_single" : "harness.credit_unit"
        return amount + " " + L10n.text(unit)
    }
    public static func sourceName(_ activity: SessionActivity, options: TaskPresentationOptions) -> String? {
        if let cloud = activity.claudeCloud { return options.hideProjects ? L10n.text("connections.kind.claude_cloud") : cloud.projectName }
        if activity.sourceHostID == DurableActivityCatalog.hostID { return "Dot" }
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
    /// What Mark All Read clears: unread endings, then unconfirmed tasks on the list.
    public let readableCompletions: [SessionActivity]
    public let requests: [PendingAttentionRequest]
    public var taskCountText: String { String(rows.count) }
    public init(activities: [SessionActivity], requests: [PendingAttentionRequest], inbox: CompletionInbox,
                groups: [ActivityTaskGroup]? = nil, overview: ActivityOverview? = nil,
                options: TaskPresentationOptions = .init(), at now: Date) {
        let groups = groups ?? ActivityTaskGroup.make(activities)
        let known = Set(groups.flatMap { $0.members.map(\.id) })
        let orphans = Set(activities.filter { $0.isCodexDelegation && !known.contains($0.id) }.map(\.id))
        let requests = orphans.isEmpty ? requests : requests.filter { !orphans.contains($0.activity.id) }
        self.groups = groups; self.requests = requests
        self.overview = overview ?? ActivityOverview(groups: groups, at: now)
        func attention(_ activity: SessionActivity) -> PendingAttentionRequest.Kind? { Self.attentionKind(activity, groups: groups, requests: requests) }
        var displayed = groups.filter {
            $0.isRunning || $0.isWaiting || $0.primary.codexGoalPause != nil || [.completed, .interrupted].contains($0.primary.phase) ||
                now < ($0.primary.unconfirmedDisplayDeadline ?? .distantPast)
        }.map(\.primary)
        let roots = Set(groups.filter { !$0.isRunning }.map { $0.primary.id })
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
        pagination = TaskPagination(itemCount: displayed.count, pageSize: options.pageSize)
        pendingCompletions = inbox.unreadActivities.filter { roots.contains($0.id) }
        let readableGroups = groups.filter { $0.canClearUnconfirmed(requests: requests) }
        let readable = Set(readableGroups.flatMap { $0.members.map(\.id) }), shown = Set(displayed.map(\.id))
        // Unconfirmed tasks on the list clear with the endings.
        let unconfirmed = readableGroups.filter { shown.contains($0.primary.id) }.flatMap(\.members).filter(inbox.isClearableUnconfirmed)
        readableCompletions = inbox.unreadActivities.filter { readable.contains($0.id) } + unconfirmed.sorted { $0.id < $1.id }
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
        if active == 0 {
            let paused = groups.contains { $0.primary.codexGoalPause != nil } ? symbol(.interrupted) : nil
            core = (prompt ?? ending.map { symbol($0.kind) } ?? paused).map(HeaderActivity.Core.symbol) ?? .idle
        }
        else if active == 1, singleTask == .stage, let glyph = prompt ?? overview.running.max(by: {
            let left = $0.lastObserved ?? .distantPast, right = $1.lastObserved ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }).map({ activity in symbol(TaskSymbol.symbol(for: activity, groupIsRunning: groups.first { $0.primary.id == activity.id }?.isRunning == true)) }) {
            core = .symbol(glyph)
        } else { core = .count(active) }
        // One unfinished task with a reported estimate shows it, whatever the core
        // shows. A turn stopped for its background work has not finished the
        // request, so its estimate stays, as it does in the task row.
        func unfinished(_ ring: TaskProgressRing?) -> TaskProgressRing? {
            ring.flatMap { $0.state == .reported && [.working, .longStep, .waiting].contains($0.mode) ? $0 : nil }
        }
        let progress = active == 1 && attention == nil ? unfinished(overview.running.first.flatMap { running in
            rows.first { $0.activity.id == running.id }?.progressRing
        }) : nil
        let running = Set(overview.running.map(\.id))
        let tasks = rows.filter { running.contains($0.activity.id) }.map { row in
            let ring = unfinished(row.progressRing)
            let helpers = groups.first { $0.primary.id == row.activity.id }?.delegations.filter(ActivityTaskRowPresentation.isRunningDelegation).count ?? 0
            return HeaderActivity.TaskShare(provider: row.activity.provider, fraction: ring?.fraction, stale: ring?.stale ?? false, helpers: helpers)
        }
        var value = HeaderActivity(core: core, activeCount: active, orbit: orbit, attention: attention, ending: ending, progress: progress,
            tasks: tasks)
        value.delegatedRunning = groups.filter { $0.isRunning || $0.isWaiting }.flatMap(\.delegations)
            .filter(ActivityTaskRowPresentation.isRunningDelegation).count
        return value
    }
}
