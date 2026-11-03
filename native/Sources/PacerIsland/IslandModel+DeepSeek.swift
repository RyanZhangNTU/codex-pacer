import PacerMacSupport
import AppKit
import PacerCore
import SwiftUI

/// Where the balance comes from. Automatic follows how Harness signs in.
typealias DeepSeekBalanceSource = DeepSeekBalanceSelection
extension DeepSeekBalanceSelection {
    static let defaultsKey = "deepseekBalanceSource"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

@MainActor
struct DeepSeekBalanceReadDependencies {
    var web: @MainActor () async throws -> DeepSeekBalance = { try await DeepSeekWebBalanceReader().read() }
    var apiKey: @MainActor () -> String? = { DeepSeekAPIKeyStore.read() }
    var api: @MainActor (String) async throws -> DeepSeekBalance = { try await DeepSeekAPIBalanceClient.read(key: $0) }
}

typealias DeepSeekBalanceAttention = DeepSeekNoticePolicy

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
    @discardableResult func cancelDeepSeekBalanceRead(stop: Bool = true) -> DeepSeekBalanceCoordinator? {
        let previous = deepseekBalanceCoordinator; previous?.invalidateSource()
        deepseekBalanceCoordinator = nil; deepseekBalanceCoordinatorID = UUID(); deepseekCredentialInput = nil
        deepseekBalanceRequestID = nil
        deepseekBalanceTask?.cancel(); cancelOwnedWork(.init(.quota, provider: .deepseek)); deepseekRefreshing = false; deepseekBalanceStarting = false
        if stop, let previous {
            launchOwnedWork(.init(.reset, provider: .deepseek, identifier: "balance")) { _ in
                await ApplicationLifecycleCoordinator.cleanup([.balance: { await previous.stop() }])
            }
        }
        return previous
    }
    private func clearDeepSeekBalance() {
        cancelDeepSeekBalanceRead()
        deepseekBalance = nil; deepseekBalanceError = nil; deepseekFailureCount = 0; deepseekBalanceState = nil
        deepseekBalanceAttention = DeepSeekBalanceAttention()
        lastDeepSeekBalanceAttempt = .distantPast
    }
    @discardableResult private func synchronizeDeepSeekBalanceSource() -> Bool {
        let binding = currentDeepSeekBalanceBinding
        guard binding != deepseekBalanceBinding else { return false }
        // An unresolved automatic source can recover its matching saved history;
        // switching billing modes invalidates it before a replacement read succeeds.
        let sameHistory = binding.retainsHistory(deepseekHistory, previousMode: deepseekBalanceBinding?.mode)
        deepseekBalanceBinding = binding
        if !sameHistory { forgetDeepSeekHistory() }
        clearDeepSeekBalance()
        return true
    }
    func restoreDeepSeekHistory() {
        deepseekHistory = .load(from: defaults)
        if let binding = deepseekBalanceBinding, binding.restoredHistory(deepseekHistory) != deepseekHistory { forgetDeepSeekHistory() }
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
            history: demo || deepseekBalanceBinding?.historySource == deepseekHistory.source ? deepseekHistory : DeepSeekBalanceHistory(),
            budgets: deepseekBudgets, spikeLimit: amount(Self.deepseekSpikeLimitKey),
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
        compactPresentation().rings.map(\.provider)
    }
    /// With no ring to draw for DeepSeek alone, the gauge shows the price clock.
    var compactGaugeShowsPriceClock: Bool { compactPresentation().gaugeClock }
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
        launchOwnedWork(.init(.activity, provider: .deepseek)) { [weak self] workTicket in
            guard let self else { return }
            defer { if generation == self.deepseekGeneration { self.ownedWork.finish(workTicket) } }
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
        else if !endedTurns.isEmpty { refreshDeepSeekBalance(turnEnded: true) }
    }

    func refreshDeepSeekBalance(force: Bool = false, scheduled: Bool = false, active: Bool? = nil, turnEnded: Bool = false, signedIn: Bool? = nil) {
        guard isModuleEnabled(.deepseek), !sleeping, !stopped, !demo else { return }
        synchronizeDeepSeekBalanceSource()
        guard deepseekBalanceTask == nil, !deepseekRefreshing, force || deepseekBalanceError?.needsConnection != true else { return }
        let mode = deepseekBalanceBinding?.mode
        let key = mode == .apiKey ? deepseekBalanceReads.apiKey() : nil
        let inputError = DeepSeekBalanceCoordinator.credentialError(mode: mode, key: key, webAvailable: true)
        guard mode != nil, inputError == nil else { deepseekBalanceError = inputError; return }
        let active = active ?? (expanded || running.contains { $0.provider == .deepseek })
        let requested = !scheduled && !turnEnded
        guard DeepSeekBalanceCoordinator.isDue(lastAttempt: deepseekBalanceState?.lastAttempt,
            failures: deepseekFailureCount, active: active, force: force, requested: requested, turnEnded: turnEnded, now: Date()) else { return }
        let owner = deepseekBalanceCoordinatorID, generation = deepseekGeneration, sourceHome = deepseekHome
        let source = DeepSeekBalanceSource.load(from: defaults), recent = deepseekUsage.provider
        let coordinator = ensureDeepSeekBalanceCoordinator(key: key)
        deepseekRefreshing = true; deepseekBalanceStarting = true
        let request = UUID(); deepseekBalanceRequestID = request
        launchOwnedWork(.init(.quota, provider: .deepseek)) { [weak self] workTicket in
            guard let self else { return }
            defer {
                if self.deepseekBalanceRequestID == request {
                    self.ownedWork.finish(workTicket); self.deepseekBalanceRequestID = nil; self.deepseekBalanceStarting = false
                }
            }
            guard !Task.isCancelled, generation == self.deepseekGeneration else { return }
            await coordinator.configure(home: sourceHome, source: source, enabled: true, recentProvider: recent, context: UInt64(generation))
            guard !Task.isCancelled, generation == self.deepseekGeneration else { return }
            if let signedIn, mode != .apiKey {
                let state = await coordinator.currentState()
                _ = await coordinator.webSessionChanged(token: state.token, newSession: signedIn)
            } else {
                _ = await coordinator.refreshIfDue(active: active, force: force, requested: requested, turnEnded: turnEnded)
            }
            if self.deepseekBalanceRequestID == request { self.deepseekBalanceStarting = false }
            self.receiveDeepSeekBalance(await coordinator.currentState(), owner: owner)
            let pending = await coordinator.refreshCompletion; await pending?.value
        }
    }
    private func ensureDeepSeekBalanceCoordinator(key: String?) -> DeepSeekBalanceCoordinator {
        let owner = deepseekBalanceCoordinatorID, generation = deepseekGeneration
        if deepseekBalanceCoordinator == nil {
            let credentials = MacDeepSeekCredentialInput(key); deepseekCredentialInput = credentials
            let reads = deepseekBalanceReads, initialHistory = deepseekHistory
            let fingerprints = DeepSeekHistoryCredential(defaults: defaults)
            let services = DeepSeekBalanceServices(readKey: { credentials.read() },
                saveKey: { let saved = DeepSeekAPIKeyStore.save($0); if saved { credentials.update($0) }; return saved },
                removeKey: { DeepSeekAPIKeyStore.remove(); credentials.update(nil); return !DeepSeekAPIKeyStore.exists },
                readAPI: { @MainActor key in try await reads.api(key) },
                fingerprint: { fingerprints.fingerprint(source: $0, identity: $1) }, readWeb: { @MainActor _ in try await reads.web() },
                loadHistory: { initialHistory }, saveHistory: { @MainActor [weak self] history, _ in
                    guard let self, self.deepseekBalanceCoordinatorID == owner, self.deepseekGeneration == generation, !self.stopped else { return }
                    if history.samples.isEmpty { self.defaults.removeObject(forKey: DeepSeekBalanceHistory.defaultsKey) }
                    else { history.save(to: self.defaults) }
                })
            deepseekBalanceCoordinator = DeepSeekBalanceCoordinator(services: services, seed: deepseekBalanceState) { [weak self] state in
                await self?.receiveDeepSeekBalance(state, owner: owner)
            }
        }
        deepseekCredentialInput?.update(key)
        return deepseekBalanceCoordinator!
    }
    private func receiveDeepSeekBalance(_ state: DeepSeekBalanceState, owner: UUID) {
        guard owner == deepseekBalanceCoordinatorID, state.context == UInt64(deepseekGeneration), !stopped, !sleeping, isModuleEnabled(.deepseek) else { return }
        // A profile can switch billing modes while Core is awaiting a read.
        // Rebind on MainActor so the replacement samples its own credential;
        // the web-mode input intentionally never reads an API key.
        if synchronizeDeepSeekBalanceSource() { refreshDeepSeekBalance(force: true); return }
        guard state.source == deepseekBalanceBinding?.source, state.mode == deepseekBalanceBinding?.mode else { return }
        let successful = state.successCount > (deepseekBalanceState?.successCount ?? 0)
        deepseekBalanceState = state; deepseekBalanceBinding = .init(source: state.source, mode: state.mode)
        deepseekBalance = state.balance; deepseekBalanceError = state.error; deepseekHistory = state.history
        deepseekRefreshing = state.refreshing || deepseekBalanceStarting; deepseekFailureCount = state.failureCount
        lastDeepSeekBalanceAttempt = state.lastAttempt ?? .distantPast
        if successful {
            now = Date()
            present(deepseekBalanceAttention.balanceNotices(deepseekWallet, low: compactLayout.warnings.contains(.lowBalance)))
            presentDeepSeekSpendNotices()
        }
        onLayoutChange?(); onStatusChange?()
    }

    /// Settings and the dial's "Sign in" both lead here.
    func connectDeepSeek() {
        switch deepseekBalanceMode {
        case .apiKey: openSettings(for: .deepseek)
        default:
            DeepSeekWebLogin.open { [weak self] newSession in
                self?.completeDeepSeekSignIn(newSession: newSession)
            }
        }
    }
    func completeDeepSeekSignIn(newSession: Bool) {
        // A challenge may keep the token, but any outstanding read predates
        // its completion. Only a new token discards the account's history.
        if DeepSeekBalanceBinding.sessionHistory(deepseekHistory, newSession: newSession) != deepseekHistory { forgetDeepSeekHistory() }
        clearDeepSeekBalance()
        refreshDeepSeekBalance(force: true, signedIn: newSession)
    }
    func saveDeepSeekAPIKey(_ raw: String) -> Bool {
        guard DeepSeekAPIKeyStore.save(raw) else { return false }
        forgetDeepSeekHistory(); clearDeepSeekBalance(); refreshDeepSeekBalance(force: true)
        return true
    }
    func removeDeepSeekConnection() {
        cancelDeepSeekBalanceRead(); lifecycle.invalidateSources([.deepseek])
        deepseekActivityTask?.cancel(); cancelOwnedWork(.init(.activity, provider: .deepseek))
        startDeepSeekActivity()
        let owner = deepseekBalanceCoordinatorID, generation = deepseekGeneration
        let coordinator = ensureDeepSeekBalanceCoordinator(key: deepseekBalanceMode == .apiKey ? deepseekBalanceReads.apiKey() : nil)
        let sourceHome = deepseekHome, source = DeepSeekBalanceSource.load(from: defaults), recent = deepseekUsage.provider
        deepseekRefreshing = true; deepseekBalanceStarting = true
        let request = UUID(); deepseekBalanceRequestID = request
        launchOwnedWork(.init(.quota, provider: .deepseek)) { [weak self] workTicket in
            guard let self else { return }
            defer {
                if self.deepseekBalanceRequestID == request {
                    self.ownedWork.finish(workTicket); self.deepseekBalanceRequestID = nil; self.deepseekBalanceStarting = false
                }
            }
            await coordinator.configure(home: sourceHome, source: source, enabled: true, recentProvider: recent, context: UInt64(generation))
            guard self.deepseekBalanceRequestID == request, !Task.isCancelled else { return }
            let state = await coordinator.currentState()
            guard let token = await coordinator.beginDisconnect(token: state.token) else {
                self.deepseekBalanceStarting = false
                self.receiveDeepSeekBalance(await coordinator.currentState(), owner: owner); return
            }
            // Core has revoked the old read and paused collection before WebKit
            // clears the owned profile. No collector can recreate site data.
            await DeepSeekWebSessionStore.signOut()
            _ = await coordinator.completeDisconnect(token: token, success: true)
            if self.deepseekBalanceRequestID == request { self.deepseekBalanceStarting = false }
            self.receiveDeepSeekBalance(await coordinator.currentState(), owner: owner)
        }
        onLayoutChange?(); onStatusChange?()
    }

    /// Another sign-in or key may be another account, so earlier readings no longer compare.
    private func forgetDeepSeekHistory() {
        deepseekHistory = DeepSeekBalanceHistory()
        defaults.removeObject(forKey: DeepSeekBalanceHistory.defaultsKey)
    }

    func resetDeepSeekSource(versionInvalidated: Bool = false) {
        if !versionInvalidated { lifecycle.invalidateSources([.deepseek]) }
        deepseekActivityTask?.cancel(); cancelOwnedWork(.init(.activity, provider: .deepseek))
        clearDeepSeekBalance(); deepseekBalanceBinding = nil
        deepseekActivityAttention = AttentionPolicy(); deepseekBalanceAttention = DeepSeekBalanceAttention()
        completionInbox.remove(provider: .deepseek)
        bindCompletionSources(.deepseek)
        deepseekReceivedActivities = []; deepseekReceivedRequests = []; deepseekAttentionRequests = []
        deepseekStreamStatuses = [:]; deepseekUsage = DeepSeekLocalUsage()
        activities.removeAll { $0.provider == .deepseek }
        clearSourceState()
        let generation = deepseekGeneration
        launchOwnedWork(.init(.reset, provider: .deepseek)) { [weak self] _ in
            guard let self, generation == self.deepseekGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
            let monitor = self.deepseekMonitor
            await ApplicationLifecycleCoordinator.cleanup([.deepseekActivity: { await monitor.shutdown() }])
            guard generation == self.deepseekGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
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
