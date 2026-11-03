import Foundation
#if os(Windows)
import CWindowsSupport
#endif

public enum PacerEngine {
    public static func run() async {
        WindowsResources.configure()
        #if os(Windows)
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-desktop-runtime") {
            let report = WindowsDesktopDiagnostic()
            if CommandLine.arguments.indices.contains(index + 2), let thread = UUID(uuidString: CommandLine.arguments[index + 2])?.uuidString.lowercased() {
                let collector = WindowsDesktopCollector(home: URL(fileURLWithPath: CommandLine.arguments[index + 1]), interval: 1,
                    onFrame: { await report.consume($0, thread: thread) }, onClosed: { await report.close() })
                await collector.discover([thread]); await collector.start()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await collector.stop()
            }
            let value = await report.result()
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-desktop-owners") {
            var report: [String: Any] = ["peerVerified": false, "ownershipAvailable": false, "writerCount": 0, "writerInPeerTree": false,
                                         "fileContentRead": false, "sentBytes": 0]
            if CommandLine.arguments.indices.contains(index + 2) {
                let home = URL(fileURLWithPath: CommandLine.arguments[index + 1]), file = URL(fileURLWithPath: CommandLine.arguments[index + 2])
                do {
                    let transport = try WindowsDesktopTransport.connectCodex()
                    defer { transport.cancel() }
                    if let peer = transport.peerIdentity {
                        report["peerVerified"] = true
                        if let owners = WindowsProcessOwnership.writers(of: file, within: home) {
                            report["ownershipAvailable"] = true; report["writerCount"] = owners.count
                            report["writerInPeerTree"] = owners.contains { WindowsProcessOwnership.isDescendant($0, of: peer) }
                        }
                    }
                } catch { report["failure"] = "unavailable" }
            } else { report["failure"] = "invalidArguments" }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-desktop-transport") {
            var report: [String: Any] = ["transportReady": false, "peerVerified": false, "sentBytes": 0, "taskDataRead": false, "initialized": false]
            do {
                let transport = try WindowsDesktopTransport.connectCodex()
                transport.cancel(); report["transportReady"] = true; report["peerVerified"] = true
            } catch WindowsDesktopTransport.Failure.identityMismatch { report["failure"] = "identityMismatch" }
            catch { report["failure"] = "unavailable" }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--diagnose-installation") {
            let found = ProviderInstallationDetection.detect()
            if let data = try? JSONSerialization.data(withJSONObject: ["codex": found.codexInstalled,
                "claude": found.claudeInstalled, "deepseek": found.deepseekInstalled], options: .sortedKeys) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--language"), CommandLine.arguments.indices.contains(index + 1),
           let language = AppLanguage(rawValue: CommandLine.arguments[index + 1]) {
            // The host's explicit language wins for this process, including
            // over a previous engine preference, without writing that domain.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[LanguagePreference.defaultsKey] = language.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let demo = CommandLine.arguments.contains("--demo")
        let readOnly = CommandLine.arguments.contains("--read-only-diagnostics")
        let quotaDiagnostics = readOnly && CommandLine.arguments.contains("--quota-diagnostics")
        defer { if quotaDiagnostics { QuotaReadDiagnostics.shared.report() } }
        let reference = demo && CommandLine.arguments.contains("--reference-fixture")
        let claudeReference = CommandLine.arguments.contains("--claude-web-fixture")
        guard !claudeReference || reference else { return }
        if reference { NSTimeZone.default = TimeZone(secondsFromGMT: 0)! }
        let clock: @Sendable () -> Date = { reference ? Date(timeIntervalSince1970: 1_800_000_000) : Date() }
        var notificationStore: EngineNotificationRegistry.Store? = demo || readOnly ? nil : .applicationDefault
        if let index = CommandLine.arguments.firstIndex(of: "--notification-qa") {
            guard reference, CommandLine.arguments.indices.contains(index + 1), let qa = UUID(uuidString: CommandLine.arguments[index + 1]) else { return }
            notificationStore = .init(url: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("notification-qa-" + qa.uuidString.lowercased())
                .appendingPathComponent("actions.json"), files: WindowsFileSystem())
        }
        var hookServices: EngineClaudeHookServices?
        if !demo && !readOnly, CommandLine.arguments.contains("--manage-claude-hooks"),
           let index = CommandLine.arguments.firstIndex(of: "--claude-runtime-root"), CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            if path.utf16.count < 16000, WindowsCodexExecutableDiscovery.absolute(path), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                hookServices = .live(root: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        let runtime = EngineRuntime(demo: demo, now: clock,
            dismissalStore: readOnly ? nil : .applicationDefault,
            notificationStore: notificationStore,
            quotaServices: demo ? nil : readOnly ? (quotaDiagnostics ? .readOnlyDiagnostics : nil) : .live, desktopServices: demo ? nil : .platformLive,
            balanceServices: readOnly ? (quotaDiagnostics ? .readOnlyDiagnostics : nil) : demo ? .demo(now: clock) : .live,
            claudeServices: quotaDiagnostics ? .readOnlyDiagnostics : nil,
            allowsLiveClaudeWeb: !demo && !readOnly, claudeWebReference: claudeReference, claudeHookServices: hookServices)
        await runtime.hello()
        let input = EngineInput()
        var framer = EngineFramer()
        do {
            while let bytes = try await input.next() {
                for frame in try framer.append(bytes) {
                    if let command = try? EngineCommand.decode(frame), command.method == "shutdown" {
                        await ShutdownDeadline().perform([{
                            _ = await runtime.receive(frame)
                            await runtime.stop()
                        }])
                        WindowsOwnedProcesses.terminateForEngineExit()
                        return
                    }
                    if !(await runtime.enqueue(frame)) {
                        await ShutdownDeadline().perform([{ await runtime.stop() }])
                        WindowsOwnedProcesses.terminateForEngineExit()
                        return
                    }
                }
            }
            if let final = try framer.finish() { _ = await runtime.receive(final) }
        } catch { await runtime.failure(id: nil, code: "invalidFrame") }
        await ShutdownDeadline().perform([{ await runtime.stop() }])
        WindowsOwnedProcesses.terminateForEngineExit()
    }
}

#if os(Windows)
private actor WindowsDesktopDiagnostic {
    private var initialized = false, bound = false, runtime = false, closed = false
    private var events = 0, requests = 0
    func consume(_ bytes: Data, thread: String) {
        guard let row = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        if row["kind"] as? String == "status", row["connected"] as? Bool == true { initialized = true }
        if row["kind"] as? String == "runtimeBatch", let rows = row["events"] as? [[String: Any]] {
            for event in rows where event["threadId"] as? String == thread {
                bound = true; events += 1
                if !["metadata", "stream/released"].contains(event["method"] as? String ?? "") { runtime = true }
            }
        }
        if row["kind"] as? String == "attention", row["threadId"] as? String == thread,
           let rows = row["requests"] as? [[String: String]] { requests += rows.count; if !rows.isEmpty { bound = true } }
    }
    func close() { closed = true }
    func result() -> [String: Any] {
        ["initialized": initialized, "sourceBound": bound, "runtimeEvidence": runtime,
         "eventCount": events, "requestCount": requests, "closed": closed,
         "conversationTextRetained": false, "taskMutationSent": false]
    }
}
#endif

private final class EngineInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.codexpacer.windows.host-input", qos: .utility)
    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    #if os(Windows)
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = pacer_read_stdin(&buffer, buffer.count)
                    guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
                    continuation.resume(returning: count == 0 ? nil : Data(buffer.prefix(Int(count))))
                    #else
                    let bytes = try FileHandle.standardInput.read(upToCount: 4096)
                    continuation.resume(returning: bytes?.isEmpty == false ? bytes : nil)
                    #endif
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

actor EngineRuntime {
    private let demo: Bool
    private let now: @Sendable () -> Date
    private var stage = DemoTaskStage.thinking
    private var initialized = false
    private let claudeHookServices: EngineClaudeHookServices?
    private var claudeHookSetup: EngineClaudeHookSetup?
    private var claudeHookTask: Task<Void, Never>? {
        get { ownedWork.task(.init(.setup, provider: .claude, identifier: "hooks")) }
        set { setOwnedTask(newValue, key: .init(.setup, provider: .claude, identifier: "hooks")) }
    }
    private var claudeHookHome: URL?, claudeHookRequest: UUID?
    private var claudeHooksEnabled = false
    private var expanded = false
    private var projectionReady = false
    private var lifecycle = ApplicationLifecycleCoordinator()
    private var generation: UInt64 { lifecycle.revision }
    private var active: Bool { initialized && lifecycle.acceptsObservedWork }
    private var lastCodexDiscovery = Date.distantPast, lastRemoteDiscovery = Date.distantPast, lastClaudeDiscovery = Date.distantPast
    private var sequence: UInt64 = 0
    private var snapshotEmission = EngineSnapshotEmission()
    private var hideProjects = false
    private var showEmbeddedCodexSessions = true
    private var showClaudeCloudProjects = true
    private var deepseekSettings = EngineDeepSeekSettings()
    private var reminderSettings = EngineReminderSettings()
    private var deepseekNoticePolicy = DeepSeekNoticePolicy()
    private var spikeSnoozedUntil = Date.distantPast
    private var retention: TimeInterval = 30 * 60
    private var enabled = Set(AgentProvider.allCases)
    private var moduleSettings = ProviderModules()
    private var moduleConfigurationActive = false
    private var installation: ProviderInstallationDetection?
    private let detectInstallation: @Sendable () async -> ProviderInstallationDetection
    private var codexHome: URL
    private let defaultCodexHome: URL
    private var codexExecutable = ""
    private var claudeHome: URL
    private let defaultClaudeHome: URL
    private var deepseekHome: URL
    private let defaultDeepseekHome: URL
    private let sourceSettings: CodexSourceSettingsServices
    private var codexReader = LocalActivityReader(fileMetadata: { WindowsFileSystem().metadata($0) })
    private var navigation = ActivityNavigationRegistry()
    private var notificationNavigation = ActivityNavigationRegistry()
    private var notificationActivities: [SessionActivity] = []
    private var notificationRegistry: EngineNotificationRegistry
    private let navigationServices: ActivityNavigationServices
    private struct LocalActivitySnapshot {
        var activities: [SessionActivity] = []
        var requests: [PendingAttentionRequest] = []
        var available = false
    }
    private lazy var claudeActivityMonitor = ClaudeActivityMonitor(clock: now)
    private lazy var deepseekActivityMonitor = DeepSeekActivityMonitor(clock: now)
    private var claudeLocal = LocalActivitySnapshot(), deepseekLocal = LocalActivitySnapshot()
    private var deepseekUsage = DeepSeekLocalUsage()
    private var activityState = ActivityApplicationState()
    private var inbox: CompletionInbox { get { activityState.inbox } set { activityState.inbox = newValue } }
    private var policy: AttentionPolicy { get { activityState.codexAttention } set { activityState.codexAttention = newValue } }
    private var activities: [SessionActivity] { get { activityState.activities } set { activityState.replaceActivities(newValue, at: now()) } }
    private var requests: [PendingAttentionRequest] { get { activityState.requests } set { activityState.replacePendingRequests(newValue) } }
    private var activityDisplayTask: Task<Void, Never>? {
        get { ownedWork.task(.init(.displayExpiry)) }
        set { setOwnedTask(newValue, key: .init(.displayExpiry)) }
    }
    private var activityDisplayDeadline: Date?
    private var navigationState = ActivityNavigationState()
    private var navigationOpens: [String: ActivityNavigationOperation] = [:]
    private var navigationFailureTask: Task<Void, Never>? {
        get { ownedWork.task(.init(.navigationError)) }
        set { setOwnedTask(newValue, key: .init(.navigationError)) }
    }
    private var ownedWork: ApplicationWorkRegistry { get { lifecycle.work } set { lifecycle.work = newValue } }
    private var hostTracking = HostApplicationTrackingState<ActivityHostApplication>()
    private let activityHostServices: ActivityHostServices
    private let navigationClock: @Sendable () -> TimeInterval
    private let navigationErrorDuration: TimeInterval
    private var sources: [EngineSource] = []
    private var loggedActivities: [SessionActivity] = []
    private var loggedRequests: [PendingAttentionRequest] = []
    private var loggedSources: [EngineSource] = []
    private let desktopServices: CodexDesktopServices?
    private var desktopState: CodexDesktopState?
    private var pendingDesktopEndings: [String: SessionActivity] { get { activityState.pendingCodexEndings } set { activityState.pendingCodexEndings = newValue } }
    private var latestFirstOutput: (at: Date, seconds: Double)? { activityState.latestFirstOutput }
    private lazy var desktopMonitor: RealtimeActivityMonitor? = desktopServices?.makeMonitor()
    private var quota: [AgentProvider: QuotaSnapshot] = [:]
    private var codexQuota: QuotaSnapshot?
    private var codexQuotaState: CodexQuotaState?
    private var codexQuotaFailed = false
    private var codexQuotaRefreshing = false
    private var codexHistory = EngineQuotaHistory()
    private var quotaSource: EngineSource?
    private let quotaServices: CodexQuotaServices?
    private lazy var quotaMonitor: CodexQuotaMonitor? = quotaServices.map { services in
        CodexQuotaMonitor(services: services, now: now) { [weak self] state in await self?.receiveQuota(state) }
    }
    private var walletSource: EngineWalletSource?
    private let balanceServices: DeepSeekBalanceServices?
    private var balanceState: DeepSeekBalanceState?
    private var webHostPublication = DeepSeekWebHostPublication()
    private var publishedBalanceContext: String?
    private lazy var balanceMonitor: DeepSeekBalanceMonitor? = balanceServices.map { services in
        DeepSeekBalanceMonitor(services: services, now: now) { [weak self] state in await self?.receiveBalance(state) }
    }
    private lazy var webBridge = DeepSeekWebBridge(now: now) { [weak self] message in await self?.sendWebHostMessage(message) }
    private let claudeServices: ClaudeQuotaServices?
    private let allowsLiveClaudeWeb: Bool
    private let claudeWebReference: Bool
    private var usesClaudeWeb: Bool { !demo || claudeWebReference }
    private var claudeOrganization = "", claudeWebPaused = false
    private var claudeQuotaState: ClaudeQuotaState?
    private var claudeHistory = EngineQuotaHistory()
    private var claudeQuotaAttention = AttentionPolicy()
    private let cloudServices: ClaudeCloudServices?
    private let cloudLocalSessions = ClaudeCloudLocalSessions()
    private var cloudWebAvailable = false
    private var deepseekWebAvailable = false
    private var cloudState: ClaudeCloudState?
    private lazy var claudeWebBridge = ClaudeWebBridge { [weak self] message in await self?.sendClaudeHostMessage(message) }
    private var effectiveClaudeServices: ClaudeQuotaServices? {
        claudeServices ?? (claudeWebReference ? .reference(bridge: claudeWebBridge, now: now) : allowsLiveClaudeWeb ? .live(bridge: claudeWebBridge) : nil)
    }
    private lazy var claudeQuotaMonitor: ClaudeQuotaMonitor? = {
        let services = effectiveClaudeServices
        return services.map { services in
            ClaudeQuotaMonitor(services: services, now: now) { [weak self] state in await self?.receiveClaudeQuota(state) }
        }
    }()
    private lazy var claudeCloudMonitor: ClaudeCloudMonitor? = {
        let services = cloudServices ?? (claudeWebReference ? .reference(bridge: claudeWebBridge, now: now) : allowsLiveClaudeWeb ? .live(bridge: claudeWebBridge) : nil)
        let local = cloudLocalSessions
        return services.map { services in
            ClaudeCloudMonitor(services: services, localSessions: { local.snapshot() }) { [weak self] state in
                await self?.receiveClaudeCloud(state)
            }
        }
    }()
    private var maintenance: Task<Void, Never>? {
        get { ownedWork.task(.init(.maintenance)) }
        set { setOwnedTask(newValue, key: .init(.maintenance)) }
    }
    private var presentationClock: Task<Void, Never>? {
        get { ownedWork.task(.init(.presentation)) }
        set { setOwnedTask(newValue, key: .init(.presentation)) }
    }
    private var refreshTask: Task<Void, Never>? { ownedWork.task(.init(.activity)) }
    private var refreshRequested = false
    private var discoveryRequested = false
    private var refreshActivityMonitorsRequested = false
    private var forceBalanceRequested = false
    #if os(Windows)
    private lazy var logWatcher = ActivityLogWatcher { [weak self] discover in
        Task { await self?.refresh(discover: discover, refreshActivityMonitors: false) }
    }
    #endif
    private let output: @Sendable (Data) -> Void

    init(demo: Bool, now: @escaping @Sendable () -> Date = { Date() },
         dismissalStore: CompletionDismissalStore? = .applicationDefault,
         notificationStore: EngineNotificationRegistry.Store? = nil,
         quotaServices: CodexQuotaServices? = nil,
         desktopServices: CodexDesktopServices? = nil,
         balanceServices: DeepSeekBalanceServices? = nil,
         claudeServices: ClaudeQuotaServices? = nil,
         cloudServices: ClaudeCloudServices? = nil,
         navigationServices: ActivityNavigationServices? = nil,
         navigationClock: @escaping @Sendable () -> TimeInterval = { ActivityNavigationState.monotonicNow },
         navigationErrorDuration: TimeInterval = TaskRowInteraction.navigationErrorDuration,
         activityHostServices: ActivityHostServices = .live,
         allowsLiveClaudeWeb: Bool = false,
         claudeWebReference: Bool = false,
         claudeHookServices: EngineClaudeHookServices? = nil,
         sourceSettings: CodexSourceSettingsServices = .live,
         installationDetection: @escaping @Sendable () async -> ProviderInstallationDetection = {
             await Task.detached(priority: .utility) { ProviderInstallationDetection.detect() }.value
         },
         output: @escaping @Sendable (Data) -> Void = { try? FileHandle.standardOutput.write(contentsOf: $0) }) {
        self.demo = demo; self.now = now; self.output = output; self.quotaServices = quotaServices; self.desktopServices = desktopServices
        self.sourceSettings = sourceSettings
        self.balanceServices = balanceServices
        self.claudeServices = claudeServices; self.allowsLiveClaudeWeb = allowsLiveClaudeWeb
        self.cloudServices = cloudServices
        self.navigationServices = navigationServices ?? (demo ? .demo : .live)
        self.navigationClock = navigationClock; self.navigationErrorDuration = navigationErrorDuration
        self.activityHostServices = activityHostServices
        self.claudeWebReference = claudeWebReference && demo
        self.claudeHookServices = claudeHookServices
        self.detectInstallation = installationDetection
        self.activityState = ActivityApplicationState(inbox: CompletionInbox(dismissalStore: demo ? nil : dismissalStore))
        self.notificationRegistry = .init(store: notificationStore, now: now())
        #if os(Windows)
        let demoHome = URL(fileURLWithPath: "C:/Users/Demo", isDirectory: true)
        #else
        let demoHome = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        #endif
        let home = demo ? demoHome : FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        func inherited(_ name: String) -> URL? {
            guard !demo else { return nil }
            #if os(Windows)
            return WindowsEnvironment.value(name, in: environment).map { URL(fileURLWithPath: $0) }
            #else
            return environment[name].map { URL(fileURLWithPath: $0) }
            #endif
        }
        defaultCodexHome = inherited("CODEX_HOME") ?? home.appendingPathComponent(".codex")
        defaultClaudeHome = inherited("CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude")
        defaultDeepseekHome = inherited("DSH_HOME") ?? home.appendingPathComponent(".dsh")
        codexHome = defaultCodexHome; claudeHome = defaultClaudeHome; deepseekHome = defaultDeepseekHome
        lifecycle = ApplicationLifecycleCoordinator(demo: demo, configuration: .init(enabled: enabled,
            sources: [.codex: codexHome.path, .claude: claudeHome.path, .deepseek: deepseekHome.path]))
    }

    func hello() {
        send(["protocolVersion": EngineProtocol.version, "type": "hello", "engine": "PacerEngine"])
    }

    private func setOwnedTask(_ task: Task<Void, Never>?, key: ApplicationWorkRegistry.Key) {
        guard let task else { ownedWork.cancel(key); return }
        let owner = ownedWork.begin(key, version: key.provider.map { lifecycle.version($0) } ?? generation)
        ownedWork.attach(task, to: owner)
    }

    /// A slow host resolver must not hold the input loop ahead of sleep,
    /// source replacement or shutdown. The actor and registry still serialize
    /// ownership; only the platform lookup can remain suspended.
    func enqueue(_ data: Data) async -> Bool {
        guard let command = try? EngineCommand.decode(data), command.method == "prepareActivityOpen" else { return await receive(data) }
        let key = ApplicationWorkRegistry.Key(.navigation, identifier: command.id)
        let owner = ownedWork.begin(key, version: generation)
        let task = Task { [weak self] in
            _ = await self?.receive(data)
            await self?.finishOwnedWork(owner)
        }
        ownedWork.attach(task, to: owner)
        return true
    }
    private func finishOwnedWork(_ owner: ApplicationWorkRegistry.Ticket) { ownedWork.finish(owner) }

    func receive(_ data: Data) async -> Bool {
        let command: EngineCommand
        do { command = try EngineCommand.decode(data) }
        catch { failure(id: EngineCommand.correlationID(data), code: "invalidCommand"); return true }
        guard initialized || command.method == "initialize" || command.method == "shutdown" else {
            failure(id: command.id, code: "initializeRequired"); return true
        }
        guard !lifecycle.isStopped || command.method == "shutdown" else {
            failure(id: command.id, code: "unavailable"); return true
        }
        if EngineShellProjection.methods.contains(command.method) {
            if let bytes = EngineShellProjection.reply(command) { output(bytes + Data([10])) }
            else { failure(id: command.id, code: "invalidPresentation") }
            return true
        }
        switch command.method {
        case "activateNotification":
            guard projectionReady, let reference = command.params?.context, let kind = command.params?.notificationAction,
                  let saved = notificationRegistry.record(reference, at: now()), saved.kind == kind else {
                failure(id: command.id, code: "staleNotification"); return true
            }
            let entry = saved.target.flatMap { target in notificationNavigation.entries.values.first { EngineNotificationRegistry.target($0) == target } }
            guard kind != "openTask" || entry.map(navigationIsCurrent) == true,
                  notificationRegistry.consume(reference, source: notificationSource(saved.provider, scope: saved.scope), kind: kind, at: now()) != nil else {
                failure(id: command.id, code: "staleNotification"); return true
            }
            if kind == "snoozeSpike" { spikeSnoozedUntil = now().addingTimeInterval(3600); publish(notices: []) }
            struct Result: Encodable {
                let protocolVersion = EngineProtocol.version, type = "result", ok = true
                let id: String, value: EngineNotificationActivation
            }
            if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: .init(kind: kind, link: entry?.link))) { output(bytes + Data([10])) }
            return true
        case "prepareActivityOpen":
            guard let context = command.params?.context, context.utf8.count <= 128,
                  let entry = navigationEntry(context: context), navigationIsCurrent(entry) else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            guard let operation = navigationState.begin(activity: entry.activity, target: entry.target, version: lifecycle.version(entry.target.provider),
                activities: activities, inbox: inbox, active: active, scope: entry.cloudContext) else {
                failure(id: command.id, code: "navigationInProgress"); return true
            }
            navigationOpens[context] = operation
            scheduleNavigationFailure()
            var prepared = false
            defer {
                if !prepared {
                    navigationState.abandon(operation)
                    if navigationOpens[context]?.id == operation.id { navigationOpens.removeValue(forKey: context) }
                }
            }
            publish(notices: [])
            let target = entry.target, home = navigationHome(for: entry.target.provider)
            var transcript = target.rolloutURL
            #if os(Windows)
            if target.provider == .claude {
                transcript = await claudeActivityMonitor.transcriptURL(for: target.threadID ?? "")
                if transcript == nil {
                    for member in entry.members {
                        if let thread = member.thread, let url = await claudeActivityMonitor.transcriptURL(for: thread) { transcript = url; break }
                    }
                }
            }
            #endif
            do {
                var input = ActivityNavigationServices.Input(context: context, activity: target, home: home, transcript: transcript)
                input.cachedHost = hostTracking.application(for: target, activities: activities, inbox: inbox)
                let plan = try await navigationServices.resolve(input)
                guard navigationIsCurrent(entry), navigationState.owns(operation), operation.isCurrent(version: lifecycle.version(target.provider), active: active, inbox: inbox, scope: entry.cloudContext),
                      home == navigationHome(for: target.provider),
                      plan.context == context, plan.provider == target.provider.rawValue else {
                    failure(id: command.id, code: "staleActivityOpen"); return true
                }
                struct Result: Encodable {
                    let protocolVersion = EngineProtocol.version, type = "result", ok = true
                    let id: String, value: EngineNavigationPlan
                }
                if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: plan)), bytes.count < 8192 {
                    output(bytes + Data([10])); prepared = true
                }
                else { failure(id: command.id, code: "navigationUnavailable") }
            } catch ActivityNavigationError.missingClaudeHost { failure(id: command.id, code: "missingClaudeHost") }
              catch ActivityNavigationError.missingCodexHost { failure(id: command.id, code: "missingCodexHost") }
              catch { failure(id: command.id, code: "navigationUnavailable") }
            return true
        case "completeActivityOpen":
            guard let context = command.params?.context, let entry = navigationEntry(context: context), navigationIsCurrent(entry),
                  let operation = navigationOpens.removeValue(forKey: context) else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            var values = activities, retained = inbox
            guard let result = navigationState.complete(operation, outcome: .openedConversation, version: lifecycle.version(entry.target.provider), active: active,
                activities: &values, inbox: &retained, scope: entry.cloudContext, now: navigationClock()), result.accepted else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            inbox = retained; activities = values
            publish(notices: [])
        case "cancelActivityOpen":
            if let context = command.params?.context, let operation = navigationOpens.removeValue(forKey: context) {
                navigationState.abandon(operation); publish(notices: [])
            }
        case "failActivityOpen", "showNavigationError":
            guard let message = command.params?.navigationMessage, message.utf8.count <= 4096 else {
                failure(id: command.id, code: "invalidCommand"); return true
            }
            if command.method == "failActivityOpen" {
                guard let context = command.params?.context, let entry = navigationEntry(context: context), navigationIsCurrent(entry) else {
                    failure(id: command.id, code: "staleActivityOpen"); return true
                }
                if let operation = navigationOpens.removeValue(forKey: context) {
                    var values = activities, retained = inbox
                    guard let result = navigationState.complete(operation, outcome: .failed(message), version: lifecycle.version(entry.target.provider), active: active,
                        activities: &values, inbox: &retained, scope: entry.cloudContext, now: navigationClock(), errorDuration: navigationErrorDuration), result.accepted else {
                        failure(id: command.id, code: "staleActivityOpen"); return true
                    }
                } else { navigationState.showFailure(message, now: navigationClock(), duration: navigationErrorDuration) }
            } else { navigationState.showFailure(message, now: navigationClock(), duration: navigationErrorDuration) }
            scheduleNavigationFailure()
            publish(notices: [])
        case "inspectClaudeLocalState":
            struct Result: Encodable {
                let protocolVersion = EngineProtocol.version, type = "result", ok = true
                let id: String
                let value: [String: [String: Int]]
            }
            func counts(_ values: [SessionActivity]) -> [String: Int] {
                Dictionary(grouping: values.filter { $0.provider == .claude && $0.claudeCloud == nil }, by: { $0.phase.rawValue }).mapValues(\.count)
            }
            let rows = claudeLocal.activities
            var isolated = CompletionInbox(dismissalStore: nil)
            _ = isolated.observe(rows, at: now(), retention: retention)
            let timing = ["missingEnd": rows.filter { $0.phaseChangedAt == nil }.count,
                "futureEnd": rows.filter { $0.phaseChangedAt.map { now().timeIntervalSince($0) < -0.001 } == true }.count,
                "outsideRetention": rows.filter { $0.phaseChangedAt.map { now().timeIntervalSince($0) >= retention } == true }.count,
                "internalReview": rows.filter(\.isInternalReview).count]
            let value = ["reader": counts(rows), "retained": counts(inbox.activities), "projected": counts(activities),
                "isolatedRetention": counts(isolated.activities), "timing": timing]
            if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: value)) { output(bytes + Data([10])) }
            return true
        case "setClaudeWebHost":
            guard let available = command.params?.webAvailable, usesClaudeWeb, claudeQuotaMonitor != nil || claudeCloudMonitor != nil else {
                failure(id: command.id, code: "unavailable"); return true
            }
            cloudWebAvailable = available
            await claudeWebBridge.setAvailable(available); await claudeQuotaMonitor?.setWebAvailable(available)
            await bindClaudeCloudMonitor(); await claudeCloudMonitor?.startAfterPublication()
            _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded, force: true)
        case "claudeWebResult":
            guard usesClaudeWeb, let id = command.params?.requestID, let context = command.params?.context, let reply = command.params?.claudeSession,
                  await claudeWebBridge.complete(id: id, context: context, reply: reply) else {
                failure(id: command.id, code: "staleWebReply"); return true
            }
        case "inspectClaudeAccount":
            guard let monitor = claudeQuotaMonitor, usesClaudeWeb else { failure(id: command.id, code: "unavailable"); return true }
            let state = await monitor.currentState()
            struct Result: Encodable {
                let protocolVersion = EngineProtocol.version, type = "result", ok = true
                let id: String; let value: EngineClaudeAccountReport
            }
            if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: .init(state, selected: claudeOrganization))), bytes.count <= EngineProtocol.maximumSnapshotBytes {
                output(bytes + Data([10]))
            } else { failure(id: command.id, code: "sourceReportLimit") }
            return true
        case "pauseClaudeConnection", "resetClaudeConnection":
            guard usesClaudeWeb, let monitor = claudeQuotaMonitor, let expected = command.params?.context else {
                failure(id: command.id, code: "unavailable"); return true
            }
            let state = await monitor.currentState()
            guard state.connectionContext == expected else { failure(id: command.id, code: "staleContext"); return true }
            claudeWebPaused = command.method == "pauseClaudeConnection"
            await bindClaudeCloudMonitor(reset: true)
            await monitor.configure(home: claudeHome, organization: claudeOrganization,
                enabled: usesClaudeWeb && enabled.contains(.claude) && !claudeWebPaused, context: lifecycle.version(.claude), reset: true)
            await claudeCloudMonitor?.startAfterPublication()
            _ = await monitor.refreshIfDue(expanded: expanded, force: true)
        case "inspectProviderHome":
            guard let name = command.params?.provider, let provider = AgentProvider(rawValue: name),
                  provider == .claude || provider == .deepseek else { failure(id: command.id, code: "invalidCommand"); return true }
            let home = command.params?.sourceHome ?? EngineCodexSourceReport.path(provider == .claude ? claudeHome : deepseekHome)
            guard home.utf8.count <= 32768, !home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                failure(id: command.id, code: "invalidCommand"); return true
            }
            let fallback = provider == .claude ? defaultClaudeHome : defaultDeepseekHome, isDemo = demo
            let report = await Task.detached(priority: .utility) {
                EngineProviderHomeReport.inspect(provider: provider, home: home, fallback: fallback, demo: isDemo)
            }.value
            struct Result: Encodable {
                let protocolVersion = EngineProtocol.version, type = "result", ok = true
                let id: String
                let value: EngineProviderHomeReport
            }
            if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: report)), bytes.count <= EngineProtocol.maximumCommandBytes { output(bytes + Data([10])) }
            else { failure(id: command.id, code: "sourceReportLimit") }
            return true
        case "inspectCodexSource":
            let executable = command.params?.codexExecutable ?? codexExecutable
            let home = command.params?.codexHome ?? EngineCodexSourceReport.path(codexHome)
            guard [executable, home].allSatisfy({ $0.utf8.count <= 32768 &&
                !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                failure(id: command.id, code: "invalidCommand"); return true
            }
            let report = demo ? EngineCodexSourceReport.demo(executable: executable, home: home, defaultHome: defaultCodexHome) :
                await sourceSettings.inspect(executable, home, defaultCodexHome)
            struct Result: Encodable {
                let protocolVersion = EngineProtocol.version, type = "result", ok = true
                let id: String
                let value: EngineCodexSourceReport
            }
            if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: report)), bytes.count <= EngineProtocol.maximumSnapshotBytes {
                output(bytes + Data([10]))
            } else { failure(id: command.id, code: "sourceReportLimit") }
            return true
        case "retryClaudeSetup":
            guard claudeHookServices != nil, enabled.contains(.claude), !demo else { failure(id: command.id, code: "claudeSetupUnavailable"); return true }
            scheduleClaudeHooks(force: true)
            publish(notices: [])
        case "initialize", "configure":
            let plan: ApplicationLifecycleCoordinator.Plan
            do { plan = try await configure(command.params) }
            catch { failure(id: command.id, code: "invalidConfiguration"); return true }
            if command.method == "initialize" { snapshotEmission = .init() }
            initialized = true
            await bindQuotaMonitor()
            if lifecycle.phase == .cold {
                let start = lifecycle.start()
                await performLifecycle(start)
                await refresh(discover: true)
            } else { await performLifecycle(plan) }
            await updateSourceWatches()
            startMaintenance()
            // The host must see the new account context before its browser
            // can answer a quota request for an organization selected here.
            await quotaMonitor?.refreshIfDue(expanded: expanded)
            _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded)
        case "prepareForSleep":
            await prepareForSleep()
        case "resumeAfterSleep":
            await resumeAfterSleep()
        case "refresh":
            await quotaMonitor?.refreshIfDue(expanded: expanded, force: true)
            _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded, force: true)
            await claudeCloudMonitor?.refresh()
            forceBalanceRequested = true
            await refresh(discover: command.params?.discover ?? false)
        case "retryQuota":
            guard let name = command.params?.provider, let provider = AgentProvider(rawValue: name), provider != .deepseek, enabled.contains(provider) else {
                failure(id: command.id, code: "invalidCommand"); return true
            }
            if demo { publish(notices: [], force: true) }
            else if provider == .codex, let quotaMonitor { await quotaMonitor.refreshIfDue(expanded: expanded, force: true) }
            else if provider == .claude, let claudeQuotaMonitor { _ = await claudeQuotaMonitor.refreshIfDue(expanded: expanded, force: true) }
            else { failure(id: command.id, code: "unavailable"); return true }
        case "snoozeDeepSeekSpike":
            guard initialized else { failure(id: command.id, code: "unavailable"); return true }
            spikeSnoozedUntil = now().addingTimeInterval(3600); publish(notices: [])
        case "setDeepSeekWebHost":
            guard let available = command.params?.webAvailable, let monitor = balanceMonitor else {
                failure(id: command.id, code: "unavailable"); return true
            }
            deepseekWebAvailable = available
            await webBridge.setAvailable(available)
            let reader: (@Sendable (String) async throws -> DeepSeekBalance)?
            if available {
                let bridge = webBridge
                reader = { context in try await bridge.read(context: context) }
            } else { reader = nil }
            await monitor.setWebReader(reader)
        case "completeDeepSeekWebRead":
            guard let id = command.params?.webRequestID, let context = command.params?.balanceContext,
                  id.utf8.count <= 64, context.utf8.count <= 64, let reply = command.params?.webReply,
                  await webBridge.complete(id: id, context: context, reply: reply) else {
                failure(id: command.id, code: "staleSource"); return true
            }
        case "deepSeekWebSessionChanged", "beginDeepSeekDisconnect", "completeDeepSeekDisconnect":
            guard enabled.contains(.deepseek), let monitor = balanceMonitor, let context = command.params?.balanceContext else {
                failure(id: command.id, code: "unavailable"); return true
            }
            let state = await monitor.currentState()
            guard state.token == context else { failure(id: command.id, code: "staleSource"); return true }
            if command.method == "deepSeekWebSessionChanged" {
                guard await monitor.webSessionChanged(token: context) else { failure(id: command.id, code: "staleSource"); return true }
            } else if command.method == "beginDeepSeekDisconnect" {
                guard let next = await monitor.beginDisconnect(token: context) else { failure(id: command.id, code: "credentialStore"); return true }
                send(["protocolVersion": EngineProtocol.version, "type": "result", "id": command.id, "ok": true, "value": ["context": next]])
                return true
            } else {
                guard let success = command.params?.webSuccess, await monitor.completeDisconnect(token: context, success: success) else {
                    failure(id: command.id, code: "staleSource"); return true
                }
            }
        case "saveDeepSeekKey", "removeDeepSeekKey", "retryDeepSeekBalance":
            guard enabled.contains(.deepseek), let monitor = balanceMonitor,
                  let token = command.params?.balanceContext else { failure(id: command.id, code: "unavailable"); return true }
            let state = await monitor.currentState()
            guard state.token == token else { failure(id: command.id, code: "staleSource"); return true }
            if command.method == "saveDeepSeekKey" {
                guard let key = command.params?.deepseekKey, await monitor.saveKey(key, token: token) else {
                    failure(id: command.id, code: "invalidCredential"); return true
                }
            } else if command.method == "removeDeepSeekKey" {
                guard await monitor.removeKey(token: token) else { failure(id: command.id, code: "credentialStore"); return true }
            } else {
                guard !state.refreshing else { failure(id: command.id, code: "requestInProgress"); return true }
                _ = await monitor.refreshIfDue(active: true, force: true)
            }
        case "setExpanded":
            guard let value = command.params?.expanded else { failure(id: command.id, code: "invalidCommand"); return true }
            expanded = value
            if !demo {
                await claudeActivityMonitor.updateRefreshPolicy(value ? .expanded : .collapsed, flushPending: true)
                await deepseekActivityMonitor.updateRefreshPolicy(value ? .expanded : .collapsed, flushPending: true)
            }
            await desktopMonitor?.updateRefreshPolicy(value ? .expanded : .collapsed, flushPending: value)
            await claudeCloudMonitor?.setExpanded(value)
            await updateSourceWatches(flushPending: value)
            if !demo {
                restartPresentationClock()
                await quotaMonitor?.refreshIfDue(expanded: value, expansion: value)
                _ = await claudeQuotaMonitor?.refreshIfDue(expanded: value, expansion: value)
                if value { await refresh(discover: false) } else { publish(notices: []) }
            } else { publish(notices: []) }
        case "markRead", "markAllRead":
            guard command.params?.snapshotSequence == sequence else {
                failure(id: command.id, code: "staleSnapshot"); return true
            }
            if command.method == "markAllRead" { activityState.markAllRead(at: now()) }
            else if let id = command.params?.activityID { activityState.markRead(activityID: id, at: now()) }
            publish(notices: [])
        case "demoStage":
            guard demo, let value = command.params?.demoStage, let next = DemoTaskStage(rawValue: value) else {
                failure(id: command.id, code: "demoOnly"); return true
            }
            stage = next; await refresh(discover: false)
        case "shutdown":
            await stop()
            send(["protocolVersion": EngineProtocol.version, "type": "result", "id": command.id, "ok": true])
            return false
        default: failure(id: command.id, code: "unknownMethod"); return true
        }
        send(["protocolVersion": EngineProtocol.version, "type": "result", "id": command.id, "ok": true])
        return true
    }

    private func configure(_ parameters: EngineCommand.Parameters?) async throws -> ApplicationLifecycleCoordinator.Plan {
        let parameters = parameters ?? EngineCommand.Parameters()
        // Validate the entire update before replacing any source state.
        // Omitted/null retains a source for protocol-1 callers; an empty
        // override explicitly restores the inherited/default source.
        let codex = try parameters.codexHome.map { try $0.isEmpty ? defaultCodexHome : Self.home($0) }
        let claude = try parameters.claudeHome.map { try $0.isEmpty ? defaultClaudeHome : Self.home($0) }
        let deepseek = try parameters.deepseekHome.map { try $0.isEmpty ? defaultDeepseekHome : Self.home($0) }
        if let organization = parameters.claudeOrganization, !organization.isEmpty, ClaudeWebQuotaDecoder.uuid(organization) == nil {
            throw EngineCommand.Failure.invalid
        }
        if let executable = parameters.codexExecutable {
            guard executable.utf8.count <= 32 * 1024,
                  !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw EngineCommand.Failure.invalid }
        }
        let explicitProviders = try parameters.enabledProviders.map { names -> Set<AgentProvider> in
            guard names.count <= AgentProvider.allCases.count else { throw EngineCommand.Failure.invalid }
            let values = names.compactMap(AgentProvider.init(rawValue:))
            guard values.count == names.count else { throw EngineCommand.Failure.invalid }
            return Set(values)
        }
        if let minutes = parameters.retentionMinutes, !(0...10080).contains(minutes) { throw EngineCommand.Failure.invalid }
        if let value = parameters.deepseekSettings, !value.isValid { throw EngineCommand.Failure.invalid }
        if let value = parameters.reminderSettings, !value.isValid { throw EngineCommand.Failure.invalid }
        guard parameters.providerModes == nil || explicitProviders == nil else { throw EngineCommand.Failure.invalid }
        var updatedSettings = moduleSettings
        if let explicitProviders {
            for provider in AgentProvider.allCases { updatedSettings.setMode(explicitProviders.contains(provider) ? .enabled : .disabled, for: provider) }
        }
        if let modes = parameters.providerModes {
            guard modes.count <= AgentProvider.allCases.count else { throw EngineCommand.Failure.invalid }
            for (name, raw) in modes {
                guard let provider = AgentProvider(rawValue: name), let mode = ProviderModuleMode(rawValue: raw) else { throw EngineCommand.Failure.invalid }
                updatedSettings.setMode(mode, for: provider)
            }
        }
        var detected = installation
        if parameters.providerModes != nil {
            let previous = generation
            if demo { detected = .init(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true) }
            else { detected = await detectInstallation() }
            guard generation == previous else { throw EngineCommand.Failure.invalid }
        }
        let selectedProviders = explicitProviders ?? (parameters.providerModes == nil ? nil :
            updatedSettings.enabledProviders(detection: detected ?? .init(codexInstalled: false, claudeInstalled: false)))
        let changesCodex = codex.map { $0 != codexHome } ?? false
        let changesClaude = claude.map { $0 != claudeHome } ?? false
        let changesDeepSeek = deepseek.map { $0 != deepseekHome } ?? false
        projectionReady = false
        activityDisplayTask = nil; activityDisplayDeadline = nil
        if let codex { codexHome = codex }
        if let claude { claudeHome = claude }
        if let organization = parameters.claudeOrganization {
            if organization.lowercased() != claudeOrganization {
                claudeQuotaState = nil
                purgeClaudeCloudActivities()
                cloudState = nil
            }
            claudeOrganization = organization.lowercased()
        }
        if let deepseek { deepseekHome = deepseek }
        if let executable = parameters.codexExecutable { codexExecutable = executable }
        moduleSettings = updatedSettings; installation = detected
        if parameters.providerModes != nil { moduleConfigurationActive = true }
        else if explicitProviders != nil { moduleConfigurationActive = false }
        if let selectedProviders {
            if enabled.contains(.deepseek), !selectedProviders.contains(.deepseek) { deepseekNoticePolicy = .init() }
            if enabled.contains(.claude), !selectedProviders.contains(.claude) { resetClaudeLocalSource() }
            for provider in enabled.subtracting(selectedProviders) { inbox.remove(provider: provider) }
            enabled = selectedProviders
        }
        if let hidden = parameters.hideProjects { hideProjects = hidden }
        if let shown = parameters.showEmbeddedCodexSessions { showEmbeddedCodexSessions = shown }
        if let shown = parameters.showClaudeCloudProjects { showClaudeCloudProjects = shown }
        if var value = parameters.deepseekSettings {
            if value.balanceSource == nil { value.balanceSource = deepseekSettings.balanceSource }
            deepseekSettings = value
        }
        if let value = parameters.reminderSettings { reminderSettings = value }
        if let minutes = parameters.retentionMinutes { retention = minutes == 0 ? .infinity : Double(minutes) * 60 }
        if changesCodex { codexReader = LocalActivityReader(fileMetadata: { WindowsFileSystem().metadata($0) }) }
        if changesClaude { resetClaudeLocalSource() }
        if changesDeepSeek {
            deepseekLocal = LocalActivitySnapshot(); deepseekUsage = DeepSeekLocalUsage()
            deepseekNoticePolicy = .init()
        }
        if changesCodex || changesClaude || changesDeepSeek { activityState.clearFirstOutput() }
        inbox.bindSourceHomes(provider: .codex, localHome: codexHome)
        inbox.bindSourceHomes(provider: .claude, localHome: claudeHome)
        inbox.bindSourceHomes(provider: .deepseek, localHome: deepseekHome)
        let plan = lifecycle.settings(lifecycleConfiguration)
        for provider in plan.changedProviders {
            resetSourceState(provider)
            navigationState.cancel(provider: provider)
            navigationOpens = navigationOpens.filter { $0.value.activity.provider != provider }
            hostTracking.cancel(provider: provider, clearApplications: true)
        }
        return plan
    }

    private var lifecycleConfiguration: ApplicationLifecycleCoordinator.Configuration {
        .init(enabled: enabled, sources: [.codex: codexHome.path + "|" + codexExecutable,
            .claude: claudeHome.path,
            .deepseek: deepseekHome.path])
    }

    private func bindQuotaMonitor() async {
        guard active else { return }
        codexHistory.bind(home: codexHome, customPath: codexExecutable)
        claudeHistory.bind(home: claudeHome, customPath: claudeOrganization)
        let codex = quotaMonitor, claude = claudeQuotaMonitor
        let codexHome = codexHome, path = codexExecutable, claudeHome = claudeHome, organization = claudeOrganization
        let codexEnabled = !demo && enabled.contains(.codex), claudeEnabled = usesClaudeWeb && enabled.contains(.claude) && !claudeWebPaused
        let codexVersion = lifecycle.version(.codex), claudeVersion = lifecycle.version(.claude)
        await ApplicationLifecycleCoordinator.cleanup([
            .codexQuota: { await codex?.configure(home: codexHome, customPath: path, enabled: codexEnabled, context: codexVersion) },
            .claudeQuota: { await claude?.configure(home: claudeHome, organization: organization, enabled: claudeEnabled, context: claudeVersion) },
            .cloud: { [weak self] in await self?.bindClaudeCloudMonitor() },
            .realtime: { [weak self] in await self?.bindDesktopMonitor() },
            .balance: { [weak self] in await self?.bindBalanceMonitor() }
        ])
    }

    private func resetClaudeLocalSource() {
        claudeLocal = LocalActivitySnapshot()
    }

    private func bindActivityMonitor(_ provider: AgentProvider) async {
        guard !demo, active else { return }
        let context = lifecycle.version(provider)
        if provider == .claude {
            scheduleClaudeHooks()
            lastClaudeDiscovery = now()
            if enabled.contains(.claude) {
                await claudeActivityMonitor.start(home: claudeHome, refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] rows, statuses, attention, performance in
                    await self?.receiveClaudeLocal(rows, statuses: statuses, attention: attention, performance: performance, context: context)
                }
            } else { await claudeActivityMonitor.shutdown(); claudeLocal = LocalActivitySnapshot() }
        } else if provider == .deepseek {
            if enabled.contains(.deepseek) {
                await deepseekActivityMonitor.start(home: deepseekHome, refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] rows, statuses, attention, performance, usage in
                    await self?.receiveDeepSeekLocal(rows, statuses: statuses, attention: attention, performance: performance, usage: usage, context: context)
                }
            } else { await deepseekActivityMonitor.shutdown(); deepseekLocal = LocalActivitySnapshot(); deepseekUsage = DeepSeekLocalUsage() }
        }
    }
    private func scheduleClaudeHooks(force: Bool = false) {
        guard let services = claudeHookServices else { return }
        let active = enabled.contains(.claude), home = claudeHome
        guard force || claudeHookHome != home || claudeHooksEnabled != active else { return }
        claudeHookTask?.cancel()
        claudeHookHome = home; claudeHooksEnabled = active
        let request = UUID(); claudeHookRequest = request
        claudeHookSetup = .init(active ? .settingUp : .disabled)
        claudeHookTask = Task { [weak self] in
            let result = await services.perform(active ? .ensure : .remove, home)
            guard !Task.isCancelled else { return }
            await self?.receiveClaudeHookSetup(result, request: request, home: home)
        }
    }
    private func receiveClaudeHookSetup(_ report: EngineClaudeHookSetup, request: UUID, home: URL) {
        guard initialized, claudeHookRequest == request, claudeHookHome == home else { return }
        claudeHookTask = nil; claudeHookSetup = report
        publish(notices: [])
    }
    private static func measured(_ rows: [SessionActivity], _ performance: [SessionPerformanceUpdate]) -> [SessionActivity] {
        var result = rows
        for index in result.indices { for sample in performance where sample.id == result[index].id { sample.apply(to: &result[index]) } }
        return result
    }
    private func receiveClaudeLocal(_ rows: [SessionActivity], statuses: [String: RuntimeStreamStatus],
        attention: [PendingAttentionRequest], performance: [SessionPerformanceUpdate], context: UInt64) async {
        guard active, lifecycle.version(.claude) == context, enabled.contains(.claude) else { return }
        let exclusions = await claudeActivityMonitor.excludedLocalActivityIDs()
        guard active, lifecycle.version(.claude) == context else { return }
        inbox.remove(activityIDs: exclusions)
        let status = statuses["local"]
        claudeLocal = LocalActivitySnapshot(activities: Self.measured(rows, performance), requests: attention,
            available: status?.connected == true && status?.sourceAvailable != false)
        if projectionReady, refreshTask == nil { projectLocal(.claude, snapshot: claudeLocal) }
    }
    private func receiveDeepSeekLocal(_ rows: [SessionActivity], statuses: [String: RuntimeStreamStatus],
        attention: [PendingAttentionRequest], performance: [SessionPerformanceUpdate], usage: DeepSeekLocalUsage, context: UInt64) async {
        guard active, lifecycle.version(.deepseek) == context, enabled.contains(.deepseek) else { return }
        let previous = Set(deepseekLocal.activities.filter { $0.phase == .running }.map { $0.id + "|" + ($0.turnID ?? "") })
        deepseekUsage = usage
        let status = statuses["local"]
        deepseekLocal = LocalActivitySnapshot(activities: Self.measured(rows, performance), requests: attention,
            available: status?.connected == true && status?.sourceAvailable != false)
        updateLocalWallet()
        if projectionReady, refreshTask == nil {
            projectLocal(.deepseek, snapshot: deepseekLocal)
            await bindBalanceMonitor()
            guard active, lifecycle.version(.deepseek) == context else { return }
            let ended = rows.contains { [.completed, .interrupted].contains($0.phase) && previous.contains($0.id + "|" + ($0.turnID ?? "")) }
            _ = await balanceMonitor?.refreshIfDue(active: expanded || rows.contains { $0.phase == .running }, turnEnded: ended)
        }
    }
    private func projectLocal(_ provider: AgentProvider, snapshot: LocalActivitySnapshot) {
        loggedActivities.removeAll { $0.provider == provider }; loggedActivities += snapshot.activities
        loggedRequests.removeAll { $0.provider == provider }; loggedRequests += snapshot.requests
        let id = provider.rawValue + ":local-logs"
        loggedSources.removeAll { $0.id == id }
        loggedSources.append(.init(id: id, provider: provider.rawValue, available: snapshot.available, transport: "logs", reason: nil))
        cloudLocalSessions.update(loggedActivities)
        projectCollected(at: now())
    }
    private func updateLocalWallet() {
        var titles = deepseekUsage.titles
        for activity in deepseekLocal.activities { if let task = activity.threadID { titles[task] = activity.title ?? activity.project } }
        walletSource = EngineWalletSource(balance: balanceState?.balance,
            connected: balanceState.map { $0.error == nil || $0.balance != nil } ?? false,
            ledger: deepseekUsage.ledger, history: balanceState?.history ?? .init(), titles: titles)
    }

    private func bindBalanceMonitor() async {
        guard let monitor = balanceMonitor else { return }
        await monitor.configure(home: deepseekHome, source: deepseekSettings.selection, enabled: enabled.contains(.deepseek),
            recentProvider: demo ? "deepseek-account" : deepseekUsage.provider, context: lifecycle.version(.deepseek))
        let state = await monitor.currentState()
        receiveBalance(state)
    }

    private func bindClaudeCloudMonitor(reset: Bool = false) async {
        await claudeCloudMonitor?.configure(home: claudeHome, organization: claudeOrganization,
            enabled: usesClaudeWeb && enabled.contains(.claude) && showClaudeCloudProjects && !claudeWebPaused,
            webAvailable: cloudWebAvailable, context: lifecycle.version(.claude), reset: reset)
        await claudeCloudMonitor?.setExpanded(expanded)
    }

    func maintenanceRefresh() async {
        guard active else { return }
        if !demo, moduleConfigurationActive, AgentProvider.allCases.contains(where: { moduleSettings.mode(for: $0) == .automatic }) {
            let previous = generation
            let detected = await detectInstallation()
            guard active, generation == previous, !Task.isCancelled else { return }
            installation = detected
            let next = moduleSettings.enabledProviders(detection: detected)
            if next != enabled {
                for provider in enabled.subtracting(next) { inbox.remove(provider: provider) }
                enabled = next; projectionReady = false
                let plan = lifecycle.settings(lifecycleConfiguration)
                for provider in plan.changedProviders { resetSourceState(provider) }
                await bindQuotaMonitor()
                await performLifecycle(plan)
            }
        }
        await performLifecycle(lifecycle.tick(lifecycleTick))
        if projectionReady { publish(notices: []) }
    }

    private var lifecycleTick: ApplicationLifecycleCoordinator.Tick {
        .init(now: now(), expanded: expanded, codexConnected: desktopState?.status.connected == true,
            lastCodexDiscovery: lastCodexDiscovery, lastRemoteDiscovery: lastRemoteDiscovery, lastClaudeDiscovery: lastClaudeDiscovery,
            deepseekRunning: activities.contains { $0.provider == .deepseek && $0.phase == .running })
    }

    private func startMaintenance() {
        guard active, maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.maintenanceRefresh()
            }
        }
    }

    private func performLifecycle(_ plan: ApplicationLifecycleCoordinator.Plan) async {
        let revision = generation
        for action in plan.actions {
            guard active, generation == revision, !Task.isCancelled else { return }
            switch action {
            case .quota(let provider, let force, let active):
                switch provider {
                case .codex: await quotaMonitor?.refreshIfDue(expanded: expanded, force: force)
                case .claude: _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded, force: force)
                // Mac's start/wake is an explicit request, without bypassing a
                // signed-out/challenge or failed-disconnect connection state.
                case .deepseek: _ = await balanceMonitor?.refreshIfDue(active: active, requested: force)
                }
            case .codexActivity: await refresh(discover: true, refreshActivityMonitors: false)
            case .remoteActivity: lastRemoteDiscovery = now() // Transport activation remains P2.
            case .activity(let provider): await bindActivityMonitor(provider)
            case .claudeTargets: await bindActivityMonitor(.claude)
            case .clock: if !demo { restartPresentationClock() }
            case .displayExpiry: scheduleActivityDisplay(at: now())
            case .pruneActivities: activityState.prune(at: now(), retention: retention)
            case .pruneHistory: codexHistory.prune(at: now()); claudeHistory.prune(at: now())
            case .resetSource(let provider):
                await resetSource(provider)
            case .updateActivityPolicy: await updateSourceWatches()
            case .cloud: await bindClaudeCloudMonitor()
            case .balanceBinding: await bindBalanceMonitor()
            case .refilter, .demoSnapshot: await refresh(discover: true)
            case .retryHostTracking: trackActivityHosts()
            case .applications, .removeClaudeHooks, .stopWatches, .cancelHostTracking, .cancelRemoteSetup, .suspendSources, .stopSources: break
            }
        }
    }

    private func resetSource(_ provider: AgentProvider) async {
        navigationState.cancel(provider: provider)
        navigationOpens = navigationOpens.filter { $0.value.activity.provider != provider }
        hostTracking.cancel(provider: provider, clearApplications: true)
        ownedWork.cancel(provider: provider, kinds: [.hostScan, .hostRetry])
        if enabled.contains(provider) {
            switch provider {
            case .codex: await quotaMonitor?.refreshIfDue(expanded: expanded, force: true)
            case .claude: _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded, force: true)
            case .deepseek: _ = await balanceMonitor?.refreshIfDue(active: expanded, requested: true)
            }
        }
        if provider != .codex { await bindActivityMonitor(provider) }
    }

    private func resetSourceState(_ provider: AgentProvider) {
        notificationActivities.removeAll { $0.provider == provider }
        inbox.remove(provider: provider)
        activities.removeAll { $0.provider == provider }
        requests.removeAll { $0.provider == provider }
        loggedActivities.removeAll { $0.provider == provider }
        loggedRequests.removeAll { $0.provider == provider }
        loggedSources.removeAll { $0.provider == provider.rawValue }
        switch provider {
        case .codex:
            desktopState = nil; pendingDesktopEndings = [:]
            codexReader = LocalActivityReader(fileMetadata: { WindowsFileSystem().metadata($0) })
            codexQuotaState = nil; codexQuota = nil; codexQuotaFailed = false; codexQuotaRefreshing = false
            activityState.codexAttention = .init()
        case .claude:
            resetClaudeLocalSource(); claudeQuotaState = nil; cloudState = nil
            claudeQuotaAttention = .init(); activityState.claudeAttention = .init()
        case .deepseek:
            deepseekLocal = LocalActivitySnapshot(); deepseekUsage = .init(); deepseekNoticePolicy = .init()
            balanceState = nil; walletSource = nil; activityState.deepseekAttention = .init()
        }
        activityState.clearFirstOutput()
    }

    private static func home(_ path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 32 * 1024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw EngineCommand.Failure.invalid }
        #if os(Windows)
        guard path.range(of: #"^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)"#, options: .regularExpression) != nil else {
            throw EngineCommand.Failure.invalid
        }
        #else
        guard path.hasPrefix("/") else { throw EngineCommand.Failure.invalid }
        #endif
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func updateSourceWatches(flushPending: Bool = false) async {
        #if os(Windows)
        guard !demo else { return }
        var directories: [URL] = []
        for (provider, home, components) in [
            (AgentProvider.codex, codexHome, ["sessions"])
        ] where enabled.contains(provider) {
            for component in components {
                let target = home.appendingPathComponent(component, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue { directories.append(target) }
                else if FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue { directories.append(home) }
            }
        }
        logWatcher.update(directories, interval: expanded ? ActivityRefreshPolicy.expanded.interval : ActivityRefreshPolicy.collapsed.interval,
            flushPending: flushPending)
        // Register before completing initialization or a source change, so a
        // write immediately after the first read cannot fall through a gap.
        _ = await logWatcher.activeWatchCount()
        #endif
    }

    private func restartPresentationClock() {
        presentationClock?.cancel()
        presentationClock = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.presentationInterval() else { return }
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
                await self?.tickPresentation()
            }
        }
    }
    private func presentationInterval() -> TimeInterval { expanded ? ActivityRefreshPolicy.expanded.interval : ActivityRefreshPolicy.collapsed.interval }
    private func tickPresentation() async {
        guard active, !Task.isCancelled else { return }
        await performLifecycle(lifecycle.tick(lifecycleTick))
        guard projectionReady, refreshTask == nil else { return }
        // Only the metadata projection changes on a clock tick. Do not reopen
        // transcript files or rescan source directories while nothing is written.
        if activities.contains(where: { [.running, .waitingForInput].contains($0.phase) }) || !quota.isEmpty || codexQuota != nil || claudeQuotaState?.snapshot != nil || enabled.contains(.deepseek) && walletSource != nil {
            publish(notices: [])
        }
    }

    private func receiveBalance(_ state: DeepSeekBalanceState) {
        guard lifecycle.acceptsObservedWork, state.context == lifecycle.version(.deepseek) else { return }
        let changed = balanceState != state
        if balanceState?.token != state.token {
            deepseekNoticePolicy = .init(); webHostPublication.rebind(context: state.token)
        }
        balanceState = state
        if var source = walletSource {
            source.balance = state.balance; source.connected = state.error == nil || state.balance != nil
            source.history = state.history; walletSource = source
        }
        if changed && initialized && projectionReady { publish(notices: []) }
    }
    private func sendWebHostMessage(_ message: DeepSeekWebHostMessage) {
        guard initialized else { return }
        for ready in webHostPublication.receive(message, publishedContext: publishedBalanceContext,
            ready: projectionReady && lifecycle.acceptsObservedWork) {
            outputWebHostMessage(ready)
        }
    }
    private func outputWebHostMessage(_ message: DeepSeekWebHostMessage) {
        guard let bytes = try? JSONEncoder().encode(message), bytes.count <= EngineProtocol.maximumCommandBytes else { return }
        output(bytes + Data([10]))
    }

    private func receiveQuota(_ state: CodexQuotaState) {
        guard active, state.context == lifecycle.version(.codex) else { return }
        codexQuotaState = state
        let previous = codexQuota?.capturedAt
        codexQuota = state.snapshot
        codexHistory.receive(snapshot: state.snapshot, history: state.history, warning: state.warning)
        codexQuotaFailed = state.error != nil; codexQuotaRefreshing = state.refreshing
        quotaSource = .init(id: "codex:quota", provider: "codex", available: state.error == nil && state.snapshot?.windows.isEmpty == false,
            transport: "app-server", reason: state.error ?? state.warning, failure: state.failure)
        let notices = !state.refreshing && state.error == nil && state.snapshot?.capturedAt != previous
            ? state.snapshot.map { policy.quotaNotices($0, at: now()) } ?? [] : []
        if projectionReady { publish(notices: notices) }
    }

    private func receiveClaudeQuota(_ state: ClaudeQuotaState) {
        guard active, state.context == lifecycle.version(.claude), usesClaudeWeb else { return }
        let previous = claudeQuotaState?.snapshot?.capturedAt
        if claudeQuotaState?.connectionContext != state.connectionContext { claudeQuotaAttention = .init() }
        claudeQuotaState = state
        claudeHistory.receive(snapshot: state.snapshot, history: state.history, warning: state.warning)
        let notices = !state.refreshing && state.error == nil && state.snapshot?.capturedAt != previous
            ? state.snapshot.map { claudeQuotaAttention.quotaNotices($0, at: now()).map {
                IslandNotice(id: "claude:" + $0.id, kind: $0.kind, title: "Claude · " + $0.title, detail: $0.detail)
            } } ?? [] : []
        if projectionReady { publish(notices: notices) }
    }

    private func receiveClaudeCloud(_ state: ClaudeCloudState) {
        guard active, state.context == lifecycle.version(.claude), usesClaudeWeb else { return }
        if let previous = cloudState, previous.purgeRevision != state.purgeRevision {
            purgeClaudeCloudActivities()
        }
        cloudState = state
        if projectionReady { projectCollected(at: now()) }
    }
    private func purgeClaudeCloudActivities() {
        notificationActivities.removeAll { $0.claudeCloud != nil }
        let ids = Set((activities + inbox.activities + activityState.claudeActivities).filter { $0.claudeCloud != nil }.map(\.id))
        inbox.remove(activityIDs: ids)
        activityState.claudeActivities.removeAll { $0.claudeCloud != nil }
        activities.removeAll { $0.claudeCloud != nil }
        requests.removeAll { $0.activity.claudeCloud != nil }
    }

    private func sendClaudeHostMessage(_ message: ClaudeWebHostMessage) {
        guard initialized, let bytes = try? JSONEncoder().encode(message), bytes.count <= EngineProtocol.maximumCommandBytes else { return }
        output(bytes + Data([10]))
    }

    private func bindDesktopMonitor() async {
        let context = lifecycle.version(.codex)
        guard !demo, enabled.contains(.codex) else {
            desktopState = nil; await desktopMonitor?.shutdown(); return
        }
        await desktopMonitor?.startAsync(home: codexHome, includeSSH: false, includeRemoteControl: false,
            useSSHFallback: false, refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] value in
                await self?.receiveDesktop(CodexDesktopState(context: context, activities: value.activities,
                    attention: value.localDesktopAttention, attentionThreads: value.attentionThreads, names: value.names,
                    performance: value.performance, status: value.localDesktopStatus))
            }
    }

    private func receiveDesktop(_ state: CodexDesktopState) {
        guard active, state.context == lifecycle.version(.codex), enabled.contains(.codex), !demo else { return }
        desktopState = state
        inbox.updateNames(state.names); inbox.updatePerformance(state.performance)
        if projectionReady { projectCollected(at: now()) }
        else {
            // Initialization/source reads may be awaiting I/O. Keep endings
            // until the first projection; a later EOF can release the stream.
            activityState.rememberCodexEndings(state.activities)
        }
    }

    func refresh(discover: Bool, refreshActivityMonitors: Bool = true) async {
        guard active else { return }
        refreshRequested = true; discoveryRequested = discoveryRequested || discover
        refreshActivityMonitorsRequested = refreshActivityMonitorsRequested || refreshActivityMonitors
        if let refreshTask {
            await ApplicationLifecycleCoordinator.cleanup([.reader: { await refreshTask.value }])
            return
        }
        let owner = ownedWork.begin(.init(.activity), version: generation)
        let task = Task { await self.drainRefreshes(owner: owner) }
        ownedWork.attach(task, to: owner)
        await ApplicationLifecycleCoordinator.cleanup([.reader: { await task.value }])
    }
    private func drainRefreshes(owner: ApplicationWorkRegistry.Ticket) async {
        while active, ownedWork.owns(owner), refreshRequested, !Task.isCancelled {
            let discover = discoveryRequested, refreshMonitors = refreshActivityMonitorsRequested
            refreshRequested = false; discoveryRequested = false; refreshActivityMonitorsRequested = false
            await collect(discover: discover, refreshMonitors: refreshMonitors)
            if refreshRequested { await Task.yield() }
        }
        // Clear inside the actor before the worker completes. A request that
        // arrives afterwards creates a new worker instead of joining a finished one.
        ownedWork.finish(owner)
    }
    private func collect(discover: Bool, refreshMonitors: Bool) async {
        let date = now(), revision = generation
        if discover { lastCodexDiscovery = date }
        let previousDeepSeekTurns = Set(activities.filter {
            $0.provider == .deepseek && $0.phase == .running
        }.map { $0.id + "|" + ($0.turnID ?? "") })
        var current: [SessionActivity] = [], pending: [PendingAttentionRequest] = [], status: [EngineSource] = []
        if demo {
            current = DemoScenario.tasks(stage: stage, at: date)
                + [DemoScenario.claudeTask(stage: stage, at: date), DemoScenario.deepseekTask(stage: stage, at: date)]
            if !claudeWebReference {
                let cloud = DemoScenario.claudeCloud(stage: stage, at: date)
                current += cloud.activities; pending = cloud.attention
            }
            quota = Dictionary(uniqueKeysWithValues: [AgentProvider.codex, .claude].compactMap { provider in
                DemoScenario.quota(provider, at: date).last.map { (provider, $0) }
            })
            for provider in [AgentProvider.codex, .claude] {
                var history = QuotaCycleHistory()
                for sample in DemoScenario.quota(provider, at: date) { history.record(sample) }
                if provider == .codex { codexHistory.receive(snapshot: quota[provider], history: history, warning: nil) }
                else { claudeHistory.receive(snapshot: quota[provider], history: history, warning: nil) }
            }
            walletSource = .demo(at: date)
            status = AgentProvider.allCases.map { .init(id: $0.rawValue + ":demo", provider: $0.rawValue,
                available: true, transport: "demo", reason: nil) }
        } else {
            if enabled.contains(.codex) {
                let result = await codexReader.read(home: codexHome, now: date, phaseAwareRate: true, metricsOnly: !discover)
                guard generation == revision else { return }
                inbox.remove(activityIDs: result.excludedIDs)
                current += result.activities; pending += result.requests
                status.append(.init(id: "codex:local-logs", provider: "codex",
                    available: FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("sessions").path),
                    transport: "logs", reason: nil))
            }
            if refreshMonitors {
                if enabled.contains(.claude) { await claudeActivityMonitor.refresh() }
                if enabled.contains(.deepseek) { await deepseekActivityMonitor.refresh() }
                guard active, generation == revision else { return }
            }
            if enabled.contains(.claude) {
                current += claudeLocal.activities; pending += claudeLocal.requests
                status.append(.init(id: "claude:local-logs", provider: "claude", available: claudeLocal.available, transport: "logs", reason: nil))
            }
            if enabled.contains(.deepseek) {
                current += deepseekLocal.activities; pending += deepseekLocal.requests
                updateLocalWallet()
                status.append(.init(id: "deepseek:local-logs", provider: "deepseek", available: deepseekLocal.available, transport: "logs", reason: nil))
            }
        }
        await bindBalanceMonitor()
        guard active, generation == revision, !Task.isCancelled else { return }
        let ended = current.contains { $0.provider == .deepseek && [.completed, .interrupted].contains($0.phase) &&
            previousDeepSeekTurns.contains($0.id + "|" + ($0.turnID ?? "")) }
        let forceBalance = forceBalanceRequested; forceBalanceRequested = false
        _ = await balanceMonitor?.refreshIfDue(active: expanded || current.contains { $0.provider == .deepseek && $0.phase == .running },
            force: forceBalance, turnEnded: ended)
        guard active, generation == revision, !Task.isCancelled else { return }
        loggedActivities = current; loggedRequests = pending; loggedSources = status
        cloudLocalSessions.update(current)
        projectCollected(at: date)
        let candidates = current.filter { $0.provider == .codex }.sorted {
            let left = [.running, .waitingForInput].contains($0.phase), right = [.running, .waitingForInput].contains($1.phase)
            if left != right { return left }
            return ($0.lastObserved ?? .distantPast) > ($1.lastObserved ?? .distantPast)
        }.prefix(256).compactMap(\.threadID)
        await desktopMonitor?.discover(candidates)
        await updateSourceWatches()
        guard active, generation == revision, !Task.isCancelled else { return }
        await claudeCloudMonitor?.startAfterPublication()
    }

    private func projectCollected(at date: Date) {
        var current = loggedActivities, pending = loggedRequests, status = loggedSources
        if usesClaudeWeb, enabled.contains(.claude), let cloud = cloudState, cloud.enabled {
            current += cloud.activities; pending += cloud.attention
            if let availability = cloud.status {
                status.append(.init(id: "claude:cloud-projects", provider: "claude", available: availability.connected && availability.sourceAvailable != false,
                    transport: "https", reason: nil))
            }
        }
        if !demo {
            current = current.filter { enabled.contains($0.provider) }
            pending = pending.filter { enabled.contains($0.provider) }
        }
        activityState.localActivities = current.filter { $0.provider == .codex }
        activityState.claudeActivities = current.filter { $0.provider == .claude }
        activityState.deepseekActivities = current.filter { $0.provider == .deepseek }
        activityState.codexLogRequests = pending.filter { $0.provider == .codex }
        activityState.claudeReceivedRequests = pending.filter { $0.provider == .claude }
        activityState.deepseekReceivedRequests = pending.filter { $0.provider == .deepseek }
        if !demo, enabled.contains(.codex), let desktop = desktopState, desktop.context == lifecycle.version(.codex) {
            activityState.remoteActivities = desktop.activities
            activityState.codexReceivedRequests = desktop.attention
            activityState.codexAttentionThreadIDs = desktop.attentionThreads
            activityState.codexStreamConnected = desktop.status.connected
            activityState.applyCodexMetadata(names: desktop.names, performance: desktop.performance, at: date, visibility: activityVisibility)
            status.append(.init(id: "codex:desktop-runtime", provider: "codex",
                available: desktop.status.connected && desktop.status.sourceAvailable == true, transport: "desktop-ipc", reason: nil))
        } else {
            activityState.remoteActivities = []; activityState.codexReceivedRequests = []
            activityState.codexAttentionThreadIDs = []; activityState.codexStreamConnected = false
        }
        sources = status.filter { enabled.contains(AgentProvider(rawValue: $0.provider) ?? .codex) }
        let update: ActivityApplicationUpdate
        if demo {
            activityState.demoActivities = current; activityState.demoRequests = pending; activityState.includesDemoMetadata = true
            inbox.observe(current, at: date, retention: retention)
            update = activityState.applyDemoSnapshot(enabled: enabled, at: date, visibility: activityVisibility)
        } else {
            update = activityState.reconcile(at: date, retention: retention, visibility: activityVisibility)
        }
        notificationActivities = current
        projectionReady = true
        publish(notices: update.notices)
        trackActivityHosts()
    }

    private var activityVisibility: ActivityVisibilityOptions {
        .init(embeddedProviders: showEmbeddedCodexSessions ? Set(AgentProvider.allCases) : [.claude, .deepseek],
            showsClaudeCloudProjects: showClaudeCloudProjects)
    }
    private func scheduleActivityDisplay(at date: Date) {
        let deadline = activityState.nextDisplayDeadline(at: date, retention: retention)
        guard deadline != activityDisplayDeadline else { return }
        activityDisplayTask?.cancel(); activityDisplayTask = nil; activityDisplayDeadline = nil
        guard active, let deadline else { return }
        activityDisplayDeadline = deadline
        let revision = generation, delay = max(0.01, deadline.timeIntervalSince(date) + 0.01)
        activityDisplayTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(86400, delay) * 1_000_000_000)) } catch { return }
            await self?.expireActivityDisplay(revision: revision, deadline: deadline)
        }
    }
    private func expireActivityDisplay(revision: UInt64, deadline: Date) {
        guard active, revision == generation, activityDisplayDeadline == deadline else { return }
        activityDisplayTask = nil; activityDisplayDeadline = nil
        // An injected reference clock may be frozen. Its elapsed wall timer
        // cannot expire display state or re-arm identical snapshots.
        let date = now()
        guard date >= deadline else { return }
        activityState.prune(at: date, retention: retention)
        publish(notices: [])
    }

    private func publish(notices: [IslandNotice], force: Bool = false) {
        let date = now()
        var wallet: EngineWallet?, walletNotices: [IslandNotice] = [], compactWallet: CompactBarContext.Wallet?
        if enabled.contains(.deepseek), let source = walletSource {
            let reading = source.wallet(at: date, configuration: deepseekSettings, reminders: reminderSettings)
            compactWallet = .init(reading, preferred: .init(rawValue: deepseekSettings.ringPeriod) ?? .day)
            wallet = source.presentation(wallet: reading, at: date, hideProjects: hideProjects, configuration: deepseekSettings,
                compactUsesBudget: enabled.subtracting([.deepseek]).count < 2, reminders: reminderSettings, connection: balanceState)
            walletNotices = deepseekNoticePolicy.balanceNotices(reading, low: reminderSettings.contains(.lowBalance))
                + deepseekNoticePolicy.spendNotices(reading, spike: reminderSettings.contains(.spendSpike), budget: reminderSettings.contains(.budget),
                    snoozedUntil: spikeSnoozedUntil, now: date)
        }
        let visibleActivities = activities, visibleRequests = requests
        let visibleNotices = activityState.visibleNotices(notices + walletNotices, visibility: activityVisibility)
        var snapshots = quota
        var displayedSources = sources
        if !demo {
            if enabled.contains(.codex) { snapshots[.codex] = codexQuota }
            if enabled.contains(.codex), let quotaSource { displayedSources.append(quotaSource) }
        }
        if usesClaudeWeb, enabled.contains(.claude) {
            snapshots[.claude] = claudeQuotaState?.snapshot
            if let state = claudeQuotaState {
                displayedSources.append(.init(id: "claude:quota", provider: "claude", available: state.error == nil && state.snapshot?.windows.isEmpty == false,
                    transport: "https", reason: state.error ?? state.warning))
            }
        }
        if enabled.contains(.deepseek), let state = balanceState {
            displayedSources.append(.init(id: "deepseek:balance", provider: "deepseek",
                available: state.balance != nil && state.error == nil,
                transport: demo ? "demo" : state.mode == .apiKey ? "https" : "webview",
                reason: state.error?.localizedDescription))
        }
        snapshots = snapshots.filter { enabled.contains($0.key) }
        activityState.replaceActivities(visibleActivities, at: date)
        let taskPresentation = activityState.presentation(at: date,
            options: .init(hideProjects: hideProjects,
                hostApplications: hostTracking.labels(for: visibleActivities, activities: activities, inbox: inbox) {
                    .init(name: $0.name, isClaudeDesktop: $0.isClaudeDesktop)
                }, showsDeepSeekTurnCost: deepseekSettings.showsTurnCost))
        scheduleActivityDisplay(at: date)
        var failedProviders = Set<AgentProvider>(), refreshingProviders = Set<AgentProvider>(), quotaErrors: [AgentProvider: String] = [:], sourceTexts: [AgentProvider: String] = [:]
        if !demo {
            if codexQuotaFailed { failedProviders.insert(.codex); quotaErrors[.codex] = quotaSource?.reason }
            if codexQuotaRefreshing { refreshingProviders.insert(.codex) }
        }
        if usesClaudeWeb, let state = claudeQuotaState {
                if let error = state.error { failedProviders.insert(.claude); quotaErrors[.claude] = error }
                if state.refreshing { refreshingProviders.insert(.claude) }
                if snapshots[.claude] != nil { sourceTexts[.claude] = state.source?.label }
        }
        if snapshots[.codex] != nil { sourceTexts[.codex] = L10n.text("quota.source_codex") }
        let compactWarnings = CompactWarningPresentation.items(enabled: enabled,
            warnings: Set(reminderSettings.warnings.compactMap(CompactIslandLayout.Warning.init(rawValue:))), snapshots: snapshots,
            failed: failedProviders, wallet: wallet?.alert, now: date)
        let compactContext = CompactBarContext(activities: visibleActivities, requests: visibleRequests, completions: inbox.unreadActivities,
            sources: AgentProvider.allCases.filter { enabled.contains($0) }.map { provider in
                .init(provider: provider, snapshot: snapshots[provider], failed: failedProviders.contains(provider))
            }, wallet: compactWallet, firstOutput: latestFirstOutput?.seconds, warnings: compactWarnings, groups: taskPresentation.groups, overview: taskPresentation.overview, now: date)
        let displayedQuota = AgentProvider.allCases.compactMap { provider in snapshots[provider].map { EngineQuota($0, provider: provider, at: date) } }
        let weekly = QuotaDashboardPresentation.Reading(provider: .codex, period: .weekly, snapshot: snapshots[.codex],
            failed: !demo && codexQuotaFailed, refreshing: !demo && codexQuotaRefreshing,
            sourceText: snapshots[.codex] == nil ? nil : L10n.text("quota.source_codex"), now: date)
        var history: [AgentProvider: QuotaHistoryPresentation] = enabled.contains(.codex) ? [.codex:
            codexHistory.presentation(provider: .codex, snapshot: snapshots[.codex], weekly: weekly,
                error: quotaErrors[.codex], refreshing: !demo && codexQuotaRefreshing, now: date)] : [:]
        if enabled.contains(.claude), (demo && !usesClaudeWeb) || (usesClaudeWeb && claudeQuotaState != nil) {
            let refreshing = claudeQuotaState?.refreshing ?? false
            let weekly = QuotaDashboardPresentation.Reading(provider: .claude, period: .weekly, snapshot: snapshots[.claude],
                failed: failedProviders.contains(.claude), refreshing: refreshing, sourceText: sourceTexts[.claude], now: date)
            history[.claude] = claudeHistory.presentation(provider: .claude, snapshot: snapshots[.claude], weekly: weekly,
                error: quotaErrors[.claude], refreshing: refreshing, now: date)
        }
        let dashboard = EngineQuotaDashboard(enabled: enabled, snapshots: snapshots,
            failed: failedProviders, refreshing: refreshingProviders, sourceText: sourceTexts, errorText: quotaErrors, history: history, at: date)
        if projectionReady {
            #if os(Windows)
            let codexDefaultProfile = demo || WindowsActivityNavigation.isDefaultProfile(codexHome, provider: .codex)
            #endif
            navigation.update(activities: visibleActivities, requests: visibleRequests, inbox: inbox,
                cloudContext: cloudNavigationContext) { activity in
                guard !activity.isInternalReview, !activity.isIgnoredCodexSession else { return false }
                if activity.provider == .deepseek { return true }
                if demo { return true }
                if activity.claudeCloud != nil { return activity.threadURL != nil }
                #if os(Windows)
                if activity.provider == .codex, !activity.launchedByEmbeddingApp,
                   !codexDefaultProfile { return false }
                #endif
                return activity.sourceHostID == nil && activity.threadID.flatMap(UUID.init(uuidString:)) != nil
            }
            // Retain a separate navigation view of cold log endings. They do
            // not become visible cards or replay notification baselines.
            var candidates = Dictionary((visibleActivities + notificationActivities).filter { enabled.contains($0.provider) }
                .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.map { $0 }
            let hiddenCodex = showEmbeddedCodexSessions ? Set<String>() : EmbeddedSessionVisibility.embeddedActivityIDs(candidates.filter { $0.provider == .codex })
            let hiddenClaude = showClaudeCloudProjects ? Set<String>() : Set(candidates.filter { $0.claudeCloud != nil }.map(\.id))
            candidates.removeAll { hiddenCodex.contains($0.id) || hiddenClaude.contains($0.id) }
            notificationNavigation.update(activities: candidates, requests: visibleRequests, inbox: inbox, cloudContext: cloudNavigationContext) {
                [.codex, .claude].contains($0.provider) && !$0.isInternalReview && !$0.isIgnoredCodexSession
            }
        }
        let notificationProjections = visibleNotices.map { notificationProjection($0, requests: visibleRequests, at: date) }
        let snapshot = EngineSnapshot(sequence: sequence + 1, demo: demo, activities: visibleActivities, requests: visibleRequests,
            sources: displayedSources, quota: displayedQuota,
            notices: visibleNotices, inbox: inbox, hideProjects: hideProjects, now: date, wallet: enabled.contains(.deepseek) ? wallet : nil,
            modules: moduleConfigurationActive ? AgentProvider.allCases.map {
                .init(provider: $0.rawValue, mode: moduleSettings.mode(for: $0).rawValue,
                    installed: installation?.isInstalled($0), enabled: enabled.contains($0))
            } : nil, quotaDashboard: dashboard, showsDeepSeekTurnCost: deepseekSettings.showsTurnCost,
            compactWarnings: compactWarnings, compactContext: compactContext, taskPresentation: taskPresentation,
            deepseekConnection: balanceState.map { EngineDeepSeekConnection($0, now: date) },
            claudeConnection: claudeQuotaState.map { EngineClaudeConnection($0, paused: claudeWebPaused) },
            claudeCloudConnection: cloudState.map(EngineClaudeCloudConnection.init), activityLinks: projectionReady ? navigation.links : [],
            notificationProjections: notificationProjections,
            navigationError: navigationState.failure.map(EngineNavigationFailure.init), openingActivityIDs: navigationState.openingActivityIDs.sorted(), claudeSetup: claudeHookSetup)
        guard let bytes = try? JSONEncoder().encode(snapshot), bytes.count <= EngineProtocol.maximumSnapshotBytes else {
            failure(id: nil, code: "snapshotLimit"); return
        }
        guard (try? snapshotEmission.accepts(bytes, force: force)) != false else { return }
        sequence += 1
        output(bytes + Data([10]))
        publishedBalanceContext = snapshot.deepseekConnection?.context
        if projectionReady && lifecycle.acceptsObservedWork {
            for message in webHostPublication.published(context: publishedBalanceContext) { outputWebHostMessage(message) }
        }
    }

    func prepareForSleep() async {
        let plan = lifecycle.prepareForSleep()
        guard plan.actions.contains(.suspendSources) else { return }
        releaseHostWork()
        let quota = quotaMonitor, claude = claudeQuotaMonitor, balance = balanceMonitor
        quota?.invalidateSource(); claude?.invalidateSource(); balance?.invalidateSource()
        // Stop owns the old clients. Waking creates replacements seeded with
        // the last accepted readings; late callbacks cannot reach the new epoch.
        quotaMonitor = nil; claudeQuotaMonitor = nil; balanceMonitor = nil
        await cleanupSources(quota: quota, claude: claude, balance: balance, sleeping: true)
    }

    func resumeAfterSleep() async {
        guard lifecycle.isSleeping else { return }
        let plan = lifecycle.resume()
        if !demo { scheduleClaudeHooks() }
        quotaMonitor = quotaServices.map { services in
            CodexQuotaMonitor(services: services, seed: codexQuotaState, now: now) { [weak self] state in await self?.receiveQuota(state) }
        }
        claudeQuotaMonitor = effectiveClaudeServices.map { services in
            ClaudeQuotaMonitor(services: services, seed: claudeQuotaState, webAvailable: cloudWebAvailable, now: now) { [weak self] state in await self?.receiveClaudeQuota(state) }
        }
        balanceMonitor = balanceServices.map { services in
            DeepSeekBalanceMonitor(services: services, seed: balanceState, now: now) { [weak self] state in await self?.receiveBalance(state) }
        }
        if deepseekWebAvailable {
            let bridge = webBridge
            await balanceMonitor?.setWebReader { context in try await bridge.read(context: context) }
        }
        await bindQuotaMonitor()
        await claudeCloudMonitor?.resume(context: lifecycle.version(.claude))
        await performLifecycle(plan)
        await updateSourceWatches()
        if !demo { restartPresentationClock() }
        startMaintenance()
        await refresh(discover: true)
    }

    func stop() async {
        let plan = lifecycle.shutdown()
        guard plan.actions.contains(.stopSources) else { return }
        initialized = false; projectionReady = false
        releaseHostWork()
        await cleanupSources(quota: quotaMonitor, claude: claudeQuotaMonitor, balance: balanceMonitor, sleeping: false)
    }
    private func releaseHostWork() {
        claudeHookTask?.cancel(); claudeHookTask = nil; claudeHookRequest = nil; claudeHookHome = nil
        webHostPublication.reset(); publishedBalanceContext = nil
        cancelHostTracking(); invalidateNavigation()
        activityDisplayDeadline = nil
        refreshRequested = false; discoveryRequested = false; refreshActivityMonitorsRequested = false
        forceBalanceRequested = false
        #if os(Windows)
        logWatcher.stop()
        #endif
    }
    private func cleanupSources(quota: CodexQuotaMonitor?, claude: ClaudeQuotaMonitor?, balance: DeepSeekBalanceMonitor?, sleeping: Bool) async {
        let cloud = claudeCloudMonitor, desktop = desktopMonitor, web = webBridge, claudeWeb = claudeWebBridge
        let deadline = ShutdownDeadline(), claudeActivity = claudeActivityMonitor, deepseekActivity = deepseekActivityMonitor
        var operations: [ApplicationLifecycleCoordinator.Resource: ApplicationLifecycleCoordinator.Cleanup] = [
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claude?.stop() },
            .cloud: { if sleeping { await cloud?.suspend() } else { await cloud?.stop() } },
            .realtime: { await desktop?.shutdown(deadline: deadline) }, .balance: { await balance?.stop() },
            .claudeActivity: { await claudeActivity.shutdown(deadline: deadline) }, .deepseekActivity: { await deepseekActivity.shutdown() }
        ]
        if !sleeping {
            operations[.web] = { await web.setAvailable(false) }
            operations[.claudeWeb] = { await claudeWeb.setAvailable(false) }
        }
        #if os(Windows)
        let watcher = logWatcher, stopWatching = !demo
        operations[.watches] = { if stopWatching { watcher.stop(); _ = await watcher.activeWatchCount() } }
        #endif
        let completed = await ApplicationLifecycleCoordinator.cleanup(operations, deadline: deadline)
        if !completed { OwnedProcessTermination.terminateAll() }
    }
    private func invalidateNavigation() {
        navigation.invalidate(); navigationState.cancel(); navigationOpens.removeAll()
        notificationNavigation.invalidate(); notificationActivities = []
        navigationFailureTask?.cancel(); navigationFailureTask = nil
    }
    private func cancelHostTracking() {
        hostTracking.cancel()
        ownedWork.cancel(kinds: [.hostScan, .hostRetry])
    }
    private func trackActivityHosts(provider only: AgentProvider? = nil, refreshRunning: Bool = true) {
        for provider in AgentProvider.allCases where provider != .deepseek && (only == nil || provider == only) {
            trackActivityHosts(for: provider, refreshRunning: refreshRunning)
        }
    }
    private func trackActivityHosts(for provider: AgentProvider, refreshRunning: Bool) {
        let references = activityState.knownActivities(for: provider)
        let decision = hostTracking.prepare(provider: provider, references: references, activities: activities, inbox: inbox,
            version: lifecycle.version(provider), now: now(), active: active, demo: demo, refreshRunning: refreshRunning)
        switch decision {
        case .idle: break
        case .retry(let retry):
            let owner = ownedWork.begin(.init(.hostRetry, provider: provider), version: retry.version)
            let task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, retry.delay) * 1_000_000_000)) } catch { return }
                await self?.finishHostRetry(retry, owner: owner)
            }
            ownedWork.attach(task, to: owner)
        case .scan(let scan):
            let owner = ownedWork.begin(.init(.hostScan, provider: provider), version: scan.version)
            let home = navigationHome(for: provider), services = activityHostServices, claude = claudeActivityMonitor
            let task = Task { [weak self] in
                var files: [String: URL] = [:]
                for row in references where row.sourceHostID == nil {
                    if let session = row.threadID, let file = row.rolloutURL { files[session.lowercased()] = file }
                }
                if provider == .claude {
                    for session in scan.sessions { if let file = await claude.transcriptURL(for: session) { files[session] = file } }
                }
                let found = await services.resolve(.init(provider: provider, sessions: scan.sessions, home: home, files: files))
                await self?.finishHostScan(scan, found: found, owner: owner)
            }
            ownedWork.attach(task, to: owner)
        }
    }
    private func finishHostRetry(_ retry: HostApplicationTrackingState<ActivityHostApplication>.Retry, owner: ApplicationWorkRegistry.Ticket) {
        defer { ownedWork.finish(owner) }
        guard hostTracking.finishRetry(retry, version: lifecycle.version(retry.provider), active: active, cancelled: Task.isCancelled) else { return }
        ownedWork.finish(owner); trackActivityHosts(for: retry.provider, refreshRunning: true)
    }
    private func finishHostScan(_ scan: HostApplicationTrackingState<ActivityHostApplication>.Scan, found: [String: ActivityHostApplication], owner: ApplicationWorkRegistry.Ticket) {
        defer { ownedWork.finish(owner) }
        let result = hostTracking.complete(scan, found: found, version: lifecycle.version(scan.provider), active: active, cancelled: Task.isCancelled)
        if result.owned { ownedWork.finish(owner) }
        guard result.accepted else { return }
        if result.changed { publish(notices: []) }
        trackActivityHosts(for: scan.provider, refreshRunning: false)
    }
    private func navigationHome(for provider: AgentProvider) -> URL {
        switch provider { case .codex: codexHome; case .claude: claudeHome; case .deepseek: deepseekHome }
    }
    private func scheduleNavigationFailure() {
        navigationFailureTask?.cancel(); navigationFailureTask = nil
        guard let failure = navigationState.failure else { return }
        let delay = max(0.001, failure.deadline - navigationClock() + 0.001)
        navigationFailureTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            await self?.expireNavigationFailure(failure.id)
        }
    }
    private func expireNavigationFailure(_ id: UUID) {
        guard active, navigationState.expireFailure(id, now: navigationClock()) else { return }
        navigationFailureTask = nil; publish(notices: [])
    }
    private var cloudNavigationContext: String? { cloudState.map { $0.connectionContext + "|" + claudeOrganization } }
    private func notificationSource(_ provider: AgentProvider, scope: String) -> String? {
        let home = provider == .codex ? codexHome : provider == .claude ? claudeHome : deepseekHome
        var fields = ["notification-source-v1", provider.rawValue, home.standardizedFileURL.resolvingSymlinksInPath().path]
        switch provider {
        case .codex: fields.append(codexExecutable)
        case .claude:
            fields.append(claudeOrganization)
            if scope == "cloud" {
                if demo { fields.append("demo-cloud") }
                else {
                    guard showClaudeCloudProjects, cloudState?.context == lifecycle.version(.claude), cloudState?.scopeVerified == true, let scope = cloudState?.verifiedScope else { return nil }
                    fields.append(scope)
                }
            }
        case .deepseek:
            fields += [deepseekSettings.selection.rawValue, DeepSeekAuthMode.detect(home: deepseekHome)?.rawValue ?? ""]
        }
        if scope == "quota" {
            guard enabled.contains(provider), let account = (provider == .claude ? claudeQuotaState?.snapshot : codexQuota)?.accountScope else { return nil }
            fields.append(account)
        }
        fields.append(scope)
        return CompletionDismissalStore.digest(fields)
    }
    private func notificationProjection(_ notice: IslandNotice, requests: [PendingAttentionRequest], at date: Date) -> EngineNotice {
        var value = EngineNotice(notice, hideProjects: hideProjects)
        let requested = requests.first { "request:" + $0.id == notice.id }?.activity.id
        let entry = notificationNavigation.entries.values.first { entry in
            entry.members.contains { member in requested == member.id || notice.id.hasPrefix(member.id + ":") }
        }
        let deepseek = notice.category?.hasPrefix("deepseek.") == true || notice.id.hasPrefix("deepseek:") ||
            notificationActivities.contains { $0.provider == .deepseek && (requested == $0.id || notice.id.hasPrefix($0.id + ":")) }
        let provider = entry?.target.provider ?? (deepseek ? .deepseek : notice.id.hasPrefix("claude:") ? .claude : .codex)
        let scope = entry?.target.claudeCloud != nil ? "cloud" : deepseek ? "wallet" : notice.kind == .lowQuota ? "quota" : "local"
        guard let source = notificationSource(provider, scope: scope) else { value.actions = []; return value }
        let target = entry.map(EngineNotificationRegistry.target)
        let kind = target != nil ? "openTask" : deepseek && notice.kind != .lowQuota ? "openHarness" : "showIsland"
        value.defaultAction = .init(kind: kind, title: L10n.text("common.open_chat"),
            reference: notificationRegistry.issue(kind: kind, provider: provider, source: source, scope: scope, target: target, now: date))
        var actions = value.actions ?? []
        if target != nil { actions.insert(.init(kind: "openTask", title: L10n.text("common.open_chat")), at: 0) }
        else if deepseek && notice.kind != .lowQuota { actions.append(.init(kind: "openHarness", title: L10n.text("deepseek.notice.open_harness"))) }
        value.actions = actions.map { action in
            var action = action
            action.reference = notificationRegistry.issue(kind: action.kind, provider: provider, source: source, scope: scope, target: action.kind == "openTask" ? target : nil, now: date)
            return action
        }
        return value
    }
    private func navigationEntry(context: String) -> ActivityNavigationRegistry.Entry? {
        navigation.entry(context: context) ?? notificationNavigation.entry(context: context)
    }
    private func navigationIsCurrent(_ entry: ActivityNavigationRegistry.Entry) -> Bool {
        active && projectionReady && navigationEntry(context: entry.link.context)?.link == entry.link && enabled.contains(entry.target.provider) &&
            entry.members.allSatisfy({ inbox.isCurrentSource($0.source) }) &&
            (entry.target.claudeCloud == nil || (showClaudeCloudProjects && entry.cloudContext == cloudNavigationContext))
    }
    func failure(id: String?, code: String) {
        var value: [String: Any] = ["protocolVersion": EngineProtocol.version, "type": "error", "code": code]
        if let id { value["id"] = id }
        send(value)
    }
    private func send(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        output(bytes + Data([10]))
    }
}
