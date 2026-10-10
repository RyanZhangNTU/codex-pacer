import AppKit
import SwiftUI
import PacerCore

enum QuotaDashboardPeriod: String, CaseIterable, Identifiable, Sendable {
    case fiveHour = "5h", weekly = "7d"
    var id: String { rawValue }
    var durationMinutes: Int { self == .fiveHour ? 300 : 10080 }
    var label: String { self == .fiveHour ? L10n.text("quota.compact_hours", 5) : L10n.text("quota.compact_days", 7) }
}

struct QuotaDashboardQuota: Equatable, Sendable {
    enum Availability: Equatable, Sendable { case available, stale, unavailable, missingPeriod, proOnly }
    let provider: AgentProvider
    let period: QuotaDashboardPeriod
    let window: QuotaWindow?
    let availability: Availability
    let remainingQuotaPercent: Double?
    let remainingTimePercent: Double?
    let capturedAt: Date?
    let freshnessText: String
    let sourceText: String?
    let bucketName: String?
}

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
            cachedTaskGroups = nil; cachedOverview = nil
            observeFirstOutputs(activities); scheduleRateExpiry()
        }
    }
    private var cachedTaskGroups: [ActivityTaskGroup]?
    private var cachedOverview: (at: Date, value: ActivityOverview)?
    private(set) var taskGroupingComputations = 0
    @Published private(set) var latestFirstOutputLatency: TimeInterval?
    private var latestFirstOutputAt: Date?
    @Published var streamStatuses: [String: RuntimeStreamStatus] = [:]
    @Published var unavailableSSH: [String] = []
    @Published var navigationError: String?
    @Published private(set) var attentionRequests: [PendingAttentionRequest] = []
    private var localActivities: [SessionActivity] = []
    private var remoteActivities: [SessionActivity] = []
    @Published private var codexHistory = QuotaCycleHistory()
    @Published private var codexHistoryWarning: String?
    @Published var notice: IslandNotice?
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
    @Published private(set) var selectedProvider: AgentProvider = .codex
    @Published private(set) var enabledProviders: [AgentProvider] = []
    @Published private(set) var dashboardPeriod: QuotaDashboardPeriod = .weekly
    private var installation: ProviderInstallationDetection
    private let installationOverride: ProviderInstallationDetection?
    private let defaults: UserDefaults
    private var modules = ProviderModules()
    private var codexSourceSignature = ""
    private var claudeSourceSignature = ""
    var quota: QuotaSnapshot? {
        get { providerQuota(selectedProvider) }
        set { if selectedProvider == .codex { codexQuota = newValue } else { claudeQuota = newValue }; onLayoutChange?() }
    }
    var history: QuotaCycleHistory {
        get { selectedProvider == .codex ? codexHistory : claudeHistory }
        set { if selectedProvider == .codex { codexHistory = newValue } else { claudeHistory = newValue } }
    }
    var historyWarning: String? {
        get { selectedProvider == .codex ? codexHistoryWarning : claudeHistoryWarning }
        set { if selectedProvider == .codex { codexHistoryWarning = newValue } else { claudeHistoryWarning = newValue } }
    }
    var errorMessage: String? {
        get { providerQuotaError(selectedProvider) }
        set { if selectedProvider == .codex { codexErrorMessage = newValue } else { claudeErrorMessage = newValue } }
    }
    var refreshing: Bool { selectedProvider == .codex ? codexRefreshing : claudeRefreshing }
    func isModuleEnabled(_ provider: AgentProvider) -> Bool { enabledProviders.contains(provider) }
    func providerDetected(_ provider: AgentProvider) -> Bool { installation.isInstalled(provider) }
    func providerRefreshing(_ provider: AgentProvider) -> Bool { provider == .codex ? codexRefreshing : claudeRefreshing }
    func providerStreamStatuses(_ provider: AgentProvider) -> [String: RuntimeStreamStatus] {
        provider == .codex ? streamStatuses : claudeStreamStatuses
    }
    func providerQuota(_ provider: AgentProvider) -> QuotaSnapshot? { provider == .codex ? codexQuota : claudeQuota }
    func providerQuotaError(_ provider: AgentProvider) -> String? { provider == .codex ? codexErrorMessage : claudeErrorMessage }
    func selectDashboardPeriod(_ period: QuotaDashboardPeriod) {
        guard dashboardPeriod != period else { return }
        dashboardPeriod = period
        defaults.set(period.rawValue, forKey: "quotaDashboardPeriod")
        onStatusChange?()
    }
    private func providerDashboardBucket(_ provider: AgentProvider) -> QuotaBucket? {
        guard let snapshot = providerQuota(provider) else { return nil }
        let selected = defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID") ?? "auto"
        if let bucket = snapshot.buckets.first(where: { $0.windows.contains(where: { $0.id == selected }) }) { return bucket }
        return snapshot.buckets.first(where: { $0.id == provider.rawValue }) ?? snapshot.buckets.first
    }
    func providerWindow(_ provider: AgentProvider, period: QuotaDashboardPeriod) -> QuotaWindow? {
        providerDashboardBucket(provider)?.windows.first { $0.durationMinutes == period.durationMinutes }
    }
    func providerHistory(_ provider: AgentProvider) -> QuotaCycleHistory { provider == .codex ? codexHistory : claudeHistory }
    func providerHistoryWarning(_ provider: AgentProvider) -> String? { provider == .codex ? codexHistoryWarning : claudeHistoryWarning }
    func providerCurrentCycle(_ provider: AgentProvider) -> QuotaCycle? {
        providerHistory(provider).currentCycle(for: providerWindow(provider, period: .weekly), at: now)
    }
    func providerSourceText(_ provider: AgentProvider) -> String? {
        provider == .claude ? claudeQuotaSource?.label : (providerQuota(provider) == nil ? nil : L10n.text("quota.source_codex"))
    }
    func providerQuotaIsStale(_ provider: AgentProvider, period: QuotaDashboardPeriod? = nil) -> Bool {
        guard let snapshot = providerQuota(provider) else { return false }
        let window = period.map { providerWindow(provider, period: $0) } ?? providerSelectedWindow(provider)
        return snapshot.isStale(at: now) || (window?.resetsAt.map { $0 <= now } ?? false)
    }
    func providerFreshnessText(_ provider: AgentProvider, period: QuotaDashboardPeriod? = nil) -> String {
        guard let snapshot = providerQuota(provider) else {
            return providerRefreshing(provider) ? L10n.text("quota.reading") : L10n.text("quota.not_read")
        }
        let window = period.map { providerWindow(provider, period: $0) } ?? providerSelectedWindow(provider)
        if window?.resetsAt.map({ $0 <= now }) == true { return L10n.text("quota.expired") }
        let elapsed = max(0, Int(now.timeIntervalSince(snapshot.capturedAt)))
        if providerQuotaIsStale(provider, period: period) || providerQuotaError(provider) != nil {
            return L10n.text("quota.age", max(1, elapsed / 60))
        }
        return elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60)
    }
    func dashboardQuota(provider: AgentProvider, period: QuotaDashboardPeriod) -> QuotaDashboardQuota {
        let snapshot = providerQuota(provider), bucket = providerDashboardBucket(provider)
        let window = providerWindow(provider, period: period)
        let stale = providerQuotaIsStale(provider, period: period) || providerQuotaError(provider) != nil
        let availability: QuotaDashboardQuota.Availability
        if snapshot == nil || bucket == nil { availability = .unavailable }
        else if stale { availability = .stale }
        else if window != nil { availability = .available }
        else if period == .fiveHour, bucket?.id == provider.rawValue,
                let weekly = bucket?.windows.first(where: { $0.durationMinutes == 10080 }),
                weekly.remainingPercent != nil, weekly.resetsAt.map({ $0 > now }) == true,
                bucket?.windows.allSatisfy({ $0.durationMinutes == 10080 }) == true {
            // Missing model-specific or untyped windows do not establish a plan restriction.
            availability = .proOnly
        } else { availability = .missingPeriod }
        return QuotaDashboardQuota(provider: provider, period: period, window: window, availability: availability,
            remainingQuotaPercent: window?.remainingPercent, remainingTimePercent: window?.remainingTimePercent(at: now),
            capturedAt: snapshot?.capturedAt, freshnessText: providerFreshnessText(provider, period: period),
            sourceText: providerSourceText(provider), bucketName: bucket.flatMap { $0.id == provider.rawValue ? nil : ($0.name ?? $0.id) })
    }
    func selectProvider(_ provider: AgentProvider) {
        guard enabledProviders.contains(provider), selectedProvider != provider else { return }
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: "selectedQuotaProvider")
        onLayoutChange?(); onStatusChange?()
    }
    func providerSelectedWindow(_ provider: AgentProvider) -> QuotaWindow? {
        let selected = defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID") ?? "auto"
        let snapshot = providerQuota(provider)
        if let window = snapshot?.windows.first(where: { $0.id == selected }) { return window }
        return providerWeeklyWindow(provider) ?? snapshot?.limitingWindow
    }
    private func providerWeeklyWindow(_ provider: AgentProvider) -> QuotaWindow? {
        let selected = defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID") ?? "auto"
        let snapshot = providerQuota(provider)
        if let bucket = snapshot?.buckets.first(where: { $0.windows.contains(where: { $0.id == selected }) }),
           let weekly = bucket.windows.first(where: { $0.durationMinutes == 10080 }) { return weekly }
        return snapshot?.buckets.first(where: { $0.id == provider.rawValue })?.windows.first(where: { $0.durationMinutes == 10080 }) ??
            snapshot?.windows.first(where: { $0.durationMinutes == 10080 })
    }
    func providerPace(_ provider: AgentProvider) -> Double? {
        guard let snapshot = providerQuota(provider), !snapshot.isStale(at: now), providerQuotaError(provider) == nil else { return nil }
        return providerSelectedWindow(provider)?.pacePercent(at: now)
    }
    var claudeHome: URL {
        let configured = defaults.string(forKey: "claudeHome") ?? ""
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    var claudeMonitoringConfigured: Bool { ClaudeHookInstaller.status(home: claudeHome) }
    func configureClaudeMonitoring() async -> String? {
        do {
            try ClaudeHookInstaller.install(home: claudeHome)
            settingsRevision += 1
            startClaudeActivity()
            return nil
        } catch { return L10n.text("claude.monitoring_setup_failed") }
    }
    func removeClaudeMonitoring() async -> String? {
        do { try ClaudeHookInstaller.uninstall(home: claudeHome); settingsRevision += 1; return nil }
        catch { return L10n.text("claude.monitoring_remove_failed") }
    }
    @Published var expanded = false
    @Published var pinned = false
    @Published var now = Date()
    @Published var settingsRevision = 0
    @Published var isAttached = false
    @Published var notchWidth: CGFloat = 0
    @Published var topHeight: CGFloat = 38
    @Published var baseHeaderHeight: CGFloat = 38
    var onLayoutChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRelaunch: (() -> String?)?
    var onOpenActivity: ((SessionActivity) async -> ActivityOpenOutcome)?
    private var openingActivities: Set<String> = []
    var onFocusRequested: (() -> Void)?
    private func conversationTarget(for activity: SessionActivity) -> SessionActivity? {
        guard activity.provider == .claude, let parent = activity.parentThreadID else { return activity }
        guard !activity.isInternalReview, activity.turnID != nil, activity.turnStartedAt != nil,
              activity.sourceHostID.map({ host in claudeRemoteTargets.contains { $0.id == host } }) ?? true else { return nil }
        let source = completionInbox.sourceToken(for: activity)
        var parentSession = parent, seen: Set<String> = [activity.canonicalized().id]
        for _ in 0..<64 {
            let id = AgentProvider.claude.activityID(sessionID: parentSession, sourceHostID: activity.sourceHostID)
            guard seen.insert(id).inserted else { return nil }
            if let observed = activities.first(where: {
                $0.canonicalized().id == id && $0.provider == activity.provider && $0.sourceHostID == activity.sourceHostID
            }) {
                guard !observed.isInternalReview, completionInbox.sourceToken(for: observed) == source else { return nil }
                if let ancestor = observed.parentThreadID {
                    guard observed.turnID != nil, observed.turnStartedAt != nil else { return nil }
                    parentSession = ancestor
                    continue
                }
                return observed.threadID.flatMap(UUID.init(uuidString:)) == nil ? nil : observed
            }
            guard let uuid = UUID(uuidString: parentSession) else { return nil }
            let session = uuid.uuidString.lowercased()
            // An observed parent UUID is routing evidence; a child's directory
            // does not establish the parent's directory or continuation ID.
            return SessionActivity(id: AgentProvider.claude.activityID(sessionID: session, sourceHostID: activity.sourceHostID),
                project: activity.project, sourceHost: activity.sourceHost, sourceHostID: activity.sourceHostID, provider: .claude, sessionID: session)
        }
        return nil
    }
    func canOpen(_ activity: SessionActivity) -> Bool {
        if activity.provider == .claude {
            guard let target = conversationTarget(for: activity) else { return false }
            return demo || (target.threadURL != nil && ClaudeApplicationResolver.find() != nil) ||
                (target.threadID.flatMap(UUID.init(uuidString:)) != nil && (target.sourceHostID != nil || ClaudeApplicationResolver.findExecutable() != nil))
        }
        return (demo || activity.threadURL != nil) && (demo || activity.sourceHostID != nil ||
            home.path == URL(fileURLWithPath: NSHomeDirectory() + "/.codex").standardizedFileURL.path)
    }
    private var measuredContentHeight: CGFloat?
    private(set) var measuredContentWidth: CGFloat = 0
    private(set) var measuredCompactWidth: CGFloat = 0
    var widthSettings: IslandWidthSettings { .load() }
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
        if QuotaDashboardLayout.usesLegacyCodexDisplay(providers: enabledProviders, snapshot: providerQuota(.codex)),
           let snapshot = providerQuota(.codex) {
            let headers = snapshot.buckets.count > 1 ? snapshot.buckets.count : 0
            quotaHeight = 286 + CGFloat(snapshot.windows.count) * 92 + CGFloat(headers) * 20
        } else { quotaHeight = 348 }
        return min(640, max(424, quotaHeight + taskHeight))
    }
    func updateMeasuredContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let rounded = ceil(height)
        guard measuredContentHeight.map({ abs($0 - rounded) >= 1 }) ?? true else { return }
        measuredContentHeight = rounded
        onLayoutChange?()
    }
    private var client: CodexClient?
    private let reader = LocalActivityReader()
    private let realtimeMonitor = RealtimeActivityMonitor()
    private var remoteTask: Task<Void, Never>?
    private var lastRemoteDiscovery = Date.distantPast
    private let historyStore: QuotaHistoryStore
    private let claudeHistoryStore: QuotaHistoryStore
    private let claudeMonitor = ClaudeActivityMonitor()
    private let claudeRemoteSetup = ClaudeRemoteSetup()
    @Published private(set) var claudeRemoteTargets: [RemoteActivityTarget] = []
    @Published private(set) var configuringClaudeHosts: Set<String> = []
    @Published private(set) var claudeRemoteSetupStatus: [String: ClaudeHookInstaller.Status] = [:]
    func configureClaudeRemote(targetID: String) async -> String? {
        guard let target = claudeRemoteTargets.first(where: { $0.id == targetID }), configuringClaudeHosts.insert(targetID).inserted else { return nil }
        defer { configuringClaudeHosts.remove(targetID) }
        do {
            let status = try await claudeRemoteSetup.install(target: target)
            claudeRemoteSetupStatus[targetID] = status
            return nil
        } catch { return L10n.text("provider.remote_configure_failed") }
    }
    private var claudeClient: ClaudeQuotaClient?
    private var claudeWebClient: ClaudeWebQuotaClient?
    private let claudeQuotaReads: ClaudeQuotaReadDependencies
    var onClaudeLogin: (() -> Void)?
    var onClaudeOrganizationSelection: (([ClaudeWebOrganization]) -> Void)?
    private var claudeOrganizationChoices: [ClaudeWebOrganization] = []
    private var claudeQuotaRestartTask: Task<Void, Never>?
    private var claudeQuotaTask: Task<Void, Never>?
    private var claudeActivityTask: Task<Void, Never>?
    private var claudeGeneration = 0
    private var claudeActivities: [SessionActivity] = []
    private var claudeAttentionRequests: [PendingAttentionRequest] = []
    private var codexAttentionRequests: [PendingAttentionRequest] = []
    private var claudeStreamStatuses: [String: RuntimeStreamStatus] = [:]
    private var claudeQuotaAttention = AttentionPolicy()
    private var claudeActivityAttention = AttentionPolicy()
    private var lastClaudeQuotaAttempt = Date.distantPast
    private var lastClaudeDiscovery = Date.distantPast
    private var claudeFailureCount = 0
    private let notifications = NotificationDelivery()
    private var attention = AttentionPolicy()
    private var completionInbox = CompletionInbox()
    private var clock: Timer?
    private var refreshTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var closeWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var rateExpiryWork: DispatchWorkItem?
    private var rateExpiryAt: Date?
    private var localActivityDirty = false
    private var localActivityNeedsDiscovery = false
    private var watchedLogURLs: [URL] = []
    private lazy var logWatcher = ActivityLogWatcher { [weak self] discover in
        Task { @MainActor in self?.refreshActivity(metricsOnly: !discover) }
    }
    private var sleeping = false
    private var stopped = false
    private(set) var interactionSuspended = false
    private var lastQuotaAttempt = Date.distantPast
    private var lastDiscovery = Date.distantPast
    private var failureCount = 0
    private var sourceGeneration = 0
    private var observations: [NSObjectProtocol] = []
    private let demo: Bool
    private let demoClock: () -> Date
    var isDemo: Bool { demo }

    var home: URL {
        let configured = defaults.string(forKey: "codexHome") ?? ""
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    var displayMode: IslandDisplayMode { .load() }
    var activityRefreshPolicy: ActivityRefreshPolicy { expanded ? .expanded : .collapsed }
    var appearance: IslandAppearance { .stored }
    var showInFullscreen: Bool { defaults.bool(forKey: "showInFullscreen") }
    var showInMenuBar: Bool { defaults.bool(forKey: "showInMenuBar") }
    var hideProjects: Bool { defaults.bool(forKey: "hideProjects") }
    var displayID: Int { defaults.integer(forKey: "displayID") }
    var taskGroups: [ActivityTaskGroup] {
        if let cachedTaskGroups { return cachedTaskGroups }
        let groups = ActivityTaskGroup.make(activities)
        cachedTaskGroups = groups; taskGroupingComputations += 1
        return groups
    }
    func taskGroup(for activity: SessionActivity) -> ActivityTaskGroup? { taskGroups.first { $0.primary.id == activity.canonicalized().id } }
    var overview: ActivityOverview {
        if let cachedOverview, cachedOverview.at == now { return cachedOverview.value }
        let value = ActivityOverview(groups: taskGroups, at: now)
        cachedOverview = (now, value)
        return value
    }
    var running: [SessionActivity] { overview.running }
    var waiting: [SessionActivity] { overview.waiting }
    var visibleActivities: [SessionActivity] {
        let groups = taskGroups
        var displayed = groups.filter {
            $0.isRunning || $0.isWaiting || [.completed, .interrupted].contains($0.primary.phase) ||
                now.timeIntervalSince($0.primary.lastObserved ?? .distantPast) < 900
        }.map(\.primary)
        let known = Set(groups.flatMap { $0.members.map(\.id) })
        var ids = Set(displayed.map(\.id))
        for request in pendingInputRequests where !known.contains(request.activity.id) && ids.insert(request.activity.id).inserted {
            displayed.append(request.activity)
        }
        return displayed.sorted {
            let lhs = attentionKind(for: $0) != nil ? 0 : priority($0.observedPhase(at: now))
            let rhs = attentionKind(for: $1) != nil ? 0 : priority($1.observedPhase(at: now))
            if lhs != rhs { return lhs < rhs }
            let left = $0.phaseChangedAt ?? .distantPast, right = $1.phaseChangedAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
    var completedRetention: TimeInterval {
        let minutes = defaults.object(forKey: "completedRetentionMinutes") as? Int ?? 30
        return Double([0, 5, 15, 30, 60, 240].contains(minutes) ? minutes : 30) * 60
    }
    var pendingCompletions: [SessionActivity] {
        guard defaults.bool(forKey: "completionReminder") else { return [] }
        let roots = Set(taskGroups.filter { !$0.isRunning }.map { $0.primary.id })
        return completionInbox.unreadActivities.filter { roots.contains($0.id) }
    }
    var pendingInputRequests: [PendingAttentionRequest] {
        defaults.bool(forKey: "inputReminder") ? attentionRequests : []
    }
    var headerStatus: String {
        if let first = pendingInputRequests.first {
            return L10n.text(first.kind == .approval ? "attention.approval" : "attention.input")
        }
        if !pendingCompletions.isEmpty { return completionSummary }
        if let first = waiting.first { return L10n.text(first.waitingForApproval ? "attention.approval" : "attention.input") }
        let count = running.count + waiting.count
        if count == 1, let task = running.first {
            if let group = taskGroup(for: task), group.runningSubagentCount > 0 {
                return L10n.text(group.runningSubagentCount == 1 ? "activity.subagent_running" : "activity.subagents_running", group.runningSubagentCount)
            }
            switch task.stage {
            case .tool: return L10n.text("activity.tool_compact")
            case .responding: return L10n.text("activity.responding_compact")
            case .thinking, .starting: return task.stage.label
            }
        }
        return count == 0 ? L10n.text("activity.idle") : L10n.text(count == 1 ? "activity.task_count_compact_singular" : "activity.task_count_compact", count > 99 ? "99+" : String(count))
    }
    var headerDisplayStatus: String {
        guard running.count > 1, waiting.isEmpty, pendingInputRequests.isEmpty, pendingCompletions.isEmpty,
              let latest = latestRunningTask else { return headerStatus }
        switch latest.stage {
        case .tool: return L10n.text("activity.tool_compact")
        case .responding: return L10n.text("activity.responding_compact")
        case .thinking, .starting: return latest.stage.label
        }
    }
    private var latestRunningTask: SessionActivity? {
        running.max {
            let left = $0.lastObserved ?? .distantPast, right = $1.lastObserved ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }
    }
    var headerSymbol: String {
        if let request = pendingInputRequests.first { return request.kind == .approval ? StatusSymbols.approval : StatusSymbols.input }
        if let completed = pendingCompletions.first { return StatusSymbols.symbol(for: completed) }
        if let first = waiting.first { return StatusSymbols.symbol(for: first) }
        let latest = latestRunningTask
        return latest.map { taskGroup(for: $0)?.isRunning == true && $0.phase != .running ? StatusSymbols.thinking : StatusSymbols.symbol(for: $0) } ?? StatusSymbols.idle
    }
    var taskAccent: Color { Color(red: 0.56, green: 0.84, blue: 0.79) }
    var headerTint: Color {
        if !pendingInputRequests.isEmpty || !waiting.isEmpty { return .orange }
        if let first = pendingCompletions.first { return first.turnFailed ? .red : first.phase == .interrupted ? .orange : first.provider.tint }
        return latestRunningTask?.provider.tint ?? .secondary
    }
    func attentionKind(for activity: SessionActivity) -> PendingAttentionRequest.Kind? {
        let group = taskGroup(for: activity)
        let ids = Set(group?.members.map(\.id) ?? [activity.id])
        let matching = pendingInputRequests.filter { ids.contains($0.activity.id) }
        if matching.contains(where: { $0.kind == .approval }) { return .approval }
        if !matching.isEmpty { return .input }
        let waiting = group?.members.first { $0.phase == .waitingForInput } ?? (activity.phase == .waitingForInput ? activity : nil)
        return waiting.map { $0.waitingForApproval ? .approval : .input }
    }
    var hidesHeaderRate: Bool {
        isAttached && L10n.language == .english && (!pendingInputRequests.isEmpty || !waiting.isEmpty)
    }
    var quotaWarningSymbol: String? {
        guard !stale, errorMessage == nil, let remaining, remaining <= 15 else { return nil }
        return remaining <= 0 ? StatusSymbols.empty : StatusSymbols.low
    }
    var headerRateText: String? {
        guard let rate else { return nil }
        if isAttached && rate >= 1_000_000 { return String(format: "%.1fM", rate / 1_000_000) }
        if isAttached && rate >= 1_000 { return String(format: "%.1fk", rate / 1_000) }
        return String(format: "%.0f", rate)
    }
    var hasConnectionIssue: Bool {
        !unavailableSSH.isEmpty || (isModuleEnabled(.codex) && streamStatuses["local"].map { !$0.connected } == true) ||
            (isModuleEnabled(.claude) && claudeStreamStatuses["local"].map { !$0.connected } == true)
    }
    var hasSSHConnectionIssue: Bool {
        monitorsSSH && (!unavailableSSH.isEmpty || (Array(streamStatuses) + Array(claudeStreamStatuses)).contains {
            $0.key.contains("remote-ssh-discovered:") && !$0.value.connected
        })
    }
    func isUnreadCompletion(_ activity: SessionActivity) -> Bool { taskGroup(for: activity)?.isRunning != true && completionInbox.isUnread(activity) }
    var completionSummary: String {
        let pending = pendingCompletions
        guard let first = pending.first else { return L10n.text("activity.idle") }
        return pending.count == 1 ? L10n.text(first.turnFailed ? "activity.failed" : first.phase == .interrupted ? "activity.stopped_compact" : "activity.done_compact") : L10n.text("activity.ended_compact", pending.count)
    }
    func openCompletionOrPin() {
        if let request = pendingInputRequests.first, canOpen(request.activity) { open(request.activity) }
        else if let activity = pendingCompletions.first, canOpen(activity) { open(activity) }
        else { togglePin() }
    }
    var selectedWindow: QuotaWindow? { providerSelectedWindow(selectedProvider) }
    var weeklyWindow: QuotaWindow? { providerWeeklyWindow(selectedProvider) }
    var currentCycle: QuotaCycle? { history.currentCycle(for: weeklyWindow, at: now) }
    var stale: Bool { (quota?.isStale(at: now) ?? false) || (selectedWindow?.resetsAt.map { $0 <= now } ?? false) }
    var remaining: Double? { selectedWindow?.remainingPercent }
    var pace: Double? { stale || errorMessage != nil ? nil : selectedWindow?.pacePercent(at: now) }
    var quotaSummary: String {
        if defaults.string(forKey: "compactMetric") == "pace" {
            return pace.map { "\(Int($0.rounded()))%" } ?? "—"
        }
        return remaining.map { "\(Int($0.rounded()))%" } ?? "—"
    }
    var compactWindow: String {
        defaults.string(forKey: "compactMetric") == "pace" ? L10n.text("quota.pace") :
        (selectedWindow?.compactLabel ?? "")
    }
    var compactMetricLabel: String {
        L10n.text(defaults.string(forKey: "compactMetric") == "pace" ? "quota.pace" : "layout.quota_label")
    }
    var remainingTimePercent: Double? { selectedWindow?.elapsedTimePercent(at: now).map { 100 - $0 } }
    var statusTitle: String { overview.title }
    var compactStatus: String {
        if let notice, ![.completed, .interrupted].contains(notice.kind) { return notice.title }
        return overview.compactTitle
    }
    var rate: Double? { overview.displayedRate }
    var rateIsFresh: Bool { overview.rateIsFresh }
    var rateHelp: String { L10n.text(rateIsFresh ? "performance.total_help" : "performance.partial_total_help", rate ?? 0) }
    var showsRate: Bool { !running.isEmpty }
    var rateText: String { rate.map { String(format: "%.1f", $0) } ?? (showsRate ? L10n.text("performance.awaiting_usage") : "—") }
    var monitorsSSH: Bool { defaults.object(forKey: "monitorSSH") == nil || defaults.bool(forKey: "monitorSSH") }
    var monitorsRemoteControl: Bool { defaults.object(forKey: "monitorRemoteControl") == nil || defaults.bool(forKey: "monitorRemoteControl") }
    var accent: Color {
        if errorMessage != nil || stale { return Color(red: 0.65, green: 0.68, blue: 0.73) }
        return selectedProvider == .codex ? taskAccent : Color(red: 0.88, green: 0.59, blue: 0.40)
    }
    var freshnessText: String {
        guard let quota else { return refreshing ? L10n.text("quota.reading") : L10n.text("quota.not_read") }
        if selectedWindow?.resetsAt.map({ $0 <= now }) == true { return L10n.text("quota.expired") }
        let elapsed = max(0, Int(now.timeIntervalSince(quota.capturedAt)))
        if stale || errorMessage != nil { return L10n.text("quota.age", max(1, elapsed / 60)) }
        return elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60)
    }
    func projectName(_ activity: SessionActivity) -> String {
        hideProjects ? L10n.text("activity.hidden_name") : (activity.title ?? activity.project)
    }

    init(demo: Bool = false, initiallyExpanded: Bool = false, demoClock: @escaping () -> Date = { Date() },
         defaults: UserDefaults = .standard, installation: ProviderInstallationDetection? = nil,
         claudeQuotaReads: ClaudeQuotaReadDependencies? = nil,
         completionDismissalStore: CompletionDismissalStore? = nil) {
        self.defaults = defaults
        self.claudeQuotaReads = claudeQuotaReads ?? ClaudeQuotaReadDependencies()
        self.installationOverride = installation
        self.installation = installation ?? .detect()
        self.modules = .load(from: defaults)
        self.demo = demo
        self.demoClock = demoClock
        dashboardPeriod = defaults.string(forKey: "quotaDashboardPeriod").flatMap(QuotaDashboardPeriod.init(rawValue:)) ?? .weekly
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/CurrentCycle", isDirectory: true)
        historyStore = QuotaHistoryStore(directory: directory)
        claudeHistoryStore = QuotaHistoryStore(directory: directory.appendingPathComponent("Claude", isDirectory: true))
        enabledProviders = AgentProvider.allCases.filter { modules.enabledProviders(detection: self.installation).contains($0) }
        if let saved = defaults.string(forKey: "selectedQuotaProvider").flatMap(AgentProvider.init(rawValue:)), enabledProviders.contains(saved) {
            selectedProvider = saved
        } else { selectedProvider = enabledProviders.first ?? .codex }
        codexSourceSignature = currentCodexSourceSignature
        claudeSourceSignature = currentClaudeSourceSignature
        claudeRemoteTargets = monitorsSSH ? RemoteActivityTarget.claudeConfigured(codexHome: home,
            additionalAliases: defaults.string(forKey: "claudeSSHHosts") ?? "") : []
        completionInbox = CompletionInbox(dismissalStore: completionDismissalStore ?? (demo ? nil : .applicationDefault))
        bindCompletionSources(.codex)
        bindCompletionSources(.claude)
        expanded = demo || initiallyExpanded
        pinned = expanded
        if demo { makeDemo() }
    }

    func start() {
        if !demo { refreshQuota(); refreshActivity(); refreshRemote(); startClaudeActivity() }
        scheduleClock()
        scheduleRateExpiry()
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.logWatcher.stop()
                self.invalidateWork()
                self.claudeGeneration += 1
                self.claudeQuotaRestartTask?.cancel(); self.claudeQuotaRestartTask = nil
                self.claudeQuotaTask?.cancel(); self.claudeActivityTask?.cancel(); self.claudeActivityTask = nil
                self.claudeRefreshing = false
                _ = await self.historyStore.flush()
                _ = await self.claudeHistoryStore.flush()
                await self.claudeMonitor.shutdown()
                await self.realtimeMonitor.shutdown()
                if let client = self.client { await client.disconnect() }
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.now = Date()
                self.scheduleRateExpiry()
                self.refreshQuota(); self.refreshActivity(); self.refreshRemote(); self.startClaudeActivity()
            }
        })
    }
    func setExpanded(_ value: Bool) {
        guard !value || !interactionSuspended else { return }
        closeWork?.cancel()
        guard expanded != value else { return }
        expanded = value
        if !demo, !sleeping, !stopped {
            logWatcher.update(watchedLogURLs, interval: activityRefreshPolicy.interval, flushPending: value)
            let generation = sourceGeneration
            Task { [weak self] in
                guard let self, generation == self.sourceGeneration, !self.sleeping, !self.stopped else { return }
                await self.realtimeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
                await self.claudeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
            }
            if value { refreshActivity(metricsOnly: true) }
        }
        if clock != nil { scheduleClock() }
        onLayoutChange?()
        if value && Date().timeIntervalSince(lastQuotaAttempt) > 30 { refreshQuota() }
    }
    func hover(_ entered: Bool) {
        guard !interactionSuspended else { return }
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
    private struct DescendantAcknowledgment {
        let activity: SessionActivity
        let token: CompletionInbox.AcknowledgmentToken
        let source: CompletionInbox.SourceToken
        let ancestors: [SessionActivity]
    }
    private func sameLifecycle(_ left: SessionActivity, _ right: SessionActivity) -> Bool {
        left.canonicalized().id == right.canonicalized().id && left.provider == right.provider && left.sourceHostID == right.sourceHostID &&
            left.parentThreadID == right.parentThreadID && left.turnID == right.turnID && left.turnStartedAt == right.turnStartedAt &&
            left.phase == right.phase && left.phaseChangedAt == right.phaseChangedAt && left.turnFailed == right.turnFailed
    }
    private func descendantAcknowledgments(for parent: SessionActivity, source: CompletionInbox.SourceToken) -> [DescendantAcknowledgment] {
        guard parent.parentThreadID == nil, let group = taskGroup(for: parent), sameLifecycle(group.primary, parent) else { return [] }
        let members = Dictionary(group.members.map { ($0.canonicalized().id, $0) }, uniquingKeysWith: { _, latest in latest })
        return group.members.compactMap { child in
            guard child.id != parent.id, !child.isInternalReview, child.provider == parent.provider, child.sourceHostID == parent.sourceHostID,
                  child.turnID != nil, child.turnStartedAt != nil, [.completed, .interrupted].contains(child.phase),
                  let token = completionInbox.acknowledgment(for: child), completionInbox.sourceToken(for: child) == source else { return nil }
            var current = child, ancestors: [SessionActivity] = [], seen = Set<String>()
            for _ in 0..<64 {
                guard seen.insert(current.id).inserted, let parentSession = current.parentThreadID,
                      let ancestor = members[current.provider.activityID(sessionID: parentSession, sourceHostID: current.sourceHostID)],
                      ancestor.provider == parent.provider, ancestor.sourceHostID == parent.sourceHostID,
                      [.completed, .interrupted].contains(ancestor.phase) else { return nil }
                ancestors.append(ancestor)
                if ancestor.id == parent.id { return DescendantAcknowledgment(activity: child, token: token, source: source, ancestors: ancestors) }
                current = ancestor
            }
            return nil
        }
    }
    func open(_ activity: SessionActivity) {
        guard canOpen(activity), let target = conversationTarget(for: activity), let open = onOpenActivity,
              openingActivities.insert(activity.id).inserted else { return }
        navigationError = nil
        let generation = activity.provider == .codex ? sourceGeneration : claudeGeneration
        let acknowledgment = completionInbox.acknowledgment(for: activity)
        let source = completionInbox.sourceToken(for: activity)
        let descendants = acknowledgment == nil ? [] : descendantAcknowledgments(for: activity, source: source)
        let prefix = activity.id + ":" + (activity.turnID ?? "") + ":"
        let openedNoticeID = notice.flatMap { $0.id.hasPrefix(prefix) ? $0.id : nil }
        Task { [weak self] in
            guard let self else { return }
            defer { self.openingActivities.remove(activity.id) }
            guard !self.stopped, generation == (activity.provider == .codex ? self.sourceGeneration : self.claudeGeneration),
                  self.completionInbox.isCurrentSource(source),
                  self.isModuleEnabled(activity.provider) || self.demo else { return }
            let outcome = await open(target)
            guard !self.stopped, generation == (activity.provider == .codex ? self.sourceGeneration : self.claudeGeneration),
                  self.completionInbox.isCurrentSource(source),
                  self.isModuleEnabled(activity.provider) || self.demo else { return }
            if case .failed(let failure) = outcome {
                self.navigationError = failure
                self.setExpanded(true)
            } else if outcome == .openedConversation {
                if activity.provider == .claude, activity.parentThreadID != nil {
                    guard let current = self.activities.first(where: { $0.canonicalized().id == activity.canonicalized().id }),
                          self.sameLifecycle(current, activity),
                          let currentTarget = self.conversationTarget(for: current),
                          currentTarget.canonicalized().id == target.canonicalized().id else { return }
                }
                let acknowledged = acknowledgment.map { self.completionInbox.dismiss(activity, acknowledging: $0) } ?? false
                if acknowledged {
                    let current = Dictionary(self.activities.map { ($0.canonicalized().id, $0) }, uniquingKeysWith: { _, latest in latest })
                    var removed = [activity]
                    for descendant in descendants {
                        guard self.completionInbox.isCurrentSource(descendant.source),
                              let child = current[descendant.activity.canonicalized().id], self.sameLifecycle(child, descendant.activity),
                              descendant.ancestors.allSatisfy({ ancestor in current[ancestor.canonicalized().id].map { self.sameLifecycle($0, ancestor) } ?? false }),
                              self.completionInbox.dismiss(descendant.activity, acknowledging: descendant.token) else { continue }
                        removed.append(descendant.activity)
                    }
                    self.activities.removeAll {
                        value in removed.contains { self.sameLifecycle(value, $0) }
                    }
                }
                if acknowledged || acknowledgment == nil, let openedNoticeID, self.notice?.id == openedNoticeID {
                    self.noticeWork?.cancel(); self.notice = nil
                }
            }
            self.onLayoutChange?(); self.onStatusChange?()
        }
    }

    func refreshQuota() {
        refreshCodexQuota()
        refreshClaudeQuota()
    }
    private func refreshCodexQuota() {
        guard isModuleEnabled(.codex), !codexRefreshing, !sleeping, !stopped, !demo else { return }
        codexRefreshing = true
        lastQuotaAttempt = Date()
        let generation = sourceGeneration
        let sourceHome = home
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.sourceGeneration { self.codexRefreshing = false } }
            do {
                if self.client == nil {
                    let custom = defaults.string(forKey: "codexExecutable") ?? ""
                    let report = await Task.detached(priority: .utility) {
                        CodexExecutableResolver.discover(customPath: custom)
                    }.value
                    guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                    self.quotaCLI = report.selected
                    guard let selection = report.selected else {
                        throw CodexClientError.executableNotFound(report.issue ?? L10n.text("cli.missing_short"))
                    }
                    self.client = CodexClient(executable: selection.url, home: sourceHome)
                }
                let snapshot = try await self.client!.readQuota()
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                if self.codexHistory.accountScope != snapshot.accountScope {
                    if let scope = snapshot.accountScope {
                        let restored = await self.historyStore.restore(home: sourceHome, accountScope: scope)
                        guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                        self.codexHistory = restored?.1 ?? QuotaCycleHistory()
                    } else { self.codexHistory = QuotaCycleHistory() }
                }
                self.codexQuota = snapshot
                self.codexHistory.record(snapshot)
                self.codexErrorMessage = snapshot.windows.isEmpty
                    ? L10n.text("quota.no_windows") : nil
                self.failureCount = 0
                self.now = Date()
                if snapshot.accountScope == nil {
                    self.codexHistoryWarning = L10n.text("quota.no_identity")
                } else {
                    let saved = await self.historyStore.save(home: sourceHome, snapshot: snapshot, history: self.codexHistory)
                    guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                    self.codexHistoryWarning = saved ? nil : L10n.text("quota.history_unsaved")
                }
                self.present(self.attention.quotaNotices(snapshot, at: self.now))
            } catch {
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                let scope = await self.client?.currentAccountScope()
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                if scope == nil {
                    self.codexQuota = nil
                    self.codexHistory = QuotaCycleHistory()
                } else if let scope, self.codexQuota?.accountScope != scope {
                    self.codexQuota = nil
                    self.codexHistory = QuotaCycleHistory()
                    let restored = await self.historyStore.restore(home: sourceHome, accountScope: scope)
                    guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                    self.codexQuota = restored?.0
                    self.codexHistory = restored?.1 ?? QuotaCycleHistory()
                }
                self.codexErrorMessage = CodexDiagnosticText.description(of: error)
                // A moved/upgraded CLI must be rediscovered on the next attempt.
                self.client = nil
                self.failureCount = min(self.failureCount + 1, 4)
            }
            self.onStatusChange?()
        }
    }

    func retryQuotaConnection() {
        retryQuotaConnection(for: selectedProvider)
    }
    func retryQuotaConnection(for provider: AgentProvider) {
        if provider == .claude { retryClaudeWebConnection(); return }
        guard !codexRefreshing else { return }
        let previous = client
        client = nil
        Task { [weak self] in
            await previous?.disconnect()
            self?.refreshCodexQuota()
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
        if afterSignIn { defaults.removeObject(forKey: "claudeWebOrganizationID") }
        if let organizationID, UUID(uuidString: organizationID) != nil {
            defaults.set(organizationID, forKey: "claudeWebOrganizationID")
        }
        guard claudeQuotaRestartTask == nil, isModuleEnabled(.claude), !sleeping, !stopped else { return }
        let generation = claudeGeneration
        let pending = claudeQuotaTask
        pending?.cancel()
        claudeQuotaRestartTask = Task { [weak self] in
            await pending?.value
            guard let self, self.isCurrentClaudeQuotaRead(generation) else { return }
            defer { if generation == self.claudeGeneration { self.claudeQuotaRestartTask = nil } }
            let previous = self.claudeWebClient, previousLegacy = self.claudeClient
            self.claudeWebClient = nil; self.claudeClient = nil
            await previous?.shutdown()
            await previousLegacy?.shutdown()
            guard self.isCurrentClaudeQuotaRead(generation) else { return }
            self.claudeQuotaRestartTask = nil
            self.claudeRefreshing = false
            self.refreshClaudeQuota()
        }
    }
    private func isCurrentClaudeQuotaRead(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == claudeGeneration && isModuleEnabled(.claude) && !sleeping && !stopped
    }
    func waitForClaudeQuotaRefresh() async {
        if let restart = claudeQuotaRestartTask { await restart.value }
        let refresh = claudeQuotaTask
        await refresh?.value
    }
    private func refreshClaudeQuota() {
        guard isModuleEnabled(.claude), !claudeRefreshing, claudeQuotaRestartTask == nil, !sleeping, !stopped, !demo else { return }
        claudeRefreshing = true; lastClaudeQuotaAttempt = Date()
        let generation = claudeGeneration, sourceHome = claudeHome
        claudeQuotaTask = Task { [weak self] in
            guard let self, self.isCurrentClaudeQuotaRead(generation) else { return }
            defer {
                if generation == self.claudeGeneration {
                    self.claudeRefreshing = false
                }
            }
            var usesWeb = false
            var ownedWebClient: ClaudeWebQuotaClient?
            let legacyClient: ClaudeQuotaClient
            if let current = self.claudeClient { legacyClient = current }
            else {
                legacyClient = ClaudeQuotaClient(home: sourceHome)
                self.claudeClient = legacyClient
            }
            do {
                let snapshot: QuotaSnapshot
                let source: ClaudeQuotaSource?
                let passive = await self.claudeQuotaReads.passive(legacyClient)
                guard self.isCurrentClaudeQuotaRead(generation) else { return }
                if let passive {
                    snapshot = passive; source = .statusLine
                } else {
                    let webSession = await self.claudeQuotaReads.webSession()
                    guard self.isCurrentClaudeQuotaRead(generation) else { return }
                    if webSession != nil {
                        usesWeb = true
                        let webClient: ClaudeWebQuotaClient
                        if let current = self.claudeWebClient { webClient = current }
                        else {
                            let selectedOrganization = self.defaults.string(forKey: "claudeWebOrganizationID")
                            webClient = ClaudeWebQuotaClient(cookieProvider: { await ClaudeWebSessionStore.session() }, home: sourceHome,
                                selectedOrganizationProvider: { selectedOrganization })
                            self.claudeWebClient = webClient
                        }
                        ownedWebClient = webClient
                        snapshot = try await self.claudeQuotaReads.web(webClient)
                        guard self.isCurrentClaudeQuotaRead(generation) else { return }
                        source = await webClient.currentSource()
                    } else {
                        snapshot = try await self.claudeQuotaReads.compatibility(legacyClient)
                        guard self.isCurrentClaudeQuotaRead(generation) else { return }
                        source = await legacyClient.currentSource()
                    }
                }
                guard self.isCurrentClaudeQuotaRead(generation) else { return }
                if self.claudeHistory.accountScope != snapshot.accountScope {
                    if let scope = snapshot.accountScope {
                        let restored = await self.claudeHistoryStore.restore(home: sourceHome, accountScope: scope)
                        guard self.isCurrentClaudeQuotaRead(generation) else { return }
                        self.claudeHistory = restored?.1 ?? QuotaCycleHistory()
                    } else { self.claudeHistory = QuotaCycleHistory() }
                }
                self.claudeQuota = snapshot; self.claudeHistory.record(snapshot)
                self.claudeQuotaSource = source
                self.claudeErrorMessage = snapshot.windows.isEmpty ? L10n.text("quota.no_windows") : nil
                self.claudeConnectionNeeded = false
                self.claudeOrganizationChoices = []
                self.claudeFailureCount = 0; self.now = Date()
                if snapshot.accountScope == nil { self.claudeHistoryWarning = L10n.text("quota.no_identity") }
                else {
                    let saved = await self.claudeHistoryStore.save(home: sourceHome, snapshot: snapshot, history: self.claudeHistory)
                    guard self.isCurrentClaudeQuotaRead(generation) else { return }
                    self.claudeHistoryWarning = saved ? nil : L10n.text("quota.history_unsaved")
                }
                self.present(self.claudeQuotaAttention.quotaNotices(snapshot, at: self.now).map {
                    IslandNotice(id: "claude:" + $0.id, kind: $0.kind, title: "Claude · " + $0.title, detail: $0.detail)
                })
            } catch {
                guard self.isCurrentClaudeQuotaRead(generation) else { return }
                let scope = usesWeb ? await ownedWebClient?.currentAccountScope() : await legacyClient.currentAccountScope()
                guard self.isCurrentClaudeQuotaRead(generation) else { return }
                if scope == nil || self.claudeQuota?.accountScope != scope {
                    self.claudeQuota = nil; self.claudeHistory = QuotaCycleHistory(); self.claudeQuotaSource = nil
                }
                self.claudeErrorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.text("claude.quota.unavailable")
                self.claudeConnectionNeeded = (error as? ClaudeQuotaError).map {
                    [ClaudeQuotaError.notLoggedIn, .credentialsExpired, .keychainAccessRequired, .accountChanged, .webChallenge, .organizationSelectionRequired].contains($0)
                } ?? false
                if (error as? ClaudeQuotaError) == .organizationSelectionRequired, let ownedWebClient {
                    let choices = await self.claudeQuotaReads.organizations(ownedWebClient)
                    guard self.isCurrentClaudeQuotaRead(generation) else { return }
                    self.claudeOrganizationChoices = choices
                } else { self.claudeOrganizationChoices = [] }
                if self.claudeConnectionNeeded { self.claudeConnectionSaved = nil }
                self.claudeFailureCount = min(self.claudeFailureCount + 1, 4)
            }
            self.onLayoutChange?(); self.onStatusChange?()
        }
    }
    private func startClaudeActivity() {
        guard isModuleEnabled(.claude), claudeActivityTask == nil, !sleeping, !stopped, !demo else { return }
        lastClaudeDiscovery = Date()
        let generation = claudeGeneration, sourceHome = claudeHome
        let targets = monitorsSSH ? RemoteActivityTarget.claudeConfigured(codexHome: home,
            additionalAliases: defaults.string(forKey: "claudeSSHHosts") ?? "") : []
        claudeRemoteTargets = targets
        bindCompletionSources(.claude)
        claudeActivityTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.claudeGeneration { self.claudeActivityTask = nil } }
            await self.claudeMonitor.start(home: sourceHome, remoteTargets: targets, refreshPolicy: self.activityRefreshPolicy) { [weak self] values, statuses, requests, performance in
                guard let model = self else { return }
                let excluded = await model.claudeMonitor.excludedLocalActivityIDs()
                await MainActor.run {
                    guard generation == model.claudeGeneration, !model.stopped, !model.sleeping, model.isModuleEnabled(.claude) else { return }
                    model.receiveClaudeUpdate(values, statuses: statuses, requests: requests, performance: performance, excludedLocalIDs: excluded)
                }
            }
        }
    }
    func receiveClaudeUpdate(_ values: [SessionActivity], statuses: [String: RuntimeStreamStatus], requests: [PendingAttentionRequest], performance: [SessionPerformanceUpdate] = [], excludedLocalIDs: Set<String> = []) {
        let excluded = Set(excludedLocalIDs.filter { $0.hasPrefix("claude:local:") })
        if !excluded.isEmpty {
            completionInbox.remove(activityIDs: excluded)
            if activities.contains(where: { excluded.contains($0.id) }) { activities.removeAll { excluded.contains($0.id) } }
            if let notice, excluded.contains(where: { notice.id.contains($0 + ":") }) {
                noticeWork?.cancel(); self.notice = nil
            }
        }
        now = Date(); claudeActivities = values.filter { !excluded.contains($0.id) }; claudeStreamStatuses = statuses; claudeAttentionRequests = requests
        let measured = performance.filter { !excluded.contains($0.id) }
        completionInbox.updatePerformance(measured)
        for update in measured { rememberFirstOutput(update.firstTokenLatency, reportedAt: update.firstTokenReportedAt) }
        observeAttentionRequests(codexAttentionRequests + claudeAttentionRequests)
        combineActivities()
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
        localTask = Task { [weak self, reader] in
            let result = await reader.read(home: sourceHome, phaseAwareRate: true, excludingThreads: covered, includeCoveredMetrics: true, metricsOnly: onlyMetrics, subagentStates: agentStates)
            guard let self else { return }
            defer {
                if generation == self.sourceGeneration {
                    self.localTask = nil
                    if self.localActivityDirty { self.refreshActivity(metricsOnly: !self.localActivityNeedsDiscovery) }
                }
            }
            guard !Task.isCancelled, generation == self.sourceGeneration else { return }
            self.now = Date()
            self.localActivities = result.activities
            if !onlyMetrics {
                self.watchedLogURLs = result.watchURLs
                self.logWatcher.update(result.watchURLs, interval: self.activityRefreshPolicy.interval)
            }
            self.combineActivities()
            self.onStatusChange?()
        }
    }

    func refreshRemote() {
        guard isModuleEnabled(.codex) else { return }
        bindCompletionSources(.codex)
        guard remoteTask == nil, !sleeping, !stopped, !demo else { return }
        lastRemoteDiscovery = Date()
        let generation = sourceGeneration
        let sourceHome = home
        remoteTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.sourceGeneration { self.remoteTask = nil } }
            await self.realtimeMonitor.start(home: sourceHome, includeSSH: self.monitorsSSH, includeRemoteControl: self.monitorsRemoteControl, refreshPolicy: self.activityRefreshPolicy) { [weak self] activities, statuses, unavailable, requests, names, performance in
                // The monitor publishes serially. Keep that order on the UI
                // queue so a later empty snapshot cannot overtake an ending.
                DispatchQueue.main.async {
                    guard let self, generation == self.sourceGeneration, !self.stopped, !self.sleeping else { return }
                    self.receiveRemoteUpdate(activities, statuses: statuses, unavailable: unavailable, requests: requests, names: names, performance: performance)
                }
            }
            // A hover/collapse can occur while start is awaiting the monitor.
            await self.realtimeMonitor.updateRefreshPolicy(self.activityRefreshPolicy, flushPending: self.expanded)
        }
    }

    func receiveRemoteUpdate(_ activities: [SessionActivity], statuses: [String: RuntimeStreamStatus],
                             unavailable: [String], requests: [PendingAttentionRequest], names: [SessionNameUpdate], performance: [SessionPerformanceUpdate] = []) {
        let oldLocal = Set(remoteActivities.filter { $0.sourceHostID == nil }.map { $0.id + ":" + ($0.turnID ?? "") })
        let newLocal = Set(activities.filter { $0.sourceHostID == nil }.map { $0.id + ":" + ($0.turnID ?? "") })
        let agentStatesChanged = localSubagentStates(remoteActivities) != localSubagentStates(activities)
        now = Date(); remoteActivities = activities
        for update in performance {
            rememberFirstOutput(update.firstTokenLatency, reportedAt: update.firstTokenReportedAt)
        }
        completionInbox.updateNames(names)
        completionInbox.updatePerformance(performance)
        if streamStatuses != statuses { streamStatuses = statuses }
        if unavailableSSH != unavailable { unavailableSSH = unavailable }
        codexAttentionRequests = requests
        observeAttentionRequests(codexAttentionRequests + claudeAttentionRequests)
        combineActivities()
        if oldLocal != newLocal { refreshActivity() }
        else if agentStatesChanged { refreshActivity(metricsOnly: true) }
    }
    func observeAttentionRequests(_ requests: [PendingAttentionRequest]) {
        if attentionRequests != requests { attentionRequests = requests }
        present(attention.requestNotices(requests.filter { $0.provider == .codex }) +
            claudeActivityAttention.requestNotices(requests.filter { $0.provider == .claude }))
        // A resolved async request clears its persistent UI immediately. Its
        // tool completion alone cannot clear it because the tool is nonblocking.
        if requests.isEmpty, notice?.id.hasPrefix("request:") == true { noticeWork?.cancel(); notice = nil }
    }
    private func combineActivities() {
        let oldHeight = panelContentHeight
        let previous = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let merged = (ActivitySourceMerger.merge(logged: localActivities, streamed: remoteActivities) + claudeActivities).map { value in
            var value = value
            if let old = previous[value.id] { value.mergeDisplayMetadata(from: old) }
            return value
        }
        let grouped = ActivityTaskGroup.make(merged).flatMap(\.members)
        observeFirstOutputs(grouped)
        let observed = completionInbox.observe(grouped, at: now, retention: completedRetention)
        let activeRoots = Set(ActivityTaskGroup.make(observed).filter(\.isRunning).map { $0.primary.id })
        let combined = observed.filter {
            !$0.isInternalReview && (activeRoots.contains($0.id) || ![.completed, .interrupted].contains($0.phase)) &&
                (activeRoots.contains($0.id) || [.running, .waitingForInput].contains($0.phase) || now.timeIntervalSince($0.lastObserved ?? .distantPast) < 900)
        } + completionInbox.activities.filter { !activeRoots.contains($0.id) }
        if activities != combined { activities = combined }
        if RuntimeDiagnostics.enabled { RuntimeDiagnostics.record("ui", source: "combined", activities: combined) }
        if oldHeight != panelContentHeight { onLayoutChange?() }
        let inputs = Set(pendingInputRequests.map { $0.activity.id })
        let noticeTasks = taskGroups.filter { !($0.isRunning && [.completed, .interrupted].contains($0.primary.phase)) }.map(\.primary)
        present((attention.activityNotices(noticeTasks.filter { $0.provider == .codex }, at: now) +
            claudeActivityAttention.activityNotices(noticeTasks.filter { $0.provider == .claude }, at: now)).filter { notice in
            notice.kind != .waitingForInput || !inputs.contains(where: { notice.id.hasPrefix($0 + ":") })
        })
        onStatusChange?()
    }

    private func observeFirstOutputs(_ values: [SessionActivity]) {
        for activity in values where !activity.isInternalReview {
            rememberFirstOutput(activity.firstTokenLatency, reportedAt: activity.firstTokenReportedAt)
        }
    }
    private func rememberFirstOutput(_ latency: TimeInterval?, reportedAt: Date?) {
        guard let latency, latency.isFinite, (0...3600).contains(latency), let reportedAt,
              reportedAt <= now, latestFirstOutputAt.map({ reportedAt > $0 }) ?? true else { return }
        latestFirstOutputAt = reportedAt; latestFirstOutputLatency = latency
    }

    private var currentCodexSourceSignature: String {
        home.path + "|" + (defaults.string(forKey: "codexExecutable") ?? "") + "|" + String(monitorsSSH) + "|" + String(monitorsRemoteControl)
    }
    private var currentClaudeSourceSignature: String {
        claudeHome.path + "|" + String(monitorsSSH) + (monitorsSSH
            ? "|" + home.path + "|" + (defaults.string(forKey: "claudeSSHHosts") ?? "") : "")
    }
    func applySettings(sourceChanged: Bool) {
        let oldEnabled = Set(enabledProviders)
        installation = installationOverride ?? .detect()
        modules = .load(from: defaults)
        enabledProviders = AgentProvider.allCases.filter { modules.enabledProviders(detection: self.installation).contains($0) }
        if !enabledProviders.contains(selectedProvider) { selectedProvider = enabledProviders.first ?? .codex }
        compactLayout = .load(); measuredCompactWidth = 0; settingsRevision += 1
        if clock != nil { scheduleClock() }
        pruneCompletions()
        if hideProjects, let current = notice, current.kind != .lowQuota {
            notice = IslandNotice(id: current.id, kind: current.kind, title: current.title, detail: L10n.text("activity.hidden_name"))
        }
        let newCodex = currentCodexSourceSignature, newClaude = currentClaudeSourceSignature
        let codexChanged = oldEnabled.contains(.codex) != isModuleEnabled(.codex) || newCodex != codexSourceSignature
        let claudeChanged = oldEnabled.contains(.claude) != isModuleEnabled(.claude) || newClaude != claudeSourceSignature
        codexSourceSignature = newCodex; claudeSourceSignature = newClaude
        if codexChanged { resetCodexSource() }
        else { logWatcher.update(watchedLogURLs, interval: activityRefreshPolicy.interval); refreshRemote() }
        if claudeChanged { resetClaudeSource() }
        else { startClaudeActivity() }
        onLayoutChange?(); onStatusChange?()
    }
    private func resetCodexSource() {
        logWatcher.stop(); invalidateWork()
        let previous = client; client = nil
        codexQuota = nil; codexHistory = QuotaCycleHistory(); codexHistoryWarning = nil; codexErrorMessage = nil
        quotaCLI = nil; failureCount = 0; attention = AttentionPolicy()
        completionInbox.remove(provider: .codex)
        bindCompletionSources(.codex)
        codexAttentionRequests = []; localActivities = []; remoteActivities = []; unavailableSSH = []; streamStatuses = [:]
        activities.removeAll { $0.provider == .codex }
        observeAttentionRequests(claudeAttentionRequests)
        clearSourceNotice(.codex)
        let generation = sourceGeneration
        Task { [weak self, reader] in
            guard let self, generation == self.sourceGeneration else { return }
            _ = await self.historyStore.flush(); await previous?.disconnect(); await self.realtimeMonitor.shutdown(); await reader.reset()
            guard generation == self.sourceGeneration else { return }
            self.refreshCodexQuota(); self.refreshActivity(); self.refreshRemote()
        }
    }
    private func resetClaudeSource() {
        claudeGeneration += 1
        claudeQuotaRestartTask?.cancel(); claudeQuotaRestartTask = nil
        claudeQuotaTask?.cancel(); claudeActivityTask?.cancel(); claudeActivityTask = nil
        let previous = claudeClient; claudeClient = nil; claudeRefreshing = false
        let previousWeb = claudeWebClient; claudeWebClient = nil
        claudeOrganizationChoices = []
        claudeQuota = nil; claudeHistory = QuotaCycleHistory(); claudeHistoryWarning = nil; claudeErrorMessage = nil
        claudeQuotaSource = nil; claudeConnectionNeeded = false; claudeConnectionSaved = nil; claudeFailureCount = 0; claudeQuotaAttention = AttentionPolicy(); claudeActivityAttention = AttentionPolicy()
        completionInbox.remove(provider: .claude)
        claudeRemoteTargets = monitorsSSH ? RemoteActivityTarget.claudeConfigured(codexHome: home,
            additionalAliases: defaults.string(forKey: "claudeSSHHosts") ?? "") : []
        bindCompletionSources(.claude)
        claudeActivities = []; claudeAttentionRequests = []; claudeStreamStatuses = [:]
        activities.removeAll { $0.provider == .claude }
        observeAttentionRequests(codexAttentionRequests)
        clearSourceNotice(.claude)
        let generation = claudeGeneration
        Task { [weak self] in
            guard let self, generation == self.claudeGeneration else { return }
            _ = await self.claudeHistoryStore.flush(); await previous?.shutdown(); await previousWeb?.shutdown(); await self.claudeMonitor.shutdown()
            guard generation == self.claudeGeneration else { return }
            self.refreshClaudeQuota(); self.startClaudeActivity()
        }
    }
    private func clearSourceNotice(_ provider: AgentProvider) {
        if let notice, (notice.id.hasPrefix("claude:") || notice.id.hasPrefix("request:claude:")) == (provider == .claude) {
            noticeWork?.cancel(); self.notice = nil
        }
        navigationError = nil
        latestFirstOutputAt = nil; latestFirstOutputLatency = nil
        observeFirstOutputs(activities)
    }

    private func bindCompletionSources(_ provider: AgentProvider) {
        let targets = provider == .codex ? (monitorsSSH ? RemoteActivityTarget.configured(home: home) : []) : claudeRemoteTargets
        let remoteHomes = Dictionary(targets.map { ($0.id, $0.home) }, uniquingKeysWith: { _, latest in latest })
        let controls = provider == .codex && isModuleEnabled(.codex) && monitorsRemoteControl
            ? Set(RemoteControlActivityTarget.configured(home: home).map(\.id)) : []
        completionInbox.bindSourceHomes(provider: provider, localHome: provider == .codex ? home : claudeHome,
            remoteHomes: remoteHomes, remoteControlHostIDs: controls)
    }

    func shutdown() async {
        stopped = true
        logWatcher.stop()
        clock?.invalidate()
        closeWork?.cancel()
        noticeWork?.cancel()
        invalidateWork()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        claudeGeneration += 1; claudeQuotaRestartTask?.cancel(); claudeQuotaTask?.cancel(); claudeActivityTask?.cancel()
        _ = await historyStore.flush()
        _ = await claudeHistoryStore.flush()
        await claudeMonitor.shutdown()
        await claudeRemoteSetup.shutdown()
        await claudeClient?.shutdown()
        await claudeWebClient?.shutdown()
        await realtimeMonitor.shutdown()
        await client?.shutdown()
    }

    private func invalidateWork() {
        rateExpiryWork?.cancel(); rateExpiryWork = nil; rateExpiryAt = nil
        sourceGeneration += 1
        refreshTask?.cancel()
        localTask?.cancel()
        remoteTask?.cancel(); remoteTask = nil
        localTask = nil
        codexRefreshing = false
    }
    private func pruneCompletions() {
        let oldHeight = panelContentHeight
        completionInbox.prune(at: now, retention: completedRetention)
        let retained = Set(completionInbox.activities.map(\.id)).union(taskGroups.filter(\.isRunning).map { $0.primary.id })
        activities.removeAll { [.completed, .interrupted].contains($0.phase) && !retained.contains($0.id) }
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
        let deadline = activities.compactMap(\.rateExpiresAt).filter { $0 > now }.min()
        guard deadline != rateExpiryAt else { return }
        rateExpiryWork?.cancel(); rateExpiryWork = nil; rateExpiryAt = nil
        guard !sleeping, !stopped, let deadline else { return }
        rateExpiryAt = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sleeping, !self.stopped else { return }
            self.rateExpiryWork = nil; self.rateExpiryAt = nil
            self.now = Date()
            self.scheduleRateExpiry()
            self.onStatusChange?()
        }
        rateExpiryWork = work
        // One UI-only wake-up at the earliest expiry; no quota, log or SSH work.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow) + 0.01, execute: work)
    }
    private func tick() {
        now = Date()
        pruneCompletions()
        codexHistory.prune(at: now); claudeHistory.prune(at: now)
        guard !sleeping, !stopped, !demo else { return }
        let normalInterval: Double = expanded ? 30 : 120
        let interval = failureCount == 0 ? normalInterval : min(600, normalInterval * pow(2, Double(failureCount)))
        if now.timeIntervalSince(lastQuotaAttempt) >= interval { refreshCodexQuota() }
        let claudeInterval = claudeFailureCount == 0 ? normalInterval : min(600, normalInterval * pow(2, Double(claudeFailureCount)))
        if now.timeIntervalSince(lastClaudeQuotaAttempt) >= claudeInterval { refreshClaudeQuota() }
        if now.timeIntervalSince(lastDiscovery) >= (streamStatuses["local"]?.connected == true ? 120 : 60) { refreshActivity() }
        if now.timeIntervalSince(lastRemoteDiscovery) >= 30 { refreshRemote() }
        if isModuleEnabled(.claude), now.timeIntervalSince(lastClaudeDiscovery) >= 30 {
            lastClaudeDiscovery = now
            let generation = claudeGeneration
            let targets = monitorsSSH ? RemoteActivityTarget.claudeConfigured(codexHome: home,
                additionalAliases: defaults.string(forKey: "claudeSSHHosts") ?? "") : []
            claudeRemoteTargets = targets
            bindCompletionSources(.claude)
            Task { [weak self] in
                guard let self, generation == self.claudeGeneration, !self.stopped, !self.sleeping else { return }
                await self.claudeMonitor.updateRemoteTargets(targets)
            }
        }
        onStatusChange?()
    }
    private func priority(_ phase: ActivityPhase) -> Int {
        switch phase {
        case .waitingForInput: return 0
        case .running: return 1
        case .interrupted: return 2
        case .completed: return 3
        case .unknown: return 4
        }
    }
    private func present(_ notices: [IslandNotice]) {
        guard !demo else { return }
        let enabled = notices.filter { notice in
            switch notice.kind {
            case .lowQuota: return defaults.bool(forKey: "lowQuotaReminder")
            case .waitingForInput: return defaults.bool(forKey: "inputReminder")
            case .completed, .interrupted: return defaults.bool(forKey: "completionReminder")
            }
        }
        guard let newest = enabled.last else { return }
        let visible = hideProjects && newest.kind != .lowQuota ?
            IslandNotice(id: newest.id, kind: newest.kind, title: newest.title, detail: L10n.text("activity.hidden_name")) : newest
        notifications.deliver(visible)
        noticeWork?.cancel()
        if [.completed, .interrupted].contains(visible.kind) {
            notice = nil
            return
        }
        notice = visible
        if visible.id.hasPrefix("request:") { return }
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    private func makeDemo() {
        for snapshot in DemoScenario.quota(at: now) { history.record(snapshot); quota = snapshot }
        setDemoStage(.thinking)
        if CommandLine.arguments.contains("--demo-completion") { setDemoStage(.completed) }
    }
    func setDemoStage(_ stage: DemoTaskStage) {
        guard demo else { return }
        now = demoClock()
        let observed = CommandLine.arguments.contains("--demo-subagents") ? DemoScenario.subagentTasks(stage: stage, at: now) : DemoScenario.tasks(stage: stage, at: now)
        completionInbox.observe(observed, at: now, retention: completedRetention)
        activities = observed
        var status = RuntimeStreamStatus()
        status.connected = true; status.attachedThreads = 1; status.notifications = 7 + stage.rawValue
        streamStatuses = ["local": status, "remote-ssh-discovered:demo": status]
        onLayoutChange?(); onStatusChange?()
    }
}
