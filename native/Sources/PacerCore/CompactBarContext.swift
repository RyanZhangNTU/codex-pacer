import Foundation

/// Numeric and enum inputs for a collapsed bar. Account identifiers, credits,
/// task names, paths and conversation text are not part of this presentation.
public struct CompactBarContext: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public let provider: AgentProvider
        public let snapshot: QuotaSnapshot?
        public let failed: Bool
        public init(provider: AgentProvider, snapshot: QuotaSnapshot?, failed: Bool) {
            self.provider = provider; self.failed = failed
            self.snapshot = snapshot.map { value in
                QuotaSnapshot(buckets: value.buckets.map {
                    QuotaBucket(id: $0.id, name: nil, plan: nil, windows: $0.windows, credits: nil)
                }, capturedAt: value.capturedAt, accountScope: nil, resetCredits: nil)
            }
        }
    }
    public struct Wallet: Codable, Equatable, Sendable {
        public let hasBalance: Bool, hasBudget: Bool, dimmed: Bool
        public let balance: String, budget: String?, stripBalance: String, stripBudget: String?
        public let budgetPercent: Double?
        public let peakNow: Bool
        public let todayTotal: Double
        /// The ring's budget period as a quota window, for its pace tick.
        public let budgetWindow: QuotaWindow?
        public init(_ wallet: DeepSeekWallet, preferred: DeepSeekBudgetPeriod.Kind) {
            let selected = wallet.ringBudget(prefer: preferred)
            budgetWindow = selected?.window
            hasBalance = wallet.balance != nil; hasBudget = selected != nil
            dimmed = [.stale, .disconnected].contains(wallet.state)
            balance = wallet.balance.map { DeepSeekWallet.compactAmount($0.total) } ?? "¥—"
            budget = selected.map { DeepSeekWallet.compactRemaining($0.remaining) }
            stripBalance = wallet.balance.map { $0.total < 10 ? String(format: "¥%.1f", $0.total) : DeepSeekWallet.compactAmount($0.total) } ?? "¥—"
            stripBudget = budget
            budgetPercent = selected.map { max(0, $0.remaining) / $0.limit * 100 }
            peakNow = wallet.peakNow; todayTotal = wallet.todayTotal
        }
    }
    private enum Status: Codable, Equatable, Sendable {
        case text(String), count(String, Int), tasks(Int)
        func text(_ language: AppLanguage) -> String {
            switch self {
            case .text(let key): return L10n.text(key, language: language)
            case .count(let key, let count): return L10n.text(key, count, language: language)
            case .tasks(let count): return L10n.text(count == 1 ? "activity.task_count_compact_singular" : "activity.task_count_compact",
                count > 99 ? "99+" : String(count), language: language)
            }
        }
    }
    public let version: Int
    public let now: Date
    public let sources: [Source]
    public let wallet: Wallet?
    public let firstOutput: Double?
    public let rate: Double?
    public let rateFresh: Bool
    public let running: Bool
    public let attention: Bool
    public let activeCount: Int
    public let warnings: [CompactWarningPresentation.Item]
    /// The latest first-output measurements, newest last, for the median.
    public let firstOutputs: [Double]?
    /// Running tasks with a measured rate, the divisor of the per-task average.
    public let measuredTasks: Int?
    private let status: Status
    private let displayStatus: Status
    /// The stage of the most recently active running task.
    private let latestStage: Status?

    public init(activities: [SessionActivity], requests: [PendingAttentionRequest], completions: [SessionActivity],
                sources: [Source], wallet: Wallet? = nil, firstOutput: Double? = nil,
                warnings: [CompactWarningPresentation.Item] = [], groups suppliedGroups: [ActivityTaskGroup]? = nil,
                overview suppliedOverview: ActivityOverview? = nil, firstOutputs: [Double] = [], now: Date) {
        version = 1; self.now = now; self.sources = sources; self.wallet = wallet; self.warnings = warnings
        self.firstOutput = firstOutput.flatMap { $0.isFinite && (0...3600).contains($0) ? $0 : nil }
        let recent = firstOutputs.filter { $0.isFinite && (0...3600).contains($0) }.suffix(CompactFirstOutputHistory.limit)
        self.firstOutputs = recent.isEmpty ? nil : Array(recent)
        let groups = suppliedGroups ?? ActivityTaskGroup.make(activities), overview = suppliedOverview ?? ActivityOverview(groups: groups, at: now)
        rate = overview.displayedRate; rateFresh = overview.rateIsFresh; running = !overview.running.isEmpty
        let measured = groups.filter { $0.isRunning && $0.displayedRate(at: now) != nil }.count
        measuredTasks = running ? measured : nil
        activeCount = overview.running.count + overview.waiting.count
        attention = !requests.isEmpty || !overview.waiting.isEmpty
        func stage(_ task: SessionActivity) -> Status {
            .text(task.stage == .tool ? "activity.tool_compact" : task.stage == .responding ? "activity.responding_compact" : "activity." + task.stage.rawValue)
        }
        let endedRoots = Set(groups.filter { !$0.isRunning }.map { $0.primary.id })
        let pending = completions.filter { endedRoots.contains($0.id) }
        let ordinary: Status
        if let request = requests.first { ordinary = .text("attention." + request.kind.rawValue) }
        else if let ending = pending.first {
            ordinary = pending.count == 1 ? .text(ending.turnFailed ? "activity.failed" : ending.phase == .interrupted ? "activity.stopped_compact" : "activity.done_compact") : .count("activity.ended_compact", pending.count)
        } else if let waiting = overview.waiting.first { ordinary = .text(waiting.waitingForApproval ? "attention.approval" : "attention.input") }
        else if activeCount == 1, let task = overview.running.first {
            let children = groups.first { $0.primary.id == task.id }?.runningSubagentCount ?? 0
            ordinary = children > 0 ? .count(children == 1 ? "activity.subagent_running" : "activity.subagents_running", children) : stage(task)
        } else { ordinary = activeCount == 0 ? .text("activity.idle") : .tasks(activeCount) }
        status = ordinary
        let latest = overview.running.max(by: {
            let left = $0.lastObserved ?? .distantPast, right = $1.lastObserved ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        })
        latestStage = latest.map(stage)
        if overview.running.count > 1, !attention, pending.isEmpty, let latest { displayStatus = stage(latest) } else { displayStatus = ordinary }
    }
    public func headerStatusText(language: AppLanguage) -> String { status.text(language) }
    public func statusText(language: AppLanguage) -> String { displayStatus.text(language) }
    /// The status component's text for one display choice: the most urgent
    /// thing, the latest stage alone, or the task count before the urgent text.
    public func statusText(_ show: CompactComponentOptions.StatusShow, language: AppLanguage) -> String {
        switch show {
        case .urgent: return displayStatus.text(language)
        case .stage: return (latestStage ?? displayStatus).text(language)
        case .count:
            guard activeCount > 1 else { return displayStatus.text(language) }
            let count = Status.tasks(activeCount).text(language), detail = displayStatus.text(language)
            return count == detail ? count : count + " · " + detail
        }
    }
    /// "attention" while the text asks for the user, "failed" for a failed
    /// ending, otherwise nil; hosts color the text from it.
    public func statusTone(_ show: CompactComponentOptions.StatusShow) -> String? {
        let shown = show == .stage ? latestStage ?? displayStatus : displayStatus
        guard case .text(let key) = shown else { return nil }
        if key.hasPrefix("attention.") { return "attention" }
        return key == "activity.failed" ? "failed" : nil
    }
    public func activitySummary(language: AppLanguage) -> String {
        let count = activeCount == 0 ? nil : Status.tasks(activeCount).text(language)
        return [count, status.text(language)].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
    }
}
