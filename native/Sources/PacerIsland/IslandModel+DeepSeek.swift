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

/// Low and exhausted balance notices fire once each time the line is crossed.
struct DeepSeekBalanceAttention {
    private var notified: DeepSeekWallet.State?
    mutating func notices(_ wallet: DeepSeekWallet) -> [IslandNotice] {
        let state = wallet.state
        guard [.low, .exhausted, .normal].contains(state) else { return [] }
        defer { notified = state == .normal ? nil : state }
        guard state != .normal, notified != state, notified != .exhausted || state == .exhausted, let balance = wallet.balance else { return [] }
        let detail = state == .exhausted ? L10n.text("deepseek.notice.exhausted_detail")
            : L10n.text("deepseek.notice.low_detail", DeepSeekWallet.compactAmount(balance.total))
        return [IslandNotice(id: "deepseek:balance:" + (state == .exhausted ? "exhausted" : "low"), kind: .lowQuota,
            title: "DeepSeek · " + L10n.text(state == .exhausted ? "deepseek.notice.exhausted" : "deepseek.notice.low"), detail: detail)]
    }
}

extension IslandModel {
    static let deepseekLowBalanceKey = "deepseekLowBalance"
    static let deepseekTurnCostKey = "deepseekShowsTurnCost"
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
    var deepseekLowBalance: Double {
        let value = defaults.object(forKey: Self.deepseekLowBalanceKey) as? Double ?? 10
        return value.isFinite && value >= 0 ? value : 10
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
    var deepseekWallet: DeepSeekWallet {
        DeepSeekWallet(balance: deepseekBalance, connected: deepseekBalanceError == nil || deepseekBalance != nil,
            ledger: deepseekUsage.ledger, now: now, lowThreshold: deepseekBalance?.alertBound ?? deepseekLowBalance)
    }

    /// A DeepSeek row's turn estimate, unless turned off in Settings.
    func displayedTurnCost(_ activity: SessionActivity) -> Double? {
        activity.provider == .deepseek && showsDeepSeekTurnCost ? activity.turnCost : nil
    }
    /// "Updated 2 min ago" for a connected wallet.
    var deepseekBalanceFreshness: String {
        guard let captured = deepseekBalance?.capturedAt else { return L10n.text("quota.not_read") }
        let elapsed = max(0, Int(now.timeIntervalSince(captured)))
        return elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60)
    }
    /// The strip's 20-point column: `¥86`, `¥8.4`, `¥1.2k`.
    var compactStripWalletText: String {
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
                self.now = Date()
                self.present(self.deepseekBalanceAttention.notices(self.deepseekWallet))
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
                self?.clearDeepSeekBalance(); self?.refreshDeepSeekBalance(force: true)
            }
        }
    }
    func saveDeepSeekAPIKey(_ raw: String) -> Bool {
        guard DeepSeekAPIKeyStore.save(raw) else { return false }
        clearDeepSeekBalance(); refreshDeepSeekBalance(force: true)
        return true
    }
    func removeDeepSeekConnection() {
        cancelDeepSeekBalanceRead()
        deepseekGeneration += 1
        DeepSeekAPIKeyStore.remove()
        Task { await DeepSeekWebSessionStore.signOut() }
        deepseekBalance = nil; deepseekBalanceError = nil
        deepseekActivityTask?.cancel(); deepseekActivityTask = nil
        startDeepSeekActivity()
        onLayoutChange?(); onStatusChange?()
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
    }
}
