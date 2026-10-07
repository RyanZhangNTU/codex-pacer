import AppKit
import SwiftUI
import PacerCore

@MainActor
final class IslandModel: ObservableObject {
    @Published var quota: QuotaSnapshot? {
        didSet { if oldValue?.windows.count != quota?.windows.count { onLayoutChange?() } }
    }
    @Published var activities: [SessionActivity] = [] {
        didSet { scheduleRateExpiry() }
    }
    @Published var streamStatuses: [String: RuntimeStreamStatus] = [:]
    @Published var unavailableSSH: [String] = []
    @Published var navigationError: String?
    @Published private(set) var attentionRequests: [PendingAttentionRequest] = []
    private var localActivities: [SessionActivity] = []
    private var remoteActivities: [SessionActivity] = []
    @Published var history = QuotaCycleHistory()
    @Published var historyWarning: String?
    @Published var notice: IslandNotice?
    @Published var errorMessage: String?
    @Published var quotaCLI: CodexExecutableResolver.Candidate?
    @Published var refreshing = false
    @Published var expanded = false
    @Published var pinned = false
    @Published var now = Date()
    @Published var settingsRevision = 0
    @Published var isAttached = false
    @Published var notchWidth: CGFloat = 0
    @Published var topHeight: CGFloat = 38
    var onLayoutChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRelaunch: (() -> String?)?
    var onOpenActivity: ((SessionActivity) async -> String?)?
    private var openingActivities: Set<String> = []
    var onFocusRequested: (() -> Void)?
    func canOpen(_ activity: SessionActivity) -> Bool {
        (demo || activity.threadURL != nil) && (demo || activity.sourceHostID != nil ||
            home.path == URL(fileURLWithPath: NSHomeDirectory() + "/.codex").standardizedFileURL.path)
    }
    private var measuredContentHeight: CGFloat?
    private(set) var measuredHeaderLeading: CGFloat = 80
    private(set) var measuredHeaderTrailing: CGFloat = 65
    private(set) var measuredContentWidth: CGFloat = 0
    var widthSettings: IslandWidthSettings { .load() }
    func updateMeasuredHeaderWidth(leading: CGFloat, trailing: CGFloat) {
        guard leading.isFinite, trailing.isFinite, leading > 0, trailing > 0 else { return }
        let left = ceil(leading), right = ceil(trailing)
        guard left != measuredHeaderLeading || right != measuredHeaderTrailing else { return }
        measuredHeaderLeading = left
        measuredHeaderTrailing = right
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
        measuredContentHeight ?? min(640, max(424, 286 + CGFloat(max(1, min(3, visibleActivities.count))) * 56 + CGFloat(quota?.windows.count ?? 1) * 92 + (demo ? 25 : 0)))
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
        let configured = UserDefaults.standard.string(forKey: "codexHome") ?? ""
        let path = configured.isEmpty ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    var displayMode: IslandDisplayMode { .load() }
    var appearance: IslandAppearance { .stored }
    var showInFullscreen: Bool { UserDefaults.standard.bool(forKey: "showInFullscreen") }
    var showInMenuBar: Bool { UserDefaults.standard.bool(forKey: "showInMenuBar") }
    var hideProjects: Bool { UserDefaults.standard.bool(forKey: "hideProjects") }
    var displayID: Int { UserDefaults.standard.integer(forKey: "displayID") }
    var overview: ActivityOverview { ActivityOverview(activities: activities, at: now) }
    var running: [SessionActivity] { overview.running }
    var waiting: [SessionActivity] { overview.waiting }
    var visibleActivities: [SessionActivity] {
        var displayed = activities.filter {
            guard !$0.isInternalReview else { return false }
            if [.completed, .interrupted].contains($0.phase) {
                return true
            }
            return [.running, .waitingForInput].contains($0.observedPhase(at: now))
        }
        // Pending input can arrive before runtime metadata. Keep its routing
        // visible in the same paginated task region without duplicating a task.
        var ids = Set(displayed.map(\.id))
        for request in pendingInputRequests where ids.insert(request.activity.id).inserted {
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
        let minutes = UserDefaults.standard.object(forKey: "completedRetentionMinutes") as? Int ?? 30
        return Double([0, 5, 15, 30, 60, 240].contains(minutes) ? minutes : 30) * 60
    }
    var pendingCompletions: [SessionActivity] {
        UserDefaults.standard.bool(forKey: "completionReminder") ? completionInbox.unreadActivities : []
    }
    var pendingInputRequests: [PendingAttentionRequest] {
        UserDefaults.standard.bool(forKey: "inputReminder") ? attentionRequests : []
    }
    var headerStatus: String {
        if let first = pendingInputRequests.first {
            return L10n.text(first.kind == .approval ? "attention.approval" : "attention.input")
        }
        if !pendingCompletions.isEmpty { return completionSummary }
        if let first = waiting.first { return L10n.text(first.waitingForApproval ? "attention.approval" : "attention.input") }
        let count = running.count + waiting.count
        if count == 1, let task = running.first {
            switch task.stage {
            case .tool: return L10n.text("activity.tool_compact")
            case .responding: return L10n.text("activity.responding_compact")
            case .thinking, .starting: return task.stage.label
            }
        }
        return count == 0 ? L10n.text("activity.idle") : L10n.text("activity.task_count_compact", count > 99 ? "99+" : String(count))
    }
    var headerDisplayStatus: String { headerStatus }
    var headerSymbol: String {
        if let request = pendingInputRequests.first { return request.kind == .approval ? StatusSymbols.approval : StatusSymbols.input }
        if let completed = pendingCompletions.first { return StatusSymbols.symbol(for: completed) }
        if let first = waiting.first { return StatusSymbols.symbol(for: first) }
        let latest = running.max {
            let left = $0.lastObserved ?? .distantPast, right = $1.lastObserved ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }
        return latest.map { StatusSymbols.symbol(for: $0) } ?? StatusSymbols.idle
    }
    var taskAccent: Color { Color(red: 0.56, green: 0.84, blue: 0.79) }
    var headerTint: Color {
        if !pendingInputRequests.isEmpty || !waiting.isEmpty { return .orange }
        if let first = pendingCompletions.first { return first.turnFailed ? .red : first.phase == .interrupted ? .orange : taskAccent }
        return running.isEmpty ? .secondary : taskAccent
    }
    func attentionKind(for activity: SessionActivity) -> PendingAttentionRequest.Kind? {
        let matching = pendingInputRequests.filter { $0.activity.id == activity.id }
        if matching.contains(where: { $0.kind == .approval }) { return .approval }
        if !matching.isEmpty { return .input }
        return activity.phase == .waitingForInput ? (activity.waitingForApproval ? .approval : .input) : nil
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
    var hasConnectionIssue: Bool { !unavailableSSH.isEmpty || streamStatuses["local"].map { !$0.connected } == true }
    func isUnreadCompletion(_ activity: SessionActivity) -> Bool { completionInbox.isUnread(activity) }
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
    var selectedWindow: QuotaWindow? {
        let selected = UserDefaults.standard.string(forKey: "quotaWindowID") ?? "auto"
        if let window = quota?.windows.first(where: { $0.id == selected }) { return window }
        return weeklyWindow ?? quota?.limitingWindow
    }
    var weeklyWindow: QuotaWindow? {
        let selected = UserDefaults.standard.string(forKey: "quotaWindowID") ?? "auto"
        if let bucket = quota?.buckets.first(where: { $0.windows.contains(where: { $0.id == selected }) }),
           let weekly = bucket.windows.first(where: { $0.durationMinutes == 10080 }) { return weekly }
        return quota?.buckets.first(where: { $0.id == "codex" })?.windows.first(where: { $0.durationMinutes == 10080 }) ??
        quota?.windows.first(where: { $0.durationMinutes == 10080 })
    }
    var currentCycle: QuotaCycle? { history.currentCycle(for: weeklyWindow, at: now) }
    var stale: Bool { (quota?.isStale(at: now) ?? false) || (selectedWindow?.resetsAt.map { $0 <= now } ?? false) }
    var remaining: Double? { selectedWindow?.remainingPercent }
    var pace: Double? { stale || errorMessage != nil ? nil : selectedWindow?.pacePercent(at: now) }
    var quotaSummary: String {
        if UserDefaults.standard.string(forKey: "compactMetric") == "pace" {
            return pace.map { "\(Int($0.rounded()))%" } ?? "—"
        }
        return remaining.map { "\(Int($0.rounded()))%" } ?? "—"
    }
    var compactWindow: String {
        UserDefaults.standard.string(forKey: "compactMetric") == "pace" ? L10n.text("quota.pace") :
        (selectedWindow?.compactLabel ?? "")
    }
    var statusTitle: String { overview.title }
    var compactStatus: String {
        if let notice, ![.completed, .interrupted].contains(notice.kind) { return notice.title }
        return overview.compactTitle
    }
    var rate: Double? { overview.displayedRate }
    var rateIsFresh: Bool { overview.rateIsFresh }
    var showsRate: Bool { !running.isEmpty }
    var rateText: String { rate.map { String(format: "%.1f", $0) } ?? (showsRate ? L10n.text("activity.sampling") : "—") }
    var monitorsSSH: Bool { UserDefaults.standard.object(forKey: "monitorSSH") == nil || UserDefaults.standard.bool(forKey: "monitorSSH") }
    var accent: Color {
        if !waiting.isEmpty || notice != nil { return Color(red: 0.91, green: 0.75, blue: 0.48) }
        if errorMessage != nil || stale { return Color(red: 0.65, green: 0.68, blue: 0.73) }
        if (remaining ?? 100) <= 15 { return Color(red: 0.91, green: 0.75, blue: 0.48) }
        return Color(red: 0.56, green: 0.84, blue: 0.79)
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

    init(demo: Bool = false, initiallyExpanded: Bool = false, demoClock: @escaping () -> Date = { Date() }) {
        self.demo = demo
        self.demoClock = demoClock
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/CurrentCycle", isDirectory: true)
        historyStore = QuotaHistoryStore(directory: directory)
        expanded = demo || initiallyExpanded
        pinned = expanded
        if demo { makeDemo() }
    }

    func start() {
        if !demo { refreshQuota(); refreshActivity(); refreshRemote() }
        scheduleClock()
        scheduleRateExpiry()
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.invalidateWork()
                _ = await self.historyStore.flush()
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
                self.refreshQuota(); self.refreshActivity(); self.refreshRemote()
            }
        })
    }
    func setExpanded(_ value: Bool) {
        guard !value || !interactionSuspended else { return }
        closeWork?.cancel()
        guard expanded != value else { return }
        expanded = value
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
    func open(_ activity: SessionActivity) {
        guard canOpen(activity), let open = onOpenActivity, openingActivities.insert(activity.id).inserted else { return }
        navigationError = nil
        let generation = sourceGeneration
        let prefix = activity.id + ":" + (activity.turnID ?? "") + ":"
        let openedNoticeID = notice.flatMap { $0.id.hasPrefix(prefix) ? $0.id : nil }
        Task { [weak self] in
            let failure = await open(activity)
            guard let self else { return }
            defer { self.openingActivities.remove(activity.id) }
            guard !self.stopped, generation == self.sourceGeneration else { return }
            if let failure {
                self.navigationError = failure
                self.setExpanded(true)
            } else {
                self.completionInbox.dismiss(activity)
                self.activities.removeAll {
                    $0.id == activity.id && $0.turnID == activity.turnID && $0.phase == activity.phase &&
                    $0.phaseChangedAt == activity.phaseChangedAt && [.completed, .interrupted].contains($0.phase)
                }
                if let openedNoticeID, self.notice?.id == openedNoticeID { self.noticeWork?.cancel(); self.notice = nil }
            }
            self.onLayoutChange?(); self.onStatusChange?()
        }
    }

    func refreshQuota() {
        guard !refreshing, !sleeping, !stopped, !demo else { return }
        refreshing = true
        lastQuotaAttempt = Date()
        let generation = sourceGeneration
        let sourceHome = home
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.sourceGeneration { self.refreshing = false } }
            do {
                if self.client == nil {
                    let custom = UserDefaults.standard.string(forKey: "codexExecutable") ?? ""
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
                if self.history.accountScope != snapshot.accountScope {
                    if let scope = snapshot.accountScope {
                        let restored = await self.historyStore.restore(home: sourceHome, accountScope: scope)
                        guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                        self.history = restored?.1 ?? QuotaCycleHistory()
                    } else { self.history = QuotaCycleHistory() }
                }
                self.quota = snapshot
                self.history.record(snapshot)
                self.errorMessage = snapshot.windows.isEmpty
                    ? L10n.text("quota.no_windows") : nil
                self.failureCount = 0
                self.now = Date()
                if snapshot.accountScope == nil {
                    self.historyWarning = L10n.text("quota.no_identity")
                } else {
                    let saved = await self.historyStore.save(home: sourceHome, snapshot: snapshot, history: self.history)
                    guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                    self.historyWarning = saved ? nil : L10n.text("quota.history_unsaved")
                }
                self.present(self.attention.quotaNotices(snapshot, at: self.now))
            } catch {
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                let scope = await self.client?.currentAccountScope()
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                if scope == nil {
                    self.quota = nil
                    self.history = QuotaCycleHistory()
                } else if let scope, self.quota?.accountScope != scope {
                    self.quota = nil
                    self.history = QuotaCycleHistory()
                    let restored = await self.historyStore.restore(home: sourceHome, accountScope: scope)
                    guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                    self.quota = restored?.0
                    self.history = restored?.1 ?? QuotaCycleHistory()
                }
                self.errorMessage = CodexDiagnosticText.description(of: error)
                // A moved/upgraded CLI must be rediscovered on the next attempt.
                self.client = nil
                self.failureCount = min(self.failureCount + 1, 4)
            }
            self.onStatusChange?()
        }
    }

    func retryQuotaConnection() {
        guard !refreshing else { return }
        let previous = client
        client = nil
        Task { [weak self] in
            await previous?.disconnect()
            self?.refreshQuota()
        }
    }

    func refreshActivity() {
        guard localTask == nil, !sleeping, !stopped, !demo else { return }
        lastDiscovery = Date()
        let generation = sourceGeneration
        let sourceHome = home
        let covered = streamStatuses["local"]?.connected == true ? Set(remoteActivities.filter {
            $0.sourceHostID == nil && $0.hasLiveEvidence && [.running, .waitingForInput].contains($0.phase)
        }.compactMap(\.threadID)) : []
        localTask = Task { [weak self, reader] in
            let result = await reader.read(home: sourceHome, phaseAwareRate: true, excludingThreads: covered)
            guard let self else { return }
            defer { if generation == self.sourceGeneration { self.localTask = nil } }
            guard !Task.isCancelled, generation == self.sourceGeneration else { return }
            self.now = Date()
            self.localActivities = result.activities
            self.combineActivities()
            self.onStatusChange?()
        }
    }

    func refreshRemote() {
        guard remoteTask == nil, !sleeping, !stopped, !demo else { return }
        lastRemoteDiscovery = Date()
        let generation = sourceGeneration
        let sourceHome = home
        remoteTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.sourceGeneration { self.remoteTask = nil } }
            await self.realtimeMonitor.start(home: sourceHome, includeSSH: self.monitorsSSH) { [weak self] activities, statuses, unavailable, requests, names in
                // The monitor publishes serially. Keep that order on the UI
                // queue so a later empty snapshot cannot overtake an ending.
                DispatchQueue.main.async {
                    guard let self, generation == self.sourceGeneration, !self.stopped, !self.sleeping else { return }
                    self.receiveRemoteUpdate(activities, statuses: statuses, unavailable: unavailable, requests: requests, names: names)
                }
            }
        }
    }

    func receiveRemoteUpdate(_ activities: [SessionActivity], statuses: [String: RuntimeStreamStatus],
                             unavailable: [String], requests: [PendingAttentionRequest], names: [SessionNameUpdate]) {
        now = Date(); remoteActivities = activities
        completionInbox.updateNames(names)
        if streamStatuses != statuses { streamStatuses = statuses }
        if unavailableSSH != unavailable { unavailableSSH = unavailable }
        observeAttentionRequests(requests)
        combineActivities()
    }
    func observeAttentionRequests(_ requests: [PendingAttentionRequest]) {
        if attentionRequests != requests { attentionRequests = requests }
        present(attention.requestNotices(requests))
        // A resolved async request clears its persistent UI immediately. Its
        // tool completion alone cannot clear it because the tool is nonblocking.
        if requests.isEmpty, notice?.id.hasPrefix("request:") == true { noticeWork?.cancel(); notice = nil }
    }
    private func combineActivities() {
        let oldHeight = panelContentHeight
        let observed = completionInbox.observe(
            ActivitySourceMerger.merge(logged: localActivities, streamed: remoteActivities),
            at: now, retention: completedRetention)
        let combined = observed.filter {
            !$0.isInternalReview && ![.completed, .interrupted].contains($0.phase) &&
                ([.running, .waitingForInput].contains($0.phase) || now.timeIntervalSince($0.lastObserved ?? .distantPast) < 900)
        } + completionInbox.activities
        if activities != combined { activities = combined }
        if RuntimeDiagnostics.enabled { RuntimeDiagnostics.record("ui", source: "combined", activities: combined) }
        if oldHeight != panelContentHeight { onLayoutChange?() }
        let inputs = Set(pendingInputRequests.map { ($0.sourceHostID ?? "local") + ":" + $0.threadID })
        present(attention.activityNotices(activities, at: now).filter { notice in
            notice.kind != .waitingForInput || !inputs.contains(where: { notice.id.hasPrefix($0 + ":") })
        })
        onStatusChange?()
    }

    func applySettings(sourceChanged: Bool) {
        settingsRevision += 1
        if clock != nil { scheduleClock() }
        pruneCompletions()
        if hideProjects, let current = notice, current.kind != .lowQuota {
            notice = IslandNotice(id: current.id, kind: current.kind, title: current.title, detail: L10n.text("activity.hidden_name"))
        }
        onLayoutChange?()
        onStatusChange?()
        guard sourceChanged else { return }
        invalidateWork()
        let previous = client
        client = nil
        quota = nil
        history = QuotaCycleHistory()
        historyWarning = nil
        attention = AttentionPolicy()
        attentionRequests = []
        completionInbox = CompletionInbox()
        activities = []; localActivities = []; remoteActivities = []; unavailableSSH = []; streamStatuses = [:]
        notice = nil
        navigationError = nil
        noticeWork?.cancel()
        errorMessage = nil
        quotaCLI = nil
        failureCount = 0
        Task { [weak self, reader] in
            _ = await self?.historyStore.flush()
            await previous?.disconnect()
            await self?.realtimeMonitor.shutdown()
            await reader.reset()
            self?.refreshQuota()
            self?.refreshActivity()
            self?.refreshRemote()
        }
    }

    func shutdown() async {
        stopped = true
        clock?.invalidate()
        closeWork?.cancel()
        noticeWork?.cancel()
        invalidateWork()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        _ = await historyStore.flush()
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
        refreshing = false
    }
    private func pruneCompletions() {
        let oldHeight = panelContentHeight
        completionInbox.prune(at: now, retention: completedRetention)
        let retained = Set(completionInbox.activities.map(\.id))
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
        history.prune(at: now)
        guard !sleeping, !stopped, !demo else { return }
        let normalInterval: Double = expanded ? 30 : 120
        let interval = failureCount == 0 ? normalInterval : min(600, normalInterval * pow(2, Double(failureCount)))
        if now.timeIntervalSince(lastQuotaAttempt) >= interval { refreshQuota() }
        if now.timeIntervalSince(lastDiscovery) >= (streamStatuses["local"]?.connected == true ? 120 : 60) { refreshActivity() }
        if now.timeIntervalSince(lastRemoteDiscovery) >= 30 { refreshRemote() }
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
            case .lowQuota: return UserDefaults.standard.bool(forKey: "lowQuotaReminder")
            case .waitingForInput: return UserDefaults.standard.bool(forKey: "inputReminder")
            case .completed, .interrupted: return UserDefaults.standard.bool(forKey: "completionReminder")
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
        let observed = DemoScenario.tasks(stage: stage, at: now)
        completionInbox.observe(observed, at: now, retention: completedRetention)
        activities = observed
        var status = RuntimeStreamStatus()
        status.connected = true; status.attachedThreads = 1; status.notifications = 7 + stage.rawValue
        streamStatuses = ["local": status, "remote-ssh-discovered:demo": status]
        onLayoutChange?(); onStatusChange?()
    }
}
