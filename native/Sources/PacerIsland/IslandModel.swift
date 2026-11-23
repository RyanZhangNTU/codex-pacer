import PacerMacSupport
import AppKit
import SwiftUI
import PacerCore

typealias QuotaDashboardPeriod = QuotaDashboardPresentation.Period
typealias QuotaDashboardQuota = QuotaDashboardPresentation.Reading

extension QuotaWindowSelection {
    var label: String { L10n.text(self == .fiveHour ? "settings.window_five_hour" : "settings.window_weekly") }
}

typealias FiveHourQuotaAlert = CompactWarningPresentation.FiveHourAlert

@MainActor
struct ClaudeQuotaReadDependencies {
    var passive: @MainActor (ClaudeQuotaClient) async -> QuotaSnapshot? = { await $0.readStatusLineOnly() }
    var webSession: @MainActor () async -> ClaudeWebSession? = { await ClaudeWebSessionStore.session() }
    var compatibility: @MainActor (ClaudeQuotaClient) async throws -> QuotaSnapshot = { try await $0.readQuota() }
    var web: @MainActor (ClaudeWebQuotaClient) async throws -> QuotaSnapshot = { try await $0.readQuota() }
    var organizations: @MainActor (ClaudeWebQuotaClient) async -> [ClaudeWebOrganization] = { await $0.organizations() }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published private var codexQuota: QuotaSnapshot? {
        didSet {
            if oldValue?.windows.count != codexQuota?.windows.count { onLayoutChange?() }
            if oldValue != codexQuota { writeCodexDelegationQuota() }
        }
    }
    @Published var activities: [SessionActivity] = [] {
        didSet {
            activityState.replaceActivities(activities, at: now)
            if latestFirstOutputLatency != activityState.latestFirstOutput?.seconds {
                latestFirstOutputLatency = activityState.latestFirstOutput?.seconds
            }
            scheduleRateExpiry()
        }
    }
    var compactPresentationCache: [Bool: (layout: CompactIslandLayout, request: CompactBarPresentation.Request, output: CompactBarPresentation.Output)] = [:]
    var activityState = ActivityApplicationState()
    var taskGroupingComputations: Int { activityState.taskGroupingComputations }
    @Published private(set) var latestFirstOutputLatency: TimeInterval?
    @Published var streamStatuses: [String: RuntimeStreamStatus] = [:]
    @Published var unavailableSSH: [String] = []
    @Published var navigationError: String?
    var navigationErrorDuration: TimeInterval = TaskRowInteraction.navigationErrorDuration
    private var navigation = ActivityNavigationState()
    var navigationClock: () -> TimeInterval = { ActivityNavigationState.monotonicNow }
    private var claudeCloudNavigationScope: String?
    @Published private(set) var hostApplications: [AgentProvider: [String: HostApplication]] = [:]
    private var hostTracking = HostApplicationTrackingState<HostApplication>()
    var lifecycle = ApplicationLifecycleCoordinator()
    private lazy var localHarnesses = LocalHarnessMonitors(platform: .macOS,
        io: .init(files: MacFileSystem(), events: MacActivityFileEvents(), now: { Date() }))
    private var localHarnessActivities = HarnessActivitySources()
    @Published private var localHarnessRevision = 0
    /// Account credits by module, for each module that reads them from its bill.
    lazy var harnessAccounts: [AgentProvider: HarnessAccountConnection] = Dictionary(uniqueKeysWithValues:
        HarnessRegistry.descriptors.compactMap { descriptor in
            descriptor.accountCredits.map { definition in
                let connection = HarnessAccountConnection(provider: descriptor.id, definition: definition, defaults: defaults)
                connection.onChange = { [weak self] in self?.receiveHarnessCredits(descriptor.id) }
                connection.onAccountReset = { [weak self] in self?.harnessCreditsAttention.reset(descriptor.id) }
                return (descriptor.id, connection)
            }
        })
    func harnessAccount(_ provider: AgentProvider) -> HarnessAccountConnection? { harnessAccounts[provider] }
    /// The last bill of each enabled module that reads one.
    var harnessCredits: [AgentProvider: HarnessAccountCredits] {
        harnessAccounts.reduce(into: [:]) { result, entry in
            if isModuleEnabled(entry.key), let credits = entry.value.credits { result[entry.key] = credits }
        }
    }
    private typealias ActivityAdapters = HarnessActivityAdapters<@MainActor @Sendable () -> Void>
    private lazy var activityAdapters: ActivityAdapters = makeActivityAdapters()

    private func makeActivityAdapters() -> ActivityAdapters {
        let realtime = realtimeMonitor, durable = durableMonitor, claude = claudeMonitor, deepseek = deepseekMonitor
        return ActivityAdapters([
            .codex: .init(start: { [weak self] in self?.refreshActivity() },
                reset: { [weak self] in self?.resetCodexSource() },
                discoverRoutes: { [weak self] in self?.refreshRemote() },
                updatePolicy: { policy, flush in await realtime.updateRefreshPolicy(policy, flushPending: flush) },
                stop: { deadline, _, _ in durable.stop(); await realtime.shutdown(deadline: deadline) }),
            .claude: .init(start: { [weak self] in self?.startClaudeActivity() },
                reset: { [weak self] in self?.resetClaudeSource() },
                discoverRoutes: { [weak self] in self?.discoverClaudeRemoteTargets() },
                updatePolicy: { [weak self] policy, flush in
                    await claude.updateRefreshPolicy(policy, flushPending: flush)
                    guard !Task.isCancelled else { return }
                    await self?.claudeCloudCoordinator?.setExpanded(flush)
                }, stop: { deadline, _, _ in await claude.shutdown(deadline: deadline) }),
            .deepseek: .init(start: { [weak self] in self?.startDeepSeekActivity() },
                reset: { [weak self] in self?.resetDeepSeekSource() }, refresh: { await deepseek.refresh() },
                updatePolicy: { policy, flush in await deepseek.updateRefreshPolicy(policy, flushPending: flush) },
                stop: { [weak self] _, reason, _ in
                    if reason == .shutdown { await self?.deepseekProgressTask?.value }
                    await deepseek.shutdown()
                })
        ], local: localHarnesses.definitions) { provider in
            .local(start: { [weak self] in self?.bindLocalHarness(provider) },
                   reset: { [weak self] in self?.resetLocalHarness(provider) },
                   monitor: { [weak self] in await self?.localActivityMonitor(provider) })
        }
    }

    private func localActivityMonitor(_ provider: AgentProvider) -> (any LocalHarnessMonitor)? { localHarnesses[provider] }

    func stopActivity(_ provider: AgentProvider, deadline: ShutdownDeadline) -> ApplicationLifecycleCoordinator.Cleanup? {
        guard let stop = activityAdapters[provider]?.stop else { return nil }
        return { await stop(deadline, .reset, nil) }
    }

    func startActivity(_ provider: AgentProvider) { activityAdapters[provider]?.start() }
    var ownedWork: ApplicationWorkRegistry { get { lifecycle.work } set { lifecycle.work = newValue } }
    func launchOwnedWork(_ key: ApplicationWorkRegistry.Key, operation: @escaping @MainActor (ApplicationWorkRegistry.Ticket) async -> Void) {
        let version = key.provider.map { UInt64(sourceGeneration(for: $0)) } ?? lifecycle.revision
        let ticket = ownedWork.begin(key, version: version)
        let task = Task { @MainActor [weak self] in
            defer { self?.ownedWork.finish(ticket) }
            await operation(ticket)
        }
        ownedWork.attach(task, to: ticket)
    }
    func cancelOwnedWork(_ key: ApplicationWorkRegistry.Key) { ownedWork.cancel(key) }
    var hostApplicationResolver: @Sendable (AgentProvider, Set<String>, URL) async -> [String: HostApplication] = { provider, sessions, home in
        await Task.detached(priority: .utility) { HostApplication.resolve(sessions: sessions, provider: provider, home: home) }.value
    }
    @Published private(set) var attentionRequests: [PendingAttentionRequest] = []
    private var localActivities: [SessionActivity] {
        get { activityState.localActivities }
        set { activityState.localActivities = newValue }
    }
    private var remoteActivities: [SessionActivity] {
        get { activityState.remoteActivities }
        set { activityState.remoteActivities = newValue }
    }
    @Published private var codexHistory = QuotaCycleHistory()
    @Published private var codexHistoryWarning: String?
    @Published private var codexErrorMessage: String?
    @Published var quotaCLI: CodexExecutableResolver.Candidate?
    @Published private var codexRefreshing = false
    @Published private var claudeQuota: QuotaSnapshot?
    @Published private(set) var claudeConnectionNeeded = false
    @Published private(set) var claudeConnectionSaved: Bool?
    @Published private var claudeHistory = QuotaCycleHistory()
    @Published private var claudeHistoryWarning: String?
    @Published private var claudeErrorMessage: String?
    @Published private var claudeRefreshing = false
    @Published private(set) var claudeQuotaSource: ClaudeQuotaSource?
    // DeepSeek has a wallet instead of quota windows; see IslandModel+DeepSeek.
    let deepseekMonitor: DeepSeekActivityMonitor
    var deepseekGeneration: Int { Int(lifecycle.version(.deepseek)) }
    var deepseekActivityTask: Task<Void, Never>? { ownedWork.task(.init(.activity, provider: .deepseek)) }
    var deepseekBalanceTask: Task<Void, Never>? { ownedWork.task(.init(.quota, provider: .deepseek)) }
    var deepseekBalanceRequestID: UUID?
    var deepseekReceivedActivities: [SessionActivity] {
        get { activityState.deepseekActivities }
        set { activityState.deepseekActivities = newValue }
    }
    var deepseekReceivedRequests: [PendingAttentionRequest] {
        get { activityState.deepseekReceivedRequests }
        set { activityState.deepseekReceivedRequests = newValue }
    }
    var deepseekAttentionRequests: [PendingAttentionRequest] {
        get { activityState.requests.filter { $0.provider == .deepseek } }
        set { activityState.replacePendingRequests(for: .deepseek, with: newValue) }
    }
    var deepseekActivityAttention: AttentionPolicy {
        get { activityState.deepseekAttention }
        set { activityState.deepseekAttention = newValue }
    }
    var deepseekBalanceAttention = DeepSeekBalanceAttention()
    var harnessCreditsAttention = HarnessCreditsNoticePolicy()
    var resetExpiryAttention = ResetExpiryNoticePolicy()
    /// Successive balance readings, for what the account was charged beyond this Mac.
    var deepseekHistory = DeepSeekBalanceHistory()
    /// Spend-spike notices stay quiet until this moment after "Not for an hour".
    var deepseekSpikeSnoozedUntil = Date.distantPast
    var deepseekFailureCount = 0
    var lastDeepSeekBalanceAttempt = Date.distantPast
    var deepseekBalanceBinding: DeepSeekBalanceBinding?
    var deepseekBalanceReads = DeepSeekBalanceReadDependencies()
    var deepseekBalanceCoordinator: DeepSeekBalanceCoordinator?
    var deepseekBalanceCoordinatorID = UUID()
    /// The newest balance history not yet written; readings arrive up to once a minute.
    var pendingDeepSeekHistory: DeepSeekBalanceHistory?
    var deepseekHistorySaveWork: DispatchWorkItem?
    /// One wallet per distinct input; a render reads it from many views.
    var deepseekWalletMemo: (inputs: DeepSeekWalletInputs, wallet: DeepSeekWallet)?
    var deepseekBalanceState: DeepSeekBalanceState?
    var deepseekCredentialInput: MacDeepSeekCredentialInput?
    var deepseekBalanceStarting = false
    @Published var deepseekStreamStatuses: [String: RuntimeStreamStatus] = [:]
    @Published var deepseekUsage = DeepSeekLocalUsage()
    @Published var deepseekBalance: DeepSeekBalance?
    @Published var deepseekBalanceError: DeepSeekBalanceError?
    @Published var deepseekRefreshing = false
    @Published private(set) var selectedProvider: AgentProvider = .codex
    @Published private(set) var enabledProviders: [AgentProvider] = []
    private var installation: ProviderInstallationDetection
    private let installationOverride: ProviderInstallationDetection?
    let defaults: UserDefaults
    private var modules = ProviderModules()
    /// Quota windows exist for Codex and Claude only; DeepSeek reports nil.
    var quota: QuotaSnapshot? {
        get { providerQuota(selectedProvider) }
        set {
            switch selectedProvider {
            case .codex: codexQuota = newValue
            case .claude: claudeQuota = newValue
            default: return
            }
            onLayoutChange?()
        }
    }
    var history: QuotaCycleHistory {
        get { providerHistory(selectedProvider) }
        set {
            switch selectedProvider {
            case .codex: codexHistory = newValue
            case .claude: claudeHistory = newValue
            default: break
            }
        }
    }
    var historyWarning: String? {
        get { providerHistoryWarning(selectedProvider) }
        set {
            switch selectedProvider {
            case .codex: codexHistoryWarning = newValue
            case .claude: claudeHistoryWarning = newValue
            default: break
            }
        }
    }
    var errorMessage: String? {
        get { providerQuotaError(selectedProvider) }
        set {
            switch selectedProvider {
            case .codex: codexErrorMessage = newValue
            case .claude: claudeErrorMessage = newValue
            default: break
            }
        }
    }
    func isModuleEnabled(_ provider: AgentProvider) -> Bool { enabledProviders.contains(provider) }
    var localHarnessDescriptors: [HarnessDescriptor] { localHarnesses.definitions.map(\.descriptor) }
    /// Every module this Mac can run, in registry order.
    var supportedModules: [AgentProvider] { HarnessRegistry.legacyIDs + localHarnessDescriptors.map(\.id) }
    /// The module library for `modules`, which Settings edits before applying them.
    func moduleLibrary(_ modules: ProviderModules) -> ModuleLibrary {
        ModuleLibrary(modules: modules, detection: installation, supported: supportedModules)
    }
    var quotaProviders: [AgentProvider] {
        enabledProviders.filter { HarnessRegistry.descriptor(for: $0)?.hasQuotaDisplay == true }
    }
    func localHarnessStatus(_ provider: AgentProvider) -> HarnessSourceStatus? { localHarnessActivities[provider]?.status }
    /// A module's last week of credits from its local usage, nil until two
    /// finished days have some.
    func harnessWeek(_ provider: AgentProvider) -> DeepSeekSoloPresentation.Week? {
        // The demo has no local data, so a WorkBuddy turned on shows the shared demo week.
        let daily = demo ? (provider == .workbuddy && isModuleEnabled(provider) ? DemoScenario.workbuddyDaily(at: now) : [])
            : localHarnessUsage(provider)?.daily ?? []
        return HarnessWeekPresentation.week(provider: provider, daily: daily, now: now)
    }
    func localHarnessUsage(_ provider: AgentProvider) -> HarnessUsage? {
        guard let reading = localHarnessActivities[provider], reading.status == .ready else { return nil }
        return reading.usage
    }
    func providerDetected(_ provider: AgentProvider) -> Bool { installation.isInstalled(provider) }
    func providerRefreshing(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .codex: codexRefreshing
        case .claude: claudeRefreshing
        case .deepseek: deepseekRefreshing
        default: false
        }
    }
    func providerStreamStatuses(_ provider: AgentProvider) -> [String: RuntimeStreamStatus] {
        switch provider {
        case .codex: streamStatuses
        case .claude: claudeStreamStatuses
        case .deepseek: deepseekStreamStatuses
        default: [:]
        }
    }
    func taskPresentationOptions(for values: [SessionActivity]) -> TaskPresentationOptions {
        let hosts = hostTracking.labels(for: values, activities: activities, inbox: completionInbox,
            remoteSourceIDs: Set(claudeRemoteTargets.map(\.id))) { .init(name: $0.name, isClaudeDesktop: $0.isClaudeDesktop) }
        var options = TaskPresentationOptions(hideProjects: hideProjects, hostApplications: hosts,
            sourceNames: streamStatuses.compactMapValues(\.sourceName), showsDeepSeekTurnCost: showsDeepSeekTurnCost,
            progressRingProviders: progressRingProviders, pageSize: panelOptions.pageSize,
            showsDelegationRows: true)
        options.hiddenTurnCredits = hiddenTurnCredits
        return options
    }
    func taskSourceName(_ activity: SessionActivity) -> String? {
        ActivityTaskRowPresentation.sourceName(activity, options: taskPresentationOptions(for: [activity]))
    }
    func providerQuota(_ provider: AgentProvider) -> QuotaSnapshot? {
        switch provider {
        case .codex: codexQuota
        case .claude: claudeQuota
        default: nil
        }
    }
    func providerQuotaError(_ provider: AgentProvider) -> String? {
        switch provider {
        case .codex: codexErrorMessage
        case .claude: claudeErrorMessage
        case .deepseek: deepseekBalanceError?.errorDescription
        default: nil
        }
    }
    func providerWindow(_ provider: AgentProvider, period: QuotaDashboardPeriod) -> QuotaWindow? {
        QuotaDashboardPresentation.window(provider: provider, snapshot: providerQuota(provider), period: period)
    }
    /// A weekly-only account, such as Codex Pro, has no 5-hour window to choose.
    func providerIsWeeklyOnly(_ provider: AgentProvider) -> Bool {
        QuotaDashboardPresentation.isWeeklyOnly(provider: provider, snapshot: providerQuota(provider))
    }
    func providerHistory(_ provider: AgentProvider) -> QuotaCycleHistory {
        switch provider {
        case .codex: codexHistory
        case .claude: claudeHistory
        default: QuotaCycleHistory()
        }
    }
    func providerHistoryWarning(_ provider: AgentProvider) -> String? {
        switch provider {
        case .codex: codexHistoryWarning
        case .claude: claudeHistoryWarning
        default: nil
        }
    }
    func providerCurrentCycle(_ provider: AgentProvider) -> QuotaCycle? {
        providerHistory(provider).currentCycle(for: providerWindow(provider, period: .weekly), at: now)
    }
    func providerSourceText(_ provider: AgentProvider) -> String? {
        switch provider {
        case .codex: providerQuota(provider) == nil ? nil : L10n.text("quota.source_codex")
        case .claude: claudeQuotaSource?.label
        case .deepseek: deepseekBalance.map { L10n.text($0.source == .web ? "deepseek.source.web" : "deepseek.source.api") }
        default: nil
        }
    }
    func providerFreshnessText(_ provider: AgentProvider, period: QuotaDashboardPeriod? = nil) -> String {
        let window = period.map { providerWindow(provider, period: $0) } ?? providerSelectedWindow(provider)
        return QuotaDashboardPresentation.freshness(snapshot: providerQuota(provider), window: window,
            failed: providerQuotaError(provider) != nil, refreshing: providerRefreshing(provider), now: now)
    }
    func dashboardQuota(provider: AgentProvider, period: QuotaDashboardPeriod) -> QuotaDashboardQuota {
        QuotaDashboardPresentation.Reading(provider: provider, period: period, snapshot: providerQuota(provider),
            failed: providerQuotaError(provider) != nil, refreshing: providerRefreshing(provider),
            sourceText: providerSourceText(provider), now: now)
    }
    func selectProvider(_ provider: AgentProvider) {
        guard quotaProviders.contains(provider), selectedProvider != provider else { return }
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: "selectedQuotaProvider")
        onLayoutChange?(); onStatusChange?()
    }
    /// The collapsed window: 5 hours when chosen and reported, otherwise 7 days,
    /// both from the provider's own bucket. A saved 5-hour choice falls back to
    /// 7 days on an account without that window.
    func providerSelectedWindow(_ provider: AgentProvider, selection: String? = nil) -> QuotaWindow? {
        QuotaDashboardPresentation.selectedWindow(provider: provider, snapshot: providerQuota(provider),
            selection: selection ?? defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID"))
    }
    /// The collapsed value usually shows a longer window, so the warning watches
    /// each provider's 5h window: below 20% is low and zero is exhausted. Stale,
    /// expired or failed quota never produces a live alert.
    func fiveHourAlert(_ provider: AgentProvider) -> FiveHourQuotaAlert? {
        CompactWarningPresentation.fiveHourAlert(provider: provider, snapshot: providerQuota(provider),
            failed: providerQuotaError(provider) != nil, now: now)
    }
    var claudeHome: URL {
        let configured = defaults.string(forKey: "claudeHome") ?? ""
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    enum ClaudeLocalSetup: Equatable { case checking, configuring, ready, missingHome, failed }
    /// Local hooks follow the Claude module: kept current while it is on.
    @Published private(set) var claudeLocalSetup: ClaudeLocalSetup = .checking
    /// Why this Mac's Claude request telemetry is off, once setup has run.
    @Published private(set) var claudeTelemetryConflict: ClaudeTelemetryConflict = .none
    /// True while the note about estimated speeds belongs on the local row:
    /// a conflict, and no exact span has arrived this run (a collector can
    /// still forward them).
    var claudeLocalSpeedsEstimated: Bool {
        claudeLocalSetup == .ready && claudeTelemetryConflict != .none && claudeStreamStatuses["local"]?.exactRequestSpans != true
    }
    /// The latest hook setup; the next one waits for it, so two never edit
    /// Claude's settings at the same time.
    private var claudeHookSetup: Task<ClaudeHookInstaller.EnsureResult, Never>?
    private func installClaudeHooks(home: URL) async -> ClaudeHookInstaller.EnsureResult {
        let previous = claudeHookSetup
        let setup = Task.detached(priority: .utility) {
            _ = await previous?.value
            return ClaudeHookInstaller.ensureInstalled(home: home)
        }
        claudeHookSetup = setup
        return await setup.value
    }
    private func ensureClaudeHooks(home: URL, generation: Int) async {
        guard generation == claudeGeneration else { return }
        if claudeLocalSetup != .ready { claudeLocalSetup = .configuring }
        // Switches that Pacer's folder can already hold are set up in the same pass.
        applyClaudeProgressSwitch(home: home)
        applyCodexDelegationSwitch(home: home)
        var result = await installClaudeHooks(home: home)
        guard generation == claudeGeneration else { return }
        // Setup creates Pacer's hook folder, which the switch files need, and
        // confirms that Pacer manages this home.
        if result == .current || result == .installed {
            let ring = applyClaudeProgressSwitch(home: home, setupConfirmed: true)
            let delegation = applyCodexDelegationSwitch(home: home, setupConfirmed: true)
            if ring || delegation {
                let again = await installClaudeHooks(home: home)
                guard generation == claudeGeneration else { return }
                if again != .current { result = again }
            }
        }
        var conflict = ClaudeTelemetryConflict.none
        if result == .current || result == .installed {
            conflict = await Task.detached(priority: .utility) { ClaudeHookInstaller.details(home: home).telemetryConflictReason }.value
            guard generation == claudeGeneration else { return }
        }
        if claudeTelemetryConflict != conflict { claudeTelemetryConflict = conflict }
        switch result {
        case .current: claudeLocalSetup = .ready
        case .installed: claudeLocalSetup = .ready; settingsRevision += 1
        case .missingHome: claudeLocalSetup = .missingHome
        case .failed: claudeLocalSetup = .failed
        }
    }
    func retryClaudeLocalSetup() {
        guard isModuleEnabled(.claude), !demo, !stopped else { return }
        let home = claudeHome, generation = claudeGeneration
        launchOwnedWork(.init(.setup, provider: .claude, identifier: "local")) { [weak self] _ in
            await self?.ensureClaudeHooks(home: home, generation: generation)
        }
    }
    static let claudeProgressRingKey = "claudeProgressRing"
    static let codexProgressRingKey = "codexProgressRing"
    static let deepseekProgressRingKey = "deepseekProgressRing"
    /// Every service's ring is on until the user turns it off; a stored
    /// choice, on or off, always wins.
    static func progressRingEnabled(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
    @Published private(set) var deepseekProgressSetup: DeepSeekProgressSetupStatus?
    private var deepseekProgressQueue = ProgressSetupQueue<DeepSeekProgressSetup.Target>()
    /// The newest setup, which waits for the earlier ones; shutdown lets it finish.
    private var deepseekProgressTask: Task<Void, Never>?
    var showsDeepSeekProgressRing: Bool { Self.progressRingEnabled(Self.deepseekProgressRingKey, in: defaults) }
    /// Also runs when the switch turns off, which removes Pacer's entry.
    func syncDeepSeekProgressSwitch(force: Bool = false) {
        guard !demo, !stopped, installationOverride == nil, let ticket = deepseekProgressQueue.request(
            .init(home: deepseekHome, enabled: showsDeepSeekProgressRing && isModuleEnabled(.deepseek)), force: force) else { return }
        deepseekProgressSetup = ticket.target.enabled ? .settingUp : nil
        let task = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                await ticket.waitForPrevious()
                return DeepSeekProgressSetup.sync(from: ticket.previous, to: ticket.target, storage: MacClaudeHookStorage())
            }.value
            guard let self, !stopped, deepseekProgressQueue.finish(ticket) else { return }
            deepseekProgressTask = nil
            deepseekProgressSetup = status
        }
        deepseekProgressQueue.track(task)
        deepseekProgressTask = task
    }
    @Published private(set) var codexProgressSetup: CodexProgressSetupStatus?
    private var codexProgressQueue = ProgressSetupQueue<CodexProgressSetup.Target>()
    private var codexProgressFlagTask: Task<Int, Never>?
    /// Whether Pacer's Codex hooks are installed, allowed in Codex and writing events.
    @Published private(set) var codexHookStatus: CodexHookStatus = .off
    private var codexHookResult: CodexHookSetupResult?
    /// Setup passes run one at a time; each knows the home the previous one used.
    private var codexHookQueue = ProgressSetupQueue<CodexHookTarget>()
    private static let codexHookHomeKey = "codexHookManagedHome"
    struct CodexHookTarget: Equatable, Sendable {
        let home: URL
        let executable: String
        let enabled: Bool
    }
    typealias CodexHookSetupCall = @Sendable (_ home: URL, _ executable: String, _ enabled: Bool) async -> CodexHookSetupResult
    /// Tests replace the installer and the trust read. Without them, a model given its installation never touches a Codex home.
    var codexHookSetupOverride: CodexHookSetupCall?
    var codexHookTrustOverride: (@Sendable (_ home: URL, _ executable: String) async -> [String]?)?
    private var codexHookStatusCheckedAt = Date.distantPast
    /// The rollout folders are listed at most this often for the status.
    static let codexHookStatusInterval: TimeInterval = 60
    /// While the user still has to allow the hooks in Codex: when to ask Codex again.
    private var codexTrustWatch: CodexHookTrustWatch?
    private var codexTrustTimer: Timer?
    private var codexTrustCheck: Task<Void, Never>?
    /// When Pacer saw the hooks become allowed; earlier turns ran without them.
    private var codexHooksTrustedAt: Date?
    /// The small floating guide beside Codex while the user allows the hooks.
    private(set) lazy var codexHooksGuideFloat = CodexHooksGuideFloat(model: self)

    /// Installs Pacer's Codex hooks while the Codex module is on and removes them
    /// when it is off. Setup is idempotent: an unchanged plugin is not reinstalled.
    /// Moving to another Codex home first removes them from the one Pacer leaves,
    /// and passes run in order, so a quick series of switches ends with the hooks
    /// in the last home only. `force` runs an unchanged target again (Retry).
    func syncCodexHooks(force: Bool = false) {
        guard !demo, installationOverride == nil || codexHookSetupOverride != nil,
              let ticket = codexHookQueue.request(.init(home: home, executable: defaults.string(forKey: "codexExecutable") ?? "",
                                                         enabled: isModuleEnabled(.codex) && !stopped), force: force) else { return }
        let target = ticket.target
        let setup: CodexHookSetupCall = codexHookSetupOverride ?? { home, executable, enabled in
            await MacCodexHookSetup.apply(home: home, customExecutable: executable, enabled: enabled)
        }
        let task = Task { [weak self] in
            await ticket.waitForPrevious()
            guard let self else { return }
            let result = await self.applyCodexHooks(target, using: setup)
            guard self.codexHookQueue.finish(ticket) else { return }
            self.codexHookResult = result
            await self.updateCodexHookStatus(force: true)
        }
        codexHookQueue.track(task)
    }

    private func applyCodexHooks(_ target: CodexHookTarget, using setup: CodexHookSetupCall) async -> CodexHookSetupResult {
        if let previous = defaults.dictionary(forKey: Self.codexHookHomeKey) as? [String: String],
           let path = previous["home"], path != target.home.path {
            let removed = await setup(URL(fileURLWithPath: path, isDirectory: true), previous["executable"] ?? "", false)
            guard removed.installed == false else { return removed }
            defaults.removeObject(forKey: Self.codexHookHomeKey)
        }
        // Installation can write only part of the plugin before failing or quitting.
        // Keep its home until Codex confirms removal, including across a restart.
        if target.enabled {
            defaults.set(["home": target.home.path, "executable": target.executable], forKey: Self.codexHookHomeKey)
        }
        let result = await setup(target.home, target.executable, target.enabled)
        if !target.enabled, result.installed == false { defaults.removeObject(forKey: Self.codexHookHomeKey) }
        return result
    }

    /// A Codex too old for hooks updates itself and starts again: its launch is
    /// when to set the hooks up again, so the status follows without Retry.
    func codexApplicationDidLaunch(_ bundleIdentifier: String?) {
        guard bundleIdentifier == "com.openai.codex", codexHookStatus == .needsCodexUpdate else { return }
        syncCodexHooks(force: true)
    }

    /// Running tasks this computer reads for `provider`, not those of other hosts, Dot or the cloud, counted as on Windows.
    func localRunningSessions(_ provider: AgentProvider) -> Int {
        ModuleMonitoring.localSessions(activities, provider: provider, at: now)
    }

    /// Claude's local setup in the vocabulary every module page shares.
    var claudeMonitoring: ModuleMonitoring {
        let setup: ModuleMonitoring.Setup = switch claudeLocalSetup {
        case .checking: .checking
        case .configuring: .configuring
        case .ready: .ready
        case .missingHome: .missingHome
        case .failed: .failed
        }
        let note = claudeLocalSpeedsEstimated ? SettingsView.claudeTelemetryNote(claudeTelemetryConflict) : nil
        return .claude(setup, sessions: localRunningSessions(.claude), note: note)
    }

    /// DeepSeek Harness, found once its sessions folder is read.
    var deepseekMonitoring: ModuleMonitoring {
        .deepseek(found: providerStreamStatuses(.deepseek)["local"]?.connected, sessions: localRunningSessions(.deepseek))
    }

    /// A local harness's data folder.
    func harnessMonitoring(_ provider: AgentProvider) -> ModuleMonitoring {
        .harness(localHarnessStatus(provider), detected: providerDetected(provider), sessions: localRunningSessions(provider))
    }

    /// The ChatGPT account Codex is signed in to, as its quota read shows it.
    var codexAccount: CodexAccountState { CodexAccountState(quota: codexQuota, error: codexErrorMessage) }

    /// Codex itself, where the user signs in; its settings open with the hooks guide elsewhere.
    func openCodexApplication() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The user has to act in Codex before local Codex tasks can show.
    var codexHooksNeedUser: Bool {
        switch codexHookStatus {
        case .needsApproval, .notRunning: return true
        default: return false
        }
    }
    private func postCodexHooksNotice() {
        present([IslandNotice(id: Self.codexHooksNoticeID, kind: .waitingForInput,
                              title: L10n.text("codex.hooks.notice_title"), detail: L10n.text("codex.hooks.notice_body"))])
    }
    /// Dot tasks come from the catalog poll while the Dot switch and the Codex module are on.
    /// Route refreshes call this every 30 seconds; the monitor keeps a poll that follows this home.
    func syncDurable() {
        guard monitorsDurable, isModuleEnabled(.codex), !demo, !stopped, !sleeping else { stopDurable(); return }
        let generation = sourceGeneration, visibility = durablePanelInView
        visibility.set(visiblyExpanded)
        durableMonitor.start(home: home, panelInView: { visibility.value }) { [weak self] activities, scope in
            DispatchQueue.main.async {
                guard let self, generation == self.sourceGeneration, !self.stopped else { return }
                if self.durableAccountScope != scope { self.durableAccountScope = scope; self.bindCompletionSources(.codex) }
                self.durableActivities = activities
                self.now = Date(); self.remoteActivities = self.sshActivities + activities
                self.refilterEmbeddedSessions()
            }
        }
    }

    func stopDurable() {
        durableMonitor.stop()
        guard !durableActivities.isEmpty else { return }
        durableActivities = []; remoteActivities = sshActivities
    }

    /// The notice asking to allow Pacer's hooks in Codex; clicking it opens Codex's page.
    static let codexHooksNoticeID = "codex:hooks-approval"
    /// Shared with Windows: the one notice asking to allow Pacer's hooks in Codex was sent.
    static let codexHooksApprovalNotifiedKey = "codexHooksApprovalNotified"

    /// Recomputes the status; the rollout folders are listed at most once a minute.
    func updateCodexHookStatus(force: Bool = false, now: Date = Date()) async {
        guard force || now.timeIntervalSince(codexHookStatusCheckedAt) >= Self.codexHookStatusInterval else { return }
        codexHookStatusCheckedAt = now
        let evidence = await reader.hookEvidence(home: self.home, now: now)
        codexHookEvaluatedRow = evidence.lastHookEvent
        let result = codexHookResult, awaitsTrust = result?.awaitsTrust == true
        var status = CodexHookStatus.evaluate(enabled: isModuleEnabled(.codex) && !demo, supportsHooks: result?.supportsHooks,
            installed: result == nil ? false : result?.installed, trust: result?.trust,
            lastHookEvent: evidence.lastHookEvent, lastCodexTurn: evidence.lastCodexTurn, trustedAt: codexHooksTrustedAt, now: now)
        let waiting: Bool
        if case .needsApproval = status { waiting = true } else { waiting = false }
        switch status {
        case .needsApproval: codexHooksAwaitingApproval = true
        case .running, .notRunning:
            // Just allowed: the turns so far ran without the hooks, so their silence says nothing.
            if codexHooksAwaitingApproval { codexHooksAwaitingApproval = false; codexHooksTrustedAt = now; status = .running }
        case .notInstalled where awaitsTrust: break // The trust is unknown, not changed.
        default: codexHooksAwaitingApproval = false
        }
        if codexHookStatus != status { codexHookStatus = status }
        if waiting, !defaults.bool(forKey: Self.codexHooksApprovalNotifiedKey) {
            defaults.set(true, forKey: Self.codexHooksApprovalNotifiedKey)
            postCodexHooksNotice()
        }
        // While the user approves, and after Codex failed to report the trust, which is asked again at once.
        if waiting { watchCodexHookTrust(true) } else { watchCodexHookTrust(awaitsTrust, due: true) }
    }
    /// The hooks waited for approval; kept while a failed trust read leaves it unknown.
    private var codexHooksAwaitingApproval = false

    /// The newest hook row the last status saw.
    private var codexHookEvaluatedRow: Date?

    /// Once the hooks are installed, only activity tells a silent hook from an idle
    /// Codex. The clock asks at most once a minute (the status's own limit), so a
    /// silence shows within about a minute while Codex works and costs one listing
    /// of two day folders a minute otherwise.
    func refreshCodexHookStatusOnClock(now: Date = Date()) {
        guard codexHookResult?.installed == true, !demo, !sleeping, !stopped else { return }
        Task { [weak self] in await self?.updateCodexHookStatus(now: now) }
    }

    /// A read that brought a new hook row while the hooks are reported silent
    /// recomputes at once, so the notice clears by itself without Retry.
    private func refreshCodexHookStatusAfterRead() {
        guard codexHookStatus == .notRunning else { return }
        Task { [weak self] in
            guard let self, let row = await self.reader.lastHookRow, row != self.codexHookEvaluatedRow else { return }
            await self.updateCodexHookStatus(force: true)
        }
    }

    /// While the hooks wait for the user, a change to Codex's config is the cue
    /// to ask Codex for their trust, which only the trust call does; the plugin stays as it is.
    private func watchCodexHookTrust(_ on: Bool, due: Bool = false) {
        guard on else {
            codexTrustTimer?.invalidate(); codexTrustTimer = nil; codexTrustWatch = nil
            return
        }
        guard codexTrustTimer == nil else { return }
        codexTrustWatch = CodexHookTrustWatch(stamp: Self.modified(CodexHookTrustWatch.trustFile(home: home)), now: Date(), due: due)
        let timer = Timer(timeInterval: CodexHookTrustWatch.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCodexHookTrust() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        codexTrustTimer = timer
    }

    private func checkCodexHookTrust() {
        guard codexTrustCheck == nil, var watch = codexTrustWatch,
              watch.shouldCheck(stamp: Self.modified(CodexHookTrustWatch.trustFile(home: home)), now: Date()) else { return }
        codexTrustWatch = watch
        let home = self.home, executable = defaults.string(forKey: "codexExecutable") ?? ""
        let read = codexHookTrustOverride ?? { home, executable in await MacCodexHookSetup.trust(home: home, customExecutable: executable) }
        codexTrustCheck = Task { [weak self] in
            let trust = await Task.detached(priority: .utility) { await read(home, executable) }.value
            guard let self else { return }
            self.codexTrustCheck = nil
            guard !Task.isCancelled, self.home == home, let trust, let result = self.codexHookResult, result.installed == true else { return }
            self.codexHookResult = .init(supportsHooks: result.supportsHooks, installed: result.installed, trust: trust)
            await self.updateCodexHookStatus(force: true)
        }
    }

    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Codex Desktop can open its settings, where the user allows the hooks.
    var canOpenCodexSettings: Bool { NSWorkspace.shared.urlForApplication(toOpen: CodexHookTrustWatch.settingsURL) != nil }

    /// Opens Codex's settings with the floating guide beside it on `screen`, the one Settings is on.
    func openCodexHooksGuide(screen: NSScreen?) {
        codexHooksGuideFloat.show(on: screen)
        NSWorkspace.shared.open(CodexHookTrustWatch.settingsURL, configuration: NSWorkspace.OpenConfiguration()) { [weak float = codexHooksGuideFloat] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { float?.close() }
        }
    }
    private let codexProgressGate = CodexProgressSwitchGate()
    var showsCodexProgressRing: Bool { Self.progressRingEnabled(Self.codexProgressRingKey, in: defaults) }
    func syncCodexProgressSwitch(force: Bool = false) {
        guard !demo, !stopped, installationOverride == nil, let reporter = Bundle.main.executableURL,
              let ticket = codexProgressQueue.request(.init(home: home, executable: defaults.string(forKey: "codexExecutable") ?? "",
                                                            enabled: showsCodexProgressRing && isModuleEnabled(.codex)), force: force) else { return }
        let target = ticket.target, durable = monitorsDurable
        // Apply flag changes in order, off the main actor and independently
        // of any earlier setup that is still waiting for Codex.
        let gate = codexProgressGate, previousHome = ticket.previous?.home
        let previousFlagTask = codexProgressFlagTask
        let flagTask = Task.detached(priority: .userInitiated) {
            _ = await previousFlagTask?.value
            return gate.change(home: target.home, wanted: target.enabled, previous: previousHome, storage: MacClaudeHookStorage())
        }
        codexProgressFlagTask = flagTask
        codexProgressSetup = target.enabled ? .settingUp : nil
        let task = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                let generation = await flagTask.value
                await ticket.waitForPrevious()
                if let previous = ticket.previous, previous.home != target.home {
                    _ = await Self.configureCodexReporter(home: previous.home, executable: previous.executable, reporter: reporter, enabled: false, durable: false)
                }
                return await Self.configureCodexReporter(home: target.home, executable: target.executable, reporter: reporter, enabled: target.enabled,
                                                         durable: durable, gate: gate, request: generation)
            }.value
            guard let self, !stopped, codexProgressQueue.finish(ticket) else { return }
            codexProgressFlagTask = nil
            codexProgressSetup = status
        }
        codexProgressQueue.track(task)
        scheduleCodexRemoteProgress()
    }

    /// Codex starts MCP servers from the config.toml of the host a task runs
    /// on, so connected SSH hosts get Pacer's progress tool too, on Claude's
    /// schedule. Nothing is shown: a failed run only backs off. With the ring
    /// off, only hosts this Mac set up are visited, to take the tool away.
    private var codexRemoteProgressRequests: [String: UUID] = [:]
    private var codexRemoteProgressFailedAt: [String: Date] = [:]
    /// This launch's successful runs, so hosts set up earlier are checked again.
    private var codexRemoteProgressCheckedAt: [String: Date] = [:]
    private lazy var codexRemoteProgressDigests: (off: String, on: String)? = {
        guard let off = try? CodexRemoteProgressSetup.digest(enabled: false),
              let on = try? CodexRemoteProgressSetup.digest(enabled: true) else { return nil }
        return (off, on)
    }()
    private var codexRemoteProgressRing: Bool { showsCodexProgressRing && isModuleEnabled(.codex) }
    private var codexRemoteProgressDigest: String? { codexRemoteProgressDigests.map { codexRemoteProgressRing ? $0.on : $0.off } }

    /// Hosts that need a run now. Off visits only hosts with a recorded setup.
    static func codexRemoteProgressPending(targets: [RemoteActivityTarget], statuses: [String: RuntimeStreamStatus],
                                           configured: [String: String], ring: Bool, digest: String, failures: [String: Date],
                                           inFlight: Set<String>, checkedAt: [String: Date], now: Date) -> [RemoteActivityTarget] {
        ClaudeRemoteAutoSetup.pending(targets: targets.filter { ring || configured[$0.alias] != nil }, statuses: statuses,
            configured: configured, digest: digest, failures: failures, inFlight: inFlight, now: now, checkedAt: checkedAt)
    }

    private func scheduleCodexRemoteProgress() {
        guard isModuleEnabled(.codex), monitorsSSH, !demo, !sleeping, !stopped, let digest = codexRemoteProgressDigest else { return }
        let pending = Self.codexRemoteProgressPending(targets: RemoteActivityTarget.configured(home: home), statuses: streamStatuses,
            configured: CodexRemoteProgressSetup.configuredDigests(defaults: defaults), ring: codexRemoteProgressRing, digest: digest,
            failures: codexRemoteProgressFailedAt, inFlight: Set(codexRemoteProgressRequests.keys),
            checkedAt: codexRemoteProgressCheckedAt, now: Date())
        for target in pending {
            launchOwnedWork(.init(.setup, provider: .codex, identifier: "remote-progress:" + target.id)) { [weak self] _ in
                _ = await self?.configureCodexRemoteProgress(target: target)
            }
        }
    }

    /// One run on `target` with the current ring. Success records the digest,
    /// so the host stays quiet until an update or the ring changes it. A
    /// host whose own `pacer_progress` entry was kept counts as checked too.
    @discardableResult
    func configureCodexRemoteProgress(target: RemoteActivityTarget) async -> CodexRemoteProgressSetup.Status? {
        guard isModuleEnabled(.codex), monitorsSSH, !sleeping, !stopped, !Task.isCancelled,
              codexRemoteProgressRequests[target.id] == nil, let digests = codexRemoteProgressDigests else { return nil }
        // One read of the switch, so the recorded digest always describes the request sent.
        let ring = codexRemoteProgressRing, digest = ring ? digests.on : digests.off
        let generation = sourceGeneration, requestID = UUID(), transport = claudeRemoteSetup
        codexRemoteProgressRequests[target.id] = requestID
        // Runs after the defer below has cleared this host's in-flight state.
        var outdated = false
        defer { if outdated { scheduleCodexRemoteProgress() } }
        defer { if codexRemoteProgressRequests[target.id] == requestID { codexRemoteProgressRequests.removeValue(forKey: target.id) } }
        do {
            let status = try await CodexRemoteProgressSetup.install(target: target, enabled: ring, transport: transport)
            guard !Task.isCancelled, generation == sourceGeneration, codexRemoteProgressRequests[target.id] == requestID,
                  isModuleEnabled(.codex), monitorsSSH, !sleeping, !stopped else { return nil }
            CodexRemoteProgressSetup.recordConfigured(alias: target.alias, digest: digest, defaults: defaults)
            codexRemoteProgressCheckedAt[target.id] = Date(); codexRemoteProgressFailedAt.removeValue(forKey: target.id)
            outdated = digest != codexRemoteProgressDigest
            return status
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration, codexRemoteProgressRequests[target.id] == requestID,
                  error as? ClaudeRemoteSetup.Failure != .cancelled else { return nil }
            codexRemoteProgressFailedAt[target.id] = Date()
            return nil
        }
    }

    private func cancelCodexRemoteProgress(clearHistory: Bool = false) {
        for targetID in codexRemoteProgressRequests.keys {
            cancelOwnedWork(.init(.setup, provider: .codex, identifier: "remote-progress:" + targetID))
        }
        codexRemoteProgressRequests.removeAll()
        if clearHistory { codexRemoteProgressFailedAt.removeAll(); codexRemoteProgressCheckedAt.removeAll() }
    }

    private nonisolated static func configureCodexReporter(home: URL, executable: String, reporter: URL, enabled: Bool, durable: Bool,
                                                           gate: CodexProgressSwitchGate? = nil, request: Int = 0) async -> CodexProgressSetupStatus? {
        let command: CodexProgressCommand? = enabled ? .native(executable: reporter, home: home) : nil
        let status = await CodexProgressSetup.apply(home: home, reporter: command, storage: MacClaudeHookStorage(),
                                              gate: gate, request: request, owns: {
            $0.isNative(named: reporter.lastPathComponent, home: home)
        }) {
            // Setup also runs at login beside the other Codex readers, so it
            // allows a cold start as long as the realtime collector does.
            CodexClient.findExecutable(customPath: executable).map { CodexClient(executable: $0, home: home, timeout: 8) }
        }
        if !enabled || status == .ready {
            // The Dot plugin is best effort: a failed install leaves local
            // sessions reporting and is retried by the next setup.
            // With Dot off the plugin is removed, as when the ring is off.
            _ = await MacDurableProgressSetup.apply(home: home, reporter: enabled && durable ? reporter : nil,
                                                    customExecutable: executable)
        }
        return status
    }
    /// Shared with Windows: modules whose progress ring is turned off. Rings
    /// are on until the user turns them off.
    static let disabledHarnessProgressKey = "disabledHarnessProgress"
    /// Shared with Windows: modules whose task rows hide each turn's credits.
    static let hiddenTurnCreditsKey = "hiddenTurnCredits"
    /// Shared with Windows: local modules' data folders chosen in Settings, by ID.
    static let harnessHomesKey = "harnessHomes"
    /// Shared with Windows: each credits module's display and reminder choices, by ID.
    static let harnessCreditsKey = "harnessCredits"
    /// Decoded once per change: the bar and notices read these often.
    private(set) lazy var creditSettings: [AgentProvider: HarnessCreditsSettings] = Self.loadCreditSettings(defaults)
    func creditSettings(_ provider: AgentProvider) -> HarnessCreditsSettings { creditSettings[provider] ?? .default }
    static func loadCreditSettings(_ defaults: UserDefaults) -> [AgentProvider: HarnessCreditsSettings] {
        guard let data = defaults.data(forKey: harnessCreditsKey),
              let stored = try? JSONDecoder().decode([String: HarnessCreditsSettings].self, from: data) else { return [:] }
        // IDs this version does not know are kept on disk and ignored here.
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in AgentProvider(rawValue: key).map { ($0, value) } })
    }
    /// Saves one module's choices, keeping entries for modules this version does not know.
    func setCreditSettings(_ provider: AgentProvider, _ value: HarnessCreditsSettings) {
        var stored = (defaults.data(forKey: Self.harnessCreditsKey)).flatMap {
            try? JSONDecoder().decode([String: HarnessCreditsSettings].self, from: $0)
        } ?? [:]
        stored[provider.rawValue] = value == .default ? nil : value
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.harnessCreditsKey) }
        creditSettings = Self.loadCreditSettings(defaults)
        receiveHarnessCredits(provider)
    }
    func showsHarnessProgress(_ provider: AgentProvider) -> Bool {
        !(defaults.stringArray(forKey: Self.disabledHarnessProgressKey) ?? []).contains(provider.rawValue)
    }
    var hiddenTurnCredits: Set<AgentProvider> {
        Set((defaults.stringArray(forKey: Self.hiddenTurnCreditsKey) ?? []).compactMap(AgentProvider.init(rawValue:)))
    }
    @Published private(set) var localHarnessProgressStatuses: [AgentProvider: LocalHarnessProgressSetup.State] = [:] {
        didSet { progressGuideHintDismissals = progressGuideHintDismissals.filter { progressGuide($0.key)?.stage == $0.value } }
    }
    private var localHarnessProgressQueues: [AgentProvider: ProgressSetupQueue<LocalHarnessProgressSetup.Target>] = [:]
    private var localHarnessProgressTasks: [AgentProvider: Task<Void, Never>] = [:]

    /// - Parameter keepsState: keep showing the current state until the
    ///   result arrives, for checks the user did not ask for.
    func syncLocalHarnessProgress(force provider: AgentProvider? = nil, inspectOnly: Bool = false, keepsState: Bool = false) {
        guard !demo, !stopped, installationOverride == nil, let executable = Bundle.main.executableURL else { return }
        if provider == nil { refreshLocalHarnessApps() }
        for definition in localHarnesses.definitions {
            let id = definition.descriptor.id
            guard let configFile = definition.progressConfigFile, provider == nil || provider == id else { continue }
            let enabled = isModuleEnabled(id) && showsHarnessProgress(id)
            if inspectOnly {
                guard enabled, definition.progressConnection != nil, localHarnessProgressStatuses[id]?.setup == .configured,
                      localHarnessProgressTasks[id] == nil else { continue }
            }
            let target = LocalHarnessProgressSetup.Target(home: localHarnessHome(definition), configFile: configFile,
                                                          reporter: executable.path, enabled: enabled, ruleDirectory: definition.progressRuleDirectory)
            guard let ticket = localHarnessProgressQueues[id, default: .init()].request(target, force: provider == id) else { continue }
            if !inspectOnly && !keepsState { localHarnessProgressStatuses[id] = enabled ? .init(.settingUp) : nil }
            let task = Task { [weak self] in
                let status = await Task.detached(priority: .utility) {
                    await LocalHarnessProgressSetup.sync(ticket, storage: MacClaudeHookStorage(),
                        connection: definition.progressConnection, inspectOnly: inspectOnly)
                }.value
                guard let self, self.localHarnessProgressQueues[id]?.finish(ticket) == true else { return }
                var state = status
                // A report recorded a moment ago may not be on disk yet.
                if state?.setup == .configured, self.localHarnessProgressStatuses[id]?.reported == true { state?.reported = true }
                self.localHarnessProgressStatuses[id] = state
                self.localHarnessProgressTasks[id] = nil
            }
            localHarnessProgressQueues[id]?.track(task)
            localHarnessProgressTasks[id] = task
        }
    }

    /// Whether each module's app runs and since when: it reads Pacer's tool only as it starts.
    @Published private(set) var localHarnessApps: [AgentProvider: HarnessProgressGuide.AppPresence] = [:]
    private var localHarnessAppObservers: [NSObjectProtocol] = []
    func refreshLocalHarnessApps() {
        guard !demo else { return }
        if localHarnessAppObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            localHarnessAppObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
                center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshLocalHarnessApps() }
                }
            }
        }
        var apps: [AgentProvider: HarnessProgressGuide.AppPresence] = [:]
        for definition in localHarnesses.definitions where definition.descriptor.progressConnector {
            apps[definition.descriptor.id] = MacLocalHarnessApplication.presence(provider: definition.descriptor.id)
        }
        // A quit app forgets which page it showed and that the card opened it,
        // and so does one that started again after the card opened it.
        for (provider, presence) in localHarnessApps where presence != .notRunning && apps[provider] == .notRunning {
            forgetHarnessPage(provider)
        }
        for (provider, opened) in harnessOpenedConnectors {
            if case .running(let since)? = apps[provider], since > opened { forgetHarnessPage(provider) }
        }
        if apps != localHarnessApps { localHarnessApps = apps }
    }

    /// When the card opened a module's connectors; kept in memory until the
    /// app quits. The app's own log counts its custom connectors after this.
    @Published private(set) var harnessOpenedConnectors: [AgentProvider: Date] = [:]
    /// When the user clicked to open them: the app can show its connectors
    /// before the system says it has opened, so its log counts from the click.
    private var harnessOpenRequests: [AgentProvider: Date] = [:]
    private var harnessLogReads: Set<AgentProvider> = []
    /// A restart Pacer started is still under way.
    func harnessRestartInFlight(_ provider: AgentProvider) -> Bool { harnessRestarting.contains(provider) }
    /// A restart the card asked for: waiting for the user to confirm over a
    /// running task, under way, or refused by the app.
    /// `cannotOpen`: Pacer couldn't open the app, before or after quitting it.
    enum HarnessRestart: Equatable { case confirm, restarting, failed, cannotOpen }
    @Published private(set) var harnessRestarts: [AgentProvider: HarnessRestart] = [:]
    private var harnessRestarting: Set<AgentProvider> = []
    /// The page each module's app shows, as its own log tells.
    @Published private(set) var harnessAppViews: [AgentProvider: HarnessProgressGuide.AppView] = [:]
    /// The small floating guide the card's actions open beside the app.
    private(set) lazy var harnessGuideFloat = HarnessGuideFloat(model: self)

    func noteOpenedConnectors(_ provider: AgentProvider, at date: Date = Date(), requested: Date? = nil) {
        harnessOpenedConnectors[provider] = date
        harnessOpenRequests[provider] = requested ?? date
    }
    func reportHarnessView(_ provider: AgentProvider, _ view: HarnessProgressGuide.AppView) {
        if harnessAppViews[provider] != view { harnessAppViews[provider] = view }
    }
    func forgetHarnessPage(_ provider: AgentProvider) {
        harnessOpenedConnectors[provider] = nil
        harnessOpenRequests[provider] = nil
        harnessAppViews[provider] = nil
        if harnessRestarts[provider] == .confirm { harnessRestarts[provider] = nil }
    }

    /// Opens the app on its connectors from the card, with the floating
    /// guide beside it on `screen`, the one Settings is on.
    func openHarnessConnectors(_ provider: AgentProvider, screen: NSScreen? = nil, requested: Date = Date()) async -> Bool {
        showHarnessFloat(provider, on: screen)
        guard await MacLocalHarnessApplication.openProgressConnectors(provider: provider) else {
            harnessGuideFloat.close()
            return false
        }
        noteOpenedConnectors(provider, requested: requested)
        return true
    }

    /// The float comes up with the click, saying to wait while the app
    /// restarts or opens, and follows the app's steps from there.
    private func showHarnessFloat(_ provider: AgentProvider, on screen: NSScreen?) {
        guard let stage = progressGuide(provider)?.stage, let name = HarnessRegistry.descriptor(for: provider)?.name else { return }
        harnessGuideFloat.show(provider, on: screen, pending: HarnessProgressGuide.pendingFloat(stage: stage, name: name))
    }

    /// Quits the app the way its own Quit does, waits for it to close, then
    /// opens it on its connectors so it reads Pacer's tool, with the floating
    /// guide beside it. Over a running task the first click only asks to
    /// confirm. It never forces the app to quit.
    func restartHarness(_ provider: AgentProvider, screen: NSScreen? = nil) async {
        guard !harnessRestarting.contains(provider) else { return }
        let busy = visibleActivities.contains { $0.provider == provider && [.running, .waitingForInput].contains($0.phase) }
        if busy, harnessRestarts[provider] != .confirm { harnessRestarts[provider] = .confirm; return }
        // A demo never quits a real app, and an app Pacer can't open again stays as it is.
        guard !demo else { return }
        guard await MacLocalHarnessApplication.find(provider: provider) != nil else { harnessRestarts[provider] = .cannotOpen; return }
        showHarnessFloat(provider, on: screen)
        let requested = Date()
        harnessRestarts[provider] = .restarting
        harnessRestarting.insert(provider)
        defer { harnessRestarting.remove(provider) }
        let running = MacLocalHarnessApplication.runningAll(provider: provider)
        running.forEach { $0.terminate() }
        // After 10 seconds the card asks the user to quit it; Pacer keeps
        // waiting a while longer and opens it once it has quit.
        let start = Date()
        while running.contains(where: { !$0.isTerminated }), Date().timeIntervalSince(start) < 180 {
            if Date().timeIntervalSince(start) > 10, harnessRestarts[provider] == .restarting { harnessRestarts[provider] = .failed }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard running.allSatisfy(\.isTerminated) else { return }
        harnessRestarts[provider] = nil
        // Let the quit settle before opening, so a late quit notice can't
        // take back the connectors this restart opens.
        for _ in 0 ..< 12 where !MacLocalHarnessApplication.runningAll(provider: provider).isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        refreshLocalHarnessApps()
        if !(await openHarnessConnectors(provider, screen: screen, requested: requested)) { harnessRestarts[provider] = .cannotOpen }
    }

    /// The app's own log tells which page it shows since the card opened its
    /// connectors: its market, then its custom connectors once it lists its
    /// servers, apart from the listing it makes as it starts. The card moves
    /// on without reading the app's window.
    private func checkHarnessLog(_ provider: AgentProvider) {
        guard let opened = harnessOpenRequests[provider] ?? harnessOpenedConnectors[provider], harnessAppViews[provider] != .customConnectors,
              let definition = localHarnesses.definition(for: provider), let logFile = definition.appLogFile,
              case .running(let since)? = localHarnessApps[provider],
              [.opening, .openConnectors, .customConnector].contains(progressGuide(provider)?.stage) else { return }
        // One read at a time per module, whether the card or the float asked.
        guard harnessLogReads.insert(provider).inserted else { return }
        let log = localHarnessHome(definition).appendingPathComponent(logFile)
        Task { [weak self] in
            defer { self?.harnessLogReads.remove(provider) }
            // Back to the earlier of the click and the app's start, so its own listing stays in view.
            let view = await Task.detached(priority: .utility) {
                HarnessAppLog.view(in: HarnessAppLog.read(log, since: min(opened, since)), opened: opened, appStarted: since, now: Date())
            }.value
            // The page only moves forward: custom connectors after the market.
            guard let self, let view, self.harnessAppViews[provider] != .customConnectors else { return }
            self.reportHarnessView(provider, view)
        }
    }

    /// Checks the app's trust again; once the app has made its folder, the
    /// setup it was waiting for continues by itself.
    func recheckLocalHarnessProgress(_ provider: AgentProvider) {
        refreshLocalHarnessApps()
        checkHarnessLog(provider)
        if localHarnessProgressStatuses[provider]?.setup == .missingHome {
            guard localHarnessProgressTasks[provider] == nil else { return }
            syncLocalHarnessProgress(force: provider, keepsState: true)
        } else {
            syncLocalHarnessProgress(force: provider, inspectOnly: true)
        }
    }

    /// The first reported estimate confirms the whole chain, so the card
    /// collapses for good; an app that has just made its folder lets setup continue.
    private func noteLocalHarnessProgress(_ provider: AgentProvider, snapshot: HarnessActivity) {
        guard let definition = localHarnesses.definition(for: provider), let state = localHarnessProgressStatuses[provider] else { return }
        switch Self.localProgressFollowUp(state, reports: snapshot.activities.contains { $0.selfReportedProgress != nil }) {
        case .continueSetup?: recheckLocalHarnessProgress(provider)
        case .markReported?:
            localHarnessProgressStatuses[provider]?.reported = true
            let home = localHarnessHome(definition)
            Task.detached(priority: .utility) { LocalHarnessProgressSetup.markReported(home, storage: MacClaudeHookStorage()) }
        case nil: break
        }
    }

    enum LocalProgressFollowUp: Equatable { case continueSetup, markReported }
    static func localProgressFollowUp(_ state: LocalHarnessProgressSetup.State, reports: Bool) -> LocalProgressFollowUp? {
        if state.setup == .missingHome { return .continueSetup }
        return state.setup == .configured && !state.reported && reports ? .markReported : nil
    }

    /// The progress ring card Core words for a module whose app must trust
    /// Pacer's tool; nil for other modules and while the ring is off.
    func progressGuide(_ provider: AgentProvider) -> HarnessProgressGuide? {
        guard let descriptor = HarnessRegistry.descriptor(for: provider), descriptor.progressConnector else { return nil }
        let state = localHarnessProgressStatuses[provider]
        return HarnessProgressGuide(setup: state?.setup, connection: state?.connection, reported: state?.reported ?? false,
                                    ringOn: isModuleEnabled(provider) && showsHarnessProgress(provider), name: descriptor.name,
                                    addedAt: state?.addedAt, removedAt: state?.removedAt, app: localHarnessApps[provider],
                                    view: harnessAppViews[provider], openedConnectors: harnessOpenedConnectors[provider] != nil)
    }

    /// The ⓘ text, also while the ring is off and there is no card to word it.
    func progressGuideInfo(_ provider: AgentProvider) -> String {
        guard let descriptor = HarnessRegistry.descriptor(for: provider) else { return "" }
        return HarnessProgressGuide(setup: .settingUp, connection: nil, reported: false, ringOn: true, name: descriptor.name)?.info ?? ""
    }

    /// The modules the onboarding note names: their ring is on and their app
    /// still needs a step, or setup has not reported back yet.
    var progressOnboardingModules: [AgentProvider] {
        HarnessRegistry.localHarnesses.map(\.descriptor).filter { descriptor in
            guard descriptor.progressConnector, isModuleEnabled(descriptor.id), showsHarnessProgress(descriptor.id) else { return false }
            return progressGuide(descriptor.id).map(\.attention) ?? true
        }.map(\.id)
    }

    /// The panel hints the user closed, by module, until that module's stage
    /// changes; kept in memory only, as on Windows.
    private var progressGuideHintDismissals: [AgentProvider: HarnessProgressGuide.Stage] = [:]
    /// A module's task is running without a ring because its app still needs
    /// a step: the panel says so in one line until closed for that stage.
    var progressGuideHints: [(provider: AgentProvider, summary: String)] {
        let running = Set(visibleActivities.filter { $0.phase == .running }.map(\.provider))
        return HarnessRegistry.localHarnesses.map(\.descriptor.id).compactMap { provider in
            guard running.contains(provider), let guide = progressGuide(provider), guide.attention, let summary = guide.summary,
                  progressGuideHintDismissals[provider] != guide.stage else { return nil }
            return (provider, provider.displayName + " · " + summary)
        }
    }
    func dismissProgressGuideHint(_ provider: AgentProvider) {
        guard let stage = progressGuide(provider)?.stage else { return }
        progressGuideHintDismissals[provider] = stage
        objectWillChange.send()
        onLayoutChange?()
    }

    func refreshProgressPresentation() {
        syncLocalHarnessProgress()
        settingsRevision += 1
        scheduleRateExpiry()
        onLayoutChange?(); onStatusChange?()
    }
    private var progressRingProviders: Set<AgentProvider> {
        var providers: Set<AgentProvider> = []
        if showsClaudeProgressRing { providers.insert(.claude) }
        if showsCodexProgressRing { providers.insert(.codex) }
        if showsDeepSeekProgressRing { providers.insert(.deepseek) }
        for definition in localHarnesses.definitions where definition.descriptor.hasTaskProgress && showsHarnessProgress(definition.descriptor.id) {
            providers.insert(definition.descriptor.id)
        }
        return providers
    }
    /// Claude's self-reported progress ring; on until the user turns it off.
    var showsClaudeProgressRing: Bool { Self.progressRingEnabled(Self.claudeProgressRingKey, in: defaults) }
    /// The setting the last settings pass applied, so a switch reaches SSH hosts once.
    private var appliedClaudeProgressRing = false
    /// The Dot switch the Codex progress setup last applied.
    private var appliedDurable = false
    /// The Claude home where this app turned the ring's switch on.
    private var claudeProgressSwitchHome: URL?
    /// Only an app that manages the hooks writes the switch; a demo never
    /// touches the Claude home. It removes only a switch it turned on itself,
    /// or a leftover in a home whose setup just confirmed that Pacer manages
    /// it, so a home it merely passed through is never changed. Returns
    /// whether the switch file changed: it decides which settings entries
    /// Pacer keeps, so a change brings the hooks current.
    @discardableResult
    func applyClaudeProgressSwitch(home: URL, setupConfirmed: Bool = false) -> Bool {
        guard !demo else { return false }
        let wanted = showsClaudeProgressRing && isModuleEnabled(.claude)
        if let previous = claudeProgressSwitchHome, previous != home {
            ClaudeProgressRingSwitch.apply(enabled: false, home: previous); claudeProgressSwitchHome = nil
        }
        let flag = ClaudeProgressRingSwitch.flagURL(home: home).path
        let before = FileManager.default.contents(atPath: flag)
        if wanted {
            ClaudeProgressRingSwitch.apply(enabled: true, home: home)
            if FileManager.default.fileExists(atPath: flag) { claudeProgressSwitchHome = home }
        } else if claudeProgressSwitchHome == home || setupConfirmed {
            ClaudeProgressRingSwitch.apply(enabled: false, home: home); claudeProgressSwitchHome = nil
        }
        return FileManager.default.contents(atPath: flag) != before
    }
    /// The Claude home where this app turned Codex for Claude on.
    private var codexDelegationHome: URL?
    /// Codex for Claude's settings file is its switch, written like the ring's:
    /// only by an app that manages the hooks, removed only where this app turned
    /// it on or its hook setup just confirmed. Each pass also writes the current
    /// choices. Returns whether the switch turned on or off: the plugin's skill
    /// follows it, so a change brings the hooks current.
    @discardableResult
    func applyCodexDelegationSwitch(home: URL, setupConfirmed: Bool = false) -> Bool {
        guard !demo else { return false }
        let preferences = CodexDelegationPreferences(defaults: defaults)
        let wanted = preferences.enabled && isModuleEnabled(.claude)
        if let previous = codexDelegationHome, previous != home {
            ClaudeCodexDelegation.apply(nil, home: previous); codexDelegationHome = nil
        }
        let before = ClaudeCodexDelegation.isOn(home: home)
        let config = ClaudeCodexDelegation.configURL(home: home)
        let trigger = ClaudeCodexDelegation.settings(FileManager.default.contents(atPath: config.path))?.trigger
        if wanted {
            // The runner starts the Codex program Pacer found, also the one inside Codex Desktop.
            let codex = CodexClient.findExecutable(customPath: defaults.string(forKey: "codexExecutable") ?? "")?.path
            if ClaudeCodexDelegation.apply(preferences.settings(codex: codex), home: home) { codexDelegationHome = home }
        } else if codexDelegationHome == home || setupConfirmed {
            ClaudeCodexDelegation.apply(nil, home: home); codexDelegationHome = nil
        }
        writeCodexDelegationQuota()
        // The switch and the trigger are written into the plugin's skill.
        return ClaudeCodexDelegation.isOn(home: home) != before
            || ClaudeCodexDelegation.settings(FileManager.default.contents(atPath: config.path))?.trigger != trigger
    }
    /// The least Codex quota left, for the runner's quota floor, while Codex
    /// for Claude is on. Its time is when Pacer read the quota, so an old
    /// reading stops holding runs back.
    func writeCodexDelegationQuota() {
        guard !demo, let home = codexDelegationHome, ClaudeCodexDelegation.isOn(home: home) else { return }
        let left = codexQuota?.windows.compactMap(\.remainingPercent).min()
        ClaudeCodexDelegation.writeQuota(remainingPercent: left, home: home, at: codexQuota?.capturedAt ?? Date())
    }
    /// Settings → Collaboration changed: the runner's choices are written at
    /// once, the skill follows the switch, and the task list follows the display.
    func applyCodexDelegationPreferences() {
        syncClaudeProgressSwitch()
        codexDelegationLedger = nil
        combineActivities()
        refreshProgressPresentation()
    }
    /// Follows the settings and the module outside a source restart, which
    /// applies the switches as part of its own setup.
    func syncClaudeProgressSwitch() {
        guard !demo, !stopped else { return }
        let home = claudeHome
        let ring = applyClaudeProgressSwitch(home: home), delegation = applyCodexDelegationSwitch(home: home)
        guard ring || delegation, isModuleEnabled(.claude), !sleeping else { return }
        let generation = claudeGeneration
        launchOwnedWork(.init(.setup, provider: .claude, identifier: "local")) { [weak self] _ in
            await self?.ensureClaudeHooks(home: home, generation: generation)
        }
    }
    @Published var expanded = false
    @Published var pinned = false
    /// The reference time for each pass. Setting it alone does not redraw: changed
    /// values publish themselves; the clock and expiry wake-ups call `redrawClock()`.
    var now = Date()
    @Published var settingsRevision = 0
    @Published var isAttached = false
    /// Attached to a real hardware notch, where the collapsed bar is pure black.
    @Published var atHardwareNotch = false
    /// The island's tone: light under Light Liquid Glass, except while the
    /// black notch bar covers the material. Previews elsewhere follow it.
    @Published private(set) var lightTone = PacerPalette.light
    private var toneCovered = false
    func coverTone(_ covered: Bool) {
        guard covered != toneCovered else { return }
        toneCovered = covered
        syncTone()
    }
    private func syncTone() {
        let light = appearance.isLight && !toneCovered
        PacerPalette.light = light
        if lightTone != light { lightTone = light }
    }
    /// The docked corner while the island floats as a vertical strip; nil for
    /// the centered bar and notch attachment.
    @Published var sideDock: IslandPosition?
    /// A bar placed low on the screen, or docked at its bottom, opens upward.
    @Published var opensUp = false
    /// The screen edge a docked island touches; its corners there stay square.
    @Published var dockedEdge: IslandPlacement.Edge?
    /// While Free Move runs, hover neither opens nor closes the island.
    @Published private(set) var islandMoving = false
    /// Changes when a drag or Return to Top Center saves a new place, so an
    /// open Settings window reloads the display and position it shows.
    @Published private(set) var placementRevision = 0
    private var moveEndedAt = Date.distantPast
    /// Set by the panel: starts a drag with the grab point as fractions of the
    /// bar from its top left.
    var onBeginMove: ((CGPoint) -> Void)?
    var onEndMoveGesture: (() -> Void)?
    /// The notch island and an island behind an update prompt stay put.
    var canMoveIsland: Bool { !isAttached && !interactionSuspended }
    func setIslandMoving(_ moving: Bool) {
        guard moving != islandMoving else { return }
        islandMoving = moving
        if moving { closeWork?.cancel() } else { moveEndedAt = Date() }
    }
    func islandPlacementSaved() { placementRevision += 1 }
    /// Return to Top Center has somewhere to leave: a dragged place, or a
    /// corner other than the top center. Settings and the panel's button share it.
    var canResetIslandPlacement: Bool {
        _ = placementRevision
        return IslandPlacement.load(from: defaults) != nil || islandPosition != .center
    }
    /// Return to Top Center: forget the dragged place and the old corner.
    func resetIslandPlacement() {
        IslandPlacement.clear(from: defaults)
        IslandPosition.center.save(to: defaults)
        IslandDisplayMode.floating.save(to: defaults)
        rememberDisplayPlace()
        placementRevision += 1
        onLayoutChange?()
    }

    /// The display the island shows on, named in Settings.
    @Published private(set) var currentDisplayName: String?
    /// The display whose place the island preferences hold, while each
    /// display keeps its own.
    private var currentDisplay: (key: String, name: String)?
    /// The panel reports the display the island shows on. Reaching another
    /// display gives the island that display's place; returns true then.
    func arrive(onDisplay key: String, name: String, hasNotch: Bool) -> Bool {
        if currentDisplayName != name { currentDisplayName = name }
        guard IslandScreenMemory.isEnabled(in: defaults) else { currentDisplay = nil; return false }
        guard currentDisplay?.key != key else { return false }
        let switched = currentDisplay != nil
        currentDisplay = (key, name)
        guard IslandScreenMemory.arrive(at: key, name: name, hasNotch: hasNotch, switched: switched, defaults: defaults) else { return false }
        // An open Settings window shows the new display's place.
        placementRevision += 1
        return true
    }
    /// A drag dropped the island on this display; the place belongs to it.
    func placeMoved(toDisplay key: String, name: String) {
        guard IslandScreenMemory.isEnabled(in: defaults) else { return }
        currentDisplay = (key, name)
        rememberDisplayPlace()
    }
    /// Keeps the island's current place for the display it is on.
    func rememberDisplayPlace() {
        guard IslandScreenMemory.isEnabled(in: defaults), let currentDisplay else { return }
        IslandScreenMemory.rememberCurrent(for: currentDisplay.key, name: currentDisplay.name, defaults: defaults)
    }
    /// The mouse-up that ends a drag must not also pin the island or open a task.
    func barClicked(_ action: () -> Void) {
        guard !islandMoving, Date().timeIntervalSince(moveEndedAt) > 0.3 else { return }
        action()
    }
    @Published var notchWidth: CGFloat = 0
    /// Physical geometry of the screen hosting Pacer, retained even in Floating mode.
    @Published var screenNotchSize: CGSize = .zero
    @Published var topHeight: CGFloat = 36
    @Published var baseHeaderHeight: CGFloat = 36
    /// Width of the bar turned on its side at a docked edge, for the bar size.
    @Published var stripWidth: CGFloat = IslandGeometry.stripWidth
    var onLayoutChange: (() -> Void)?
    /// The collapsed bar's corners: an attached or edge-docked bar keeps its
    /// free corners at the size's radius, a floating one is a full capsule and
    /// a side strip rounds half its width.
    var collapsedCornerRadius: CGFloat {
        if sideDock != nil { return max(1, stripWidth / 2) }
        let half = max(1, baseHeaderHeight / 2)
        return isAttached || dockedEdge == .top || dockedEdge == .bottom ? min(CGFloat(barMetrics.radius), baseHeaderHeight) : half
    }
    var onStatusChange: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Opens Settings on a module's own page, where its sign-in and locations live.
    func openSettings(for provider: AgentProvider) {
        UserDefaults.standard.set(SettingsPane(provider: provider).rawValue, forKey: SettingsPane.defaultsKey)
        onSettings?()
    }
    /// The panel's reset capsule asks History to open on Codex with the deadlines showing.
    private(set) var opensResetExpiries = false
    func openResetExpiries() {
        opensResetExpiries = true
        UserDefaults.standard.set(SettingsPane.history.rawValue, forKey: SettingsPane.defaultsKey)
        onSettings?()
    }
    /// History takes the request once, when it appears.
    func takeResetExpiryRequest() -> Bool { defer { opensResetExpiries = false }; return opensResetExpiries }
    var onQuit: (() -> Void)?
    var onRelaunch: (() -> String?)?
    var onOpenActivity: ((SessionActivity) async -> ActivityOpenOutcome)?
    /// The expanded panel's header offers each enabled module's desktop app,
    /// whether or not it has a task; with the buttons off, the More menu does.
    /// A module without its app offers none.
    static let showsAppButtonsKey = "showAppButtons"
    var showsAppButtons: Bool { defaults.object(forKey: Self.showsAppButtonsKey) == nil || defaults.bool(forKey: Self.showsAppButtonsKey) }
    var desktopAppProviders: [AgentProvider] { enabledProviders.filter { desktopApplications[$0] != nil } }
    var appButtonProviders: [AgentProvider] { showsAppButtons ? desktopAppProviders : [] }
    @Published private(set) var desktopApplications: [AgentProvider: URL] = [:]
    var desktopApplicationResolver: @Sendable (AgentProvider) async -> URL? = { provider in
        await Task.detached(priority: .utility) {
            switch provider {
            case .codex: CodexApplicationResolver.find()
            case .claude: ClaudeApplicationResolver.find()
            case .deepseek: DeepSeekApplicationResolver.find()
            default: await MacLocalHarnessApplication.find(provider: provider)
            }
        }.value
    }
    var onOpenDesktopApplication: ((AgentProvider, URL) async -> ActivityOpenOutcome)?
    private var desktopApplicationScan: Task<Void, Never>? { ownedWork.task(.init(.applications)) }
    private var desktopApplicationsScannedAt = Date.distantPast
    /// Installations change rarely, so opening the panel looks again at most
    /// once a minute; settings changes and a failed open look at once. Demo
    /// shows every enabled module and opens only its labeled sample.
    func refreshDesktopApplications(force: Bool = true, now: Date = Date()) {
        guard !stopped, force || now.timeIntervalSince(desktopApplicationsScannedAt) >= 60 else { return }
        desktopApplicationsScannedAt = now
        let providers = enabledProviders
        if demo {
            desktopApplications = Dictionary(uniqueKeysWithValues: providers.map { ($0, Bundle.main.bundleURL) }); return
        }
        desktopApplicationScan?.cancel()
        let resolve = desktopApplicationResolver
        launchOwnedWork(.init(.applications)) { [weak self] workTicket in
            var found: [AgentProvider: URL] = [:]
            for provider in providers { found[provider] = await resolve(provider) }
            guard let self, !Task.isCancelled, self.ownedWork.owns(workTicket) else { return }
            guard found != self.desktopApplications else { return }
            self.desktopApplications = found; self.onLayoutChange?()
        }
    }
    func openDesktopApplication(_ provider: AgentProvider) {
        guard desktopAppProviders.contains(provider), let application = desktopApplications[provider],
              let open = onOpenDesktopApplication else { return }
        clearNavigationError()
        let generation = sourceGeneration(for: provider)
        launchOwnedWork(.init(.navigation, provider: provider, identifier: "desktop")) { [weak self] _ in
            let outcome = await open(provider, application)
            guard let self, generation == self.sourceGeneration(for: provider), !self.sleeping, !self.stopped,
                  !Task.isCancelled, case .failed(let failure) = outcome else { return }
            self.showNavigationError(failure)
            self.refreshDesktopApplications()
        }
    }
    var onFocusRequested: (() -> Void)?
    private func conversationTarget(for activity: SessionActivity) -> SessionActivity? {
        ActivityNavigationTarget.resolve(activity, activities: activities, inbox: completionInbox,
            remoteSourceIDs: Set(claudeRemoteTargets.map(\.id)))
    }
    func canOpen(_ activity: SessionActivity) -> Bool {
        guard !activity.isIgnoredCodexSession else { return false }
        if localHarnesses.definition(for: activity.provider) != nil {
            return providerDetected(activity.provider) && localHarnessActivities[activity.provider]?.conversationURLs[activity.id] != nil
        }
        // Harness has no conversation link; its app opens on the session list.
        if activity.provider == .deepseek { return demo || DeepSeekApplicationResolver.cachedApplication() != nil }
        if activity.provider == .codex, activity.sourceHostID == nil, activity.launchedByEmbeddingApp {
            return conversationTarget(for: activity)?.threadID.flatMap(UUID.init(uuidString:)) != nil
        }
        if activity.provider == .claude {
            if activity.claudeCloud != nil { return true }
            guard let target = conversationTarget(for: activity) else { return false }
            // A local session whose app is unknown still opens, to report that.
            return demo || target.threadID.flatMap(UUID.init(uuidString:)) != nil ||
                (target.threadURL != nil && ClaudeApplicationResolver.cachedApplication() != nil)
        }
        return (demo || activity.threadURL != nil) && (demo || activity.sourceHostID != nil ||
            home.path == URL(fileURLWithPath: NSHomeDirectory() + "/.codex").standardizedFileURL.path)
    }
    private var measuredContentHeight: CGFloat?
    private(set) var measuredContentWidth: CGFloat = 0
    private(set) var measuredCompactWidth: CGFloat = 0
    private var measuredStripHeight: CGFloat?
    /// The docked strip follows its stacked components, as the bar's width does.
    var stripHeight: CGFloat { measuredStripHeight ?? 132 }
    func updateMeasuredStripHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let rounded = max(56, ceil(height))
        guard rounded != measuredStripHeight else { return }
        measuredStripHeight = rounded
        onLayoutChange?()
    }
    @Published private(set) var compactLayout = CompactIslandLayout.load()
    /// The expanded panel's saved blocks, nil while they follow the services,
    /// and how they draw. Settings writes both keys and reloads them here.
    @Published private(set) var savedPanelLayout: ExpandedPanelLayout?
    @Published private(set) var panelOptions = ExpandedPanelOptions()
    func reloadPanelSettings() {
        let saved = ExpandedPanelLayout.load(from: defaults), options = ExpandedPanelOptions.load(from: defaults)
        guard saved != savedPanelLayout || options != panelOptions else { return }
        savedPanelLayout = saved; panelOptions = options
        onLayoutChange?()
    }
    func updateMeasuredCompactWidth(_ width: CGFloat) {
        guard width.isFinite, width >= 0 else { return }
        let rounded = ceil(width)
        guard rounded != measuredCompactWidth else { return }
        measuredCompactWidth = rounded
        onLayoutChange?()
    }
    func updateMeasuredContentWidth(_ width: CGFloat) {
        guard width.isFinite, width >= 0 else { return }
        let rounded = ceil(width)
        guard rounded != measuredContentWidth else { return }
        measuredContentWidth = rounded
        onLayoutChange?()
    }
    var panelContentHeight: CGFloat {
        if let measuredContentHeight { return measuredContentHeight }
        let count = visibleActivities.count, page = panelOptions.pageSize, rows = max(1, min(page, count))
        let rowHeight: CGFloat = panelOptions.rowStyle == .oneLine ? 58 : 74
        let taskHeight = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * 2 + (count > page ? 26 : 0) + (demo ? 25 : 0)
        let quotaHeight: CGFloat
        if QuotaDashboardLayout.usesLegacyCodexDisplay(providers: quotaProviders, snapshot: providerQuota(.codex), style: expandedQuotaStyle),
           let snapshot = providerQuota(.codex) {
            let headers = snapshot.buckets.count > 1 ? snapshot.buckets.count : 0
            quotaHeight = 256 + CGFloat(snapshot.windows.count) * 92 + CGFloat(headers) * 20
        } else { quotaHeight = 318 }
        // Estimates before the first measurement; actions live in the task header, not a footer.
        return min(640, max(394, quotaHeight + taskHeight))
    }
    func updateMeasuredContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let rounded = ceil(height)
        guard measuredContentHeight.map({ abs($0 - rounded) >= 1 }) ?? true else { return }
        measuredContentHeight = rounded
        onLayoutChange?()
    }
    private var codexQuotaCoordinator: CodexQuotaCoordinator?
    private var codexQuotaState: CodexQuotaState?
    private var codexQuotaOwnerID = UUID()
    private var codexQuotaReceiptID: UUID?
    private var codexQuotaStarting = false
    private var claudeQuotaCoordinator: ClaudeQuotaCoordinator?
    private var claudeQuotaState: ClaudeQuotaState?
    private var claudeQuotaOwnerID = UUID()
    private var claudeQuotaReceiptID: UUID?
    private var claudeQuotaStarting = false
    let reader = LocalActivityReader(writerProbe: MacRolloutWriters.probe)
    private let realtimeMonitor = RealtimeActivityMonitor()
    private let durableMonitor: MacDurableMonitor
    /// SSH tasks and Dot tasks, which arrive separately and show together.
    private var sshActivities: [SessionActivity] = []
    private var durableActivities: [SessionActivity] = []
    /// A thread-safe copy of whether the panel can be seen, for the Dot poll's pacing.
    private let durablePanelInView = DurableVisibility()
    private var remoteTask: Task<Void, Never>? { ownedWork.task(.init(.remote, provider: .codex)) }
    private var appliedCodexSSH: Bool?
    private var durableAccountScope: String?
    private var lastRemoteDiscovery = Date.distantPast
    private let historyStore: QuotaHistoryStore
    private let claudeHistoryStore: QuotaHistoryStore
    private let claudeMonitor: ClaudeActivityMonitor
    /// Set by the app, so tests and demos never reach claude.ai.
    var makeClaudeCloudMonitor: (@MainActor () -> ClaudeCloudProjectMonitor)?
    private var claudeCloudCoordinator: ClaudeCloudCoordinator?
    private var claudeCloudHistoryBinding = ClaudeCloudHistoryBinding()
    private var claudeCloudGeneration = 0
    private let claudeRemoteSetup: ClaudeRemoteSetup
    private var claudeDiscoveryTask: Task<Void, Never>? { ownedWork.task(.init(.discovery, provider: .claude)) }
    private var claudeDiscoveryRevision = 0
    private var claudeRemoteSetupTasks: [String: Task<ClaudeHookInstaller.Status, Error>] = [:]
    private var claudeRemoteSetupIDs: [String: UUID] = [:]
    @Published private(set) var claudeRemoteTargets: [RemoteActivityTarget] = []
    @Published private(set) var configuringClaudeHosts: Set<String> = []
    @Published private(set) var claudeRemoteSetupStatus: [String: ClaudeHookInstaller.Status] = [:]
    @Published private(set) var claudeRemoteSetupFailures: [String: String] = [:]
    private var claudeRemoteSetupFailedAt: [String: Date] = [:]
    /// This launch's successful setups, so current hosts are checked again.
    private var claudeRemoteCheckedAt: [String: Date] = [:]
    /// Rechecks of current hosts run quietly: the row stays connected and a
    /// failed recheck only backs off.
    private var recheckingClaudeHosts: Set<String> = []
    private lazy var claudeAdapterDigests: (off: String, on: String)? = {
        guard let off = try? ClaudeRemoteSetup.adapterDigest(), let on = try? ClaudeRemoteSetup.adapterDigest(progressRing: true) else { return nil }
        return (off, on)
    }()
    /// The digest includes the progress ring, so switching it sets connected hosts up again.
    private var claudeAdapterDigest: String? { claudeAdapterDigests.map { showsClaudeProgressRing ? $0.on : $0.off } }
    /// Hosts whose current setup kept Pacer's request telemetry off, by alias.
    func claudeRemoteTelemetryConflicts() -> [String: ClaudeTelemetryConflict] {
        ClaudeRemoteAutoSetup.telemetryConflicts(defaults: defaults)
    }
    /// True once this host carries the hooks shipped with this build.
    func claudeRemoteConfigured(_ target: RemoteActivityTarget) -> Bool {
        claudeAdapterDigest.map { ClaudeRemoteAutoSetup.configuredDigests(defaults: defaults)[target.alias] == $0 } ?? false
    }
    /// Setup never creates a Claude home on a host without one. Success records
    /// the adapter digest so later checks stay quiet until an update changes it.
    /// `automatic` runs keep telemetry keys the user removed on the host removed.
    func configureClaudeRemote(targetID: String, automatic: Bool = false) async -> String? {
        guard isModuleEnabled(.claude), monitorsSSH, !sleeping, !stopped, !Task.isCancelled,
              let target = claudeRemoteTargets.first(where: { $0.id == targetID }),
              !configuringClaudeHosts.contains(targetID), !recheckingClaudeHosts.contains(targetID) else { return nil }
        let generation = claudeGeneration, requestID = UUID(), quiet = automatic && claudeRemoteConfigured(target)
        let setup = claudeRemoteSetup
        // The setup remembers what it installs, so a ring switched meanwhile sets the host up again.
        let progressRing = showsClaudeProgressRing, digest = claudeAdapterDigest
        let task = Task { try await setup.install(target: target, requireHome: true, progressRing: progressRing, automatic: automatic) }
        launchOwnedWork(.init(.setup, provider: .claude, identifier: targetID)) { _ in
            await withTaskCancellationHandler {
                _ = try? await task.value
            } onCancel: { task.cancel() }
        }
        claudeRemoteSetupTasks[targetID] = task
        claudeRemoteSetupIDs[targetID] = requestID
        if quiet { recheckingClaudeHosts.insert(targetID) } else { configuringClaudeHosts.insert(targetID) }
        // Runs after the defer below has cleared this host's in-flight state.
        var outdated = false
        defer { if outdated { scheduleClaudeRemoteSetup() } }
        defer {
            // An old request must not clear a replacement started after reset.
            if generation == claudeGeneration, claudeRemoteSetupIDs[targetID] == requestID {
                claudeRemoteSetupTasks.removeValue(forKey: targetID)
                claudeRemoteSetupIDs.removeValue(forKey: targetID)
                if quiet { recheckingClaudeHosts.remove(targetID) } else { configuringClaudeHosts.remove(targetID) }
            }
        }
        do {
            let status = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, generation == claudeGeneration, isModuleEnabled(.claude), monitorsSSH, !sleeping, !stopped,
                  claudeRemoteTargets.contains(target), claudeRemoteSetupIDs[targetID] == requestID else { return nil }
            claudeRemoteSetupStatus[targetID] = status
            claudeRemoteSetupFailures.removeValue(forKey: targetID); claudeRemoteSetupFailedAt.removeValue(forKey: targetID)
            claudeRemoteCheckedAt[targetID] = Date()
            if let digest {
                ClaudeRemoteAutoSetup.recordConfigured(alias: target.alias, digest: digest, conflict: status.telemetryConflictReason, defaults: defaults)
            }
            await claudeMonitor.refresh(remoteTargetID: targetID)
            outdated = digest != claudeAdapterDigest
            return nil
        } catch {
            guard !Task.isCancelled, generation == claudeGeneration, claudeRemoteSetupIDs[targetID] == requestID,
                  claudeRemoteTargets.contains(target),
                  error as? ClaudeRemoteSetup.Failure != .cancelled else { return nil }
            claudeRemoteSetupFailedAt[targetID] = Date()
            if quiet { return nil }
            let message = L10n.text(error as? ClaudeRemoteSetup.Failure == .missingHome ? "provider.remote_source_missing" : "provider.remote_configure_failed")
            claudeRemoteSetupFailures[targetID] = message
            return message
        }
    }
    private func cancelClaudeRemoteSetup() {
        claudeDiscoveryTask?.cancel(); cancelOwnedWork(.init(.discovery, provider: .claude))
        claudeRemoteSetupTasks.values.forEach { $0.cancel() }
        for targetID in claudeRemoteSetupTasks.keys {
            cancelOwnedWork(.init(.setup, provider: .claude, identifier: targetID))
            cancelOwnedWork(.init(.setup, provider: .claude, identifier: "auto:" + targetID))
        }
        claudeRemoteSetupTasks.removeAll()
        claudeRemoteSetupIDs.removeAll()
        configuringClaudeHosts.removeAll(); recheckingClaudeHosts.removeAll()
    }
    /// A client-side removal/replacement retires only its owned collector/setup.
    func reconcileClaudeRemoteTargets(_ targets: [RemoteActivityTarget]) {
        for previous in claudeRemoteTargets where !targets.contains(previous) {
            claudeRemoteSetupTasks.removeValue(forKey: previous.id)?.cancel()
            cancelOwnedWork(.init(.setup, provider: .claude, identifier: previous.id))
            claudeRemoteSetupIDs.removeValue(forKey: previous.id)
            configuringClaudeHosts.remove(previous.id); recheckingClaudeHosts.remove(previous.id)
            claudeRemoteSetupStatus.removeValue(forKey: previous.id)
            claudeRemoteSetupFailures.removeValue(forKey: previous.id)
            claudeRemoteSetupFailedAt.removeValue(forKey: previous.id)
            claudeRemoteCheckedAt.removeValue(forKey: previous.id)
            claudeStreamStatuses.removeValue(forKey: previous.id)
        }
        if claudeRemoteTargets != targets { claudeRemoteTargets = targets }
        bindCompletionSources(.claude)
    }
    private func discoverClaudeRemoteTargets(refresh: Bool = false) {
        guard isModuleEnabled(.claude), !sleeping, !stopped, !demo else { return }
        if refresh { claudeDiscoveryTask?.cancel(); cancelOwnedWork(.init(.discovery, provider: .claude)) }
        guard claudeDiscoveryTask == nil else { return }
        lastClaudeDiscovery = Date(); claudeDiscoveryRevision += 1
        let revision = claudeDiscoveryRevision, generation = claudeGeneration
        let codexHome = home, sourceHome = claudeHome, includeSSH = monitorsSSH
        launchOwnedWork(.init(.discovery, provider: .claude)) { [weak self] workTicket in
            guard let self else { return }
            defer { if revision == self.claudeDiscoveryRevision { self.ownedWork.finish(workTicket) } }
            let targets = includeSSH ? await RemoteActivityTarget.claudeConfigured(codexHome: codexHome, claudeHome: sourceHome) : []
            guard !Task.isCancelled, generation == self.claudeGeneration, !self.stopped, !self.sleeping else { return }
            self.reconcileClaudeRemoteTargets(targets)
            await self.claudeMonitor.updateRemoteTargets(targets)
            if refresh, !Task.isCancelled, generation == self.claudeGeneration { await self.claudeMonitor.refresh() }
        }
    }
    private func scheduleClaudeRemoteSetup() {
        guard isModuleEnabled(.claude), monitorsSSH,
              !demo, !sleeping, !stopped, let digest = claudeAdapterDigest else { return }
        let pending = ClaudeRemoteAutoSetup.pending(targets: claudeRemoteTargets, statuses: claudeStreamStatuses,
            configured: ClaudeRemoteAutoSetup.configuredDigests(defaults: defaults), digest: digest,
            failures: claudeRemoteSetupFailedAt, inFlight: configuringClaudeHosts.union(recheckingClaudeHosts), now: Date(),
            checkedAt: claudeRemoteCheckedAt, conflicts: ClaudeRemoteAutoSetup.telemetryConflicts(defaults: defaults))
        let generation = claudeGeneration
        for target in pending {
            launchOwnedWork(.init(.setup, provider: .claude, identifier: "auto:" + target.id)) { [weak self] _ in
                guard let self, generation == self.claudeGeneration else { return }
                _ = await self.configureClaudeRemote(targetID: target.id, automatic: true)
            }
        }
    }
    private let claudeQuotaReads: ClaudeQuotaReadDependencies
    var onClaudeLogin: (() -> Void)?
    var onClaudeOrganizationSelection: (([ClaudeWebOrganization]) -> Void)?
    private var claudeOrganizationChoices: [ClaudeWebOrganization] = []
    private var claudeQuotaRestartTask: Task<Void, Never>? { ownedWork.task(.init(.quotaRestart, provider: .claude)) }
    private var claudeQuotaTask: Task<Void, Never>? { ownedWork.task(.init(.quota, provider: .claude)) }
    private var claudeActivityTask: Task<Void, Never>? { ownedWork.task(.init(.activity, provider: .claude)) }
    private var claudeGeneration: Int { Int(lifecycle.version(.claude)) }
    /// Unfiltered reader state also feeds completion retention while embedded
    /// sessions are hidden. Only presentation and attention are filtered.
    private var claudeReceivedActivities: [SessionActivity] {
        get { activityState.claudeActivities }
        set { activityState.claudeActivities = newValue }
    }
    private var claudeReceivedRequests: [PendingAttentionRequest] {
        get { activityState.claudeReceivedRequests }
        set { activityState.claudeReceivedRequests = newValue }
    }
    private var claudeAttentionRequests: [PendingAttentionRequest] {
        get { activityState.requests.filter { $0.provider == .claude } }
        set { activityState.replacePendingRequests(for: .claude, with: newValue) }
    }
    private var codexReceivedRequests: [PendingAttentionRequest] {
        get { activityState.codexReceivedRequests }
        set { activityState.codexReceivedRequests = newValue }
    }
    private var codexLogRequests: [PendingAttentionRequest] {
        get { activityState.codexLogRequests }
        set { activityState.codexLogRequests = newValue }
    }
    private var excludedCodexActivityIDs: Set<String> {
        get { activityState.excludedCodexActivityIDs }
        set { activityState.excludedCodexActivityIDs = newValue }
    }
    private var codexAttentionRequests: [PendingAttentionRequest] {
        get { activityState.requests.filter { $0.provider == .codex } }
        set { activityState.replacePendingRequests(for: .codex, with: newValue) }
    }
    private var claudeStreamStatuses: [String: RuntimeStreamStatus] = [:]
    private var claudeQuotaAttention = AttentionPolicy()
    private var claudeActivityAttention: AttentionPolicy {
        get { activityState.claudeAttention }
        set { activityState.claudeAttention = newValue }
    }
    private var lastClaudeDiscovery = Date.distantPast
    lazy var notifications = NotificationDelivery(defaults: defaults)
    private var attention: AttentionPolicy {
        get { activityState.codexAttention }
        set { activityState.codexAttention = newValue }
    }
    var completionInbox: CompletionInbox {
        get { activityState.inbox }
        set { activityState.inbox = newValue }
    }
    private var clock: Timer?
    private var refreshTask: Task<Void, Never>? { ownedWork.task(.init(.quota, provider: .codex)) }
    private var localTask: Task<Void, Never>? { ownedWork.task(.init(.activity, provider: .codex)) }
    private var closeWork: DispatchWorkItem?
    private var rateExpiryWork: DispatchWorkItem?
    private var rateExpiryAt: Date?
    private var codexRunningExpiry: Date?
    private var localActivityDirty = false
    private var localActivityNeedsDiscovery = false
    private(set) var watchedLogURLs: [URL] = []
    private lazy var logWatcher = ActivityLogWatcher { [weak self] discover in
        Task { @MainActor in self?.refreshActivity(metricsOnly: !discover) }
    }
    var sleeping: Bool { lifecycle.isSleeping }
    var stopped: Bool { lifecycle.isStopped }
    private(set) var interactionSuspended = false
    private var sourceGeneration: Int { Int(lifecycle.version(.codex)) }
    private var observations: [NSObjectProtocol] = []
    private var networkChanges: MacNetworkChanges?
    private var sshReconnect = SSHReconnectPolicy()
    let demo: Bool
    private let demoClock: () -> Date
    /// Source tests pass nil to keep demo's I/O isolation while supplying their own events.
    private let demoArguments: [String]?
    private var demoActivities: [SessionActivity] {
        get { activityState.demoActivities }
        set { activityState.demoActivities = newValue }
    }
    private var demoRequests: [PendingAttentionRequest] {
        get { activityState.demoRequests }
        set { activityState.demoRequests = newValue }
    }
    var isDemo: Bool { demo }
    /// The demo computer has the three original services; WorkBuddy reads as
    /// not found, so reference shots stay the same, unless `--demo-workbuddy`
    /// puts it there too. A module on in the demo adds its task and dial.
    private static func demoInstallation(_ arguments: [String]?) -> ProviderInstallationDetection {
        ProviderInstallationDetection(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true,
            additional: arguments?.contains("--demo-workbuddy") == true ? [.workbuddy] : [])
    }

    var home: URL {
        let configured = defaults.string(forKey: "codexHome") ?? ""
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    var displayMode: IslandDisplayMode { .load() }
    var islandPosition: IslandPosition { .load(from: defaults) }
    var activityRefreshPolicy: ActivityRefreshPolicy { visiblyExpanded ? .expanded : .collapsed }
    /// Why an open panel cannot be seen. It then refreshes at the collapsed cadence.
    enum VisibilityBlocker: Hashable { case displaySleep, screenLock, inactiveSession, occluded }
    private(set) var visibilityBlockers: Set<VisibilityBlocker> = []
    /// Expanded and actually on screen: only then do clocks, quotas and activity use the fast cadence.
    var visiblyExpanded: Bool { expanded && visibilityBlockers.isEmpty }
    func setVisibilityBlocked(_ blocker: VisibilityBlocker, _ blocked: Bool) {
        let wasLive = visiblyExpanded
        if blocked { visibilityBlockers.insert(blocker) }
        // The user is back: an SSH host that came back meanwhile need not wait out its backoff.
        else if visibilityBlockers.remove(blocker) != nil, blocker != .occluded { requestSSHReconnect() }
        guard visiblyExpanded != wasLive else { return }
        applyRefreshCadence()
        guard visiblyExpanded else { return }
        // Back in view: catch up once, as opening the panel does.
        redrawClock()
        if !demo, !sleeping, !stopped { refreshActivity(metricsOnly: true) }
        if Date().timeIntervalSince(codexQuotaState?.lastAttempt ?? .distantPast) > 30 { refreshQuota() }
    }
    private func applyRefreshCadence() {
        durablePanelInView.set(visiblyExpanded)
        if !demo, !sleeping, !stopped {
            logWatcher.update(watchedLogURLs, interval: activityRefreshPolicy.interval, flushPending: visiblyExpanded)
            let generation = sourceGeneration
            launchOwnedWork(.init(.presentation, identifier: "activity-policy")) { [weak self] ticket in
                guard let self else { return }
                for provider in self.enabledProviders {
                    guard generation == self.sourceGeneration, self.lifecycle.owns(ticket) else { return }
                    let policy = self.activityRefreshPolicy
                    await self.activityAdapters[provider]?.updatePolicy(policy, self.visiblyExpanded)
                }
            }
        }
        if clock != nil { scheduleClock() }
    }
    var appearance: IslandAppearance { .stored(in: defaults) }
    var expandedQuotaStyle: ExpandedQuotaStyle { .load(from: defaults) }
    var showInFullscreen: Bool { defaults.bool(forKey: "showInFullscreen") }
    var hideProjects: Bool { defaults.bool(forKey: "hideProjects") }
    var displayID: Int { defaults.integer(forKey: "displayID") }
    var taskGroups: [ActivityTaskGroup] { activityState.taskGroups() }
    func taskGroup(for activity: SessionActivity) -> ActivityTaskGroup? { taskGroups.first { $0.primary.id == activity.canonicalized().id } }
    var overview: ActivityOverview { activityState.overview(at: now) }
    var running: [SessionActivity] { overview.running }
    var waiting: [SessionActivity] { overview.waiting }
    var taskPresentation: ActivityTaskPresentation {
        activityState.presentation(at: now, options: taskPresentationOptions(for: activities))
    }
    var visibleActivities: [SessionActivity] { taskPresentation.visibleActivities }
    var completedRetention: TimeInterval {
        let minutes = defaults.object(forKey: "completedRetentionMinutes") as? Int ?? 30
        return Double([0, 5, 15, 30, 60, 240].contains(minutes) ? minutes : 30) * 60
    }
    var pendingCompletions: [SessionActivity] { taskPresentation.pendingCompletions }
    var pendingInputRequests: [PendingAttentionRequest] { attentionRequests }
    var headerStatus: String { compactTaskContext.headerStatusText(language: L10n.language) }
    var headerDisplayStatus: String { compactTaskContext.statusText(language: L10n.language) }
    func headerActivity(singleTask: ActivityBadgeSingleTask? = nil) -> HeaderActivity {
        taskPresentation.header(singleTask: singleTask ?? ActivityBadgeSingleTask(defaults: defaults), symbol: StatusSymbols.symbol)
    }
    var taskAccent: Color { Color(red: 0.56, green: 0.84, blue: 0.79) }
    func attentionKind(for activity: SessionActivity) -> PendingAttentionRequest.Kind? {
        taskPresentation.attentionKind(for: activity)
    }
    var headerRateText: String? { rate == nil ? nil : compactComponent(.tps).text }
    var hasSSHConnectionIssue: Bool {
        monitorsSSH && (!unavailableSSH.isEmpty || ConnectionSource.hasSSHFailure(in: [streamStatuses, claudeStreamStatuses]))
    }
    func isUnreadCompletion(_ activity: SessionActivity) -> Bool { taskGroup(for: activity)?.isRunning != true && completionInbox.isUnread(activity) }
    private var readableCompletions: [SessionActivity] { taskPresentation.readableCompletions }
    var canMarkAllRead: Bool { !readableCompletions.isEmpty }
    func markAllRead() {
        guard activityState.markAllRead(at: now) else { return }
        applyActivityUpdate(activityState.update())
        onLayoutChange?(); onStatusChange?()
    }
    func openCompletionOrPin() {
        if let request = pendingInputRequests.first, canOpen(request.activity) { open(request.activity) }
        else if let activity = pendingCompletions.first, canOpen(activity) { open(activity) }
        else { togglePin() }
    }
    var selectedWindow: QuotaWindow? { providerSelectedWindow(selectedProvider) }
    var compactMetricLabel: String {
        L10n.text((defaults.string(forKey: "compactMetric").flatMap(CompactBarPresentation.Metric.init(rawValue:)) ?? .remaining).labelKey)
    }
    func compactQuotaValue(_ provider: AgentProvider, metric: String? = nil, selection: String? = nil) -> Double? {
        CompactBarPresentation.quotaValue(provider: provider, snapshot: providerQuota(provider),
            failed: providerQuotaError(provider) != nil,
            metric: (metric ?? defaults.string(forKey: "compactMetric")).flatMap(CompactBarPresentation.Metric.init(rawValue:)) ?? .remaining,
            selection: selection ?? defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID"), now: now)
    }
    /// The percentage without its sign, for the docked strip's stacked units.
    func compactQuotaNumber(_ provider: AgentProvider, metric: String? = nil, selection: String? = nil) -> String? {
        compactQuotaValue(provider, metric: metric, selection: selection).map { "\(Int($0.rounded()))" }
    }
    func compactQuotaText(_ provider: AgentProvider, metric: String? = nil, selection: String? = nil) -> String {
        if provider == .deepseek { return deepseekCompactText }
        return compactQuotaNumber(provider, metric: metric, selection: selection).map { $0 + "%" } ?? "—"
    }
    func compactTimeRemainingNumber(_ provider: AgentProvider, selection: String? = nil) -> String? {
        CompactBarPresentation.timeRemainingNumber(provider: provider, snapshot: providerQuota(provider),
            selection: selection ?? defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID"), now: now)
    }
    func compactTimeRemainingText(_ provider: AgentProvider, selection: String? = nil) -> String {
        compactTimeRemainingNumber(provider, selection: selection).map { $0 + "%" } ?? "—"
    }
    var rate: Double? { overview.displayedRate }
    var rateIsFresh: Bool { overview.rateIsFresh }
    var monitorsSSH: Bool { defaults.object(forKey: "monitorSSH") == nil || defaults.bool(forKey: "monitorSSH") }
    /// Dot tasks are opt-in; see `migrateDurableSwitch`.
    nonisolated static let monitorsDurableKey = "monitorDurable"
    var monitorsDurable: Bool { defaults.bool(forKey: Self.monitorsDurableKey) }
    /// An upgraded profile decides once: Dot stays on where its tasks already reported progress.
    static func migrateDurableSwitch(in defaults: UserDefaults, home: URL, files: any PlatformFileSystem = MacFileSystem()) {
        guard defaults.object(forKey: monitorsDurableKey) == nil else { return }
        defaults.set(DurableUsageEvidence.hasReceipts(home: home, files: files), forKey: monitorsDurableKey)
    }
    static let showsClaudeCloudProjectsKey = "showClaudeCloudProjects"
    var showsClaudeCloudProjects: Bool {
        defaults.object(forKey: Self.showsClaudeCloudProjectsKey) == nil || defaults.bool(forKey: Self.showsClaudeCloudProjectsKey)
    }
    static let showsEmbeddedClaudeSessionsKey = "showEmbeddedClaudeSessions"
    static let showsEmbeddedCodexSessionsKey = "showEmbeddedCodexSessions"
    /// Sessions that another app runs through an agent SDK (a Zotero plugin,
    /// for example). Terminal, editor and Desktop sessions always show.
    func showsEmbeddedSessions(for provider: AgentProvider) -> Bool {
        // Only Codex and Claude run inside other apps' SDKs.
        guard provider == .codex || provider == .claude else { return true }
        let key = provider == .codex ? Self.showsEmbeddedCodexSessionsKey : Self.showsEmbeddedClaudeSessionsKey
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
    func projectName(_ activity: SessionActivity) -> String {
        ActivityTaskRowPresentation.title(activity, hideProjects: hideProjects)
    }

    init(demo: Bool = false, initiallyExpanded: Bool = false, demoClock: @escaping () -> Date = { Date() },
         demoArguments: [String]? = CommandLine.arguments,
         defaults: UserDefaults = .standard, installation: ProviderInstallationDetection? = nil,
         claudeQuotaReads: ClaudeQuotaReadDependencies? = nil,
         completionDismissalStore: CompletionDismissalStore? = nil,
         claudeMonitor: ClaudeActivityMonitor = ClaudeActivityMonitor(),
         claudeRemoteSetup: ClaudeRemoteSetup = ClaudeRemoteSetup(),
         deepseekMonitor: DeepSeekActivityMonitor = DeepSeekActivityMonitor(),
         durableMonitor: MacDurableMonitor = MacDurableMonitor()) {
        self.defaults = defaults
        self.durableMonitor = durableMonitor
        self.compactLayout = .load(from: defaults)
        self.savedPanelLayout = .load(from: defaults)
        self.panelOptions = .load(from: defaults)
        self.claudeMonitor = claudeMonitor
        self.deepseekMonitor = deepseekMonitor
        self.claudeRemoteSetup = claudeRemoteSetup
        self.claudeQuotaReads = claudeQuotaReads ?? ClaudeQuotaReadDependencies()
        self.installationOverride = installation
        self.installation = installation ?? (demo && demoArguments != nil
            ? Self.demoInstallation(demoArguments)
            : .detect(harnessHomes: defaults.dictionary(forKey: Self.harnessHomesKey) as? [String: String] ?? [:]))
        self.modules = .load(from: defaults)
        self.appliedClaudeProgressRing = Self.progressRingEnabled(Self.claudeProgressRingKey, in: defaults)
        self.demo = demo
        self.demoClock = demoClock
        self.demoArguments = demoArguments
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/CurrentCycle", isDirectory: true)
        historyStore = QuotaHistoryStore(directory: directory)
        claudeHistoryStore = QuotaHistoryStore(directory: directory.appendingPathComponent("Claude", isDirectory: true))
        enabledProviders = configuredProviders
        if let saved = defaults.string(forKey: "selectedQuotaProvider").flatMap(AgentProvider.init(rawValue:)), quotaProviders.contains(saved) {
            selectedProvider = saved
        } else { selectedProvider = quotaProviders.first ?? .codex }
        if !demo { Self.migrateDurableSwitch(in: defaults, home: home) }
        appliedDurable = defaults.bool(forKey: Self.monitorsDurableKey)
        lifecycle = ApplicationLifecycleCoordinator(demo: demo, configuration: lifecycleConfiguration)
        deepseekBalanceBinding = currentDeepSeekBalanceBinding
        if !demo { restoreDeepSeekHistory() }
        claudeRemoteTargets = monitorsSSH ? RemoteActivityTarget.claudeCodexTargets(home: home) : []
        activityState = ActivityApplicationState(inbox: CompletionInbox(dismissalStore: completionDismissalStore ?? (demo ? nil : .applicationDefault)))
        activityState.includesDemoMetadata = demo && demoArguments != nil
        bindCompletionSources(.codex)
        bindCompletionSources(.claude)
        bindCompletionSources(.deepseek)
        // Demo opens pinned so its content is visible; --demo-collapsed keeps the bar.
        expanded = (demo && demoArguments?.contains("--demo-collapsed") != true) || initiallyExpanded
        pinned = expanded
        if demo { makeDemo() }
    }

    func start() {
        let plan = lifecycle.start()
        guard !plan.actions.isEmpty else { return }
        syncCodexProgressSwitch()
        syncCodexHooks()
        syncDeepSeekProgressSwitch()
        syncLocalHarnessProgress()
        configureHarnessAccounts()
        performLifecycle(plan)
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.prepareForSleep()
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.resumeAfterSleep()
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.codexApplicationDidLaunch(bundle) }
        })
        // A pinned panel behind a dark display, the lock screen or another user's session is not seen.
        for (name, blocker, blocked) in [(NSWorkspace.screensDidSleepNotification, VisibilityBlocker.displaySleep, true),
                                         (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
                                         (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
                                         (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setVisibilityBlocked(blocker, blocked) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, blocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observations.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setVisibilityBlocked(.screenLock, blocked) }
            })
        }
        // A VPN tunnel or Wi-Fi coming back, also after sleep, retries unreachable SSH hosts.
        networkChanges = MacNetworkChanges { [weak self] in
            Task { @MainActor in self?.requestSSHReconnect() }
        }
    }
    func prepareForSleep() async {
        let plan = lifecycle.prepareForSleep()
        guard plan.actions.contains(.suspendSources) else { return }
        // Credits stay through sleep; a failed read after waking dims them, and notices stay as they were.
        harnessAccounts.values.forEach { $0.suspend() }
        performLifecycle(plan)
        navigation.cancel(); clearNavigationError()
        invalidateWork(invalidateSource: false)
        claudeRefreshing = false
        let balance = cancelDeepSeekBalanceRead(stop: false)
        let deadline = ShutdownDeadline()
        let quota = detachCodexQuota(), claudeQuota = detachClaudeQuota(), cloud = claudeCloudCoordinator
        let harnesses = detachLocalHarnesses()
        await ApplicationLifecycleCoordinator.cleanup([
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claudeQuota?.stop() },
            .cloud: { await cloud?.suspend() }, .balance: { await balance?.stop() }
        ], activity: activityAdapters.cleanup(.sleep, deadline: deadline, detached: harnesses), deadline: deadline)
    }
    func resumeAfterSleep() {
        let plan = lifecycle.resume()
        guard !plan.actions.isEmpty else { return }
        configureHarnessAccounts()
        redrawClock(); performLifecycle(plan)
    }
    /// Elapsed times, countdowns and rate expiry change with time alone.
    func redrawClock(_ date: Date = Date()) { now = date; objectWillChange.send() }
    func setExpanded(_ value: Bool) {
        guard !value || !interactionSuspended else { return }
        closeWork?.cancel()
        guard expanded != value else { return }
        expanded = value
        applyRefreshCadence()
        if value, !demo, !sleeping, !stopped { refreshActivity(metricsOnly: true) }
        onLayoutChange?()
        if value && Date().timeIntervalSince(codexQuotaState?.lastAttempt ?? .distantPast) > 30 { refreshQuota() }
        if value { refreshDesktopApplications(force: false) }
    }
    func hover(_ entered: Bool) {
        guard !interactionSuspended, !islandMoving else { return }
        closeWork?.cancel()
        if entered { setExpanded(true) }
        else if !pinned {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
    func togglePin() {
        guard !interactionSuspended else { return }
        pinned.toggle(); setExpanded(true); if pinned { onFocusRequested?() }
    }
    func setInteractionSuspended(_ suspended: Bool) {
        interactionSuspended = suspended
        if suspended { close() }
    }
    /// A published write redraws every view even when the value is unchanged.
    func close() { if pinned { pinned = false }; setExpanded(false) }
    private func navigationScope(for activity: SessionActivity) -> String? {
        if let value = localHarnessActivities[activity.provider] { return value.scope }
        return activity.claudeCloud == nil ? nil : claudeCloudNavigationScope
    }
    private func acceptsNavigation(_ activity: SessionActivity) -> Bool {
        !stopped && !sleeping && (isModuleEnabled(activity.provider) || demo)
    }
    func open(_ activity: SessionActivity) {
        guard canOpen(activity), let target = conversationTarget(for: activity), let open = onOpenActivity,
              let operation = navigation.begin(activity: activity, target: target, version: UInt64(sourceGeneration(for: activity.provider)),
                activities: activities, inbox: completionInbox, active: acceptsNavigation(activity), scope: navigationScope(for: activity), requests: pendingInputRequests) else { return }
        clearNavigationError()
        launchOwnedWork(.init(.navigation, provider: activity.provider, identifier: operation.id.uuidString)) { [weak self] _ in
            guard let self else { return }
            defer { self.navigation.abandon(operation) }
            guard self.navigation.owns(operation), operation.isCurrent(version: UInt64(self.sourceGeneration(for: activity.provider)),
                active: self.acceptsNavigation(activity), inbox: self.completionInbox, scope: self.navigationScope(for: activity)) else { return }
            let outcome = await open(operation.target)
            var values = self.activities, inbox = self.completionInbox
            guard let result = self.navigation.complete(operation, outcome: outcome, version: UInt64(self.sourceGeneration(for: activity.provider)),
                active: self.acceptsNavigation(activity), activities: &values, inbox: &inbox, remoteSourceIDs: Set(self.claudeRemoteTargets.map(\.id)),
                scope: self.navigationScope(for: activity), now: self.navigationClock(), errorDuration: self.navigationErrorDuration, requests: self.pendingInputRequests), result.accepted else { return }
            self.completionInbox = inbox
            if !result.removed.isEmpty { self.activities = values }
            if result.failure != nil { self.publishNavigationFailure() }
            self.onLayoutChange?(); self.onStatusChange?()
        }
    }
    private func clearNavigationError() {
        navigation.clearFailure(); cancelOwnedWork(.init(.navigationError))
        navigationError = nil
    }
    func showNavigationError(_ message: String) {
        guard !stopped else { return }
        navigation.showFailure(message, now: navigationClock(), duration: navigationErrorDuration)
        publishNavigationFailure()
    }
    private func publishNavigationFailure() {
        guard let failure = navigation.failure else { return }
        navigationError = failure.message; setExpanded(true)
        let delay = max(0.001, failure.deadline - navigationClock() + 0.001)
        launchOwnedWork(.init(.navigationError)) { [weak self] _ in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.navigation.expireFailure(failure.id, now: self.navigationClock()) else { return }
            self.navigationError = nil; self.onLayoutChange?()
        }
    }

    func hostApplication(for activity: SessionActivity) -> HostApplication? {
        hostTracking.application(for: activity, activities: activities, inbox: completionInbox, remoteSourceIDs: Set(claudeRemoteTargets.map(\.id)))
    }
    func claudeHost(for activity: SessionActivity) -> HostApplication? { hostApplication(for: activity) }
    private func publishHostApplications(layout: Bool = true) {
        guard hostApplications != hostTracking.applications else { return }
        hostApplications = hostTracking.applications
        if layout { onLayoutChange?() }
    }
    func recordHostApplications(_ found: [String: HostApplication], provider: AgentProvider) {
        if hostTracking.record(found, provider: provider) { publishHostApplications() }
    }
    func trackHostApplications(for provider: AgentProvider, now: Date = Date()) {
        let decision = hostTracking.prepare(provider: provider, references: knownActivities(for: provider), activities: activities, inbox: completionInbox,
            remoteSourceIDs: Set(claudeRemoteTargets.map(\.id)), version: UInt64(sourceGeneration(for: provider)), now: now,
            active: !stopped && !sleeping, demo: demo)
        publishHostApplications(layout: false)
        let retryKey = ApplicationWorkRegistry.Key(.hostRetry, provider: provider)
        switch decision {
        case .idle: break
        case .cancelRetry: ownedWork.cancel(retryKey)
        case .retry(let retry):
            let owner = ownedWork.begin(retryKey, version: retry.version)
            let task = Task { [weak self] in
                defer { if let self { self.ownedWork.finish(owner) } }
                do { try await Task.sleep(nanoseconds: UInt64(max(0, retry.delay) * 1_000_000_000)) } catch { return }
                guard let self, self.hostTracking.finishRetry(retry, version: UInt64(self.sourceGeneration(for: provider)),
                    active: !self.stopped && !self.sleeping, cancelled: Task.isCancelled) else { return }
                self.ownedWork.finish(owner); self.trackHostApplications(for: provider)
            }
            ownedWork.attach(task, to: owner)
        case .scan(let scan):
            ownedWork.cancel(retryKey)
            let sourceHome = provider == .codex ? home : claudeHome, resolve = hostApplicationResolver
            let owner = ownedWork.begin(.init(.hostScan, provider: provider), version: scan.version)
            let task = Task { [weak self] in
                let found = await resolve(provider, scan.sessions, sourceHome)
                guard let self else { return }
                defer { self.ownedWork.finish(owner) }
                let result = self.hostTracking.complete(scan, found: found, version: UInt64(self.sourceGeneration(for: provider)),
                    active: !self.stopped && !self.sleeping, cancelled: Task.isCancelled)
                if result.owned { self.ownedWork.finish(owner) }
                guard result.accepted else { return }
                self.publishHostApplications(); self.trackHostApplications(for: provider)
            }
            ownedWork.attach(task, to: owner)
        }
    }
    func sourceGeneration(for provider: AgentProvider) -> Int {
        switch provider {
        case .codex: sourceGeneration
        case .claude: claudeGeneration
        default: Int(lifecycle.version(provider))
        }
    }
    private func cancelHostTracking(for provider: AgentProvider? = nil, clearApplications: Bool = false) {
        hostTracking.cancel(provider: provider, clearApplications: clearApplications)
        ownedWork.cancel(provider: provider, kinds: [.hostScan, .hostRetry])
        publishHostApplications(layout: false)
    }

    func refreshQuota() {
        refreshCodexQuota()
        refreshClaudeQuota()
        refreshDeepSeekBalance()
    }
    private func refreshCodexQuota(force: Bool = true) {
        guard isModuleEnabled(.codex), refreshTask == nil, !sleeping, !stopped, !demo else { return }
        guard ProviderQuotaRefreshPolicy.isDue(lastAttempt: codexQuotaState?.lastAttempt, expanded: visiblyExpanded,
            failures: codexQuotaState?.failureCount ?? 0, now: Date(), force: force) else { return }
        let generation = sourceGeneration, sourceHome = home, custom = defaults.string(forKey: "codexExecutable") ?? ""
        let owner = codexQuotaOwnerID, receipt = UUID()
        if codexQuotaCoordinator == nil {
            let services = CodexQuotaServices(makeClient: { home, custom in
                let report = await Task.detached(priority: .utility) { CodexExecutableResolver.discover(customPath: custom) }.value
                try Task.checkCancellation()
                guard let selected = report.selected else {
                    throw CodexClientError.executableNotFound(report.issue ?? L10n.text("cli.missing_short"))
                }
                return MacCodexQuotaConnection(client: CodexClient(executable: selected.url, home: home), selection: selected)
            }, history: historyStore)
            codexQuotaCoordinator = CodexQuotaCoordinator(services: services, seed: codexQuotaState) { [weak self] state in
                await self?.receiveCodexQuota(state, owner: owner)
            }
        }
        guard let coordinator = codexQuotaCoordinator else { return }
        codexQuotaReceiptID = receipt
        codexQuotaStarting = true; codexRefreshing = true
        launchOwnedWork(.init(.quota, provider: .codex)) { [weak self] workTicket in
            guard let self else { return }
            defer { if self.codexQuotaReceiptID == receipt { self.ownedWork.finish(workTicket); self.codexQuotaReceiptID = nil } }
            guard generation == self.sourceGeneration, !Task.isCancelled else { return }
            await coordinator.configure(home: sourceHome, customPath: custom, enabled: true, context: UInt64(generation))
            guard generation == self.sourceGeneration, !Task.isCancelled else { return }
            await coordinator.refreshIfDue(expanded: self.visiblyExpanded, force: force)
            if self.codexQuotaReceiptID == receipt { self.codexQuotaStarting = false }
            self.receiveCodexQuota(await coordinator.currentState(), owner: owner)
            await coordinator.waitForRefresh()
        }
    }
    private func receiveCodexQuota(_ state: CodexQuotaState, owner: UUID) {
        guard owner == codexQuotaOwnerID, state.context == UInt64(sourceGeneration), !stopped, !sleeping, isModuleEnabled(.codex) else { return }
        let successful = state.successCount > (codexQuotaState?.successCount ?? 0)
        codexQuotaState = state; codexQuota = state.snapshot; codexHistory = state.history
        codexErrorMessage = state.error; codexHistoryWarning = state.warning; codexRefreshing = state.refreshing || codexQuotaStarting; quotaCLI = state.executable
        if successful, let snapshot = state.snapshot {
            now = Date(); present(attention.quotaNotices(snapshot, at: now))
            remindResetExpiry()
        }
        onStatusChange?()
    }
    /// How many days ahead Codex's banked resets count as expiring, for the
    /// collapsed bar's warning and its notification.
    var resetExpiryLeadDays: Int { ResetExpiryReminder.leadDays(defaults.object(forKey: ResetExpiryReminder.defaultsKey) as? Int) }
    func setResetExpiryLeadDays(_ days: Int) {
        defaults.set(ResetExpiryReminder.leadDays(days), forKey: ResetExpiryReminder.defaultsKey)
        objectWillChange.send(); remindResetExpiry()
        onLayoutChange?(); onStatusChange?()
    }
    /// One notification when banked resets enter the lead time, only while the
    /// bar's warning is chosen, like the other reminders that follow it.
    private func remindResetExpiry() {
        guard !demo, !sleeping, !stopped, isModuleEnabled(.codex), compactLayout.shownWarnings.contains(.resetExpiry) else { return }
        present(resetExpiryAttention.notices(codexQuota, leadDays: resetExpiryLeadDays, now: Date()))
    }
    @discardableResult private func detachCodexQuota(preservingCadence: Bool = true) -> CodexQuotaCoordinator? {
        let previous = codexQuotaCoordinator; previous?.invalidateSource()
        codexQuotaCoordinator = nil; codexQuotaOwnerID = UUID(); codexQuotaReceiptID = nil
        refreshTask?.cancel(); cancelOwnedWork(.init(.quota, provider: .codex)); codexRefreshing = false; codexQuotaStarting = false
        if !preservingCadence { codexQuotaState = nil }
        return previous
    }

    func retryQuotaConnection() {
        retryQuotaConnection(for: selectedProvider)
    }
    func retryQuotaConnection(for provider: AgentProvider) {
        if provider == .claude { retryClaudeWebConnection(); return }
        guard !codexRefreshing else { return }
        let previous = detachCodexQuota(), generation = sourceGeneration
        launchOwnedWork(.init(.quotaRestart, provider: .codex)) { [weak self] _ in
            await ApplicationLifecycleCoordinator.cleanup([.codexQuota: { await previous?.stop() }])
            guard let self, generation == self.sourceGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
            self.refreshCodexQuota()
        }
    }

    var claudeNeedsOrganizationSelection: Bool { !claudeOrganizationChoices.isEmpty }
    var claudeConnectionActionTitleKey: String {
        claudeNeedsOrganizationSelection ? "claude.quota.choose_workspace" : "claude.quota.connect"
    }
    var claudeConnectionActionHelpKey: String {
        claudeNeedsOrganizationSelection ? "claude.quota.choose_workspace_help" : "claude.quota.connect_help"
    }
    func signInClaudeQuota() { onClaudeLogin?() }
    func chooseClaudeOrganization() {
        guard claudeNeedsOrganizationSelection else { return }
        onClaudeOrganizationSelection?(claudeOrganizationChoices)
    }
    func connectClaudeQuota() {
        if claudeNeedsOrganizationSelection { chooseClaudeOrganization() }
        else { signInClaudeQuota() }
    }
    func retryClaudeWebConnection(organizationID: String? = nil, afterSignIn: Bool = false) {
        let previousOrganization = defaults.string(forKey: "claudeWebOrganizationID")
        if afterSignIn { defaults.removeObject(forKey: "claudeWebOrganizationID") }
        if let organizationID, UUID(uuidString: organizationID) != nil { defaults.set(organizationID, forKey: "claudeWebOrganizationID") }
        if afterSignIn || previousOrganization != defaults.string(forKey: "claudeWebOrganizationID") {
            // Revoke Cloud callbacks now, before either owner awaits browser or
            // client cleanup. Its history binding still retains the same scope.
            stopClaudeCloudMonitor(); syncClaudeCloudMonitor()
        } else if let cloud = claudeCloudCoordinator {
            launchOwnedWork(.init(.activity, provider: .claude, identifier: "cloud-refresh")) { _ in await cloud.refresh() }
        }
        guard claudeQuotaRestartTask == nil, isModuleEnabled(.claude), !sleeping, !stopped else { return }
        let generation = claudeGeneration, previous = detachClaudeQuota()
        launchOwnedWork(.init(.quotaRestart, provider: .claude)) { [weak self] workTicket in
            await previous?.stop()
            guard let self, self.isCurrentClaudeQuotaRead(generation) else { return }
            self.ownedWork.finish(workTicket); self.refreshClaudeQuota()
        }
    }
    private func isCurrentClaudeQuotaRead(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == claudeGeneration && isModuleEnabled(.claude) && !sleeping && !stopped
    }
    func waitForClaudeQuotaRefresh() async {
        if let restart = claudeQuotaRestartTask { await restart.value }
        let refresh = claudeQuotaTask; await refresh?.value
    }
    private func refreshClaudeQuota(force: Bool = true) {
        guard isModuleEnabled(.claude), claudeQuotaTask == nil, claudeQuotaRestartTask == nil, !sleeping, !stopped, !demo else { return }
        guard ProviderQuotaRefreshPolicy.isDue(lastAttempt: claudeQuotaState?.lastAttempt, expanded: visiblyExpanded,
            failures: claudeQuotaState?.failureCount ?? 0, now: Date(), force: force) else { return }
        let generation = claudeGeneration, sourceHome = claudeHome
        let organization = defaults.string(forKey: "claudeWebOrganizationID") ?? ""
        let owner = claudeQuotaOwnerID, receipt = UUID()
        if claudeQuotaCoordinator == nil {
            let reads = claudeQuotaReads
            let services = ClaudeQuotaServices(makeClient: { @MainActor home, organization, _ in
                let legacy = ClaudeQuotaClient(home: home)
                let compatibility = MacClaudeQuotaConnection(read: { @MainActor in try await reads.compatibility(legacy) },
                    scope: { await legacy.currentAccountScope() }, source: { await legacy.currentSource() },
                    retry: { await legacy.nextRetryAt() }, choices: { [] }, close: { await legacy.shutdown() })
                return PrioritizedClaudeQuotaConnection(services: .init(
                    passive: { @MainActor in await reads.passive(legacy) },
                    webAvailable: { @MainActor in await reads.webSession() != nil },
                    makeWeb: { @MainActor in
                        let web = ClaudeWebQuotaClient(cookieProvider: { await ClaudeWebSessionStore.session() }, home: home,
                            selectedOrganizationProvider: { organization.isEmpty ? nil : organization })
                        return MacClaudeQuotaConnection(read: { @MainActor in try await reads.web(web) },
                            scope: { await web.currentAccountScope() }, source: { await web.currentSource() },
                            retry: { await web.nextRetryAt() }, choices: { @MainActor in await reads.organizations(web) },
                            close: { await web.shutdown() })
                    }, compatibility: compatibility))
            }, history: claudeHistoryStore)
            claudeQuotaCoordinator = ClaudeQuotaCoordinator(services: services, seed: claudeQuotaState, webAvailable: true) { [weak self] state in
                await self?.receiveClaudeQuota(state, owner: owner)
            }
        }
        guard let coordinator = claudeQuotaCoordinator else { return }
        claudeQuotaReceiptID = receipt
        claudeQuotaStarting = true; claudeRefreshing = true
        launchOwnedWork(.init(.quota, provider: .claude)) { [weak self] workTicket in
            guard let self else { return }
            defer { if self.claudeQuotaReceiptID == receipt { self.ownedWork.finish(workTicket); self.claudeQuotaReceiptID = nil } }
            guard self.isCurrentClaudeQuotaRead(generation) else { return }
            await coordinator.configure(home: sourceHome, organization: organization, enabled: true, context: UInt64(generation))
            guard self.isCurrentClaudeQuotaRead(generation) else { return }
            _ = await coordinator.refreshIfDue(expanded: self.visiblyExpanded, force: force)
            if self.claudeQuotaReceiptID == receipt { self.claudeQuotaStarting = false }
            self.receiveClaudeQuota(await coordinator.currentState(), owner: owner)
            await coordinator.waitForRefresh()
        }
    }
    private func receiveClaudeQuota(_ state: ClaudeQuotaState, owner: UUID) {
        guard owner == claudeQuotaOwnerID, state.context == UInt64(claudeGeneration), !stopped, !sleeping, isModuleEnabled(.claude) else { return }
        let successful = state.successCount > (claudeQuotaState?.successCount ?? 0)
        claudeQuotaState = state; claudeQuota = state.snapshot; claudeHistory = state.history
        claudeErrorMessage = state.error; claudeHistoryWarning = state.warning; claudeRefreshing = state.refreshing || claudeQuotaStarting; claudeQuotaSource = state.source
        claudeConnectionNeeded = state.failure.map { [ClaudeQuotaError.notLoggedIn, .credentialsExpired, .keychainAccessRequired, .accountChanged, .webChallenge, .organizationSelectionRequired].contains($0) } ?? false
        claudeOrganizationChoices = state.failure == .organizationSelectionRequired ? state.organizations : []
        if claudeConnectionNeeded { claudeConnectionSaved = nil }
        if successful, let snapshot = state.snapshot {
            now = Date()
            present(claudeQuotaAttention.quotaNotices(snapshot, at: now).map {
                IslandNotice(id: "claude:" + $0.id, kind: $0.kind, title: "Claude · " + $0.title, detail: $0.detail)
            })
        }
        onLayoutChange?(); onStatusChange?()
    }
    @discardableResult private func detachClaudeQuota(preservingCadence: Bool = true) -> ClaudeQuotaCoordinator? {
        let previous = claudeQuotaCoordinator; previous?.invalidateSource()
        claudeQuotaCoordinator = nil; claudeQuotaOwnerID = UUID(); claudeQuotaReceiptID = nil
        claudeQuotaTask?.cancel(); cancelOwnedWork(.init(.quota, provider: .claude)); claudeRefreshing = false; claudeQuotaStarting = false
        if !preservingCadence { claudeQuotaState = nil }
        return previous
    }
    private func startClaudeActivity() {
        guard isModuleEnabled(.claude), claudeActivityTask == nil, !sleeping, !stopped, !demo else { return }
        lastClaudeDiscovery = Date()
        let generation = claudeGeneration, sourceHome = claudeHome, codexHome = home
        launchOwnedWork(.init(.activity, provider: .claude)) { [weak self] workTicket in
            guard let self else { return }
            defer { if generation == self.claudeGeneration { self.ownedWork.finish(workTicket) } }
            // Install or bring Pacer's hooks current before reading the spool.
            await self.ensureClaudeHooks(home: sourceHome, generation: generation)
            guard generation == self.claudeGeneration, !self.stopped else { return }
            // Local collection starts immediately; SSH route lookups cannot
            // hold up local lifecycle or quota presentation.
            await self.claudeMonitor.start(home: sourceHome, remoteTargets: self.claudeRemoteTargets, refreshPolicy: self.activityRefreshPolicy) { [weak self] values, statuses, requests, performance in
                guard let model = self else { return }
                let excluded = await model.claudeMonitor.excludedLocalActivityIDs()
                await MainActor.run {
                    guard generation == model.claudeGeneration, !model.stopped, !model.sleeping, model.isModuleEnabled(.claude) else { return }
                    model.receiveClaudeUpdate(values, statuses: statuses, requests: requests, performance: performance, excludedLocalIDs: excluded)
                }
            }
            self.syncClaudeCloudMonitor()
            let targets = self.monitorsSSH ? await RemoteActivityTarget.claudeConfigured(codexHome: codexHome, claudeHome: sourceHome) : []
            guard !Task.isCancelled, generation == self.claudeGeneration, !self.stopped, !self.sleeping else { return }
            self.reconcileClaudeRemoteTargets(targets)
            await self.claudeMonitor.updateRemoteTargets(targets)
        }
    }
    /// Pausing for sleep keeps the monitor, because what was running can end
    /// meanwhile. Stopping the source forgets it.
    private func syncClaudeCloudMonitor() {
        guard isModuleEnabled(.claude), showsClaudeCloudProjects, !sleeping, !stopped, !demo else { stopClaudeCloudMonitor(); return }
        let generation = claudeGeneration, expanded = visiblyExpanded
        if claudeCloudCoordinator == nil {
            guard let factory = makeClaudeCloudMonitor else { return }
            let clients = MacClaudeCloudClients(prepared: factory(), factory: factory)
            claudeCloudGeneration += 1
            let cloudGeneration = claudeCloudGeneration, target = claudeMonitor
            claudeCloudCoordinator = ClaudeCloudCoordinator(services: .init(makeClient: { await clients.make($0) })) { [weak self] state in
                guard let self, await self.acceptsClaudeCloud(state, generation: cloudGeneration) else { return }
                await target.updateCloud(activities: state.activities, status: state.status, attention: state.attention)
            }
        }
        guard let coordinator = claudeCloudCoordinator else { return }
        let cloudGeneration = claudeCloudGeneration
        let sourceHome = claudeHome, organization = defaults.string(forKey: "claudeWebOrganizationID") ?? ""
        launchOwnedWork(.init(.activity, provider: .claude, identifier: "cloud-binding")) { [weak self] _ in
            guard let self, self.isCurrentClaudeQuotaRead(generation), self.claudeCloudGeneration == cloudGeneration else { return }
            await coordinator.resume(context: UInt64(generation))
            guard self.isCurrentClaudeQuotaRead(generation), self.claudeCloudGeneration == cloudGeneration else { return }
            await coordinator.configure(home: sourceHome, organization: organization, enabled: true, webAvailable: true, context: UInt64(generation))
            guard self.isCurrentClaudeQuotaRead(generation), self.claudeCloudGeneration == cloudGeneration else { return }
            await coordinator.setExpanded(expanded)
            guard self.isCurrentClaudeQuotaRead(generation), self.claudeCloudGeneration == cloudGeneration else { return }
            await coordinator.startAfterPublication()
        }
    }
    private func acceptsClaudeCloud(_ state: ClaudeCloudState, generation: Int) -> Bool {
        guard generation == claudeCloudGeneration, state.context == UInt64(claudeGeneration), !sleeping, !stopped, isModuleEnabled(.claude) else { return false }
        claudeCloudNavigationScope = state.connectionContext + "|" + (defaults.string(forKey: "claudeWebOrganizationID") ?? "")
        if claudeCloudHistoryBinding.observe(state) {
            let ids = Set((activities + completionInbox.activities).filter { $0.claudeCloud != nil }.map(\.id))
            completionInbox.remove(activityIDs: ids)
            claudeReceivedActivities.removeAll { $0.claudeCloud != nil }
            activities.removeAll { $0.claudeCloud != nil }
        }
        return true
    }
    private func stopClaudeCloudMonitor() {
        claudeCloudNavigationScope = nil
        guard let coordinator = claudeCloudCoordinator else { return }
        coordinator.invalidateSource(); claudeCloudCoordinator = nil; claudeCloudGeneration += 1
        let target = claudeMonitor, cloudGeneration = claudeCloudGeneration
        launchOwnedWork(.init(.reset, provider: .claude, identifier: "cloud")) { [weak self] _ in
            let deadline = ShutdownDeadline()
            await deadline.perform([{ await coordinator.stop() }])
            guard self?.claudeCloudGeneration == cloudGeneration else { return }
            await deadline.perform([{ await target.updateCloud(activities: [], status: nil, attention: []) }])
        }
    }
    func receiveClaudeUpdate(_ values: [SessionActivity], statuses: [String: RuntimeStreamStatus], requests: [PendingAttentionRequest], performance: [SessionPerformanceUpdate] = [], excludedLocalIDs: Set<String> = []) {
        let excluded = Set(excludedLocalIDs.filter { $0.hasPrefix("claude:local:") })
        if !excluded.isEmpty {
            completionInbox.remove(activityIDs: excluded)
            if activities.contains(where: { excluded.contains($0.id) }) { activities.removeAll { excluded.contains($0.id) } }
        }
        now = Date(); claudeStreamStatuses = statuses
        activityState.replaceHarness(.claude, with: .init(activities: values.filter { !excluded.contains($0.id) }, requests: requests))
        let hidden = hiddenEmbeddedActivityIDs
        let measured = performance.filter { !excluded.contains($0.id) }
        completionInbox.updatePerformance(measured)
        for update in measured where !hidden.contains(update.id) {
            rememberFirstOutput(update.firstTokenLatency, reportedAt: update.firstTokenReportedAt)
        }
        refilterEmbeddedSessions()
        scheduleClaudeRemoteSetup()
    }

    /// Reader metadata wins over an older retained ending. Both providers use
    /// the same visibility rule; hiding never acknowledges or deletes a card.
    private func knownActivities(for provider: AgentProvider) -> [SessionActivity] { activityState.knownActivities(for: provider) }
    private var activityVisibility: ActivityVisibilityOptions {
        .init(embeddedProviders: Set(AgentProvider.allCases.filter { showsEmbeddedSessions(for: $0) }), showsClaudeCloudProjects: showsClaudeCloudProjects)
    }
    private var ignoredCodexActivityIDs: Set<String> { activityState.ignoredCodexActivityIDs }
    private var hiddenEmbeddedActivityIDs: Set<String> { activityState.hiddenActivityIDs(activityVisibility) }
    func refilterEmbeddedSessions() {
        combineActivities()
        for provider in AgentProvider.allCases { trackHostApplications(for: provider) }
    }

    private func localSubagentStates(_ values: [SessionActivity]) -> [String: SessionActivity.SubagentEvidence] {
        var result: [String: SessionActivity.SubagentEvidence] = [:]
        for value in values where value.sourceHostID == nil {
            for (id, evidence) in value.subagentStates {
                if result[id] == nil || result[id]!.observedAt < evidence.observedAt { result[id] = evidence }
            }
        }
        return result
    }
    func refreshTaskSources() {
        activityAdapters[.codex]?.start()
        launchOwnedWork(.init(.discovery, identifier: "manual")) { [weak self] ticket in
            guard let self, self.lifecycle.owns(ticket) else { return }
            await self.realtimeMonitor.retryInactiveHelpers()
            guard self.lifecycle.owns(ticket) else { return }
            self.refreshRemote()
            await self.claudeCloudCoordinator?.refresh()
            for provider in self.enabledProviders where provider != .codex {
                guard self.lifecycle.owns(ticket) else { return }
                await self.activityAdapters[provider]?.refresh?()
            }
        }
        discoverClaudeRemoteTargets(refresh: true)
    }
    func refreshLocalHarness(_ provider: AgentProvider) {
        guard !sleeping, !stopped, isModuleEnabled(provider), localHarnesses[provider] != nil,
              let refresh = activityAdapters[provider]?.refresh else { return }
        launchOwnedWork(.init(.activity, provider: provider, identifier: "refresh-harness")) { _ in
            await refresh()
        }
    }
    /// A burst of network changes joins one pending retry; sleep cancels it.
    func requestSSHReconnect(at now: Date = Date()) {
        let key = ApplicationWorkRegistry.Key(.discovery, identifier: "ssh-reconnect")
        guard monitorsSSH, !demo, !sleeping, !stopped, ownedWork.task(key) == nil else { return }
        let delay = sshReconnect.delay(at: now)
        launchOwnedWork(key) { [weak self] ticket in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.lifecycle.owns(ticket) else { return }
            self.sshReconnect.ran(at: Date())
            if self.isModuleEnabled(.codex) { await self.realtimeMonitor.reconnectUnreachableSSH() }
            guard self.lifecycle.owns(ticket) else { return }
            if self.isModuleEnabled(.claude) { await self.claudeMonitor.reconnectUnreachableSSH() }
        }
    }
    func refreshActivity(metricsOnly: Bool = false) {
        guard isModuleEnabled(.codex), !sleeping, !stopped, !demo else { return }
        if !metricsOnly { localActivityNeedsDiscovery = true }
        guard localTask == nil else { localActivityDirty = true; return }
        localActivityDirty = false
        let onlyMetrics = !localActivityNeedsDiscovery
        localActivityNeedsDiscovery = false
        let generation = sourceGeneration
        let sourceHome = home
        let agentStates = localSubagentStates(remoteActivities)
        launchOwnedWork(.init(.activity, provider: .codex)) { [weak self, reader] workTicket in
            let result = await reader.read(home: sourceHome, phaseAwareRate: true, metricsOnly: onlyMetrics, subagentStates: agentStates)
            let expiry = await reader.nextRunningExpiry
            guard let self else { return }
            defer {
                if generation == self.sourceGeneration {
                    self.ownedWork.finish(workTicket)
                    if self.localActivityDirty { self.refreshActivity(metricsOnly: !self.localActivityNeedsDiscovery) }
                }
            }
            guard !Task.isCancelled, generation == self.sourceGeneration else { return }
            // A metrics read discovers too when a hook row names a new rollout, so
            // the watches follow what the reader follows, not the kind of read asked for.
            if !onlyMetrics || Set(result.watchURLs) != Set(self.watchedLogURLs) {
                self.watchedLogURLs = result.watchURLs
                self.logWatcher.update(result.watchURLs, interval: self.activityRefreshPolicy.interval)
            }
            self.codexRunningExpiry = expiry
            self.receiveLocalUpdate(result.activities, requests: result.requests, excludedIDs: result.excludedIDs)
            self.scheduleRateExpiry()
            self.refreshCodexHookStatusAfterRead()
            self.onStatusChange?()
        }
    }

    func receiveLocalUpdate(_ values: [SessionActivity], requests: [PendingAttentionRequest], excludedIDs: Set<String> = []) {
        now = Date(); excludedCodexActivityIDs = excludedIDs
        activityState.replaceHarness(.codex, with: .init(activities: values, requests: requests))
        refilterEmbeddedSessions()
    }

    func refreshRemote() {
        guard isModuleEnabled(.codex) else { return }
        bindCompletionSources(.codex)
        guard remoteTask == nil, !sleeping, !stopped, !demo else { return }
        lastRemoteDiscovery = Date()
        let generation = sourceGeneration
        let sourceHome = home
        launchOwnedWork(.init(.remote, provider: .codex)) { [weak self] workTicket in
            guard let self else { return }
            defer { if generation == self.sourceGeneration { self.ownedWork.finish(workTicket) } }
            await self.realtimeMonitor.startAsync(home: sourceHome, includeSSH: self.monitorsSSH,
                refreshPolicy: self.activityRefreshPolicy) { [weak self] snapshot in
                // The monitor publishes serially. Keep that order on the UI
                // queue so a later empty snapshot cannot overtake an ending.
                DispatchQueue.main.async {
                    guard let self, generation == self.sourceGeneration, !self.stopped, !self.sleeping else { return }
                    self.receiveRemoteUpdate(snapshot.activities, statuses: snapshot.statuses,
                        unavailable: snapshot.unavailableSources.filter(ConnectionSource.isSSHSourceID),
                        requests: [], names: snapshot.names, performance: snapshot.performance)
                }
            }
            // A hover/collapse can occur while start is awaiting the monitor.
            await self.realtimeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.visiblyExpanded)
            self.syncDurable()
        }
    }

    func receiveRemoteUpdate(_ activities: [SessionActivity], statuses: [String: RuntimeStreamStatus],
                             unavailable: [String], requests: [PendingAttentionRequest], names: [SessionNameUpdate], performance: [SessionPerformanceUpdate] = []) {
        let oldLocal = Set(remoteActivities.filter { $0.sourceHostID == nil }.map { $0.id + ":" + ($0.turnID ?? "") })
        let newLocal = Set(activities.filter { $0.sourceHostID == nil }.map { $0.id + ":" + ($0.turnID ?? "") })
        let agentStatesChanged = localSubagentStates(remoteActivities) != localSubagentStates(activities)
        now = Date(); sshActivities = activities; remoteActivities = activities + durableActivities
        let hidden = hiddenEmbeddedActivityIDs, ignored = ignoredCodexActivityIDs
        for update in performance where !hidden.contains(update.id) {
            rememberFirstOutput(update.firstTokenLatency, reportedAt: update.firstTokenReportedAt)
        }
        completionInbox.updateNames(names.filter { !ignored.contains($0.id) })
        completionInbox.updatePerformance(performance.filter { !ignored.contains($0.id) })
        if !Self.sameVisibleStreamState(streamStatuses, statuses) { streamStatuses = statuses }
        if unavailableSSH != unavailable { unavailableSSH = unavailable }
        codexReceivedRequests = requests
        refilterEmbeddedSessions()
        if oldLocal != newLocal { refreshActivity() }
        else if agentStatesChanged { refreshActivity(metricsOnly: true) }
        // A host that just connected can get the progress tool.
        scheduleCodexRemoteProgress()
    }
    /// Helper CPU, loop and notification counters change on every heartbeat and are never shown.
    static func sameVisibleStreamState(_ lhs: [String: RuntimeStreamStatus], _ rhs: [String: RuntimeStreamStatus]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { key, value in rhs[key].map(value.sameState(as:)) == true }
    }
    func applyActivityUpdate(_ update: ActivityApplicationUpdate) {
        if activities != update.activities { activities = update.activities }
        if attentionRequests != update.requests { attentionRequests = update.requests }
        if latestFirstOutputLatency != update.latestFirstOutputLatency { latestFirstOutputLatency = update.latestFirstOutputLatency }
    }
    func observeAttentionRequests(_ requests: [PendingAttentionRequest]) {
        let notices = activityState.observeAttentionRequests(requests, visibility: activityVisibility)
        applyActivityUpdate(activityState.update()); present(notices)
    }
    private var codexDelegationLedger: (at: Date, links: [String: CodexDelegationLink])?
    /// The ledger's runs as last read.
    private(set) var codexDelegationRuns: [ClaudeCodexDelegation.Run] = []
    /// Collaboration's self-check: Codex's version, sign-in and model catalog.
    @Published var codexDelegationCheck = CodexDelegationCheck()
    /// Codex for Claude's ledger, read at most once a second: a run's rollout
    /// changes as it starts, runs and is deleted, so each change combines anyway.
    private func codexDelegationLinks(at date: Date) -> [String: CodexDelegationLink] {
        guard !demo, isModuleEnabled(.claude), isModuleEnabled(.codex) else { codexDelegationRuns = []; return [:] }
        if let cached = codexDelegationLedger, abs(date.timeIntervalSince(cached.at)) < 1 { return cached.links }
        codexDelegationRuns = ClaudeCodexDelegation.runs(home: claudeHome)
        let links = ClaudeCodexDelegation.links(codexDelegationRuns)
        codexDelegationLedger = (date, links); return links
    }
    /// Asks a running Codex for Claude run's runner to stop it; the runner
    /// stops Codex and tells Claude the user stopped it in Pacer.
    @discardableResult
    func stopDelegation(_ activity: SessionActivity) -> Bool {
        guard let link = activityState.codexDelegation(for: activity), link.status == .running else { return false }
        return ClaudeCodexDelegation.requestStop(directory: link.directory)
    }
    private func combineActivities() {
        let oldHeight = panelContentHeight
        activityState.codexDelegations = codexDelegationLinks(at: now)
        let update = activityState.reconcile(at: now, retention: completedRetention, visibility: activityVisibility)
        applyActivityUpdate(update)
        if RuntimeDiagnostics.enabled { RuntimeDiagnostics.record("ui", source: "combined", activities: update.activities) }
        if oldHeight != panelContentHeight { onLayoutChange?() }
        present(update.notices); onStatusChange?()
    }
    func rememberFirstOutput(_ latency: TimeInterval?, reportedAt: Date?) {
        activityState.rememberFirstOutput(latency, reportedAt: reportedAt, at: now)
        if latestFirstOutputLatency != activityState.latestFirstOutput?.seconds {
            latestFirstOutputLatency = activityState.latestFirstOutput?.seconds
        }
    }

    private var currentCodexSourceSignature: String {
        home.path + "|" + (defaults.string(forKey: "codexExecutable") ?? "") + "|" + String(monitorsDurable)
    }
    private var currentClaudeSourceSignature: String {
        claudeHome.path + "|" + String(monitorsSSH) + (monitorsSSH
            ? "|" + home.path : "")
    }
    private var configuredProviders: [AgentProvider] {
        let supported = HarnessRegistry.legacyIDs + localHarnessDescriptors.map(\.id)
        let enabled = modules.enabledProviders(detection: installation, supported: supported)
        return supported.filter(enabled.contains)
    }
    private var lifecycleConfiguration: ApplicationLifecycleCoordinator.Configuration {
        var sources: [AgentProvider: String] = [.codex: currentCodexSourceSignature,
            .claude: currentClaudeSourceSignature, .deepseek: currentDeepSeekSourceSignature]
        for definition in localHarnesses.definitions where isModuleEnabled(definition.descriptor.id) {
            sources[definition.descriptor.id] = localHarnessHome(definition).path
        }
        return .init(enabled: Set(enabledProviders), sources: sources, hasDemoSnapshot: demo && demoArguments != nil)
    }
    /// The data folder chosen in Settings, then the environment, then the default.
    func localHarnessHome(_ definition: LocalHarnessDefinition) -> URL {
        let chosen = (defaults.dictionary(forKey: Self.harnessHomesKey) as? [String: String])?[definition.descriptor.id.rawValue]
            .map { ($0 as NSString).expandingTildeInPath }.flatMap { $0.isEmpty ? nil : $0 }
        return definition.resolveHome(override: chosen ?? ProcessInfo.processInfo.environment[definition.homeEnvironmentKey]) { $0.hasPrefix("/") }
    }
    func localHarnessHome(_ provider: AgentProvider) -> URL? { localHarnesses.definition(for: provider).map(localHarnessHome) }
    private func bindLocalHarness(_ provider: AgentProvider) {
        guard !demo, !sleeping, !stopped, isModuleEnabled(provider), !localHarnessActivities.isBound(provider),
              let definition = localHarnesses.definition(for: provider) else { return }
        let monitor = localHarnesses.monitor(for: definition)
        let home = localHarnessHome(definition), version = lifecycle.version(provider)
        localHarnessActivities.bind(provider, home: home, generation: version)
        launchOwnedWork(.init(.activity, provider: provider, identifier: "local-harness")) { [weak self] ticket in
            guard let self, self.lifecycle.owns(ticket) else { return }
            let policy = self.activityRefreshPolicy
            await monitor.start(home: home, policy: policy) { [weak self] snapshot in
                await self?.receiveLocalHarness(provider, snapshot: snapshot, home: home, version: version)
            }
        }
    }

    /// A module's credits changed: redraw what shows them and notify once
    /// when they fall low or run out. Only signing out, switching accounts or
    /// sites and turning the module off forget earlier notices; stopping for
    /// sleep does not, so waking with the same low reading stays quiet.
    func receiveHarnessCredits(_ provider: AgentProvider) {
        objectWillChange.send()
        if !demo, !sleeping, !stopped {
            present(harnessCreditsAttention.notices(harnessCredits, settings: creditSettings,
                                                    low: compactLayout.shownWarnings.contains(.lowCredits), now: Date()))
        }
        onLayoutChange?(); onStatusChange?()
    }
    private func configureHarnessAccounts() {
        for (provider, connection) in harnessAccounts {
            if demo {
                connection.showDemo(isModuleEnabled(provider) && provider == .workbuddy ? DemoScenario.workbuddyCredits(at: now) : nil)
                continue
            }
            connection.configure(enabled: !sleeping && !stopped && isModuleEnabled(provider),
                                 keepsReading: sleeping && isModuleEnabled(provider))
        }
    }
    private func receiveLocalHarness(_ provider: AgentProvider, snapshot: HarnessActivity, home: URL, version: UInt64) {
        guard !sleeping, !stopped, isModuleEnabled(provider), lifecycle.version(provider) == version,
              let update = localHarnessActivities.receive(provider, snapshot: snapshot) else { return }
        if update.scopeChanged {
            navigation.cancel(provider: provider)
            activityState.removeHarness(provider)
        }
        if update.needsSourceBinding {
            completionInbox.bindSourceHomes(provider: provider, localHome: home, localAccountScope: update.activity.scope)
        }
        activityState.replaceHarness(provider, with: update.activity)
        now = Date()
        combineActivities()
        localHarnessRevision &+= 1
        noteLocalHarnessProgress(provider, snapshot: snapshot)
    }
    private func resetLocalHarness(_ provider: AgentProvider) {
        localHarnessActivities.remove(provider)
        activityState.removeHarness(provider)
        localHarnessRevision &+= 1
        guard let monitor = localHarnesses.remove(provider), let stop = activityAdapters[provider]?.stop else {
            activityAdapters[provider]?.start(); return
        }
        launchOwnedWork(.init(.activity, provider: provider, identifier: "reset-harness")) { [weak self] ticket in
            let deadline = ShutdownDeadline()
            await deadline.perform([{ await stop(deadline, .reset, monitor) }])
            guard let self, self.lifecycle.owns(ticket) else { return }
            self.activityAdapters[provider]?.start()
        }
    }
    private func detachLocalHarnesses() -> LocalHarnessMonitors {
        localHarnessActivities.detachLocalBindings()
        localHarnessRevision &+= 1
        return localHarnesses.detach()
    }
    func localHarnessDestination(for activity: SessionActivity) -> (url: URL, application: URL)? {
        guard let destination = localHarnessActivities[activity.provider]?.conversationURLs[activity.id],
              let application = MacLocalHarnessApplication.find(provider: activity.provider, destination: destination) else { return nil }
        return (destination, application)
    }
    func applySettings(sourceChanged: Bool) {
        installation = installationOverride ?? (demo && demoArguments != nil
            ? Self.demoInstallation(demoArguments)
            : .detect(harnessHomes: defaults.dictionary(forKey: Self.harnessHomesKey) as? [String: String] ?? [:]))
        modules = .load(from: defaults)
        creditSettings = Self.loadCreditSettings(defaults)
        PacerAccent.current = PacerAccent(defaults: defaults)
        // Light Liquid Glass turns the whole island light before it redraws.
        syncTone()
        enabledProviders = configuredProviders
        syncCodexProgressSwitch()
        syncCodexHooks()
        syncDeepSeekProgressSwitch()
        syncLocalHarnessProgress()
        if !quotaProviders.contains(selectedProvider) { selectedProvider = quotaProviders.first ?? .codex }
        // The header reports its width only when it changes, so the last measurement
        // stays: clearing it would leave the bar at the wider estimate after any setting.
        compactLayout = .load(from: defaults); settingsRevision += 1
        savedPanelLayout = .load(from: defaults); panelOptions = .load(from: defaults)
        // A place chosen in Settings belongs to the display the island is on.
        rememberDisplayPlace()
        if clock != nil { scheduleClock() }
        let plan = lifecycle.settings(lifecycleConfiguration, explicitlyDisablesClaude: modules.claudeMode == .disabled)
        for provider in plan.changedProviders { navigation.cancel(provider: provider) }
        performLifecycle(plan)
        // SSH is outside the Codex source signature so the Remote Control
        // directory survives the switch; hand it to the running monitor now.
        if appliedCodexSSH != monitorsSSH {
            let changed = appliedCodexSSH != nil
            appliedCodexSSH = monitorsSSH
            if changed && !plan.changedProviders.contains(.codex) { refreshRemote() }
            if !monitorsSSH { cancelCodexRemoteProgress() }
        }
        // A restarted Claude source applies the ring's switch as part of its setup.
        if !plan.changedProviders.contains(.claude) || !isModuleEnabled(.claude) { syncClaudeProgressSwitch() }
        if appliedDurable != monitorsDurable {
            appliedDurable = monitorsDurable
            syncCodexProgressSwitch(force: true)
            syncDurable()
        }
        if appliedClaudeProgressRing != showsClaudeProgressRing {
            appliedClaudeProgressRing = showsClaudeProgressRing
            scheduleClaudeRemoteSetup()
        }
        onLayoutChange?(); onStatusChange?()
    }
    private func resetCodexSource() {
        cancelHostTracking(for: .codex, clearApplications: true)
        cancelCodexRemoteProgress(clearHistory: true)
        excludedCodexActivityIDs = []; codexReceivedRequests = []; codexLogRequests = []
        logWatcher.stop(); invalidateWork(invalidateSource: false)
        let previous = detachCodexQuota(preservingCadence: false)
        codexQuota = nil; codexHistory = QuotaCycleHistory(); codexHistoryWarning = nil; codexErrorMessage = nil
        quotaCLI = nil; attention = AttentionPolicy()
        completionInbox.remove(provider: .codex)
        durableAccountScope = nil
        bindCompletionSources(.codex)
        stopDurable(); sshActivities = []
        codexAttentionRequests = []; localActivities = []; remoteActivities = []; unavailableSSH = []; streamStatuses = [:]
        activities.removeAll { $0.provider == .codex }
        observeAttentionRequests(claudeAttentionRequests + deepseekAttentionRequests)
        clearSourceState()
        let generation = sourceGeneration
        launchOwnedWork(.init(.reset, provider: .codex)) { [weak self, reader] _ in
            guard let self else {
                await ApplicationLifecycleCoordinator.cleanup([.codexQuota: { await previous?.stop() }]); return
            }
            let current = generation == self.sourceGeneration && !self.sleeping && !self.stopped && !Task.isCancelled
            let deadline = ShutdownDeadline()
            let stop = self.stopActivity(.codex, deadline: deadline)
            await ApplicationLifecycleCoordinator.cleanup([
                .codexQuota: { await previous?.stop() },
                .realtime: { if current { await stop?() } },
                .reader: { if current { await reader.reset() } }
            ], deadline: deadline)
            guard generation == self.sourceGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
            self.refreshCodexQuota()
            self.activityAdapters[.codex]?.start()
            self.activityAdapters[.codex]?.discoverRoutes?()
        }
    }
    private func resetClaudeSource() {
        stopClaudeCloudMonitor()
        cancelClaudeRemoteSetup()
        claudeRemoteSetupStatus.removeAll(); claudeRemoteSetupFailures.removeAll(); claudeRemoteSetupFailedAt.removeAll(); claudeRemoteCheckedAt.removeAll()
        claudeQuotaRestartTask?.cancel(); cancelOwnedWork(.init(.quotaRestart, provider: .claude))
        claudeQuotaTask?.cancel(); claudeActivityTask?.cancel(); cancelOwnedWork(.init(.activity, provider: .claude))
        let previous = detachClaudeQuota(preservingCadence: false)
        claudeOrganizationChoices = []
        claudeQuota = nil; claudeHistory = QuotaCycleHistory(); claudeHistoryWarning = nil; claudeErrorMessage = nil
        claudeQuotaSource = nil; claudeConnectionNeeded = false; claudeConnectionSaved = nil; claudeQuotaAttention = AttentionPolicy(); claudeActivityAttention = AttentionPolicy()
        completionInbox.remove(provider: .claude)
        claudeRemoteTargets = monitorsSSH ? RemoteActivityTarget.claudeCodexTargets(home: home) : []
        bindCompletionSources(.claude)
        claudeReceivedActivities = []; claudeReceivedRequests = []
        claudeAttentionRequests = []; claudeStreamStatuses = [:]
        cancelHostTracking(for: .claude, clearApplications: true)
        activities.removeAll { $0.provider == .claude }
        observeAttentionRequests(codexAttentionRequests + deepseekAttentionRequests)
        clearSourceState()
        let generation = claudeGeneration
        launchOwnedWork(.init(.reset, provider: .claude)) { [weak self] _ in
            guard let self else {
                await ApplicationLifecycleCoordinator.cleanup([.claudeQuota: { await previous?.stop() }]); return
            }
            let current = generation == self.claudeGeneration && !self.sleeping && !self.stopped && !Task.isCancelled
            let deadline = ShutdownDeadline()
            let stop = self.stopActivity(.claude, deadline: deadline)
            await ApplicationLifecycleCoordinator.cleanup([
                .claudeQuota: { await previous?.stop() }, .claudeActivity: { if current { await stop?() } }
            ], deadline: deadline)
            guard generation == self.claudeGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
            self.refreshClaudeQuota(); self.activityAdapters[.claude]?.start()
        }
    }
    func clearSourceState() {
        clearNavigationError()
        activityState.clearFirstOutput(); latestFirstOutputLatency = nil
        activityState.replaceActivities(activities, at: now)
        latestFirstOutputLatency = activityState.latestFirstOutput?.seconds
    }

    func bindCompletionSources(_ provider: AgentProvider) {
        guard provider != .deepseek else { completionInbox.bindSourceHomes(provider: provider, localHome: deepseekHome); return }
        let targets = provider == .codex ? (monitorsSSH ? RemoteActivityTarget.configured(home: home) : []) : claudeRemoteTargets
        var remoteHomes = Dictionary(targets.map { ($0.id, $0.home) }, uniquingKeysWith: { _, latest in latest })
        if provider == .claude { remoteHomes[ClaudeCloudProjectState.sourceID] = "cloud" }
        completionInbox.bindSourceHomes(provider: provider, localHome: provider == .codex ? home : claudeHome,
            remoteHomes: remoteHomes, durableAccountScope: provider == .codex ? durableAccountScope : nil)
    }

    func shutdown() async {
        // A saved opt-out also takes effect if the settings view has not yet
        // applied its pending changes.
        if codexProgressQueue.target?.enabled == true, !showsCodexProgressRing { syncCodexProgressSwitch() }
        if deepseekProgressQueue.target?.enabled == true, !showsDeepSeekProgressRing { syncDeepSeekProgressSwitch() }
        flushDeepSeekHistory()
        let plan = lifecycle.shutdown()
        guard plan.actions.contains(.stopSources) else { return }
        harnessAccounts.values.forEach { $0.stop() }
        desktopApplicationScan?.cancel()
        clock?.invalidate(); closeWork?.cancel()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        networkChanges = nil
        performLifecycle(plan)
        navigation.cancel(); clearNavigationError()
        invalidateWork(invalidateSource: false)
        let balance = cancelDeepSeekBalanceRead(stop: false)
        let deadline = ShutdownDeadline()
        let quota = detachCodexQuota(), claudeQuota = detachClaudeQuota(), cloud = claudeCloudCoordinator
        let setup = claudeRemoteSetup
        let harnesses = detachLocalHarnesses()
        let progressFlag = codexProgressFlagTask
        let localProgress = Array(localHarnessProgressTasks.values)
        let completed = await ApplicationLifecycleCoordinator.cleanup([
            .codexProgressFlag: { _ = await progressFlag?.value },
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claudeQuota?.stop() },
            .cloud: { await cloud?.stop() }, .remoteSetup: { await setup.shutdown() }, .balance: { await balance?.stop() },
            .harnesses: { for task in localProgress { await task.value } }
        ], activity: activityAdapters.cleanup(.shutdown, deadline: deadline, detached: harnesses), deadline: deadline)
        if !completed { OwnedProcessTermination.terminateAll() }
    }

    private func invalidateWork(invalidateSource: Bool = true) {
        codexRunningExpiry = nil
        rateExpiryWork?.cancel(); rateExpiryWork = nil; rateExpiryAt = nil
        if invalidateSource { lifecycle.invalidateSources([.codex]) }
        codexQuotaCoordinator?.invalidateSource(); refreshTask?.cancel()
        localTask?.cancel()
        remoteTask?.cancel(); cancelOwnedWork(.init(.remote, provider: .codex))
        cancelOwnedWork(.init(.activity, provider: .codex))
        codexRefreshing = false
    }
    private func pruneCompletions() {
        let oldHeight = panelContentHeight
        activityState.prune(at: now, retention: completedRetention)
        applyActivityUpdate(activityState.update())
        scheduleRateExpiry()
        if oldHeight != panelContentHeight { onLayoutChange?() }
    }
    private var harnessMaintenanceAt = Date.distantPast
    /// At most once a minute: credit reminders follow the calendar, so a quiet
    /// account is still reminded before its credits lapse, and a progress guide
    /// that waits on the app checks again, so trusting it outside Pacer's
    /// checks still clears the sidebar dot and the Overview line.
    private func harnessMaintenance() {
        guard !demo, !sleeping, !stopped, now.timeIntervalSince(harnessMaintenanceAt) >= 60 else { return }
        harnessMaintenanceAt = now
        if !harnessCredits.isEmpty {
            present(harnessCreditsAttention.notices(harnessCredits, settings: creditSettings,
                                                    low: compactLayout.shownWarnings.contains(.lowCredits), now: Date()))
        }
        // Reset deadlines also follow the calendar between quota readings.
        remindResetExpiry()
        for definition in localHarnesses.definitions where progressGuide(definition.descriptor.id)?.waiting == true {
            recheckLocalHarnessProgress(definition.descriptor.id)
        }
    }

    private func scheduleClock() {
        clock?.invalidate()
        let interval: TimeInterval = !visiblyExpanded ? 30 : 2
        clock = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        clock?.tolerance = interval * 0.2
    }
    private func scheduleRateExpiry() {
        let display = activityState.nextDisplayDeadline(at: now, retention: completedRetention, progressRingProviders: progressRingProviders)
        let deadline = [display, codexRunningExpiry].compactMap { $0 }.min()
        guard deadline != rateExpiryAt else { return }
        rateExpiryWork?.cancel(); rateExpiryWork = nil; rateExpiryAt = nil
        guard !sleeping, !stopped, let deadline else { return }
        rateExpiryAt = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sleeping, !self.stopped else { return }
            self.rateExpiryWork = nil; self.rateExpiryAt = nil
            self.redrawClock()
            if let expiry = self.codexRunningExpiry, expiry <= self.now {
                self.codexRunningExpiry = nil
                self.refreshActivity(metricsOnly: true)
            }
            self.pruneCompletions()
            self.scheduleRateExpiry()
            self.onStatusChange?()
        }
        rateExpiryWork = work
        // Display deadlines redraw only. A quiet Codex turn gets one read at its own deadline.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow) + 0.01, execute: work)
    }
    private func tick() {
        redrawClock()
        harnessMaintenance()
        refreshCodexHookStatusOnClock()
        performLifecycle(lifecycle.tick(.init(now: now, expanded: visiblyExpanded,
            lastRemoteDiscovery: lastRemoteDiscovery, lastClaudeDiscovery: lastClaudeDiscovery,
            deepseekRunning: running.contains { $0.provider == .deepseek })))
        if !sleeping, !stopped, !demo { onStatusChange?() }
    }
    private func performLifecycle(_ plan: ApplicationLifecycleCoordinator.Plan) {
        if plan.changedProviders.contains(where: { harnessAccounts[$0] != nil }) {
            for provider in plan.changedProviders where harnessAccounts[provider] != nil && !isModuleEnabled(provider) {
                harnessCreditsAttention.reset(provider)
            }
            configureHarnessAccounts()
        }
        for action in plan.actions {
            switch action {
            case .quota(let provider, let force, let active):
                switch provider {
                case .codex: refreshCodexQuota(force: force)
                case .claude: refreshClaudeQuota(force: force)
                case .deepseek: refreshDeepSeekBalance(scheduled: !force, active: active)
                default: break
                }
            case .activity(let provider): activityAdapters[provider]?.start()
            case .discoverActivityRoutes(let provider): activityAdapters[provider]?.discoverRoutes?()
            case .applications: refreshDesktopApplications()
            case .clock: scheduleClock()
            case .displayExpiry: scheduleRateExpiry()
            case .pruneActivities: pruneCompletions()
            case .pruneHistory: codexHistory.prune(at: now); claudeHistory.prune(at: now)
            case .resetSource(let provider): activityAdapters[provider]?.reset()
            case .updateActivityPolicy: logWatcher.update(watchedLogURLs, interval: activityRefreshPolicy.interval)
            case .cloud: syncClaudeCloudMonitor()
            case .balanceBinding: applyDeepSeekBalanceSource()
            case .refilter: refilterEmbeddedSessions()
            case .removeClaudeHooks:
                let home = claudeHome
                launchOwnedWork(.init(.setup, provider: .claude, identifier: "uninstall")) { _ in
                    await Task.detached(priority: .utility) { _ = try? ClaudeHookInstaller.uninstall(home: home) }.value
                }
                claudeLocalSetup = .checking
            case .retryHostTracking: for provider in AgentProvider.allCases { trackHostApplications(for: provider) }
            case .stopWatches: logWatcher.stop()
            case .cancelHostTracking: cancelHostTracking()
            case .cancelRemoteSetup: cancelClaudeRemoteSetup(); cancelCodexRemoteProgress()
            case .demoSnapshot: applyDemoSnapshot()
            case .suspendSources, .stopSources: break
            }
        }
    }
    /// The collapsed bar already shows each of these states while it lasts, so
    /// a moment only leaves the island as a system notification, when chosen.
    func present(_ notices: [IslandNotice]) {
        guard !demo else { return }
        for notice in notices { notifications.deliver(notice) }
    }
    /// Each provider gets its own sample, whichever one Settings showed last.
    private func makeDemo() {
        redrawClock(demoClock())
        for snapshot in DemoScenario.quota(.codex, at: now) { codexHistory.record(snapshot); codexQuota = snapshot }
        for snapshot in DemoScenario.quota(.claude, at: now) { claudeHistory.record(snapshot); claudeQuota = snapshot }
        makeDeepSeekDemo()
        configureHarnessAccounts()
        guard demoArguments != nil else { return }
        setDemoStage(demoArguments?.contains("--demo-cloud") == true ? .tool : .thinking)
        if demoArguments?.contains("--demo-completion") == true { setDemoStage(.completed) }
    }
    private func applyDemoSnapshot() {
        let update = activityState.applyDemoSnapshot(enabled: Set(enabledProviders), at: now, visibility: activityVisibility)
        applyActivityUpdate(update); present(update.notices)
    }
    func setDemoStage(_ stage: DemoTaskStage) {
        guard demo else { return }
        redrawClock(demoClock())
        let demoArguments = demoArguments ?? []
        var observed = demoArguments.contains("--demo-subagents") ? DemoScenario.subagentTasks(stage: stage, at: now) : DemoScenario.tasks(stage: stage, at: now)
        if demoArguments.contains("--demo-claude") { observed.append(DemoScenario.claudeTask(stage: stage, at: now)) }
        if demoArguments.contains("--demo-deepseek") { observed.append(DemoScenario.deepseekTask(stage: stage, at: now)) }
        // A module turned on in the demo joins it with its own task.
        if isModuleEnabled(.workbuddy) { observed.append(DemoScenario.workbuddyTask(stage: stage, at: now)) }
        demoRequests = []
        if demoArguments.contains("--demo-cloud") {
            let cloud = DemoScenario.claudeCloud(stage: stage, at: now)
            observed += cloud.activities
            demoRequests = cloud.attention
        }
        demoActivities = observed
        completionInbox.observe(observed, at: now, retention: completedRetention)
        applyDemoSnapshot()
        var status = RuntimeStreamStatus()
        status.connected = true; status.attachedThreads = 1; status.notifications = 7 + stage.rawValue
        streamStatuses = ["local": status, "remote-ssh-discovered:demo": status]
        onLayoutChange?(); onStatusChange?()
    }
}

/// Whether the panel can be seen, readable from the Dot poll's background task.
final class DurableVisibility: @unchecked Sendable {
    private let lock = NSLock()
    private var current = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ value: Bool) { lock.lock(); current = value; lock.unlock() }
}

