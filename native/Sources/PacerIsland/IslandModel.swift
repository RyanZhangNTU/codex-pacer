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
        didSet { if oldValue?.windows.count != codexQuota?.windows.count { onLayoutChange?() } }
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
            case .deepseek: return
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
            case .deepseek: break
            }
        }
    }
    var historyWarning: String? {
        get { providerHistoryWarning(selectedProvider) }
        set {
            switch selectedProvider {
            case .codex: codexHistoryWarning = newValue
            case .claude: claudeHistoryWarning = newValue
            case .deepseek: break
            }
        }
    }
    var errorMessage: String? {
        get { providerQuotaError(selectedProvider) }
        set {
            switch selectedProvider {
            case .codex: codexErrorMessage = newValue
            case .claude: claudeErrorMessage = newValue
            case .deepseek: break
            }
        }
    }
    func isModuleEnabled(_ provider: AgentProvider) -> Bool { enabledProviders.contains(provider) }
    func providerDetected(_ provider: AgentProvider) -> Bool { installation.isInstalled(provider) }
    func providerRefreshing(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .codex: codexRefreshing
        case .claude: claudeRefreshing
        case .deepseek: deepseekRefreshing
        }
    }
    func providerStreamStatuses(_ provider: AgentProvider) -> [String: RuntimeStreamStatus] {
        switch provider {
        case .codex: streamStatuses
        case .claude: claudeStreamStatuses
        case .deepseek: deepseekStreamStatuses
        }
    }
    func taskPresentationOptions(for values: [SessionActivity]) -> TaskPresentationOptions {
        let hosts = hostTracking.labels(for: values, activities: activities, inbox: completionInbox,
            remoteSourceIDs: Set(claudeRemoteTargets.map(\.id))) { .init(name: $0.name, isClaudeDesktop: $0.isClaudeDesktop) }
        return .init(hideProjects: hideProjects, hostApplications: hosts,
            sourceNames: streamStatuses.compactMapValues(\.sourceName), showsDeepSeekTurnCost: showsDeepSeekTurnCost,
            progressRingProviders: progressRingProviders)
    }
    func taskSourceName(_ activity: SessionActivity) -> String? {
        ActivityTaskRowPresentation.sourceName(activity, options: taskPresentationOptions(for: [activity]))
    }
    func providerQuota(_ provider: AgentProvider) -> QuotaSnapshot? {
        switch provider {
        case .codex: codexQuota
        case .claude: claudeQuota
        case .deepseek: nil
        }
    }
    func providerQuotaError(_ provider: AgentProvider) -> String? {
        switch provider {
        case .codex: codexErrorMessage
        case .claude: claudeErrorMessage
        case .deepseek: deepseekBalanceError?.errorDescription
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
        case .deepseek: QuotaCycleHistory()
        }
    }
    func providerHistoryWarning(_ provider: AgentProvider) -> String? {
        switch provider {
        case .codex: codexHistoryWarning
        case .claude: claudeHistoryWarning
        case .deepseek: nil
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
        guard enabledProviders.contains(provider), selectedProvider != provider else { return }
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
        // A switch that Pacer's folder can already hold is set up in the same pass.
        applyClaudeProgressSwitch(home: home)
        var result = await installClaudeHooks(home: home)
        guard generation == claudeGeneration else { return }
        // Setup creates Pacer's hook folder, which the switch file needs, and
        // confirms that Pacer manages this home.
        if result == .current || result == .installed, applyClaudeProgressSwitch(home: home, setupConfirmed: true) {
            let again = await installClaudeHooks(home: home)
            guard generation == claudeGeneration else { return }
            if again != .current { result = again }
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
    private let codexProgressGate = CodexProgressSwitchGate()
    var showsCodexProgressRing: Bool { Self.progressRingEnabled(Self.codexProgressRingKey, in: defaults) }
    func syncCodexProgressSwitch(force: Bool = false) {
        guard !demo, !stopped, installationOverride == nil, let reporter = Bundle.main.executableURL,
              let ticket = codexProgressQueue.request(.init(home: home, executable: defaults.string(forKey: "codexExecutable") ?? "",
                                                            enabled: showsCodexProgressRing && isModuleEnabled(.codex)), force: force) else { return }
        let target = ticket.target
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
                    _ = await Self.configureCodexReporter(home: previous.home, executable: previous.executable, reporter: reporter, enabled: false)
                }
                return await Self.configureCodexReporter(home: target.home, executable: target.executable, reporter: reporter, enabled: target.enabled,
                                                         gate: gate, request: generation)
            }.value
            guard let self, !stopped, codexProgressQueue.finish(ticket) else { return }
            codexProgressFlagTask = nil
            codexProgressSetup = status
        }
        codexProgressQueue.track(task)
    }

    private nonisolated static func configureCodexReporter(home: URL, executable: String, reporter: URL, enabled: Bool,
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
            _ = await MacDurableProgressSetup.apply(home: home, reporter: enabled ? reporter : nil,
                                                    customExecutable: executable)
        }
        return status
    }
    private var progressRingProviders: Set<AgentProvider> {
        var providers: Set<AgentProvider> = []
        if showsClaudeProgressRing { providers.insert(.claude) }
        if showsCodexProgressRing { providers.insert(.codex) }
        if showsDeepSeekProgressRing { providers.insert(.deepseek) }
        return providers
    }
    /// Claude's self-reported progress ring; on until the user turns it off.
    var showsClaudeProgressRing: Bool { Self.progressRingEnabled(Self.claudeProgressRingKey, in: defaults) }
    /// The setting the last settings pass applied, so a switch reaches SSH hosts once.
    private var appliedClaudeProgressRing = false
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
    /// Follows the setting and the module outside a source restart, which
    /// applies the switch as part of its own setup.
    private func syncClaudeProgressSwitch() {
        guard !demo, !stopped else { return }
        let home = claudeHome
        guard applyClaudeProgressSwitch(home: home), isModuleEnabled(.claude), !sleeping else { return }
        let generation = claudeGeneration
        launchOwnedWork(.init(.setup, provider: .claude, identifier: "local")) { [weak self] _ in
            await self?.ensureClaudeHooks(home: home, generation: generation)
        }
    }
    @Published var expanded = false
    @Published var pinned = false
    @Published var now = Date()
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
    var onQuit: (() -> Void)?
    var onRelaunch: (() -> String?)?
    var onOpenActivity: ((SessionActivity) async -> ActivityOpenOutcome)?
    /// The expanded task header offers each enabled module's desktop app,
    /// whether or not it has a task. A module without one shows no button.
    static let showsAppButtonsKey = "showAppButtons"
    var showsAppButtons: Bool { defaults.object(forKey: Self.showsAppButtonsKey) == nil || defaults.bool(forKey: Self.showsAppButtonsKey) }
    var appButtonProviders: [AgentProvider] {
        showsAppButtons ? enabledProviders.filter { desktopApplications[$0] != nil } : []
    }
    @Published private(set) var desktopApplications: [AgentProvider: URL] = [:]
    var desktopApplicationResolver: @Sendable (AgentProvider) async -> URL? = { provider in
        await Task.detached(priority: .utility) {
            switch provider {
            case .codex: CodexApplicationResolver.find()
            case .claude: ClaudeApplicationResolver.find()
            case .deepseek: DeepSeekApplicationResolver.find()
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
        guard showsAppButtons, !stopped, force || now.timeIntervalSince(desktopApplicationsScannedAt) >= 60 else { return }
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
        guard appButtonProviders.contains(provider), let application = desktopApplications[provider],
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
        let count = visibleActivities.count, rows = max(1, min(3, count))
        let taskHeight = CGFloat(rows) * 74 + CGFloat(rows - 1) * 2 + (count > 3 ? 26 : 0) + (demo ? 25 : 0)
        let quotaHeight: CGFloat
        if QuotaDashboardLayout.usesLegacyCodexDisplay(providers: enabledProviders, snapshot: providerQuota(.codex), style: expandedQuotaStyle),
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
    private let reader = LocalActivityReader()
    private let realtimeMonitor = RealtimeActivityMonitor()
    private var remoteTask: Task<Void, Never>? { ownedWork.task(.init(.remote, provider: .codex)) }
    private var remoteControlHostIDs: Set<String>?
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
    private var localActivityDirty = false
    private var localActivityNeedsDiscovery = false
    private var watchedLogURLs: [URL] = []
    private lazy var logWatcher = ActivityLogWatcher { [weak self] discover in
        Task { @MainActor in self?.refreshActivity(metricsOnly: !discover) }
    }
    var sleeping: Bool { lifecycle.isSleeping }
    var stopped: Bool { lifecycle.isStopped }
    private(set) var interactionSuspended = false
    private var lastDiscovery = Date.distantPast
    private var sourceGeneration: Int { Int(lifecycle.version(.codex)) }
    private var observations: [NSObjectProtocol] = []
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

    var home: URL {
        let configured = defaults.string(forKey: "codexHome") ?? ""
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    var displayMode: IslandDisplayMode { .load() }
    var islandPosition: IslandPosition { .load(from: defaults) }
    var activityRefreshPolicy: ActivityRefreshPolicy { expanded ? .expanded : .collapsed }
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
    var rateHelp: String { L10n.text(rateIsFresh ? "performance.total_help" : "performance.partial_total_help", rate ?? 0) }
    var monitorsSSH: Bool { defaults.object(forKey: "monitorSSH") == nil || defaults.bool(forKey: "monitorSSH") }
    var monitorsRemoteControl: Bool { defaults.object(forKey: "monitorRemoteControl") == nil || defaults.bool(forKey: "monitorRemoteControl") }
    static let showsClaudeCloudProjectsKey = "showClaudeCloudProjects"
    var showsClaudeCloudProjects: Bool {
        defaults.object(forKey: Self.showsClaudeCloudProjectsKey) == nil || defaults.bool(forKey: Self.showsClaudeCloudProjectsKey)
    }
    static let showsEmbeddedClaudeSessionsKey = "showEmbeddedClaudeSessions"
    static let showsEmbeddedCodexSessionsKey = "showEmbeddedCodexSessions"
    /// Sessions that another app runs through an agent SDK (a Zotero plugin,
    /// for example). Terminal, editor and Desktop sessions always show.
    func showsEmbeddedSessions(for provider: AgentProvider) -> Bool {
        guard provider != .deepseek else { return true }
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
         deepseekMonitor: DeepSeekActivityMonitor = DeepSeekActivityMonitor()) {
        self.defaults = defaults
        self.compactLayout = .load(from: defaults)
        self.claudeMonitor = claudeMonitor
        self.deepseekMonitor = deepseekMonitor
        self.claudeRemoteSetup = claudeRemoteSetup
        self.claudeQuotaReads = claudeQuotaReads ?? ClaudeQuotaReadDependencies()
        self.installationOverride = installation
        self.installation = installation ?? (demo && demoArguments != nil
            ? ProviderInstallationDetection(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true) : .detect())
        self.modules = .load(from: defaults)
        self.appliedClaudeProgressRing = Self.progressRingEnabled(Self.claudeProgressRingKey, in: defaults)
        self.demo = demo
        self.demoClock = demoClock
        self.demoArguments = demoArguments
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/CurrentCycle", isDirectory: true)
        historyStore = QuotaHistoryStore(directory: directory)
        claudeHistoryStore = QuotaHistoryStore(directory: directory.appendingPathComponent("Claude", isDirectory: true))
        enabledProviders = AgentProvider.allCases.filter { modules.enabledProviders(detection: self.installation).contains($0) }
        if let saved = defaults.string(forKey: "selectedQuotaProvider").flatMap(AgentProvider.init(rawValue:)), enabledProviders.contains(saved) {
            selectedProvider = saved
        } else { selectedProvider = enabledProviders.first ?? .codex }
        lifecycle = ApplicationLifecycleCoordinator(demo: demo, configuration: .init(enabled: Set(enabledProviders),
            sources: [.codex: currentCodexSourceSignature, .claude: currentClaudeSourceSignature, .deepseek: currentDeepSeekSourceSignature],
            hasDemoSnapshot: demo && demoArguments != nil))
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
        syncDeepSeekProgressSwitch()
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
    }
    func prepareForSleep() async {
        let plan = lifecycle.prepareForSleep()
        guard plan.actions.contains(.suspendSources) else { return }
        performLifecycle(plan)
        navigation.cancel(); clearNavigationError()
        invalidateWork(invalidateSource: false)
        claudeRefreshing = false
        let balance = cancelDeepSeekBalanceRead(stop: false)
        let deadline = ShutdownDeadline()
        let quota = detachCodexQuota(), claudeQuota = detachClaudeQuota(), cloud = claudeCloudCoordinator
        let claude = claudeMonitor, deepseek = deepseekMonitor, realtime = realtimeMonitor
        await ApplicationLifecycleCoordinator.cleanup([
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claudeQuota?.stop() },
            .cloud: { await cloud?.suspend() }, .claudeActivity: { await claude.shutdown(deadline: deadline) },
            .deepseekActivity: { await deepseek.shutdown() }, .realtime: { await realtime.shutdown(deadline: deadline) },
            .balance: { await balance?.stop() }
        ], deadline: deadline)
    }
    func resumeAfterSleep() {
        let plan = lifecycle.resume()
        guard !plan.actions.isEmpty else { return }
        now = Date(); performLifecycle(plan)
    }
    func setExpanded(_ value: Bool) {
        guard !value || !interactionSuspended else { return }
        closeWork?.cancel()
        guard expanded != value else { return }
        expanded = value
        if !demo, !sleeping, !stopped {
            logWatcher.update(watchedLogURLs, interval: activityRefreshPolicy.interval, flushPending: value)
            let generation = sourceGeneration
            launchOwnedWork(.init(.presentation, identifier: "activity-policy")) { [weak self] ticket in
                guard let self, generation == self.sourceGeneration, self.lifecycle.owns(ticket) else { return }
                await self.realtimeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
                guard self.lifecycle.owns(ticket) else { return }
                await self.claudeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
                guard self.lifecycle.owns(ticket) else { return }
                await self.claudeCloudCoordinator?.setExpanded(self.expanded)
                guard self.lifecycle.owns(ticket) else { return }
                await self.deepseekMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
            }
            if value { refreshActivity(metricsOnly: true) }
        }
        if clock != nil { scheduleClock() }
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
    func close() { pinned = false; setExpanded(false) }
    private func navigationScope(for activity: SessionActivity) -> String? {
        activity.claudeCloud == nil ? nil : claudeCloudNavigationScope
    }
    private func acceptsNavigation(_ activity: SessionActivity) -> Bool {
        !stopped && !sleeping && (isModuleEnabled(activity.provider) || demo)
    }
    func open(_ activity: SessionActivity) {
        guard canOpen(activity), let target = conversationTarget(for: activity), let open = onOpenActivity,
              let operation = navigation.begin(activity: activity, target: target, version: UInt64(sourceGeneration(for: activity.provider)),
                activities: activities, inbox: completionInbox, active: acceptsNavigation(activity), scope: navigationScope(for: activity)) else { return }
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
                scope: self.navigationScope(for: activity), now: self.navigationClock(), errorDuration: self.navigationErrorDuration), result.accepted else { return }
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
    func trackHostApplications(for provider: AgentProvider, now: Date = Date(), refreshRunning: Bool = true) {
        let decision = hostTracking.prepare(provider: provider, references: knownActivities(for: provider), activities: activities, inbox: completionInbox,
            remoteSourceIDs: Set(claudeRemoteTargets.map(\.id)), version: UInt64(sourceGeneration(for: provider)), now: now,
            active: !stopped && !sleeping, demo: demo, refreshRunning: refreshRunning)
        publishHostApplications(layout: false)
        switch decision {
        case .idle: break
        case .retry(let retry):
            let owner = ownedWork.begin(.init(.hostRetry, provider: provider), version: retry.version)
            let task = Task { [weak self] in
                defer { if let self { self.ownedWork.finish(owner) } }
                do { try await Task.sleep(nanoseconds: UInt64(max(0, retry.delay) * 1_000_000_000)) } catch { return }
                guard let self, self.hostTracking.finishRetry(retry, version: UInt64(self.sourceGeneration(for: provider)),
                    active: !self.stopped && !self.sleeping, cancelled: Task.isCancelled) else { return }
                self.ownedWork.finish(owner); self.trackHostApplications(for: provider)
            }
            ownedWork.attach(task, to: owner)
        case .scan(let scan):
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
                self.publishHostApplications(); self.trackHostApplications(for: provider, refreshRunning: false)
            }
            ownedWork.attach(task, to: owner)
        }
    }
    func sourceGeneration(for provider: AgentProvider) -> Int {
        switch provider {
        case .codex: sourceGeneration
        case .claude: claudeGeneration
        case .deepseek: deepseekGeneration
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
        guard ProviderQuotaRefreshPolicy.isDue(lastAttempt: codexQuotaState?.lastAttempt, expanded: expanded,
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
            await coordinator.refreshIfDue(expanded: self.expanded, force: force)
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
        }
        onStatusChange?()
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
        guard ProviderQuotaRefreshPolicy.isDue(lastAttempt: claudeQuotaState?.lastAttempt, expanded: expanded,
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
            _ = await coordinator.refreshIfDue(expanded: self.expanded, force: force)
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
        let generation = claudeGeneration, expanded = expanded
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
        now = Date(); claudeReceivedActivities = values.filter { !excluded.contains($0.id) }; claudeStreamStatuses = statuses
        claudeReceivedRequests = requests
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
        refreshActivity()
        launchOwnedWork(.init(.discovery, identifier: "manual")) { [weak self] ticket in
            guard let self, self.lifecycle.owns(ticket) else { return }
            await self.realtimeMonitor.invalidateRemoteControlCatalog()
            guard self.lifecycle.owns(ticket) else { return }
            self.refreshRemote()
            await self.claudeCloudCoordinator?.refresh()
        }
        discoverClaudeRemoteTargets(refresh: true)
    }
    func refreshActivity(metricsOnly: Bool = false) {
        guard isModuleEnabled(.codex), !sleeping, !stopped, !demo else { return }
        if !metricsOnly { localActivityNeedsDiscovery = true }
        guard localTask == nil else { localActivityDirty = true; return }
        localActivityDirty = false
        let onlyMetrics = !localActivityNeedsDiscovery
        localActivityNeedsDiscovery = false
        if !onlyMetrics { lastDiscovery = Date() }
        let generation = sourceGeneration
        let sourceHome = home
        let covered = streamStatuses["local"]?.connected == true ? Set(remoteActivities.filter {
            $0.sourceHostID == nil && $0.hasLiveEvidence && [.running, .waitingForInput].contains($0.phase)
        }.compactMap(\.threadID)) : []
        let agentStates = localSubagentStates(remoteActivities)
        launchOwnedWork(.init(.activity, provider: .codex)) { [weak self, reader] workTicket in
            let result = await reader.read(home: sourceHome, phaseAwareRate: true, excludingThreads: covered, includeCoveredMetrics: true, metricsOnly: onlyMetrics, subagentStates: agentStates)
            guard let self else { return }
            defer {
                if generation == self.sourceGeneration {
                    self.ownedWork.finish(workTicket)
                    if self.localActivityDirty { self.refreshActivity(metricsOnly: !self.localActivityNeedsDiscovery) }
                }
            }
            guard !Task.isCancelled, generation == self.sourceGeneration else { return }
            if !onlyMetrics {
                self.watchedLogURLs = result.watchURLs
                self.logWatcher.update(result.watchURLs, interval: self.activityRefreshPolicy.interval)
            }
            self.receiveLocalUpdate(result.activities, requests: result.requests, excludedIDs: result.excludedIDs)
            self.onStatusChange?()
        }
    }

    func receiveLocalUpdate(_ values: [SessionActivity], requests: [PendingAttentionRequest], excludedIDs: Set<String> = []) {
        now = Date(); localActivities = values; codexLogRequests = requests; excludedCodexActivityIDs = excludedIDs
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
            await self.realtimeMonitor.startAsync(home: sourceHome, includeSSH: self.monitorsSSH, includeRemoteControl: self.monitorsRemoteControl, refreshPolicy: self.activityRefreshPolicy) { [weak self] snapshot in
                // The monitor publishes serially. Keep that order on the UI
                // queue so a later empty snapshot cannot overtake an ending.
                DispatchQueue.main.async {
                    guard let self, generation == self.sourceGeneration, !self.stopped, !self.sleeping else { return }
                    self.receiveRemoteUpdate(snapshot.activities, statuses: snapshot.statuses, unavailable: snapshot.unavailable,
                        requests: snapshot.attention, names: snapshot.names, performance: snapshot.performance,
                        remoteControlBindings: snapshot.bindings, durableAccountScope: snapshot.durableAccountScope)
                }
            }
            // A hover/collapse can occur while start is awaiting the monitor.
            await self.realtimeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
        }
    }

    func receiveRemoteUpdate(_ activities: [SessionActivity], statuses: [String: RuntimeStreamStatus],
                             unavailable: [String], requests: [PendingAttentionRequest], names: [SessionNameUpdate], performance: [SessionPerformanceUpdate] = [],
                             remoteControlBindings: RemoteControlSourceBindings? = nil, durableAccountScope: String? = nil) {
        if self.durableAccountScope != durableAccountScope {
            self.durableAccountScope = durableAccountScope
            bindCompletionSources(.codex)
        }
        if let bindings = remoteControlBindings {
            let previous = remoteControlHostIDs ?? Set(RemoteControlActivityTarget.configured(home: home).map(\.id))
            let hosts = bindings.authoritative ? bindings.hostIDs : previous.union(bindings.hostIDs)
            if remoteControlHostIDs != hosts {
                remoteControlHostIDs = hosts
                bindCompletionSources(.codex)
            }
        }
        let oldLocal = Set(remoteActivities.filter { $0.sourceHostID == nil }.map { $0.id + ":" + ($0.turnID ?? "") })
        let newLocal = Set(activities.filter { $0.sourceHostID == nil }.map { $0.id + ":" + ($0.turnID ?? "") })
        let agentStatesChanged = localSubagentStates(remoteActivities) != localSubagentStates(activities)
        now = Date(); remoteActivities = activities
        let hidden = hiddenEmbeddedActivityIDs, ignored = ignoredCodexActivityIDs
        for update in performance where !hidden.contains(update.id) {
            rememberFirstOutput(update.firstTokenLatency, reportedAt: update.firstTokenReportedAt)
        }
        completionInbox.updateNames(names.filter { !ignored.contains($0.id) })
        completionInbox.updatePerformance(performance.filter { !ignored.contains($0.id) })
        if streamStatuses != statuses { streamStatuses = statuses }
        if unavailableSSH != unavailable { unavailableSSH = unavailable }
        codexReceivedRequests = requests
        refilterEmbeddedSessions()
        if oldLocal != newLocal { refreshActivity() }
        else if agentStatesChanged { refreshActivity(metricsOnly: true) }
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
    private func combineActivities() {
        let oldHeight = panelContentHeight
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
        home.path + "|" + (defaults.string(forKey: "codexExecutable") ?? "") + "|" + String(monitorsSSH) + "|" + String(monitorsRemoteControl)
    }
    private var currentClaudeSourceSignature: String {
        claudeHome.path + "|" + String(monitorsSSH) + (monitorsSSH
            ? "|" + home.path : "")
    }
    func applySettings(sourceChanged: Bool) {
        installation = installationOverride ?? (demo && demoArguments != nil
            ? ProviderInstallationDetection(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true) : .detect())
        modules = .load(from: defaults)
        PacerAccent.current = PacerAccent(defaults: defaults)
        // Light Liquid Glass turns the whole island light before it redraws.
        syncTone()
        enabledProviders = AgentProvider.allCases.filter { modules.enabledProviders(detection: self.installation).contains($0) }
        syncCodexProgressSwitch()
        syncDeepSeekProgressSwitch()
        if !enabledProviders.contains(selectedProvider) { selectedProvider = enabledProviders.first ?? .codex }
        // The header reports its width only when it changes, so the last measurement
        // stays: clearing it would leave the bar at the wider estimate after any setting.
        compactLayout = .load(from: defaults); settingsRevision += 1
        // A place chosen in Settings belongs to the display the island is on.
        rememberDisplayPlace()
        if clock != nil { scheduleClock() }
        let plan = lifecycle.settings(.init(enabled: Set(enabledProviders),
            sources: [.codex: currentCodexSourceSignature, .claude: currentClaudeSourceSignature, .deepseek: currentDeepSeekSourceSignature],
            hasDemoSnapshot: demo && demoArguments != nil), explicitlyDisablesClaude: modules.claudeMode == .disabled)
        for provider in plan.changedProviders { navigation.cancel(provider: provider) }
        performLifecycle(plan)
        // A restarted Claude source applies the ring's switch as part of its setup.
        if !plan.changedProviders.contains(.claude) || !isModuleEnabled(.claude) { syncClaudeProgressSwitch() }
        if appliedClaudeProgressRing != showsClaudeProgressRing {
            appliedClaudeProgressRing = showsClaudeProgressRing
            scheduleClaudeRemoteSetup()
        }
        onLayoutChange?(); onStatusChange?()
    }
    private func resetCodexSource(versionInvalidated: Bool = false) {
        cancelHostTracking(for: .codex, clearApplications: true)
        excludedCodexActivityIDs = []; codexReceivedRequests = []; codexLogRequests = []
        logWatcher.stop(); invalidateWork(invalidateSource: !versionInvalidated)
        let previous = detachCodexQuota(preservingCadence: false)
        codexQuota = nil; codexHistory = QuotaCycleHistory(); codexHistoryWarning = nil; codexErrorMessage = nil
        quotaCLI = nil; attention = AttentionPolicy()
        completionInbox.remove(provider: .codex)
        remoteControlHostIDs = nil
        durableAccountScope = nil
        bindCompletionSources(.codex)
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
            let realtime = self.realtimeMonitor
            await ApplicationLifecycleCoordinator.cleanup([
                .codexQuota: { await previous?.stop() },
                .realtime: { if current { await realtime.shutdown(deadline: deadline) } },
                .reader: { if current { await reader.reset() } }
            ], deadline: deadline)
            guard generation == self.sourceGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
            self.refreshCodexQuota(); self.refreshActivity(); self.refreshRemote()
        }
    }
    private func resetClaudeSource(versionInvalidated: Bool = false) {
        if !versionInvalidated { lifecycle.invalidateSources([.claude]) }
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
            let monitor = self.claudeMonitor
            await ApplicationLifecycleCoordinator.cleanup([
                .claudeQuota: { await previous?.stop() }, .claudeActivity: { if current { await monitor.shutdown(deadline: deadline) } }
            ], deadline: deadline)
            guard generation == self.claudeGeneration, !self.sleeping, !self.stopped, !Task.isCancelled else { return }
            self.refreshClaudeQuota(); self.startClaudeActivity()
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
        let controls = provider == .codex && isModuleEnabled(.codex) && monitorsRemoteControl
            ? remoteControlHostIDs ?? Set(RemoteControlActivityTarget.configured(home: home).map(\.id)) : []
        completionInbox.bindSourceHomes(provider: provider, localHome: provider == .codex ? home : claudeHome,
            remoteHomes: remoteHomes, remoteControlHostIDs: controls,
            durableAccountScope: provider == .codex ? durableAccountScope : nil)
    }

    func shutdown() async {
        // A saved opt-out also takes effect if the settings view has not yet
        // applied its pending changes.
        if codexProgressQueue.target?.enabled == true, !showsCodexProgressRing { syncCodexProgressSwitch() }
        if deepseekProgressQueue.target?.enabled == true, !showsDeepSeekProgressRing { syncDeepSeekProgressSwitch() }
        let plan = lifecycle.shutdown()
        guard plan.actions.contains(.stopSources) else { return }
        desktopApplicationScan?.cancel()
        clock?.invalidate(); closeWork?.cancel()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        performLifecycle(plan)
        navigation.cancel(); clearNavigationError()
        invalidateWork(invalidateSource: false)
        let balance = cancelDeepSeekBalanceRead(stop: false)
        let deadline = ShutdownDeadline()
        let quota = detachCodexQuota(), claudeQuota = detachClaudeQuota(), cloud = claudeCloudCoordinator
        let claude = claudeMonitor, deepseek = deepseekMonitor, setup = claudeRemoteSetup, realtime = realtimeMonitor
        let progressFlag = codexProgressFlagTask, deepseekProgress = deepseekProgressTask
        let completed = await ApplicationLifecycleCoordinator.cleanup([
            .codexProgressFlag: { _ = await progressFlag?.value },
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claudeQuota?.stop() },
            .cloud: { await cloud?.stop() }, .claudeActivity: { await claude.shutdown(deadline: deadline) },
            // Removing DeepSeek's reporter entry is local file work that takes milliseconds.
            .deepseekActivity: { await deepseekProgress?.value; await deepseek.shutdown() }, .remoteSetup: { await setup.shutdown() },
            .realtime: { await realtime.shutdown(deadline: deadline) }, .balance: { await balance?.stop() }
        ], deadline: deadline)
        if !completed { OwnedProcessTermination.terminateAll() }
    }

    private func invalidateWork(invalidateSource: Bool = true) {
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
    private func scheduleClock() {
        clock?.invalidate()
        let interval: TimeInterval = !expanded ? 30 : 2
        clock = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        clock?.tolerance = interval * 0.2
    }
    private func scheduleRateExpiry() {
        let deadline = activityState.nextDisplayDeadline(at: now, retention: completedRetention, progressRingProviders: progressRingProviders)
        guard deadline != rateExpiryAt else { return }
        rateExpiryWork?.cancel(); rateExpiryWork = nil; rateExpiryAt = nil
        guard !sleeping, !stopped, let deadline else { return }
        rateExpiryAt = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sleeping, !self.stopped else { return }
            self.rateExpiryWork = nil; self.rateExpiryAt = nil
            self.now = Date()
            self.pruneCompletions()
            self.scheduleRateExpiry()
            self.onStatusChange?()
        }
        rateExpiryWork = work
        // One UI-only wake-up at the earliest expiry; no quota, log or SSH work.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow) + 0.01, execute: work)
    }
    private func tick() {
        now = Date()
        performLifecycle(lifecycle.tick(.init(now: now, expanded: expanded, codexConnected: streamStatuses["local"]?.connected == true,
            lastCodexDiscovery: lastDiscovery, lastRemoteDiscovery: lastRemoteDiscovery, lastClaudeDiscovery: lastClaudeDiscovery,
            deepseekRunning: running.contains { $0.provider == .deepseek })))
        if !sleeping, !stopped, !demo { onStatusChange?() }
    }
    private func performLifecycle(_ plan: ApplicationLifecycleCoordinator.Plan) {
        for action in plan.actions {
            switch action {
            case .quota(let provider, let force, let active):
                switch provider {
                case .codex: refreshCodexQuota(force: force)
                case .claude: refreshClaudeQuota(force: force)
                case .deepseek: refreshDeepSeekBalance(scheduled: !force, active: active)
                }
            case .codexActivity: refreshActivity()
            case .remoteActivity: refreshRemote()
            case .activity(let provider):
                if provider == .claude { startClaudeActivity() }
                else if provider == .deepseek { startDeepSeekActivity() }
            case .claudeTargets: discoverClaudeRemoteTargets()
            case .applications: refreshDesktopApplications()
            case .clock: scheduleClock()
            case .displayExpiry: scheduleRateExpiry()
            case .pruneActivities: pruneCompletions()
            case .pruneHistory: codexHistory.prune(at: now); claudeHistory.prune(at: now)
            case .resetSource(let provider):
                switch provider {
                case .codex: resetCodexSource(versionInvalidated: true)
                case .claude: resetClaudeSource(versionInvalidated: true)
                case .deepseek: resetDeepSeekSource(versionInvalidated: true)
                }
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
            case .cancelRemoteSetup: cancelClaudeRemoteSetup()
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
        now = demoClock()
        for snapshot in DemoScenario.quota(.codex, at: now) { codexHistory.record(snapshot); codexQuota = snapshot }
        for snapshot in DemoScenario.quota(.claude, at: now) { claudeHistory.record(snapshot); claudeQuota = snapshot }
        makeDeepSeekDemo()
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
        now = demoClock()
        let demoArguments = demoArguments ?? []
        var observed = demoArguments.contains("--demo-subagents") ? DemoScenario.subagentTasks(stage: stage, at: now) : DemoScenario.tasks(stage: stage, at: now)
        if demoArguments.contains("--demo-claude") { observed.append(DemoScenario.claudeTask(stage: stage, at: now)) }
        if demoArguments.contains("--demo-deepseek") { observed.append(DemoScenario.deepseekTask(stage: stage, at: now)) }
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
