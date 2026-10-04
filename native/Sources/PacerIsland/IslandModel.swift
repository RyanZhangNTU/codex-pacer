import AppKit
import SwiftUI
import PacerCore

@MainActor
final class IslandModel: ObservableObject {
    @Published var quota: QuotaSnapshot? {
        didSet { if oldValue?.windows.count != quota?.windows.count { onLayoutChange?() } }
    }
    @Published var activities: [SessionActivity] = []
    @Published var streamStatuses: [String: RuntimeStreamStatus] = [:]
    @Published var unavailableSSH: [String] = []
    private var localActivities: [SessionActivity] = []
    private var remoteActivities: [SessionActivity] = []
    @Published var history = QuotaCycleHistory()
    @Published var historyWarning: String?
    @Published var notice: IslandNotice?
    @Published var errorMessage: String?
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
    var onOpenActivity: ((SessionActivity) -> Void)?
    var onFocusRequested: (() -> Void)?
    func canOpen(_ activity: SessionActivity) -> Bool {
        (demo || activity.threadURL != nil) && (demo || activity.sourceHostID != nil ||
            home.path == URL(fileURLWithPath: NSHomeDirectory() + "/.codex").standardizedFileURL.path)
    }
    var panelContentHeight: CGFloat {
        min(640, max(424, 286 + CGFloat(max(1, min(3, visibleActivities.count))) * 56 + CGFloat(quota?.windows.count ?? 1) * 92 + (demo ? 25 : 0)))
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
    private var sleeping = false
    private var stopped = false
    private var lastQuotaAttempt = Date.distantPast
    private var lastDiscovery = Date.distantPast
    private var failureCount = 0
    private var sourceGeneration = 0
    private var observations: [NSObjectProtocol] = []
    private let demo: Bool
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
        activities.filter {
            guard !$0.isInternalReview else { return false }
            if [.completed, .interrupted].contains($0.phase) {
                return true
            }
            return [.running, .waitingForInput, .unknown].contains($0.observedPhase(at: now)) ||
            now.timeIntervalSince($0.phaseChangedAt ?? .distantPast) < 120
        }.sorted {
            let lhs = priority($0.observedPhase(at: now)), rhs = priority($1.observedPhase(at: now))
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
    func isUnreadCompletion(_ activity: SessionActivity) -> Bool { completionInbox.isUnread(activity) }
    var completionSummary: String {
        let pending = pendingCompletions
        return pending.count == 1 ? (pending[0].phase == .interrupted ? "本轮中断" : "本轮结束") : "\(pending.count) 轮结束"
    }
    func openCompletionOrPin() {
        if let activity = pendingCompletions.first, canOpen(activity) { open(activity) }
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
        UserDefaults.standard.string(forKey: "compactMetric") == "pace" ? "配速" :
        (selectedWindow?.label.replacingOccurrences(of: "额度", with: "") ?? "")
    }
    var statusTitle: String { overview.title }
    var compactStatus: String {
        if let notice, ![.completed, .interrupted].contains(notice.kind) { return notice.title }
        return overview.compactTitle
    }
    var rate: Double? { overview.displayedRate }
    var rateIsFresh: Bool { overview.rateIsFresh }
    var showsRate: Bool { !running.isEmpty }
    var rateText: String { rate.map { String(format: "%.1f", $0) } ?? (showsRate ? "采样中" : "—") }
    var monitorsSSH: Bool { UserDefaults.standard.object(forKey: "monitorSSH") == nil || UserDefaults.standard.bool(forKey: "monitorSSH") }
    var accent: Color {
        if !waiting.isEmpty || notice != nil { return Color(red: 0.91, green: 0.75, blue: 0.48) }
        if errorMessage != nil || stale { return Color(red: 0.65, green: 0.68, blue: 0.73) }
        if (remaining ?? 100) <= 15 { return Color(red: 0.91, green: 0.75, blue: 0.48) }
        return Color(red: 0.56, green: 0.84, blue: 0.79)
    }
    var freshnessText: String {
        guard let quota else { return refreshing ? "正在读取额度" : "尚未读取额度" }
        if selectedWindow?.resetsAt.map({ $0 <= now }) == true { return "窗口已到期，等待更新" }
        let elapsed = max(0, Int(now.timeIntervalSince(quota.capturedAt)))
        if stale || errorMessage != nil { return "\(max(1, elapsed / 60)) 分钟前的额度" }
        return elapsed < 10 ? "刚刚更新" : elapsed < 60 ? "\(elapsed) 秒前更新" : "\(elapsed / 60) 分钟前更新"
    }
    func projectName(_ activity: SessionActivity) -> String {
        hideProjects ? "Codex 任务" : (activity.title ?? activity.project)
    }

    init(demo: Bool = false, initiallyExpanded: Bool = false) {
        self.demo = demo
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
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.invalidateWork()
                await self.realtimeMonitor.shutdown()
                if let client = self.client { await client.disconnect() }
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.now = Date()
                self.refreshQuota(); self.refreshActivity(); self.refreshRemote()
            }
        })
    }
    func setExpanded(_ value: Bool) {
        closeWork?.cancel()
        guard expanded != value else { return }
        expanded = value
        if clock != nil { scheduleClock() }
        onLayoutChange?()
        if value && Date().timeIntervalSince(lastQuotaAttempt) > 30 { refreshQuota() }
    }
    func hover(_ entered: Bool) {
        closeWork?.cancel()
        if entered { setExpanded(true) }
        else if !pinned {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
    func togglePin() { pinned.toggle(); setExpanded(true); if pinned { onFocusRequested?() } }
    func close() { pinned = false; setExpanded(false) }
    func open(_ activity: SessionActivity) {
        guard canOpen(activity) else { return }
        completionInbox.dismiss(activity)
        activities.removeAll { $0.id == activity.id && [.completed, .interrupted].contains($0.phase) }
        if notice?.id.hasPrefix(activity.id + ":") == true { noticeWork?.cancel(); notice = nil }
        onLayoutChange?(); onStatusChange?()
        onOpenActivity?(activity)
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
                    guard let executable = CodexClient.findExecutable(customPath: custom) else { throw CodexClientError.missingExecutable }
                    self.client = CodexClient(executable: executable, home: sourceHome)
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
                self.errorMessage = snapshot.windows.isEmpty ? "当前登录方式未返回订阅额度。请检查 Codex 账户。" : nil
                self.failureCount = 0
                self.now = Date()
                if snapshot.accountScope == nil {
                    self.historyWarning = "账户标识暂不可用，曲线尚未开始记录。"
                } else {
                    let saved = await self.historyStore.save(home: sourceHome, snapshot: snapshot, history: self.history)
                    guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                    self.historyWarning = saved ? nil : "曲线暂未保存，退出后可能丢失。"
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
                self.errorMessage = (error as? CodexClientError)?.errorDescription ?? "额度读取失败，请稍后刷新。"
                self.failureCount = min(self.failureCount + 1, 4)
            }
            self.onStatusChange?()
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
            await self.realtimeMonitor.start(home: sourceHome, includeSSH: self.monitorsSSH) { [weak self] activities, statuses, unavailable in
                Task { @MainActor in
                    guard let self, generation == self.sourceGeneration, !self.stopped, !self.sleeping else { return }
                    self.now = Date(); self.remoteActivities = activities; self.streamStatuses = statuses
                    self.unavailableSSH = unavailable; self.combineActivities()
                }
            }
        }
    }
    private func combineActivities() {
        let oldHeight = panelContentHeight
        let observed = ActivitySourceMerger.merge(logged: localActivities, streamed: remoteActivities)
        completionInbox.observe(observed, at: now, retention: completedRetention)
        activities = observed.filter {
            !$0.isInternalReview && ![.completed, .interrupted].contains($0.phase) &&
                ([.running, .waitingForInput].contains($0.phase) || now.timeIntervalSince($0.lastObserved ?? .distantPast) < 900)
        } + completionInbox.activities
        if oldHeight != panelContentHeight { onLayoutChange?() }
        present(attention.activityNotices(activities, at: now))
        onStatusChange?()
    }

    func applySettings(sourceChanged: Bool) {
        settingsRevision += 1
        if clock != nil { scheduleClock() }
        pruneCompletions()
        if hideProjects, let current = notice, current.kind != .lowQuota {
            notice = IslandNotice(id: current.id, kind: current.kind, title: current.title, detail: "Codex 任务")
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
        completionInbox = CompletionInbox()
        activities = []; localActivities = []; remoteActivities = []; unavailableSSH = []; streamStatuses = [:]
        notice = nil
        noticeWork?.cancel()
        errorMessage = nil
        failureCount = 0
        Task { [weak self, reader] in
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
        await realtimeMonitor.shutdown()
        await client?.shutdown()
    }

    private func invalidateWork() {
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
            IslandNotice(id: newest.id, kind: newest.kind, title: newest.title, detail: "Codex 任务") : newest
        notifications.deliver(visible)
        noticeWork?.cancel()
        if [.completed, .interrupted].contains(visible.kind) {
            notice = nil
            return
        }
        notice = visible
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
        now = Date()
        let observed = DemoScenario.tasks(stage: stage, at: now)
        completionInbox.observe(observed, at: now, retention: completedRetention)
        activities = observed
        var status = RuntimeStreamStatus()
        status.connected = true; status.attachedThreads = 1; status.notifications = 7 + stage.rawValue
        streamStatuses = ["local": status, "remote-ssh-discovered:demo": status]
        onLayoutChange?(); onStatusChange?()
    }
}
