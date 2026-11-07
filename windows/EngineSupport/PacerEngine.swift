import Foundation
import PacerCore
#if os(Windows)
import CWindowsSupport
#endif

public enum PacerEngine {
    public static func run() async {
        WindowsResources.configure()
        #if os(Windows)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ssh-terminal" {
            WindowsSSHTerminal.run(CommandLine.arguments[2]); return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--wsl-terminal" {
            WindowsWSLResume.run(CommandLine.arguments[2]); return
        }
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
        else if let zone = EngineStartupTimeZone.parse(CommandLine.arguments) { NSTimeZone.default = zone }
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
        var progressRoot = WindowsCodexProgressPaths.defaultRoot
        if let index = CommandLine.arguments.firstIndex(of: "--codex-progress-runtime-root") {
            guard CommandLine.arguments.indices.contains(index + 1), WindowsCodexExecutableDiscovery.absolute(CommandLine.arguments[index + 1]) else { return }
            progressRoot = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        let ssh: WindowsSSHServices? = demo || readOnly ? nil : WindowsSSHServices()
        let wsl: WindowsWSLServices? = demo || readOnly ? nil : WindowsWSLServices()
        let runtime = EngineRuntime(demo: demo, now: clock,
            dismissalStore: readOnly ? nil : .applicationDefault,
            notificationStore: notificationStore,
            quotaServices: demo ? nil : readOnly ? (quotaDiagnostics ? .readOnlyDiagnostics : nil) : .live, desktopServices: demo ? nil : .platformLive,
            balanceServices: readOnly ? (quotaDiagnostics ? .readOnlyDiagnostics : nil) : demo ? .demo(now: clock) : .live,
            claudeServices: quotaDiagnostics ? .readOnlyDiagnostics : nil,
            wslServices: wsl,
            sshServices: ssh, claudeRemoteServices: .live(ssh: ssh, wsl: wsl),
            allowsLiveClaudeWeb: !demo && !readOnly, claudeWebReference: claudeReference, claudeHookServices: hookServices,
            managesCodexProgress: !demo && !readOnly, codexProgressPaths: .init(root: progressRoot), allowsStorageRecovery: !readOnly)
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
    private var monitorRemoteControl = true
    private var monitorWSL = true
    private let wslServices: WindowsWSLServices?
    private var wslNeedsReconcile = false
    private struct SourceQuotaState {
        var windows: [EngineQuota.Window]?
        var refreshing = false
        var error: String?
        var profile: WindowsWSLProfile?
    }
    private var wslQuota: [String: SourceQuotaState] = [:]
    private var remoteControlHostIDs: Set<String> = []
    private var remoteControlScope: String?
    private var desktopBinding = UUID()
    private var desktopConfiguration: String?
    private var showEmbeddedClaudeSessions = true
    private var showClaudeCloudProjects = true
    private var monitorSSH = true
    private let sshServices: WindowsSSHServices?
    private let claudeRemoteServices: EngineClaudeRemoteServices?
    private lazy var claudeRemoteSetup = claudeRemoteServices.map { WindowsClaudeRemoteCoordinator(services: $0, now: now, maximumTargets: 16) }
    private var claudeRemoteSetups: [EngineClaudeRemoteSetup] = []
    private var codexRemoteTargets: [RemoteActivityTarget] = [], claudeRemoteTargets: [RemoteActivityTarget] = []
    private var claudeRemoteStatuses: [String: RuntimeStreamStatus] = [:]
    private var localStreamStatuses: [AgentProvider: RuntimeStreamStatus] = [:]
    private var deepseekSettings = EngineDeepSeekSettings()
    private var reminderSettings = EngineReminderSettings()
    /// Claude's self-reported progress ring; off until the desktop turns it on.
    private var claudeProgressRing = false
    private var codexProgressRing = false
    private let managesCodexProgress: Bool
    private let codexProgressPaths: WindowsCodexProgressPaths
    private var codexProgressTarget: (home: URL, executable: String, enabled: Bool)?
    private var codexProgressSetup: CodexProgressSetupStatus?
    private var codexProgressTask: Task<Void, Never>?
    private let codexProgressGate = CodexProgressSwitchGate()
    private var codexProgressRequest: UUID?
    private var progressRingProviders: Set<AgentProvider> {
        var providers: Set<AgentProvider> = []
        if claudeProgressRing { providers.insert(.claude) }
        if codexProgressRing { providers.insert(.codex) }
        return providers
    }
    /// The Claude home where this engine switched the ring on.
    private var claudeProgressSwitchHome: URL?
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
    private lazy var claudeActivityMonitor = ClaudeActivityMonitor(clock: now, ssh: sshServices, wsl: wslServices)
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
    private var navigationHosts: [UUID: ActivityHostApplication] = [:]
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
    private lazy var desktopMonitor: RealtimeActivityMonitor? = desktopServices?.makeMonitor(ssh: sshServices, wsl: wslServices, targets: { [weak self] _ in
        await self?.monitoredRemoteTargets(.codex) ?? []
    })
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
    private let allowsStorageRecovery: Bool

    init(demo: Bool, now: @escaping @Sendable () -> Date = { Date() },
         dismissalStore: CompletionDismissalStore? = .applicationDefault,
         notificationStore: EngineNotificationRegistry.Store? = nil,
         quotaServices: CodexQuotaServices? = nil,
         desktopServices: CodexDesktopServices? = nil,
         balanceServices: DeepSeekBalanceServices? = nil,
         claudeServices: ClaudeQuotaServices? = nil,
         wslServices: WindowsWSLServices? = nil,
         sshServices: WindowsSSHServices? = nil,
         claudeRemoteServices: EngineClaudeRemoteServices? = nil,
         cloudServices: ClaudeCloudServices? = nil,
         navigationServices: ActivityNavigationServices? = nil,
         navigationClock: @escaping @Sendable () -> TimeInterval = { ActivityNavigationState.monotonicNow },
         navigationErrorDuration: TimeInterval = TaskRowInteraction.navigationErrorDuration,
         activityHostServices: ActivityHostServices = .live,
         allowsLiveClaudeWeb: Bool = false,
         claudeWebReference: Bool = false,
         claudeHookServices: EngineClaudeHookServices? = nil,
         managesCodexProgress: Bool = false,
         codexProgressPaths: WindowsCodexProgressPaths = .init(root: WindowsCodexProgressPaths.defaultRoot),
         allowsStorageRecovery: Bool = true,
         sourceSettings: CodexSourceSettingsServices = .live,
         installationDetection: @escaping @Sendable () async -> ProviderInstallationDetection = {
             await Task.detached(priority: .utility) { ProviderInstallationDetection.detect() }.value
         },
         output: @escaping @Sendable (Data) -> Void = { try? FileHandle.standardOutput.write(contentsOf: $0) }) {
        self.demo = demo; self.now = now; self.output = output; self.quotaServices = quotaServices; self.desktopServices = desktopServices
        self.allowsStorageRecovery = allowsStorageRecovery
        self.sourceSettings = sourceSettings
        self.balanceServices = balanceServices
        self.claudeServices = claudeServices; self.allowsLiveClaudeWeb = allowsLiveClaudeWeb
        self.cloudServices = cloudServices
        self.wslServices = wslServices
        self.sshServices = sshServices
        self.claudeRemoteServices = claudeRemoteServices
        self.navigationServices = navigationServices ?? (demo ? .demo : .live)
        self.navigationClock = navigationClock; self.navigationErrorDuration = navigationErrorDuration
        self.activityHostServices = activityHostServices
        self.claudeWebReference = claudeWebReference && demo
        self.claudeHookServices = claudeHookServices
        self.managesCodexProgress = managesCodexProgress; self.codexProgressPaths = codexProgressPaths
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
        guard let command = try? EngineCommand.decode(data), ["prepareActivityOpen", "activateActivityHost"].contains(command.method) else { return await receive(data) }
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
        case "storageRecoveryStatus", "recoverFutureStorage":
            // Demo and read-only diagnostics never mutate real application stores.
            let recovery = WindowsStorageRecovery.shared
            if command.method == "recoverFutureStorage", !demo {
                guard allowsStorageRecovery else { failure(id: command.id, code: "readOnly"); return true }
                guard recovery.recoverFutureFiles() else { failure(id: command.id, code: "storageRecoveryFailed"); return true }
            }
            let status: [String: Any] = demo ? ["futureFiles": [String]()] : recovery.status()
            send(["protocolVersion": EngineProtocol.version, "type": "result", "id": command.id, "ok": true, "value": status])
            return true
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
                input.remoteTarget = (target.provider == .claude ? claudeRemoteTargets : codexRemoteTargets).first { $0.id == target.sourceHostID }
                input.remoteControlHosts = allowedRemoteControlHosts
                input.wslProfile = target.sourceHostID.flatMap { wslServices?.registry.profile(id: $0, provider: target.provider) }
                if let profile = input.wslProfile, let services = wslServices,
                   !(await services.validate(profile, provider: target.provider)) { throw ActivityNavigationError.unavailable }
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
                    if plan.kind == "host", let pid = plan.pid, let started = plan.started {
                        navigationHosts[operation.id] = plan.hostApplication ?? .init(identity: .init(pid: pid, started: started),
                            provider: nil, name: "", home: home)
                    }
                    output(bytes + Data([10])); prepared = true
                }
                else { failure(id: command.id, code: "navigationUnavailable") }
            } catch ActivityNavigationError.missingClaudeHost { failure(id: command.id, code: "missingClaudeHost") }
              catch ActivityNavigationError.missingCodexHost { failure(id: command.id, code: "missingCodexHost") }
              catch { failure(id: command.id, code: "navigationUnavailable") }
            return true
        case "activateActivityHost":
            guard let context = command.params?.context, let entry = navigationEntry(context: context), navigationIsCurrent(entry),
                  let operation = navigationOpens[context], navigationState.owns(operation),
                  operation.isCurrent(version: lifecycle.version(entry.target.provider), active: active, inbox: inbox, scope: entry.cloudContext),
                  let host = navigationHosts.removeValue(forKey: operation.id), host.home == navigationHome(for: entry.target.provider) else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            let opened = await activityHostServices.activate(host)
            guard navigationState.owns(operation), navigationIsCurrent(entry),
                  operation.isCurrent(version: lifecycle.version(entry.target.provider), active: active, inbox: inbox, scope: entry.cloudContext) else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            struct HostResult: Encodable {
                let protocolVersion = EngineProtocol.version, type = "result", ok = true
                let id: String, value: Bool
            }
            if let bytes = try? JSONEncoder().encode(HostResult(id: command.id, value: opened)) { output(bytes + Data([10])) }
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
        case "retryClaudeRemoteSetup":
            guard active, !demo, let source = command.params?.sourceID, source.utf8.count <= 256,
                  let context = command.params?.context, UUID(uuidString: context) != nil,
                  let setup = claudeRemoteSetup,
                  await setup.retry(sourceID: source, context: context) else {
                failure(id: command.id, code: "staleRemoteSetup"); return true
            }
        case "retryClaudeSetup":
            guard claudeHookServices != nil, enabled.contains(.claude), !demo else { failure(id: command.id, code: "claudeSetupUnavailable"); return true }
            scheduleClaudeHooks(force: true)
            publish(notices: [])
        case "retryCodexProgressSetup":
            guard managesCodexProgress, codexProgressRing, enabled.contains(.codex) else { failure(id: command.id, code: "codexProgressSetupUnavailable"); return true }
            scheduleCodexProgressSetup(force: true)
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
        case "refreshRemoteControl":
            guard initialized, enabled.contains(.codex), monitorRemoteControl else {
                failure(id: command.id, code: "unavailable"); return true
            }
            await bindDesktopMonitor(force: true)
        case "refreshTaskSources":
            guard active else { failure(id: command.id, code: "unavailable"); return true }
            scheduleConnectionRetry()
        case "readConnectionQuota":
            guard let source = command.params?.sourceID, let name = command.params?.provider,
                  let provider = AgentProvider(rawValue: name), enabled.contains(provider), monitorWSL,
                  let profile = wslServices?.registry.profile(id: source, provider: provider) else {
                failure(id: command.id, code: "unavailable"); return true
            }
            readWSLQuota(profile, provider: provider)
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
        case "deepSeekWebSessionChanged", "beginDeepSeekWebSignIn", "beginDeepSeekDisconnect", "completeDeepSeekDisconnect":
            guard enabled.contains(.deepseek), let monitor = balanceMonitor, let context = command.params?.balanceContext else {
                failure(id: command.id, code: "unavailable"); return true
            }
            let state = await monitor.currentState()
            guard state.token == context else { failure(id: command.id, code: "staleSource"); return true }
            if command.method == "beginDeepSeekWebSignIn" {
                await webBridge.revoke(context: context)
            } else if command.method == "deepSeekWebSessionChanged" {
                guard await monitor.webSessionChanged(token: context, newSession: command.params?.webNewSession ?? true) else { failure(id: command.id, code: "staleSource"); return true }
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
        if let value = parameters.claudeProgressRing { claudeProgressRing = value }
        if let value = parameters.codexProgressRing { codexProgressRing = value }
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
        if let value = parameters.monitorRemoteControl { monitorRemoteControl = value }
        if let value = parameters.monitorWSL, value != monitorWSL {
            monitorWSL = value; wslNeedsReconcile = true
            ownedWork.cancel(.init(.discovery, identifier: "wsl")); wslServices?.registry.suspend()
            wslQuota = [:]
        }
        if let shown = parameters.showEmbeddedClaudeSessions { showEmbeddedClaudeSessions = shown }
        if let shown = parameters.showClaudeCloudProjects { showClaudeCloudProjects = shown }
        if let value = parameters.monitorSSH, value != monitorSSH {
            monitorSSH = value; ownedWork.cancel(.init(.discovery, identifier: "ssh"))
            codexRemoteTargets = []; claudeRemoteTargets = []; claudeRemoteStatuses = [:]
        }
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
        if changesCodex || changesClaude {
            ownedWork.cancel(.init(.discovery, identifier: "wsl")); wslServices?.registry.suspend()
            ownedWork.cancel(.init(.discovery, identifier: "ssh"))
            codexRemoteTargets = []; claudeRemoteTargets = []; claudeRemoteStatuses = [:]
            wslNeedsReconcile = true
        }
        applyClaudeProgressSwitch()
        scheduleCodexProgressSetup()
        bindCodexCompletionSources()
        bindWSLCompletionSources(.claude)
        inbox.bindSourceHomes(provider: .deepseek, localHome: deepseekHome)
        let plan = lifecycle.settings(lifecycleConfiguration)
        await bindClaudeRemoteSetup()
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
        if wslNeedsReconcile {
            wslNeedsReconcile = false
            await bindActivityMonitor(.claude)
            scheduleWSLDiscovery()
        }
    }

    private func resetClaudeLocalSource() {
        claudeLocal = LocalActivitySnapshot()
        localStreamStatuses[.claude] = nil
    }

    private func bindActivityMonitor(_ provider: AgentProvider) async {
        guard !demo, active else { return }
        let context = lifecycle.version(provider)
        if provider == .claude {
            scheduleClaudeHooks()
            lastClaudeDiscovery = now()
            if enabled.contains(.claude) {
                await claudeActivityMonitor.start(home: claudeHome, remoteTargets: monitoredRemoteTargets(.claude),
                    refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] rows, statuses, attention, performance in
                    await self?.receiveClaudeLocal(rows, statuses: statuses, attention: attention, performance: performance, context: context)
                }
            } else { await claudeActivityMonitor.shutdown(); claudeLocal = LocalActivitySnapshot() }
            await bindClaudeRemoteSetup()
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
        // Setup creates Pacer's hook folder, which the switch file needs, and
        // confirms that this engine manages that home.
        applyClaudeProgressSwitch(setupConfirmed: report.state == .ready)
        publish(notices: [])
    }
    private func scheduleCodexProgressSetup(force: Bool = false) {
        guard managesCodexProgress else { return }
        let home = codexHome, executable = codexExecutable, wanted = codexProgressRing && enabled.contains(.codex)
        let previous = codexProgressTarget
        guard force || previous?.home != home || previous?.executable != executable || previous?.enabled != wanted else { return }
        codexProgressTarget = (home, executable, wanted)
        // Turning reporting off, or leaving a home, takes effect at once: an
        // earlier setup may still be waiting for Codex, and Pacer may exit
        // before the registration itself is removed.
        let gate = codexProgressGate
        let generation = gate.change(home: home, wanted: wanted, previous: previous?.home, storage: WindowsLocalProfileStorage())
        let pending = codexProgressTask, request = UUID(), paths = codexProgressPaths
        codexProgressRequest = request
        codexProgressSetup = wanted ? .settingUp : nil
        codexProgressTask = Task { [weak self] in
            await pending?.value
            guard !Task.isCancelled else { return }
            if let previous, previous.home != home {
                _ = await Self.configureCodexReporter(home: previous.home, executable: previous.executable, enabled: false, paths: paths)
            }
            let status = await Self.configureCodexReporter(home: home, executable: executable, enabled: wanted, paths: paths,
                                                           gate: gate, request: generation)
            await self?.receiveCodexProgressSetup(status, request: request)
        }
    }

    private func receiveCodexProgressSetup(_ status: CodexProgressSetupStatus?, request: UUID) {
        guard codexProgressRequest == request else { return }
        codexProgressTask = nil; codexProgressSetup = status
        if initialized { publish(notices: []) }
    }

    private static func configureCodexReporter(home: URL, executable: String, enabled: Bool, paths: WindowsCodexProgressPaths,
                                              gate: CodexProgressSwitchGate? = nil, request: Int = 0) async -> CodexProgressSetupStatus? {
        guard enabled || CodexProgressSetup.wasConfigured(in: home) else { return nil }
        let reporter: CodexProgressCommand?
        if enabled {
            let engine = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let install = engine.deletingLastPathComponent().deletingLastPathComponent().path.lowercased()
            let root = paths.root.path.lowercased()
            guard root != install, !root.hasPrefix(install + "/") else { return .failed }
            let helper = engine.deletingLastPathComponent().appendingPathComponent("PacerInstallerHooks.exe")
            guard let data = await WindowsSubprocess.capture(executable: helper,
                    arguments: ["--prepare-codex-progress", paths.root.path, home.path], timeout: 8, limit: 8192),
                  let command = try? JSONDecoder().decode(CodexProgressCommand.self, from: data),
                  paths.owns(command, home: home) else { return .failed }
            reporter = command
        } else { reporter = nil }
        return await CodexProgressSetup.apply(home: home, reporter: reporter, storage: WindowsLocalProfileStorage(),
                                              gate: gate, request: request, owns: {
            paths.owns($0, home: home) || $0.isNative(named: "PacerEngine.exe", home: home)
        }) {
            CodexClient.findExecutable(customPath: executable).map { CodexClient(executable: $0, home: home, timeout: 3) }
        }
    }
    /// Only an engine that manages the hooks writes the switch; demo and
    /// read-only diagnostics never touch the Claude home. It removes only a
    /// switch it turned on itself, or a leftover in the home its hook setup
    /// just confirmed, so a home it merely passed through is never changed.
    private func applyClaudeProgressSwitch(setupConfirmed: Bool = false) {
        guard claudeHookServices != nil else { return }
        let wanted = claudeProgressRing && enabled.contains(.claude)
        func present(_ home: URL) -> Bool { FileManager.default.fileExists(atPath: ClaudeProgressRingSwitch.flagURL(home: home).path) }
        if let previous = claudeProgressSwitchHome, previous != claudeHome {
            ClaudeProgressRingSwitch.apply(enabled: false, home: previous); claudeProgressSwitchHome = nil
        }
        func contents(_ home: URL) -> Data? { FileManager.default.contents(atPath: ClaudeProgressRingSwitch.flagURL(home: home).path) }
        let before = contents(claudeHome)
        if wanted {
            ClaudeProgressRingSwitch.apply(enabled: true, home: claudeHome)
            if present(claudeHome) { claudeProgressSwitchHome = claudeHome }
        } else if claudeProgressSwitchHome == claudeHome || setupConfirmed {
            ClaudeProgressRingSwitch.apply(enabled: false, home: claudeHome); claudeProgressSwitchHome = nil
        }
        // The switch also decides which settings entries Pacer keeps (the
        // display observer or its plugin), so a change brings them current.
        if contents(claudeHome) != before { scheduleClaudeHooks(force: true) }
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
        localStreamStatuses[.claude] = status
        claudeRemoteStatuses = statuses.filter { $0.key != "local" && allowsRemoteSource($0.key, provider: .claude) }
        await bindClaudeRemoteSetup()
        guard active, lifecycle.version(.claude) == context else { return }
        claudeLocal = LocalActivitySnapshot(activities: Self.measured(rows, performance).filter { allowsRemoteSource($0.sourceHostID, provider: .claude) },
            requests: attention.filter { allowsRemoteSource($0.sourceHostID, provider: .claude) },
            available: status?.connected == true && status?.sourceAvailable != false)
        if projectionReady, refreshTask == nil { projectLocal(.claude, snapshot: claudeLocal) }
    }
    private func receiveDeepSeekLocal(_ rows: [SessionActivity], statuses: [String: RuntimeStreamStatus],
        attention: [PendingAttentionRequest], performance: [SessionPerformanceUpdate], usage: DeepSeekLocalUsage, context: UInt64) async {
        guard active, lifecycle.version(.deepseek) == context, enabled.contains(.deepseek) else { return }
        let previous = Set(deepseekLocal.activities.filter { $0.phase == .running }.map { $0.id + "|" + ($0.turnID ?? "") })
        deepseekUsage = usage
        let status = statuses["local"]
        localStreamStatuses[.deepseek] = status
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
            case .remoteActivity: lastRemoteDiscovery = now(); scheduleRemoteDiscovery(); scheduleWSLDiscovery(); await bindDesktopMonitor()
            case .activity(let provider): await bindActivityMonitor(provider)
            case .claudeTargets: await bindActivityMonitor(.claude); scheduleRemoteDiscovery(); scheduleWSLDiscovery()
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
        localStreamStatuses[provider] = nil
        notificationActivities.removeAll { $0.provider == provider }
        inbox.remove(provider: provider)
        activities.removeAll { $0.provider == provider }
        requests.removeAll { $0.provider == provider }
        loggedActivities.removeAll { $0.provider == provider }
        loggedRequests.removeAll { $0.provider == provider }
        loggedSources.removeAll { $0.provider == provider.rawValue }
        switch provider {
        case .codex:
            desktopBinding = UUID(); remoteControlHostIDs = []; remoteControlScope = nil
            bindCodexCompletionSources()
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

    private var allowedRemoteControlHosts: Set<String> {
        guard monitorRemoteControl, enabled.contains(.codex), let grant = desktopServices?.authorization(home: codexHome),
              grant.verified, !grant.revoked, grant.scope != nil, grant.scope == remoteControlScope else { return [] }
        return grant.hostIDs.intersection(remoteControlHostIDs)
    }
    private func bindCodexCompletionSources() {
        inbox.bindSourceHomes(provider: .codex, localHome: codexHome,
            remoteHomes: remoteCompletionHomes(.codex),
            remoteControlHostIDs: monitorRemoteControl ? remoteControlHostIDs : [], remoteControlAccountScope: remoteControlScope)
    }
    private func wslCompletionHomes(_ provider: AgentProvider) -> [String: String] {
        guard monitorWSL, let state = wslServices?.registry.snapshot() else { return [:] }
        return Dictionary(state.profiles.compactMap { profile in
            profile.target(provider).map { ($0.id, $0.home + "|" + (profile.rootIdentity(provider) ?? "")) }
        }, uniquingKeysWith: { _, latest in latest })
    }
    private func bindWSLCompletionSources(_ provider: AgentProvider) {
        inbox.bindSourceHomes(provider: provider, localHome: provider == .codex ? codexHome : claudeHome, remoteHomes: remoteCompletionHomes(provider))
    }
    private func remoteCompletionHomes(_ provider: AgentProvider) -> [String: String] {
        var homes = wslCompletionHomes(provider)
        for target in monitorSSH ? (provider == .codex ? codexRemoteTargets : claudeRemoteTargets) : [] { homes[target.id] = target.home }
        return homes
    }
    private func monitoredRemoteTargets(_ provider: AgentProvider) -> [RemoteActivityTarget] {
        let ssh = monitorSSH ? (provider == .codex ? codexRemoteTargets : claudeRemoteTargets) : []
        let wsl = monitorWSL ? wslServices?.registry.targets(provider) ?? [] : []
        return Array(ssh.prefix(8)) + Array(wsl.prefix(8))
    }
    private func scheduleWSLDiscovery() {
        let key = ApplicationWorkRegistry.Key(.discovery, identifier: "wsl")
        guard !demo, active, monitorWSL, let services = wslServices, ownedWork.task(key) == nil else { return }
        let owner = ownedWork.begin(key, version: generation)
        let task = Task { [weak self] in
            await services.discover()
            await self?.receiveWSLDiscovery(owner)
        }
        ownedWork.attach(task, to: owner)
    }
    private func receiveWSLDiscovery(_ owner: ApplicationWorkRegistry.Ticket) async {
        guard active, generation == owner.version, ownedWork.owns(owner), monitorWSL else { return }
        ownedWork.finish(owner)
        for (id, state) in wslQuota {
            guard let profile = state.profile, let provider = AgentProvider(rawValue: String(id.prefix { $0 != ":" })) else { continue }
            if wslServices?.registry.profile(id: profile.id, provider: provider) != profile {
                ownedWork.cancel(.init(.quota, provider: provider, identifier: profile.id)); wslQuota.removeValue(forKey: id)
            }
        }
        bindCodexCompletionSources(); bindWSLCompletionSources(.claude)
        await bindActivityMonitor(.claude); await bindDesktopMonitor(force: true)
        guard active else { return }
        if projectionReady { projectCollected(at: now()) }
    }
    private func readWSLQuota(_ profile: WindowsWSLProfile, provider: AgentProvider) {
        guard let services = wslServices else { return }
        let id = provider.rawValue + ":" + profile.id, key = ApplicationWorkRegistry.Key(.quota, provider: provider, identifier: profile.id)
        guard ownedWork.task(key) == nil else { return }
        let owner = ownedWork.begin(key, version: generation)
        wslQuota[id] = .init(refreshing: true, profile: profile)
        if projectionReady { projectCollected(at: now()) }
        let task = Task { [weak self] in
            do {
                let value = try await services.readQuota(profile: profile, provider: provider)
                await self?.receiveWSLQuota(value, profile: profile, provider: provider, owner: owner)
            } catch { await self?.receiveWSLQuota(nil, profile: profile, provider: provider, owner: owner) }
        }
        ownedWork.attach(task, to: owner)
    }
    private func receiveWSLQuota(_ value: QuotaSnapshot?, profile: WindowsWSLProfile, provider: AgentProvider,
                                 owner: ApplicationWorkRegistry.Ticket) {
        guard ownedWork.owns(owner) else { return }
        ownedWork.finish(owner)
        let id = provider.rawValue + ":" + profile.id
        guard active, generation == owner.version, monitorWSL,
              wslServices?.registry.profile(id: profile.id, provider: provider) == profile else {
            wslQuota.removeValue(forKey: id); return
        }
        wslQuota[id] = .init(windows: value.map { EngineQuota($0, provider: provider, at: now()).windows }, refreshing: false,
                            error: value == nil ? L10n.text("provider.state.failed") : nil, profile: profile)
        if projectionReady { projectCollected(at: now()) }
    }
    private func bindDesktopMonitor(force: Bool = false) async {
        let context = lifecycle.version(.codex)
        let key = ApplicationWorkRegistry.Key(.remote, provider: .codex, identifier: "desktop-start")
        guard !demo, enabled.contains(.codex) else {
            ownedWork.cancel(key); desktopBinding = UUID()
            desktopConfiguration = nil
            desktopState = nil; await desktopMonitor?.shutdown(); return
        }
        let configuration = "\(context)|\(codexHome.path)|\(codexExecutable)|\(monitorRemoteControl)|\(monitorWSL)|\(monitorSSH)"
        let replace = configuration != desktopConfiguration
        guard force || replace || ownedWork.task(key) == nil else { return }
        desktopConfiguration = configuration
        desktopServices?.setExecutable(codexExecutable)
        let binding = UUID(); desktopBinding = binding
        let monitor = desktopMonitor, home = codexHome, control = monitorRemoteControl
        let includeWSL = (monitorWSL && wslServices != nil) || (monitorSSH && sshServices != nil)
        let policy: ActivityRefreshPolicy = expanded ? .expanded : .collapsed
        let start: @Sendable () async -> Void = { [weak self] in
            if force || replace { await monitor?.invalidateRemoteControlCatalog(retryTransport: force) }
            await monitor?.startAsync(home: home, includeSSH: includeWSL, includeRemoteControl: control,
                useSSHFallback: true, refreshPolicy: policy) { [weak self] value in
                    await self?.receiveDesktop(CodexDesktopState(context: context, activities: value.activities,
                        attention: value.attention, attentionThreads: value.attentionThreads, names: value.names,
                        performance: value.performance, status: value.localDesktopStatus, statuses: value.statuses,
                        bindings: value.bindings, unavailable: value.unavailableSources), binding: binding)
                }
        }
        // Local transport fixtures need no directory request. Production owns
        // the bounded catalog request separately from initialize/quota work.
        if desktopServices?.catalog == nil { await start(); return }
        let owner = ownedWork.begin(key, version: context)
        let task = Task { [weak self] in
            await start()
            await self?.finishDesktopStart(owner)
        }
        ownedWork.attach(task, to: owner)
    }
    private func finishDesktopStart(_ owner: ApplicationWorkRegistry.Ticket) { ownedWork.finish(owner) }

    private func receiveDesktop(_ state: CodexDesktopState, binding: UUID) {
        guard active, desktopBinding == binding, state.context == lifecycle.version(.codex), enabled.contains(.codex), !demo else { return }
        if monitorRemoteControl {
            let bindings = state.bindings
            if remoteControlScope != bindings.accountScope {
                pendingDesktopEndings = pendingDesktopEndings.filter { $0.value.sourceHostID?.hasPrefix(ConnectionSource.controlPrefix) != true }
                activityState.clearFirstOutput()
            }
            remoteControlScope = bindings.accountScope
            remoteControlHostIDs = bindings.authoritative ? bindings.hostIDs : remoteControlHostIDs.union(bindings.hostIDs)
        } else { remoteControlHostIDs = [] }
        bindCodexCompletionSources()
        let rows = state.activities.filter { allowsRemoteSource($0.sourceHostID, provider: .codex) }
        desktopState = .init(context: state.context, activities: rows,
            attention: state.attention.filter { allowsRemoteSource($0.sourceHostID, provider: .codex) }, attentionThreads: state.attentionThreads,
            names: state.names, performance: state.performance, status: state.status,
            statuses: state.statuses.filter { $0.key == "local" || allowsRemoteSource($0.key, provider: .codex) }, bindings: state.bindings,
            unavailable: state.unavailable.filter { allowsRemoteSource($0, provider: .codex) })
        inbox.updateNames(state.names); inbox.updatePerformance(state.performance)
        if projectionReady { projectCollected(at: now()) }
        else {
            // Initialization/source reads may be awaiting I/O. Keep endings
            // until the first projection; a later EOF can release the stream.
            activityState.rememberCodexEndings(rows)
        }
    }
    private func allowsRemoteSource(_ source: String?, provider: AgentProvider) -> Bool {
        guard let source else { return true }
        if source.hasPrefix(ConnectionSource.wslPrefix) { return monitorWSL && wslServices?.registry.profile(id: source, provider: provider) != nil }
        if source.hasPrefix(ConnectionSource.controlPrefix) { return provider == .codex && monitorRemoteControl && remoteControlHostIDs.contains(source) }
        if source == ClaudeCloudProjectState.sourceID { return provider == .claude && showClaudeCloudProjects }
        return monitorSSH && (provider == .claude ? claudeRemoteTargets : codexRemoteTargets).contains { $0.id == source }
    }

    private func scheduleRemoteDiscovery() {
        guard !demo, monitorSSH, let services = sshServices else { return }
        let key = ApplicationWorkRegistry.Key(.discovery, identifier: "ssh")
        guard ownedWork.task(key) == nil else { return }
        let owner = ownedWork.begin(key, version: generation), codex = codexHome, claude = claudeHome
        let codexEnabled = enabled.contains(.codex), claudeEnabled = enabled.contains(.claude)
        let task = Task { [weak self] in
            let codexTargets = codexEnabled ? await services.codexTargets(home: codex) : []
            let claudeTargets = claudeEnabled ? await services.claudeTargets(codexHome: codex, claudeHome: claude) : []
            await self?.receiveRemoteTargets(codexTargets, claude: claudeTargets, owner: owner)
        }
        ownedWork.attach(task, to: owner)
    }
    private func receiveRemoteTargets(_ codex: [RemoteActivityTarget], claude: [RemoteActivityTarget], owner: ApplicationWorkRegistry.Ticket) async {
        guard ownedWork.owns(owner) else { return }
        let current = lifecycle.owns(owner)
        ownedWork.finish(owner)
        guard active, monitorSSH, current, !Task.isCancelled else { return }
        codexRemoteTargets = codex; claudeRemoteTargets = claude
        await bindClaudeRemoteSetup()
        bindRemoteCompletionSources()
        await bindDesktopMonitor(); await bindActivityMonitor(.claude)
    }
    private func bindRemoteCompletionSources() {
        bindCodexCompletionSources(); bindWSLCompletionSources(.claude)
    }

    private func bindClaudeRemoteSetup() async {
        guard let setup = claudeRemoteSetup else { return }
        await setup.configure(targets: monitoredRemoteTargets(.claude), statuses: claudeRemoteStatuses,
            enabled: active && (monitorSSH || monitorWSL) && enabled.contains(.claude), progressRing: claudeProgressRing,
            version: lifecycle.version(.claude),
            update: { [weak self] rows, version in await self?.receiveClaudeRemoteSetups(rows, version: version) },
            didConfigure: { [weak self] source, version in await self?.refreshConfiguredClaudeRemote(source, version: version) })
    }

    private func scheduleConnectionRetry() {
        let key = ApplicationWorkRegistry.Key(.remote, identifier: "connections-retry")
        guard ownedWork.task(key) == nil else { return }
        let owner = ownedWork.begin(key, version: generation)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.retryConnections(owner)
        }
        ownedWork.attach(task, to: owner)
    }
    private func retryConnections(_ owner: ApplicationWorkRegistry.Ticket) async {
        defer { ownedWork.finish(owner) }
        guard active, owner.version == generation else { return }
        if demo { publish(notices: [], force: true); return }
        scheduleRemoteDiscovery(); scheduleWSLDiscovery()
        await desktopMonitor?.retryInactiveHelpers()
        guard active, ownedWork.owns(owner), owner.version == generation else { return }
        await bindDesktopMonitor(force: true)
        if enabled.contains(.claude) { await claudeActivityMonitor.refresh() }
        if enabled.contains(.deepseek) { await deepseekActivityMonitor.refresh() }
        guard active, ownedWork.owns(owner), owner.version == generation else { return }
        for row in claudeRemoteSetups where row.canRetry && row.message != nil {
            _ = await claudeRemoteSetup?.retry(sourceID: row.sourceID, context: row.context)
            guard active, ownedWork.owns(owner), owner.version == generation else { return }
        }
        // Quota/balance keep their normal due-time policy; this action does
        // not force the three services' quota requests like "refresh" does.
        await refresh(discover: true, refreshActivityMonitors: false)
    }

    private func connectionPresentation() -> ConnectionPagePresentation {
        var streams: [AgentProvider: [String: RuntimeStreamStatus]] = [:]
        for provider in enabled {
            if demo {
                var status = RuntimeStreamStatus(); status.connected = true; status.sourceAvailable = true
                streams[provider] = ["local": status]
                for (source, rows) in Dictionary(grouping: activities.filter { $0.provider == provider }, by: { $0.sourceHostID ?? "local" }) {
                    status.attachedThreads = Set(rows.map { $0.threadID ?? $0.id }).count; status.sourceName = rows.first?.sourceHost
                    streams[provider, default: [:]][source] = status
                }
            } else if provider == .codex {
                streams[provider] = desktopState?.statuses ?? [:]
                if let status = desktopState?.status { streams[provider, default: [:]]["local"] = status }
            } else {
                streams[provider] = provider == .claude ? claudeRemoteStatuses : [:]
                if let status = localStreamStatuses[provider] { streams[provider, default: [:]]["local"] = status }
            }
            streams[provider] = streams[provider]?.filter { source, _ in
                if source == "local" { return true }
                if !demo { return allowsRemoteSource(source, provider: provider) }
                if source.hasPrefix(ConnectionSource.sshPrefix) { return monitorSSH }
                if source.hasPrefix(ConnectionSource.controlPrefix) { return monitorRemoteControl }
                if source.hasPrefix(ConnectionSource.wslPrefix) { return monitorWSL }
                return source == ClaudeCloudProjectState.sourceID && showClaudeCloudProjects
            }
        }
        if !demo, showClaudeCloudProjects, let cloud = cloudState, cloud.enabled, let status = cloud.status {
            streams[.claude, default: [:]][ClaudeCloudProjectState.sourceID] = status
        }
        if !demo, monitorSSH {
            for provider in [AgentProvider.codex, .claude] where enabled.contains(provider) {
                for target in provider == .claude ? claudeRemoteTargets : codexRemoteTargets where streams[provider]?[target.id] == nil {
                    var status = RuntimeStreamStatus(); status.sourceName = target.name
                    streams[provider, default: [:]][target.id] = status
                }
            }
        }
        let catalog = !demo && monitorWSL ? wslServices?.registry.snapshot() : nil
        for provider in [AgentProvider.codex, .claude] where enabled.contains(provider) {
            for profile in catalog?.profiles ?? [] {
                var status = streams[provider]?[profile.id] ?? RuntimeStreamStatus()
                status.sourceName = "WSL · " + profile.distro; status.remoteHostOnline = catalog?.active.contains(profile.id) == true
                if status.remoteHostOnline == false { status.connected = false }
                if profile.target(provider) == nil { status.sourceAvailable = false; status.connected = false }
                streams[provider, default: [:]][profile.id] = status
            }
        }
        return EngineConnectionProjection.make(enabled: enabled, statuses: streams, targets: monitorSSH ? claudeRemoteTargets : [],
            setups: claudeRemoteSetups, profiles: catalog?.profiles ?? [], activeWSL: catalog?.active ?? [], canRetrySetup: !demo && claudeRemoteServices != nil)
    }
    private func receiveClaudeRemoteSetups(_ rows: [EngineClaudeRemoteSetup], version: UInt64) {
        guard active, lifecycle.version(.claude) == version, rows != claudeRemoteSetups else { return }
        claudeRemoteSetups = rows
        if projectionReady { publish(notices: []) }
    }
    private func refreshConfiguredClaudeRemote(_ source: String, version: UInt64) async {
        guard active, lifecycle.version(.claude) == version,
              monitoredRemoteTargets(.claude).contains(where: { $0.id == source }) else { return }
        await claudeActivityMonitor.refresh(remoteTargetID: source)
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
        if !demo, monitorWSL, let services = wslServices {
            let catalog = services.registry.snapshot()
            var statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [.codex: desktopState?.statuses ?? [:], .claude: claudeRemoteStatuses]
            for provider in [AgentProvider.codex, .claude] {
                for profile in catalog.profiles {
                    var reading = statuses[provider]?[profile.id] ?? RuntimeStreamStatus()
                    reading.sourceName = "WSL · " + profile.distro
                    reading.remoteHostOnline = catalog.active.contains(profile.id)
                    if reading.remoteHostOnline == false { reading.connected = false }
                    if profile.target(provider) == nil { reading.sourceAvailable = false; reading.connected = false }
                    statuses[provider, default: [:]][profile.id] = reading
                }
            }
            status += ConnectionSource.sources(statuses: statuses, unavailableSSH: [], names: [:])
                .filter { $0.key.hasPrefix(ConnectionSource.wslPrefix) }.map { source in
                    let quota = wslQuota[source.id]
                    return .init(id: source.id, provider: source.provider.rawValue, available: source.state == .connected, transport: "wsl", reason: nil,
                        sourceName: source.name, state: String(describing: source.state),
                        stateLabel: source.state == .paused ? L10n.text("connections.state.paused", source.provider.displayName) : L10n.text("connections.state." + String(describing: source.state)),
                        sessions: source.sessions, quotaWindows: quota?.windows, quotaRefreshing: quota?.refreshing ?? false, quotaError: quota?.error)
                }
        }
        if !demo {
            current = current.filter { enabled.contains($0.provider) }
            pending = pending.filter { enabled.contains($0.provider) }
        }
        if !demo, monitorSSH {
            status += claudeRemoteStatuses.filter { $0.key.hasPrefix(ConnectionSource.sshPrefix) }.map { id, value in
                EngineSource(id: "claude:" + id, provider: "claude", available: value.connected && value.sourceAvailable != false,
                    transport: "ssh", reason: nil)
            }
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
            if monitorSSH {
                status += desktop.remoteStatuses.filter { $0.key.hasPrefix(ConnectionSource.sshPrefix) }.map { id, value in
                    EngineSource(id: "codex:" + id, provider: "codex", available: value.connected && value.sourceAvailable != false, transport: "ssh", reason: nil)
                }
            }
            status += ConnectionSource.sources(statuses: [.codex: desktop.statuses], unavailableSSH: [], names: [:])
                .filter { monitorRemoteControl && $0.key.hasPrefix(ConnectionSource.controlPrefix) }.map { source in
                    .init(id: source.id, provider: "codex", available: source.state == .connected, transport: "remote-control", reason: nil,
                        sourceName: source.name, state: String(describing: source.state),
                        stateLabel: source.state == .paused ? L10n.text("connections.state.paused", source.provider.displayName) :
                            L10n.text("connections.state." + String(describing: source.state)), sessions: source.sessions)
                }
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
        .init(embeddedProviders: Set(AgentProvider.allCases.filter {
                $0 == .codex ? showEmbeddedCodexSessions : $0 != .claude || showEmbeddedClaudeSessions
            }),
            showsClaudeCloudProjects: showClaudeCloudProjects)
    }
    private func scheduleActivityDisplay(at date: Date) {
        let deadline = activityState.nextDisplayDeadline(at: date, retention: retention, progressRingProviders: progressRingProviders)
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
        let openIDs = Set(navigationOpens.values.map(\.id))
        navigationHosts = navigationHosts.filter { openIDs.contains($0.key) }
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
                }, showsDeepSeekTurnCost: deepseekSettings.showsTurnCost,
                progressRingProviders: progressRingProviders))
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
        let codexSSH = enabled.contains(.codex) ? desktopState.flatMap { $0.context == lifecycle.version(.codex) ? $0 : nil } : nil
        let sshIssue = !demo && monitorSSH && EngineSSHReminder.raised(codex: codexSSH?.remoteStatuses ?? [:],
            codexUnavailable: codexSSH?.unavailable ?? [], claude: enabled.contains(.claude) ? claudeRemoteStatuses : [:]) {
                allowsRemoteSource($0, provider: $1)
            }
        let compactWarnings = CompactWarningPresentation.items(enabled: enabled,
            warnings: Set(reminderSettings.warnings.compactMap(CompactIslandLayout.Warning.init(rawValue:))), snapshots: snapshots,
            failed: failedProviders, sshIssue: sshIssue, wallet: wallet?.alert, now: date)
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
                if let host = activity.sourceHostID {
                    if monitorWSL, wslServices?.registry.profile(id: host, provider: activity.provider) != nil { return true }
                    if host.hasPrefix(ConnectionSource.sshPrefix) { return allowsRemoteSource(host, provider: activity.provider) && activity.threadID.flatMap(UUID.init(uuidString:)) != nil }
                    return activity.provider == .codex && allowedRemoteControlHosts.contains(host) && activity.threadURL != nil
                }
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
            let hidden = activityState.hiddenActivityIDs(activityVisibility)
            candidates.removeAll { hidden.contains($0.canonicalized().id) }
            notificationNavigation.update(activities: candidates, requests: visibleRequests, inbox: inbox, cloudContext: cloudNavigationContext) {
                [.codex, .claude].contains($0.provider) && !$0.isInternalReview && !$0.isIgnoredCodexSession
            }
            for (context, operation) in navigationOpens where navigationEntry(context: context) == nil {
                navigationState.abandon(operation); navigationOpens.removeValue(forKey: context)
                navigationHosts.removeValue(forKey: operation.id)
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
            progressRingProviders: progressRingProviders,
            compactWarnings: compactWarnings, compactContext: compactContext, taskPresentation: taskPresentation,
            deepseekConnection: balanceState.map { EngineDeepSeekConnection($0, now: date) },
            claudeConnection: claudeQuotaState.map { EngineClaudeConnection($0, paused: claudeWebPaused) },
            claudeCloudConnection: cloudState.map(EngineClaudeCloudConnection.init), activityLinks: projectionReady ? navigation.links : [],
            notificationProjections: notificationProjections,
            navigationError: navigationState.failure.map(EngineNavigationFailure.init), openingActivityIDs: navigationState.openingActivityIDs.sorted(), claudeSetup: claudeHookSetup,
            claudeRemoteSetups: claudeRemoteSetups, connections: connectionPresentation(), codexProgressSetup: codexProgressSetup)
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
        wslServices?.registry.suspend()
        wslQuota = [:]
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
        let cloud = claudeCloudMonitor, desktop = desktopMonitor, web = webBridge, claudeWeb = claudeWebBridge, remoteSetup = claudeRemoteSetup
        let deadline = ShutdownDeadline(), claudeActivity = claudeActivityMonitor, deepseekActivity = deepseekActivityMonitor
        var operations: [ApplicationLifecycleCoordinator.Resource: ApplicationLifecycleCoordinator.Cleanup] = [
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claude?.stop() },
            .cloud: { if sleeping { await cloud?.suspend() } else { await cloud?.stop() } },
            .realtime: { await desktop?.shutdown(deadline: deadline) }, .balance: { await balance?.stop() },
            .claudeActivity: { await claudeActivity.shutdown(deadline: deadline) }, .deepseekActivity: { await deepseekActivity.shutdown() },
            .remoteSetup: { await remoteSetup?.shutdown() }
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
        navigation.invalidate(); navigationState.cancel(); navigationOpens.removeAll(); navigationHosts.removeAll()
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
        let sourceIsCurrent: Bool
        if entry.target.claudeCloud != nil || entry.target.sourceHostID == nil { sourceIsCurrent = true }
        else if let source = entry.target.sourceHostID, source.hasPrefix(ConnectionSource.controlPrefix) {
            sourceIsCurrent = entry.target.provider == .codex && allowedRemoteControlHosts.contains(source)
        } else if let source = entry.target.sourceHostID, source.hasPrefix(ConnectionSource.wslPrefix) {
            sourceIsCurrent = monitorWSL && wslServices?.registry.profile(id: source, provider: entry.target.provider) != nil
        } else {
            sourceIsCurrent = monitorSSH && (entry.target.provider == .claude ? claudeRemoteTargets : codexRemoteTargets).contains { $0.id == entry.target.sourceHostID }
        }
        return active && projectionReady && navigationEntry(context: entry.link.context)?.link == entry.link && enabled.contains(entry.target.provider) && sourceIsCurrent &&
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
