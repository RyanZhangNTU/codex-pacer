import AppKit
import PacerCore
import SwiftUI

/// Where the balance comes from. Automatic follows how Harness signs in.
enum DeepSeekBalanceSource: String, CaseIterable, Identifiable {
    case automatic, web, apiKey
    static let defaultsKey = "deepseekBalanceSource"
    var id: String { rawValue }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

/// Both the saved choice and its effective billing mode own the wallet state.
struct DeepSeekBalanceBinding: Equatable {
    let source: DeepSeekBalanceSource
    let mode: DeepSeekAuthMode?
}

@MainActor
struct DeepSeekBalanceReadDependencies {
    var web: @MainActor () async throws -> DeepSeekBalance = { try await DeepSeekWebBalanceReader().read() }
    var apiKey: @MainActor () -> String? = { DeepSeekAPIKeyStore.read() }
    var api: @MainActor (String) async throws -> DeepSeekBalance = { try await DeepSeekAPIBalanceClient.read(key: $0) }
}

/// Wallet notices fire once each time a line is crossed. Low and exhausted
/// follow balance readings; spend spikes and budgets take a baseline first,
/// so a relaunch never repeats one already shown.
struct DeepSeekBalanceAttention {
    static let spikeCategory = "deepseek.spike"
    static let balanceCategory = "deepseek.balance"
    private var notified: DeepSeekWallet.State?
    private var spiking: Bool?
    private var budgetLevels: [String: Int]?
    /// An empty wallet always notifies; a low one only while that reminder is on.
    mutating func notices(_ wallet: DeepSeekWallet, low: Bool = true) -> [IslandNotice] {
        let state = wallet.state
        guard [.low, .exhausted, .normal].contains(state) else { return [] }
        defer { notified = state == .normal ? nil : state }
        guard state != .normal, notified != state, notified != .exhausted || state == .exhausted, let balance = wallet.balance,
              state == .exhausted || low else { return [] }
        let detail = state == .exhausted ? L10n.text("deepseek.notice.exhausted_detail")
            : L10n.text("deepseek.notice.low_detail", DeepSeekWallet.compactAmount(balance.total))
        return [IslandNotice(id: "deepseek:balance:" + (state == .exhausted ? "exhausted" : "low"), kind: .lowQuota,
            title: "DeepSeek · " + L10n.text(state == .exhausted ? "deepseek.notice.exhausted" : "deepseek.notice.low"), detail: detail,
            category: Self.balanceCategory)]
    }
    mutating func spendNotices(_ wallet: DeepSeekWallet, spike: Bool, budget: Bool, snoozedUntil: Date, now: Date) -> [IslandNotice] {
        var result: [IslandNotice] = []
        let wasSpiking = spiking
        spiking = wallet.spiking
        if spike, wallet.spiking, wasSpiking == false, now >= snoozedUntil {
            result.append(IslandNotice(id: "deepseek:spike", kind: .lowQuota, title: "DeepSeek · " + L10n.text("deepseek.notice.spike"),
                detail: L10n.text("deepseek.notice.spike_detail", DeepSeekWallet.compactSpend(wallet.recentSpend),
                    DeepSeekWallet.compactSpend(wallet.spikeLimit)), category: Self.spikeCategory))
        }
        var levels: [String: Int] = [:]
        for period in [wallet.daily, wallet.weekly].compactMap({ $0 }) {
            let key = period.kind.rawValue + String(Int(period.interval.start.timeIntervalSince1970))
            let level = period.exceeded ? 2 : period.nearing ? 1 : 0
            levels[key] = level
            guard budget, let previous = budgetLevels, level > previous[key, default: 0] else { continue }
            let day = period.kind == .day
            result.append(IslandNotice(id: "deepseek:budget:" + key + ":" + String(level), kind: .lowQuota,
                title: "DeepSeek · " + L10n.text(level == 2 ? (day ? "deepseek.notice.day_over" : "deepseek.notice.week_over")
                    : (day ? "deepseek.notice.day_near" : "deepseek.notice.week_near")),
                detail: L10n.text(day ? "deepseek.notice.budget_detail_day" : "deepseek.notice.budget_detail_week",
                    DeepSeekDayDial.amount(period.spent), DeepSeekDayDial.amount(period.limit))))
        }
        budgetLevels = levels
        return result
    }
}

/// Which providers draw the collapsed rings. Unset follows the modules:
/// Codex and Claude first, DeepSeek in a free ring once it has a budget.
enum QuotaRingSlot: Int, CaseIterable {
    case outer, inner
    var defaultsKey: String { self == .outer ? "quotaRingOuter" : "quotaRingInner" }
}

extension IslandModel {
    /// A low-balance line set in Pacer; unset follows the platform's alert line.
    nonisolated static let deepseekLowBalanceKey = "deepseekLowBalanceLine"
    /// 4.0 stored ¥10 here whenever Settings changed, so only another amount was chosen.
    nonisolated static let legacyDeepSeekLowBalanceKey = "deepseekLowBalance"
    static let deepseekTurnCostKey = "deepseekShowsTurnCost"
    nonisolated static let deepseekDailyBudgetKey = "deepseekDailyBudget"
    nonisolated static let deepseekWeeklyBudgetKey = "deepseekWeeklyBudget"
    /// `day` or `week`: which budget the collapsed ring shows.
    nonisolated static let deepseekRingPeriodKey = "deepseekRingPeriod"
    /// `balance` or `budget`. Budgets count only in budget mode; the amounts stay for the next switch.
    nonisolated static let deepseekModeKey = "deepseekMode"
    /// A spike line set in Pacer; unset follows the last seven days.
    nonisolated static let deepseekSpikeLimitKey = "deepseekSpikeLimit"
    /// `local` or `account`: what speed and the spike line count.
    nonisolated static let deepseekSpeedSourceKey = "deepseekSpeedSource"
    static let deepseekTopUpURL = URL(string: "https://platform.deepseek.com/top_up")!
    static let deepseekUsageURL = URL(string: "https://platform.deepseek.com/usage")!
    static let deepseekPricingURL = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing")!
    var deepseekHome: URL { DeepSeekHome.resolve(configured: defaults.string(forKey: "deepseekHome")) }
    /// Only the data directory restarts collection; a new balance source rereads the wallet.
    var currentDeepSeekSourceSignature: String { deepseekHome.path }
    func applyDeepSeekBalanceSource() {
        if synchronizeDeepSeekBalanceSource() { refreshDeepSeekBalance(force: true) }
    }
    var currentDeepSeekBalanceBinding: DeepSeekBalanceBinding {
        DeepSeekBalanceBinding(source: .load(from: defaults), mode: deepseekBalanceMode)
    }
    /// Cancellation alone cannot stop a WebKit read from returning late.
    func cancelDeepSeekBalanceRead() {
        deepseekBalanceRequestID = nil
        deepseekBalanceTask?.cancel(); deepseekBalanceTask = nil; deepseekRefreshing = false
    }
    private func clearDeepSeekBalance() {
        cancelDeepSeekBalanceRead()
        deepseekBalance = nil; deepseekBalanceError = nil; deepseekFailureCount = 0
        deepseekBalanceAttention = DeepSeekBalanceAttention()
        lastDeepSeekBalanceAttempt = .distantPast
    }
    @discardableResult private func synchronizeDeepSeekBalanceSource() -> Bool {
        let binding = currentDeepSeekBalanceBinding
        guard binding != deepseekBalanceBinding else { return false }
        deepseekBalanceBinding = binding
        clearDeepSeekBalance()
        return true
    }
    nonisolated static func deepseekLowLine(in defaults: UserDefaults) -> Double? {
        if defaults.object(forKey: deepseekLowBalanceKey) != nil { return DeepSeekBudgetSettings.amount(deepseekLowBalanceKey, in: defaults) }
        let legacy = DeepSeekBudgetSettings.amount(legacyDeepSeekLowBalanceKey, in: defaults)
        return legacy == DeepSeekWallet.defaultLowLine ? nil : legacy
    }
    var showsDeepSeekTurnCost: Bool { defaults.object(forKey: Self.deepseekTurnCostKey) == nil || defaults.bool(forKey: Self.deepseekTurnCostKey) }
    /// The balance source in use: the chosen one, or the one Harness bills through.
    var deepseekBalanceMode: DeepSeekAuthMode? {
        switch DeepSeekBalanceSource.load(from: defaults) {
        case .web: .account
        case .apiKey: .apiKey
        case .automatic: deepseekDetectedMode
        }
    }
    var deepseekDetectedMode: DeepSeekAuthMode? { DeepSeekAuthMode.detect(home: deepseekHome, recentProvider: deepseekUsage.provider) }
    var deepseekConnectionNeeded: Bool { deepseekBalanceError?.needsConnection == true }
    private func amount(_ key: String) -> Double? { DeepSeekBudgetSettings.amount(key, in: defaults) }
    var deepseekBudgets: DeepSeekBudgets {
        guard defaults.string(forKey: Self.deepseekModeKey) == "budget" else { return DeepSeekBudgets() }
        return DeepSeekBudgets(daily: amount(Self.deepseekDailyBudgetKey), weekly: amount(Self.deepseekWeeklyBudgetKey))
    }
    /// What Settings shows for an amount left to the rules.
    var deepseekAutomaticLowLine: Double { DeepSeekWallet.automaticLowLine(deepseekBalance) }
    var deepseekAutomaticSpikeLimit: Double {
        deepseekUsage.ledger.automaticSpikeLimit(before: Calendar.current.startOfDay(for: now))
    }
    var deepseekRingPeriod: DeepSeekBudgetPeriod.Kind {
        defaults.string(forKey: Self.deepseekRingPeriodKey).flatMap(DeepSeekBudgetPeriod.Kind.init(rawValue:)) ?? .day
    }
    /// Budget mode with an amount set shows the budget dial; otherwise the time dial.
    var deepseekShowsBudgetDial: Bool { !deepseekBudgets.isEmpty }
    /// DeepSeek alone shows the full dashboard unless the simple one was chosen.
    var deepseekPanelStyle: DeepSeekPanelStyle { .load(from: defaults) }
    var deepseekSpeedSource: DeepSeekSpeedSource {
        defaults.string(forKey: Self.deepseekSpeedSourceKey).flatMap(DeepSeekSpeedSource.init(rawValue:)) ?? .local
    }
    var deepseekWallet: DeepSeekWallet {
        DeepSeekWallet(balance: deepseekBalance, connected: deepseekBalanceError == nil || deepseekBalance != nil,
            ledger: deepseekUsage.ledger, now: now, lowLine: Self.deepseekLowLine(in: defaults),
            history: deepseekHistory, budgets: deepseekBudgets, spikeLimit: amount(Self.deepseekSpikeLimitKey),
            speedSource: deepseekSpeedSource)
    }
    /// The wallet cannot be read: the collapsed bar dims rather than recolors.
    var deepseekWalletDimmed: Bool { [.stale, .disconnected].contains(deepseekWallet.state) }
    /// The one collapsed alert, from the reminders that are on.
    var deepseekAlert: DeepSeekAlert? {
        guard isModuleEnabled(.deepseek) else { return nil }
        let kinds = compactLayout.warnings
        return deepseekWallet.alert(lowBalance: kinds.contains(.lowBalance), spike: kinds.contains(.spendSpike), budget: kinds.contains(.budget))
    }

    /// The saved provider of a ring, `nil` for an empty ring, or unset.
    func quotaRingChoice(_ slot: QuotaRingSlot) -> AgentProvider?? {
        guard let value = defaults.string(forKey: slot.defaultsKey) else { return .none }
        return .some(AgentProvider(rawValue: value))
    }
    /// The providers in the collapsed rings, outer first. DeepSeek draws only with a budget.
    var compactRingProviders: [AgentProvider] {
        let enabled = enabledProviders
        let hasBudget = !deepseekBudgets.isEmpty
        let drawable = { (provider: AgentProvider) in provider != .deepseek || hasBudget }
        let outer = quotaRingChoice(.outer), inner = quotaRingChoice(.inner)
        guard outer != nil || inner != nil else {
            var result = Array(enabled.filter { $0 != .deepseek }.prefix(2))
            if result.count == 1, enabled.contains(.deepseek), drawable(.deepseek) { result.append(.deepseek) }
            return result
        }
        var result: [AgentProvider] = []
        for case let provider?? in [outer, inner] where enabled.contains(provider) && drawable(provider) && !result.contains(provider) {
            result.append(provider)
        }
        return result
    }
    /// With no ring to draw for DeepSeek alone, the gauge shows the price clock.
    var compactGaugeShowsPriceClock: Bool {
        compactRingProviders.isEmpty && isModuleEnabled(.deepseek) && !compactLayout.components.contains(.priceClock)
    }
    /// DeepSeek's value follows its ring: the budget left, else the balance.
    var deepseekValueShowsBudget: Bool {
        compactLayout.components.contains(.quotaGauge) && compactRingProviders.contains(.deepseek)
    }
    var deepseekCompactText: String {
        if deepseekValueShowsBudget, let budget = deepseekWallet.ringBudget(prefer: deepseekRingPeriod) {
            return DeepSeekWallet.compactRemaining(budget.remaining)
        }
        return deepseekBalance.map { DeepSeekWallet.compactAmount($0.total) } ?? "¥—"
    }
    /// A DeepSeek task's spend today with its sub-agents, and how many there are.
    func deepseekTaskSpend(_ activity: SessionActivity) -> (spend: DeepSeekSpendLedger.TaskSpend, subagents: Int)? {
        guard activity.provider == .deepseek, let session = activity.threadID else { return nil }
        let task = deepseekUsage.task(of: session)
        return deepseekWallet.tasks.first { $0.task == task }.map { ($0, deepseekUsage.subagents(of: task)) }
    }
    /// The row title of a task in Where It Went.
    /// A task's name from its row, or once the row is gone, from the title its log gave it.
    func deepseekTaskTitle(_ task: String) -> String {
        if let activity = activities.first(where: { $0.provider == .deepseek && $0.threadID == task }) { return projectName(activity) }
        if hideProjects { return L10n.text("activity.hidden_name") }
        return deepseekUsage.titles[task] ?? L10n.text("deepseek.task_untitled")
    }
    func snoozeDeepSeekSpike() { deepseekSpikeSnoozedUntil = Date().addingTimeInterval(3600) }
    /// Brings DeepSeek Harness forward, as opening one of its rows does.
    func openDeepSeekApp() {
        guard let application = DeepSeekApplicationResolver.find() else { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration)
    }
    /// Spend spikes and budget lines, after either the local estimate or the balance moves.
    func presentDeepSeekSpendNotices() {
        guard isModuleEnabled(.deepseek), !demo else { return }
        let kinds = compactLayout.warnings
        present(deepseekBalanceAttention.spendNotices(deepseekWallet, spike: kinds.contains(.spendSpike), budget: kinds.contains(.budget),
            snoozedUntil: deepseekSpikeSnoozedUntil, now: now))
    }

    /// A DeepSeek row's turn estimate, unless turned off in Settings.
    func displayedTurnCost(_ activity: SessionActivity) -> Double? {
        activity.provider == .deepseek && showsDeepSeekTurnCost ? activity.turnCost : nil
    }
    /// The peak mark and tooltip beside a DeepSeek row's estimate.
    func deepseekCostDetail(_ activity: SessionActivity) -> (peak: Bool, help: String)? {
        guard displayedTurnCost(activity) != nil else { return nil }
        var lines = [L10n.text("deepseek.turn_cost_row_help")]
        if let task = deepseekTaskSpend(activity) {
            lines.append(L10n.text("deepseek.task_help", DeepSeekDayDial.amount(task.spend.total)))
            var parts: [String] = []
            if task.spend.total > 0, task.spend.peak >= 0.005 {
                parts.append(L10n.text("deepseek.task_peak", Int((task.spend.peak / task.spend.total * 100).rounded())))
            }
            if task.subagents > 0 { parts.append(L10n.text("deepseek.task_subagents", task.subagents)) }
            if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        }
        return ((activity.turnPeakCost ?? 0) >= 0.005, lines.joined(separator: "\n"))
    }
    /// "Updated 2 min ago" for a connected wallet.
    var deepseekBalanceFreshness: String {
        guard let captured = deepseekBalance?.capturedAt else { return L10n.text("quota.not_read") }
        let elapsed = max(0, Int(now.timeIntervalSince(captured)))
        return elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60)
    }
    /// The strip's 20-point column: `¥86`, `¥8.4`, `¥1.2k`.
    var compactStripWalletText: String {
        if deepseekValueShowsBudget, let budget = deepseekWallet.ringBudget(prefer: deepseekRingPeriod) {
            return DeepSeekWallet.compactRemaining(budget.remaining)
        }
        guard let total = deepseekBalance?.total else { return "¥—" }
        return total < 10 ? String(format: "¥%.1f", total) : DeepSeekWallet.compactAmount(total)
    }
    /// "until 12:00" style text for the next peak or off-peak boundary.
    var deepseekPriceChangeText: String {
        guard let change = DeepSeekPricing.nextChange(after: now) else { return "—" }
        return change.formatted(date: Calendar.current.isDate(change, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
    }

    func startDeepSeekActivity() {
        guard isModuleEnabled(.deepseek), deepseekActivityTask == nil, !sleeping, !stopped, !demo else { return }
        let generation = deepseekGeneration, home = deepseekHome
        deepseekActivityTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.deepseekGeneration { self.deepseekActivityTask = nil } }
            await self.deepseekMonitor.start(home: home, refreshPolicy: self.activityRefreshPolicy) { [weak self] values, statuses, requests, performance, usage in
                guard let model = self else { return }
                await MainActor.run {
                    guard generation == model.deepseekGeneration, !model.stopped, !model.sleeping, model.isModuleEnabled(.deepseek) else { return }
                    model.receiveDeepSeekUpdate(values, statuses: statuses, requests: requests, performance: performance, usage: usage)
                }
            }
        }
    }

    func receiveDeepSeekUpdate(_ values: [SessionActivity], statuses: [String: RuntimeStreamStatus], requests: [PendingAttentionRequest],
                               performance: [SessionPerformanceUpdate] = [], usage: DeepSeekLocalUsage = DeepSeekLocalUsage()) {
        let endedTurns = Set(values.filter { [.completed, .interrupted].contains($0.phase) }.compactMap(\.turnID))
            .subtracting(deepseekReceivedActivities.filter { [.completed, .interrupted].contains($0.phase) }.compactMap(\.turnID))
        now = Date(); deepseekReceivedActivities = values; deepseekReceivedRequests = requests
        if deepseekStreamStatuses != statuses { deepseekStreamStatuses = statuses }
        if deepseekUsage != usage { deepseekUsage = usage }
        let balanceSourceChanged = synchronizeDeepSeekBalanceSource()
        completionInbox.updatePerformance(performance)
        for update in performance { rememberFirstOutput(update.firstTokenLatency, reportedAt: update.firstTokenReportedAt) }
        refilterEmbeddedSessions()
        // A finished turn has spent money; read the wallet soon after.
        presentDeepSeekSpendNotices()
        if balanceSourceChanged { refreshDeepSeekBalance(force: true) }
        else if !endedTurns.isEmpty, now.timeIntervalSince(lastDeepSeekBalanceAttempt) > 20 { refreshDeepSeekBalance() }
    }

    func refreshDeepSeekBalance(force: Bool = false) {
        guard isModuleEnabled(.deepseek), !sleeping, !stopped, !demo else { return }
        synchronizeDeepSeekBalanceSource()
        guard !deepseekRefreshing, force || deepseekBalanceError?.needsConnection != true else { return }
        let mode = deepseekBalanceBinding?.mode
        let key = mode == .apiKey ? deepseekBalanceReads.apiKey() : nil
        guard let mode, mode == .account || key != nil else {
            deepseekBalanceError = mode == .apiKey ? .missingKey : nil; return
        }
        deepseekRefreshing = true; lastDeepSeekBalanceAttempt = Date()
        let generation = deepseekGeneration, reads = deepseekBalanceReads, requestID = UUID()
        deepseekBalanceRequestID = requestID
        deepseekBalanceTask = Task { [weak self] in
            let result: Result<DeepSeekBalance, Error>
            do { result = .success(mode == .account ? try await reads.web() : try await reads.api(key!)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, generation == self.deepseekGeneration,
                  requestID == self.deepseekBalanceRequestID, !self.stopped, !self.sleeping, self.isModuleEnabled(.deepseek) else { return }
            // A profile can change while suspended, before the next collector update.
            if self.synchronizeDeepSeekBalanceSource() { self.refreshDeepSeekBalance(force: true); return }
            self.deepseekRefreshing = false; self.deepseekBalanceTask = nil; self.deepseekBalanceRequestID = nil
            switch result {
            case .success(let balance):
                self.deepseekBalance = balance; self.deepseekBalanceError = nil; self.deepseekFailureCount = 0
                self.deepseekHistory.record(total: balance.total, at: balance.capturedAt, source: balance.source.rawValue)
                self.deepseekHistory.save(to: self.defaults)
                self.now = Date()
                self.present(self.deepseekBalanceAttention.notices(self.deepseekWallet, low: self.compactLayout.warnings.contains(.lowBalance)))
                self.presentDeepSeekSpendNotices()
            case .failure(let error):
                let failure = error as? DeepSeekBalanceError ?? .connectionFailed
                self.deepseekBalanceError = failure
                if failure.needsConnection { self.deepseekBalance = nil }
                self.deepseekFailureCount = min(self.deepseekFailureCount + 1, 4)
            }
            self.onLayoutChange?(); self.onStatusChange?()
        }
    }

    /// Settings and the dial's "Sign in" both lead here.
    func connectDeepSeek() {
        switch deepseekBalanceMode {
        case .apiKey: openSettings(for: .deepseek)
        default:
            DeepSeekWebLogin.open { [weak self] in
                self?.forgetDeepSeekHistory(); self?.clearDeepSeekBalance(); self?.refreshDeepSeekBalance(force: true)
            }
        }
    }
    func saveDeepSeekAPIKey(_ raw: String) -> Bool {
        guard DeepSeekAPIKeyStore.save(raw) else { return false }
        forgetDeepSeekHistory(); clearDeepSeekBalance(); refreshDeepSeekBalance(force: true)
        return true
    }
    func removeDeepSeekConnection() {
        cancelDeepSeekBalanceRead()
        deepseekGeneration += 1
        DeepSeekAPIKeyStore.remove()
        forgetDeepSeekHistory()
        Task { await DeepSeekWebSessionStore.signOut() }
        deepseekBalance = nil; deepseekBalanceError = nil
        deepseekActivityTask?.cancel(); deepseekActivityTask = nil
        startDeepSeekActivity()
        onLayoutChange?(); onStatusChange?()
    }

    /// Another sign-in or key may be another account, so earlier readings no longer compare.
    private func forgetDeepSeekHistory() {
        deepseekHistory = DeepSeekBalanceHistory()
        defaults.removeObject(forKey: DeepSeekBalanceHistory.defaultsKey)
    }

    func resetDeepSeekSource() {
        deepseekGeneration += 1
        deepseekActivityTask?.cancel(); deepseekActivityTask = nil
        clearDeepSeekBalance(); deepseekBalanceBinding = nil
        deepseekActivityAttention = AttentionPolicy(); deepseekBalanceAttention = DeepSeekBalanceAttention()
        completionInbox.remove(provider: .deepseek)
        bindCompletionSources(.deepseek)
        deepseekReceivedActivities = []; deepseekReceivedRequests = []; deepseekAttentionRequests = []
        deepseekStreamStatuses = [:]; deepseekUsage = DeepSeekLocalUsage()
        activities.removeAll { $0.provider == .deepseek }
        clearSourceState()
        let generation = deepseekGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.deepseekMonitor.shutdown()
            guard generation == self.deepseekGeneration else { return }
            self.startDeepSeekActivity(); self.refreshDeepSeekBalance()
        }
    }

    func makeDeepSeekDemo() {
        var status = RuntimeStreamStatus(); status.connected = true; status.attachedThreads = 1
        deepseekStreamStatuses = ["local": status]
        deepseekUsage = DemoScenario.deepseekUsage(at: now)
        deepseekBalance = DeepSeekBalance(total: 86.4, granted: 6.4, tokenEstimation: 21_600_000, capturedAt: now, source: .web)
        // Readings since midnight that were charged ¥2.10 more than this Mac estimated.
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(60)
        let local = deepseekUsage.ledger.total(in: DateInterval(start: start, end: now)).total
        deepseekHistory = DeepSeekBalanceHistory()
        deepseekHistory.record(total: 86.4 + local + 2.1, at: start, source: "web")
        deepseekHistory.record(total: 86.4, at: now, source: "web")
    }
}
