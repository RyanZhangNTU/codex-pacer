import AppKit
import SwiftUI
import PacerCore

@MainActor
final class IslandModel: ObservableObject {
    @Published var quota: QuotaSnapshot?
    @Published var activities: [SessionActivity] = []
    @Published var errorMessage: String?
    @Published var refreshing = false
    @Published var expanded = false
    @Published var pinned = false
    @Published var now = Date()
    @Published var settingsRevision = 0
    var onLayoutChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onSettings: (() -> Void)?
    var notchWidth: CGFloat = 0
    var topHeight: CGFloat = 38
    private var client: CodexClient?
    private let reader = LocalActivityReader()
    private let watcher = ActivityWatcher()
    private var clock: Timer?
    private var refreshTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var closeWork: DispatchWorkItem?
    private var sleeping = false
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
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    var prefersFloating: Bool { UserDefaults.standard.bool(forKey: "floatingIsland") }
    var showInFullscreen: Bool { UserDefaults.standard.bool(forKey: "showInFullscreen") }
    var displayID: Int { UserDefaults.standard.integer(forKey: "displayID") }
    var running: [SessionActivity] { activities.filter { $0.observedPhase(at: now) == .running } }
    var stale: Bool { quota?.isStale(at: now) ?? false }
    var remaining: Double? { quota?.limitingWindow?.remainingPercent }
    var quotaSummary: String {
        guard let remaining else { return "—" }
        return "\(Int(remaining.rounded()))%"
    }
    var compactWindow: String {
        quota?.limitingWindow?.label.replacingOccurrences(of: "额度", with: "") ?? ""
    }
    var statusTitle: String {
        if !running.isEmpty { return "正在处理任务" }
        if activities.first?.observedPhase(at: now) == .completed { return "任务已结束" }
        if activities.first?.observedPhase(at: now) == .interrupted { return "任务已中断" }
        return "状态未确认"
    }
    var compactStatus: String { running.isEmpty ? statusTitle : "\(running.count) 个运行中" }
    var accent: Color {
        if errorMessage != nil || stale { return Color(red: 0.65, green: 0.68, blue: 0.73) }
        if (remaining ?? 100) <= 15 { return Color(red: 0.91, green: 0.75, blue: 0.48) }
        return Color(red: 0.56, green: 0.84, blue: 0.79)
    }
    var freshnessText: String {
        guard let quota else { return refreshing ? "正在读取额度" : "尚未读取额度" }
        let elapsed = max(0, Int(now.timeIntervalSince(quota.capturedAt)))
        if stale || errorMessage != nil { return "\(max(1, elapsed / 60)) 分钟前的额度" }
        return elapsed < 10 ? "刚刚更新" : elapsed < 60 ? "\(elapsed) 秒前更新" : "\(elapsed / 60) 分钟前更新"
    }

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            quota = try? QuotaSnapshot.decode(Data("""
            {"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":\(Date().addingTimeInterval(8280).timeIntervalSince1970)},"secondary":{"usedPercent":59,"windowDurationMins":10080,"resetsAt":\(Date().addingTimeInterval(172800).timeIntervalSince1970)}}}
            """.utf8))
            var activity = SessionActivity(id: "demo", project: "Codex Pacer")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            activity.consume(Data("{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"demo\"}}".utf8))
            activities = [activity]
            expanded = true
            pinned = true
        }
    }

    func start() {
        if !demo { refreshQuota(); refreshActivity() }
        clock = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.sourceGeneration += 1
                self.refreshing = false
                self.watcher.stop()
                self.refreshTask?.cancel()
                if let client = self.client { await client.disconnect() }
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.refreshQuota(); self.refreshActivity()
            }
        })
    }

    func setExpanded(_ value: Bool) {
        closeWork?.cancel()
        guard expanded != value else { return }
        expanded = value
        onLayoutChange?()
        if value && now.timeIntervalSince(lastQuotaAttempt) > 30 { refreshQuota() }
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
    func togglePin() { pinned.toggle(); setExpanded(true) }
    func close() { pinned = false; setExpanded(false) }

    func refreshQuota() {
        guard !refreshing, !sleeping, !demo else { return }
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
                self.quota = snapshot
                self.errorMessage = snapshot.windows.isEmpty ? "当前登录方式未返回订阅额度。请检查 Codex 账户。" : nil
                self.failureCount = 0
            } catch {
                guard !Task.isCancelled, generation == self.sourceGeneration else { return }
                self.errorMessage = (error as? CodexClientError)?.errorDescription ?? "额度读取失败，请稍后刷新。"
                self.failureCount = min(self.failureCount + 1, 4)
            }
            self.onStatusChange?()
        }
    }

    func refreshActivity() {
        guard localTask == nil, !sleeping, !demo else { return }
        lastDiscovery = Date()
        let generation = sourceGeneration
        let sourceHome = home
        localTask = Task { [weak self, reader] in
            let result = await reader.read(home: sourceHome)
            guard let self else { return }
            defer { self.localTask = nil }
            guard !Task.isCancelled, generation == self.sourceGeneration else { return }
            self.activities = result.activities.filter { Date().timeIntervalSince($0.lastObserved ?? .distantPast) < 900 }
            self.watcher.observe(result.watchURLs) { [weak self] in self?.refreshActivity() }
            self.onStatusChange?()
        }
    }

    func applySettings(sourceChanged: Bool) {
        settingsRevision += 1
        onLayoutChange?()
        guard sourceChanged else { return }
        sourceGeneration += 1
        refreshTask?.cancel()
        localTask?.cancel()
        watcher.stop()
        let previous = client
        client = nil
        quota = nil
        activities = []
        errorMessage = nil
        refreshing = false
        Task { [weak self, reader] in
            await previous?.disconnect()
            await reader.reset()
            self?.refreshQuota()
            self?.refreshActivity()
        }
    }

    func shutdown() async {
        clock?.invalidate()
        closeWork?.cancel()
        watcher.stop()
        refreshTask?.cancel()
        localTask?.cancel()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        await client?.disconnect()
    }

    private func tick() {
        now = Date()
        guard !sleeping, !demo else { return }
        let normalInterval: Double = expanded ? 30 : 120
        let interval = failureCount == 0 ? normalInterval : min(600, normalInterval * pow(2, Double(failureCount)))
        if now.timeIntervalSince(lastQuotaAttempt) >= interval { refreshQuota() }
        if now.timeIntervalSince(lastDiscovery) >= 30 { refreshActivity() }
        onStatusChange?()
    }
}

@MainActor
private final class ActivityWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounce: DispatchWorkItem?
    func observe(_ urls: [URL], onChange: @escaping () -> Void) {
        let desired = Set(urls)
        for url in Array(sources.keys) where !desired.contains(url) { sources.removeValue(forKey: url)?.cancel() }
        for url in desired where sources[url] == nil {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if let flags = self.sources[url]?.data, !flags.intersection([.rename, .delete]).isEmpty {
                    self.sources.removeValue(forKey: url)?.cancel()
                }
                self.debounce?.cancel()
                let work = DispatchWorkItem(block: onChange)
                self.debounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources[url] = source
            source.resume()
        }
    }
    func stop() {
        debounce?.cancel()
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
    }
}
