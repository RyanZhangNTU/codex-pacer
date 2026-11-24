import Foundation
import PacerCore
#if os(Windows)
import CWindowsSupport
#endif

public enum PacerEngine {
    public static func run() async {
        if TaskProgressReporter.serveLocalHarnessIfRequested(arguments: CommandLine.arguments, read: EngineInput.read) { return }
        #if os(Windows)
        // First, so a failure anywhere below leaves a report.
        WindowsCrashReport.install()
        if WindowsCrashReport.diagnose() { return }
        if WindowsLowAddressDiagnostic.run() { return }
        #endif
        WindowsResources.configure()
        #if os(Windows)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ssh-terminal" {
            WindowsSSHTerminal.run(CommandLine.arguments[2]); return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--wsl-terminal" {
            WindowsWSLResume.run(CommandLine.arguments[2]); return
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
            codexRemoteProgressServices: demo || readOnly ? nil : .codexProgress(ssh: ssh, wsl: wsl),
            allowsLiveClaudeWeb: !demo && !readOnly, claudeWebReference: claudeReference, claudeHookServices: hookServices,
            codexHookServices: demo || readOnly ? nil : .live(runtimeRoot: progressRoot),
            managesCodexProgress: !demo && !readOnly, managesDeepSeekProgress: !demo && !readOnly, managesLocalHarnessProgress: !demo && !readOnly,
            codexProgressPaths: .init(root: progressRoot), allowsStorageRecovery: !readOnly)
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

private final class EngineInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.codexpacer.windows.host-input", qos: .utility)
    static func read() throws -> Data? {
        #if os(Windows)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = pacer_read_stdin(&buffer, buffer.count)
        guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
        return count == 0 ? nil : Data(buffer.prefix(Int(count)))
        #else
        let bytes = try FileHandle.standardInput.read(upToCount: 4096)
        return bytes?.isEmpty == false ? bytes : nil
        #endif
    }
    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try Self.read())
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
    private let codexHookServices: EngineCodexHookServices?
    /// Not keyed to the Codex source: replacing the source (as initialization
    /// does) must not cancel the setup it started. A new home sets up again.
    private static let codexHookKey = ApplicationWorkRegistry.Key(.setup, identifier: "codex-hooks")
    private var codexHookTask: Task<Void, Never>? {
        get { ownedWork.task(Self.codexHookKey) }
        set { setOwnedTask(newValue, key: Self.codexHookKey) }
    }
    private var codexHookHome: URL?, codexHookExecutable: String?, codexHookRequest: UUID?
    private var codexHooksEnabled = false
    /// The last setup pass; nil while one runs or Codex is not managed.
    private var codexHookResult: CodexHookSetupResult?
    /// Codex Desktop is there to open its settings, where the user allows the hooks.
    private var codexHooksOpenSettings = false
    /// Whether the last setup found the Codex CLI; nil until it looked.
    private var codexExecutableFound: Bool?
    private var codexTrustWatch: CodexHookTrustWatch?
    /// The hooks last waited for the user; when Pacer then saw them allowed, earlier turns ran without them.
    private var codexHooksAwaitingApproval = false, codexHooksTrustedAt: Date?
    /// The newest hook row and the newest rollout change, read at most once a minute.
    private var codexHookActivity: (hook: Date?, turn: Date?, checked: Date?) = (nil, nil, nil)
    private var codexHookActivityRequest: UUID?
    private var expanded = false
    private var projectionReady = false
    private var lifecycle = ApplicationLifecycleCoordinator()
    private var generation: UInt64 { lifecycle.revision }
    private var active: Bool { initialized && lifecycle.acceptsObservedWork }
    private var lastRemoteDiscovery = Date.distantPast, lastClaudeDiscovery = Date.distantPast
    private var sequence: UInt64 = 0
    private var snapshotEmission = EngineSnapshotEmission()
    private var hideProjects = false
    private var showEmbeddedCodexSessions = true
    /// Dot (Durable) tasks are opt-in: off, no catalog poll starts and the
    /// Durable progress plugin is removed.
    private var monitorDurable = false
    private var monitorWSL = false
    private let wslServices: WindowsWSLServices?
    private var wslNeedsReconcile = false
    private var wslAvailability: WindowsWSLAvailability?
    private var wslWatch: (any ActivityFileWatch)?
    private var wslWatchID = UUID()
    private var wslEpoch: UInt64 = 0
    private var wslFallback: Task<Void, Never>?
    private struct WSLDiscoveryRequest {
        var checkInstalled = false
        var forceProfiles = false
        var manual = false
        func merging(_ other: Self) -> Self {
            .init(checkInstalled: checkInstalled || other.checkInstalled,
                  forceProfiles: forceProfiles || other.forceProfiles, manual: manual || other.manual)
        }
    }
    private var pendingWSLDiscovery: WSLDiscoveryRequest?
    private var wslRecoverAfter = Date.distantPast
    private var wslReconnects: [AgentProvider: Set<String>] = [:]
    private var boundWSLCodex: [RemoteActivityTarget] = [], boundWSLClaude: [RemoteActivityTarget] = []
    private var boundWSLCompletionProfiles: [WindowsWSLProfile] = []
    private struct SourceQuotaState {
        var windows: [EngineQuota.Window]?
        var refreshing = false
        var error: String?
        var profile: WindowsWSLProfile?
    }
    private var wslQuota: [String: SourceQuotaState] = [:]
    /// Dot's account scope; its catalog poll sets it again once it is rebuilt.
    private var durableAccountScope: String?
    /// Dot tasks from the catalog poll, kept apart from SSH and WSL tasks.
    private var durableState = DurableActivityState()
    private var durableActivities: [SessionActivity] = []
    private var durableConfiguration: String?
    private var desktopBinding = UUID()
    private var desktopConfiguration: String?
    private var showEmbeddedClaudeSessions = true
    private var showClaudeCloudProjects = true
    private var monitorSSH = true
    private var sshReconnect = SSHReconnectPolicy()
    private let sshServices: WindowsSSHServices?
    private let claudeRemoteServices: EngineClaudeRemoteServices?
    private lazy var claudeRemoteSetup = claudeRemoteServices.map { WindowsClaudeRemoteCoordinator(services: $0, now: now, maximumTargets: 16) }
    private var claudeRemoteSetups: [EngineClaudeRemoteSetup] = []
    /// Pacer's Codex progress tool on SSH and WSL hosts, with Claude's schedule.
    private let codexRemoteProgressServices: EngineClaudeRemoteServices?
    private lazy var codexRemoteProgress = codexRemoteProgressServices.map { WindowsClaudeRemoteCoordinator(services: $0, now: now, maximumTargets: 16) }
    private var codexRemoteProgressInput: String?
    private var codexRemoteTargets: [RemoteActivityTarget] = [], claudeRemoteTargets: [RemoteActivityTarget] = []
    private var claudeRemoteStatuses: [String: RuntimeStreamStatus] = [:]
    private var localStreamStatuses: [AgentProvider: RuntimeStreamStatus] = [:]
    private var deepseekSettings = EngineDeepSeekSettings()
    private var reminderSettings = EngineReminderSettings()
    private func notifies(_ kind: CompactIslandLayout.Warning) -> Bool { reminderSettings.notifies(kind) }
    private var panelSettings = EngineExpandedPanelSettings()
    /// Claude's self-reported progress ring; off until the desktop turns it on.
    private var claudeProgressRing = false
    /// Codex for Claude; off until the desktop turns it on.
    private var codexDelegationSettings = EngineCodexDelegationSettings()
    private var codexDelegationHome: URL?
    private var codexDelegationLedger: (at: Date, links: [String: CodexDelegationLink])?
    private var codexDelegationRuns: [ClaudeCodexDelegation.Run] = []
    /// The quota left last written for the runner's quota floor.
    private var codexDelegationQuotaWritten: (left: Double?, at: Date?)?
    private var codexDelegationStatusCache: (at: Date, value: EngineCodexDelegationStatus)?
    private var codexDelegationCheck = CodexDelegationCheck()
    private var codexProgressRing = false
    private var deepseekProgressRing = false
    private var disabledHarnessProgress: Set<AgentProvider> = []
    /// Account credits the host read after its own sign-in, by module.
    private var accountCredits: [AgentProvider: (credits: HarnessAccountCredits, stale: Bool)] = [:]
    private var creditsNoticePolicy = HarnessCreditsNoticePolicy()
    private var resetExpiryNoticePolicy = ResetExpiryNoticePolicy()
    private var hiddenTurnCredits: Set<AgentProvider> = []
    private var creditSettings: [AgentProvider: HarnessCreditsSettings] = [:]
    /// Data folders chosen in Settings for local modules.
    private var harnessHomeOverrides: [AgentProvider: URL] = [:]
    private let managesLocalHarnessProgress: Bool
    private var localProgressQueues: [AgentProvider: ProgressSetupQueue<LocalHarnessProgressSetup.Target>] = [:]
    private var localProgressTasks: [AgentProvider: Task<Void, Never>] = [:]
    private var localProgressStatuses: [AgentProvider: LocalHarnessProgressSetup.State] = [:]
    /// The module's app as the host last saw it, for the reopen step.
    private var localHarnessApps: [AgentProvider: HarnessProgressGuide.AppPresence] = [:]
    private var localHarnessViews: [AgentProvider: HarnessProgressGuide.AppView] = [:]
    /// When the user opened each app's connectors from the card.
    private var openedHarnessConnectors: [AgentProvider: Date] = [:]
    private let managesDeepSeekProgress: Bool
    private var deepseekProgressQueue = ProgressSetupQueue<DeepSeekProgressSetup.Target>()
    /// The latest DeepSeek setup, which shutdown lets finish.
    private var deepseekProgressTask: Task<Void, Never>?
    private var deepseekProgressSetup: DeepSeekProgressSetupStatus?
    private let managesCodexProgress: Bool
    private let codexProgressPaths: WindowsCodexProgressPaths
    private var codexProgressQueue = ProgressSetupQueue<CodexProgressSetup.Target>()
    private var codexProgressSetup: CodexProgressSetupStatus?
    private var lastFailedSetupRetry = Date.distantPast
    private let codexProgressGate = CodexProgressSwitchGate()
    private var progressRingProviders: Set<AgentProvider> {
        var providers: Set<AgentProvider> = []
        if claudeProgressRing { providers.insert(.claude) }
        if codexProgressRing { providers.insert(.codex) }
        if deepseekProgressRing { providers.insert(.deepseek) }
        providers.formUnion(localHarnesses.definitions.filter { $0.descriptor.hasTaskProgress }.map(\.descriptor.id)
            .filter { !disabledHarnessProgress.contains($0) })
        return providers
    }
    /// The Claude home where this engine switched the ring on.
    private var claudeProgressSwitchHome: URL?
    private var deepseekNoticePolicy = DeepSeekNoticePolicy()
    private var spikeSnoozedUntil = Date.distantPast
    private var retention: TimeInterval = 30 * 60
    private var enabled = Set(HarnessRegistry.legacyIDs)
    private var clientSupportsHarnessModules = false
    private var supportedProviders: [AgentProvider] {
        HarnessRegistry.legacyIDs + (clientSupportsHarnessModules ? localHarnesses.definitions.map(\.descriptor.id) : [])
    }
    private let localHarnessDefinitions: [LocalHarnessDefinition]
    private lazy var localHarnesses = LocalHarnessMonitors(platform: .windows,
        io: .init(files: WindowsFileSystem(), events: WindowsActivityLogWatcher(), now: now), registered: localHarnessDefinitions)
    private typealias ActivityAdapters = HarnessActivityAdapters<@Sendable () async -> Void>
    private lazy var activityAdapters: ActivityAdapters = makeActivityAdapters()

    private func makeActivityAdapters() -> ActivityAdapters {
        let desktop = desktopMonitor, claude = claudeActivityMonitor, deepseek = deepseekActivityMonitor
        let codex = ActivityAdapters.Adapter(start: { [weak self] in await self?.refresh(discover: true, refreshActivityMonitors: false) },
            reset: { [weak self] in await self?.resetCodexActivity() },
            discoverRoutes: { [weak self] in await self?.discoverCodexActivityRoutes() },
            updatePolicy: { [weak self] policy, flush in await self?.applyCodexActivityPolicy(policy, flush: flush) },
            stop: { [weak self] deadline, _, _ in await self?.stopDurable(); await desktop?.shutdown(deadline: deadline) },
            collect: { [weak self] context in await self?.collectCodexLogs(context) })
        return ActivityAdapters([
            .codex: codex,
            .claude: .init(start: { [weak self] in await self?.bindClaudeActivity() },
                reset: { [weak self] in await self?.resetClaudeActivity() },
                discoverRoutes: { [weak self] in await self?.discoverClaudeActivityRoutes() },
                refresh: { await claude.refresh() },
                updatePolicy: { policy, flush in await claude.updateRefreshPolicy(policy, flushPending: flush) },
                stop: { deadline, _, _ in await claude.shutdown(deadline: deadline) }),
            .deepseek: .init(start: { [weak self] in await self?.bindDeepSeekActivity() },
                reset: { [weak self] in await self?.resetDeepSeekActivity() }, refresh: { await deepseek.refresh() },
                updatePolicy: { policy, flush in await deepseek.updateRefreshPolicy(policy, flushPending: flush) },
                stop: { _, _, _ in await deepseek.shutdown() })
        ], local: localHarnesses.definitions) { provider in
            .local(start: { [weak self] in await self?.bindLocalHarness(provider) },
                   reset: { [weak self] in await self?.resetLocalHarness(provider) },
                   monitor: { [weak self] in await self?.localActivityMonitor(provider) })
        }
    }

    private func localActivityMonitor(_ provider: AgentProvider) -> (any LocalHarnessMonitor)? { localHarnesses[provider] }
    private var harnessActivities = HarnessActivitySources()
    private var moduleSettings = ProviderModules()
    private var moduleConfigurationActive = false
    private var installation: ProviderInstallationDetection?
    private var lastInstallationDetection = Date.distantPast
    private let detectInstallation: @Sendable () async -> ProviderInstallationDetection
    private var codexHome: URL
    private var usesCustomCodexHome = false
    private let defaultCodexHome: URL
    private var codexExecutable = ""
    private var claudeHome: URL
    private let defaultClaudeHome: URL
    private var deepseekHome: URL
    private let defaultDeepseekHome: URL
    private let sourceSettings: CodexSourceSettingsServices
    private var codexReader = EngineRuntime.makeCodexReader()
    /// Every Codex reader asks Windows which processes still hold a quiet turn's rollout for writing.
    static func makeCodexReader() -> LocalActivityReader {
        #if os(Windows)
        LocalActivityReader(fileMetadata: { WindowsFileSystem().metadata($0) },
            writerProbe: { file, home in WindowsProcessOwnership.hasWriter(of: file, within: home) })
        #else
        LocalActivityReader(fileMetadata: { WindowsFileSystem().metadata($0) })
        #endif
    }
    private var navigation = ActivityNavigationRegistry()
    private var notificationNavigation = ActivityNavigationRegistry()
    private var notificationActivities: [SessionActivity] = []
    private var notificationRegistry: EngineNotificationRegistry
    private let navigationServices: ActivityNavigationServices
    private lazy var claudeActivityMonitor = ClaudeActivityMonitor(clock: now, ssh: sshServices, wsl: wslServices,
        wslDisconnected: { [weak self] provider, source in await self?.wslHelperDisconnected(provider: provider, source: source) })
    private lazy var deepseekActivityMonitor = DeepSeekActivityMonitor(clock: now)
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
    private var demoActivity = HarnessActivity()
    private let desktopServices: CodexDesktopServices?
    private var desktopState: CodexDesktopState?
    private var pendingDesktopEndings: [String: SessionActivity] { get { activityState.pendingCodexEndings } set { activityState.pendingCodexEndings = newValue } }
    private var latestFirstOutput: (at: Date, seconds: Double)? { activityState.latestFirstOutput }
    private lazy var desktopMonitor: RealtimeActivityMonitor? = desktopServices?.makeMonitor(ssh: sshServices, wsl: wslServices,
        targets: { [weak self] _ in await self?.monitoredRemoteTargets(.codex) ?? [] },
        wslDisconnected: { [weak self] provider, source in await self?.wslHelperDisconnected(provider: provider, source: source) })
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
    private var claudeVerification = ClaudeVerificationAfterSignIn()
    /// The host reads claude.ai in its own browser profile, as `ClaudeWebBridge.fetchesInBrowser`.
    private var claudeWebFetches = false
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
    private var immediateRefreshRequested = false
    private var collectHandoff = EngineCollectHandoff()
    private var forceBalanceRequested = false
    private var codexMetricsPending = false
    private let codexMetricsWork = ApplicationWorkRegistry.Key(.presentation, provider: .codex, identifier: "log-metrics")
    #if os(Windows)
    private var watchedCodexLogURLs: [URL] = []
    /// Sizes of the followed rollouts and the hook spool at the last clock check.
    /// Codex keeps a rollout open while it writes, and Windows reports a size
    /// change of an open file only once it is closed or flushed to disk.
    private var codexLogSizes: [URL: UInt64] = [:]
    /// When a running local Codex turn's evidence runs out and it needs one more
    /// read although nothing grew (`LocalActivityReader.nextRunningExpiry`).
    private var codexRunningExpiry: Date?
    /// The Codex packages the last hook setup saw, and when a Codex too old for
    /// hooks was last checked for an update: a new package version sets up again.
    private var codexHookPackages: [String] = []
    private var codexUpdateCheckedAt: Date?
    // Give a burst of writes time to land before reading lifecycle evidence.
    private static let codexFileEventCoalescing: TimeInterval = 0.1
    private lazy var logWatcher = ActivityLogWatcher { [weak self] discover in
        Task { await self?.refresh(discover: discover, refreshActivityMonitors: false, fileEvent: true) }
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
         codexRemoteProgressServices: EngineClaudeRemoteServices? = nil,
         cloudServices: ClaudeCloudServices? = nil,
         navigationServices: ActivityNavigationServices? = nil,
         navigationClock: @escaping @Sendable () -> TimeInterval = { ActivityNavigationState.monotonicNow },
         navigationErrorDuration: TimeInterval = TaskRowInteraction.navigationErrorDuration,
         activityHostServices: ActivityHostServices = .live,
         allowsLiveClaudeWeb: Bool = false,
         claudeWebReference: Bool = false,
         claudeHookServices: EngineClaudeHookServices? = nil,
         codexHookServices: EngineCodexHookServices? = nil,
         managesCodexProgress: Bool = false,
         managesDeepSeekProgress: Bool = false,
         managesLocalHarnessProgress: Bool = false,
         codexProgressPaths: WindowsCodexProgressPaths = .init(root: WindowsCodexProgressPaths.defaultRoot),
         allowsStorageRecovery: Bool = true,
         sourceSettings: CodexSourceSettingsServices = .live,
         localHarnessDefinitions: [LocalHarnessDefinition] = HarnessRegistry.localHarnesses,
         installationDetection: @escaping @Sendable () async -> ProviderInstallationDetection = {
             await Task.detached(priority: .utility) { ProviderInstallationDetection.detect() }.value
         },
         output: @escaping @Sendable (Data) -> Void = { try? FileHandle.standardOutput.write(contentsOf: $0) }) {
        self.demo = demo; self.now = now; self.output = output; self.quotaServices = quotaServices; self.desktopServices = desktopServices
        self.allowsStorageRecovery = allowsStorageRecovery
        self.sourceSettings = sourceSettings
        self.localHarnessDefinitions = localHarnessDefinitions
        self.balanceServices = balanceServices
        self.claudeServices = claudeServices; self.allowsLiveClaudeWeb = allowsLiveClaudeWeb
        self.cloudServices = cloudServices
        self.wslServices = wslServices
        self.sshServices = sshServices
        self.claudeRemoteServices = claudeRemoteServices
        self.codexRemoteProgressServices = codexRemoteProgressServices
        self.navigationServices = navigationServices ?? (demo ? .demo : .live)
        self.navigationClock = navigationClock; self.navigationErrorDuration = navigationErrorDuration
        self.activityHostServices = activityHostServices
        self.claudeWebReference = claudeWebReference && demo
        self.claudeHookServices = claudeHookServices
        self.codexHookServices = codexHookServices
        self.managesCodexProgress = managesCodexProgress; self.codexProgressPaths = codexProgressPaths
        self.managesDeepSeekProgress = managesDeepSeekProgress
        self.managesLocalHarnessProgress = managesLocalHarnessProgress
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
        send(["protocolVersion": EngineProtocol.version, "type": "hello", "engine": "PacerEngine",
              "harnessModules": localHarnesses.definitions.map(\.descriptor.id.rawValue)])
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
                activities: activities, inbox: inbox, active: active, scope: entry.cloudContext, requests: requests) else {
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
                input.allowsDurable = allowsRemoteSource(DurableActivityCatalog.hostID, provider: target.provider)
                input.wslProfile = target.sourceHostID.flatMap { wslServices?.registry.profile(id: $0, provider: target.provider) }
                if let profile = input.wslProfile, let services = wslServices,
                   !(await services.validate(profile, provider: target.provider)) { throw ActivityNavigationError.unavailable }
                let plan: EngineNavigationPlan
                if localHarnesses.definition(for: target.provider) != nil {
                    guard let url = harnessActivities[target.provider]?.conversationURLs[target.id] else {
                        throw ActivityNavigationError.unavailable
                    }
                    plan = .init(context: context, provider: target.provider, url: url)
                } else { plan = try await navigationServices.resolve(input) }
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
                activities: &values, inbox: &retained, scope: entry.cloudContext, now: navigationClock(), requests: requests), result.accepted else {
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
            let rows = harnessActivities[.claude]?.activities ?? []
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
            cloudWebAvailable = available; claudeWebFetches = available && command.params?.webFetch == true
            await claudeWebBridge.setAvailable(available, fetching: claudeWebFetches); await claudeQuotaMonitor?.setWebAvailable(available)
            await bindClaudeCloudMonitor(); await claudeCloudMonitor?.startAfterPublication()
            _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded, force: true)
        case "claudeWebResult":
            guard usesClaudeWeb, let id = command.params?.requestID, let context = command.params?.context, let reply = command.params?.claudeSession,
                  await claudeWebBridge.complete(id: id, context: context, reply: reply) else {
                failure(id: command.id, code: "staleWebReply"); return true
            }
        case "claudeFetchResult":
            guard usesClaudeWeb, let id = command.params?.requestID, let context = command.params?.context, let reply = command.params?.claudeFetch,
                  await claudeWebBridge.complete(id: id, context: context, fetched: reply) else {
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
            if !claudeWebPaused { claudeVerification.reset(signedIn: command.params?.signedIn == true) }
            await bindClaudeCloudMonitor(reset: true)
            await monitor.configure(home: claudeHome, organization: claudeOrganization,
                enabled: usesClaudeWeb && enabled.contains(.claude) && !claudeWebPaused, context: lifecycle.version(.claude), reset: true)
            await claudeCloudMonitor?.startAfterPublication()
            _ = await monitor.refreshIfDue(expanded: expanded, force: true)
        case "retryHarnessProgressSetup":
            guard active, managesLocalHarnessProgress, clientSupportsHarnessModules, let name = command.params?.provider,
                  let definition = localHarnesses.definitions.first(where: { $0.descriptor.id.rawValue == name }),
                  definition.progressConfigFile != nil else { failure(id: command.id, code: "unavailable"); return true }
            scheduleLocalHarnessProgress(definition, force: true)
            if projectionReady { publish(notices: []) }
        case "refreshHarnessProgressConnection":
            guard active, let name = command.params?.provider,
                  let definition = localHarnesses.definitions.first(where: { $0.descriptor.id.rawValue == name }),
                  definition.progressConnection != nil else { failure(id: command.id, code: "unavailable"); return true }
            let provider = definition.descriptor.id
            if let running = command.params?.appRunning {
                let started = command.params?.appStartedAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                let presence: HarnessProgressGuide.AppPresence? = running ? started.map { .running(since: $0) } : .notRunning
                // The host knows when the user opened the connectors from the
                // card; a closed app starts over at its connectors.
                var opened = openedHarnessConnectors
                opened[provider] = running ? command.params?.openedConnectorsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } : nil
                // WorkBuddy notes in its log when it shows its connector market
                // and when its custom connectors list its servers.
                var view: HarnessProgressGuide.AppView?
                if let openedAt = opened[provider], case .running(let since)? = presence {
                    // The log can be read back several megabytes; off the engine's actor.
                    let log = definition.appLogFile.map { localHarnessHome(definition).appendingPathComponent($0) }
                    let data = await Task.detached(priority: .utility) { log.flatMap { HarnessAppLog.read($0, since: min(openedAt, since)) } }.value
                    guard active else { return true }
                    view = HarnessAppLog.view(in: data, opened: openedAt, appStarted: since, now: now())
                }
                if localHarnessApps[provider] != presence || localHarnessViews[provider] != view || opened != openedHarnessConnectors {
                    localHarnessApps[provider] = presence; localHarnessViews[provider] = view; openedHarnessConnectors = opened
                    if projectionReady { publish(notices: []) }
                }
            }
            // Once the app has made its folder, setup continues without a retry.
            if localProgressStatuses[provider]?.setup == .missingHome { scheduleLocalHarnessProgress(definition, force: true) }
            else { scheduleLocalHarnessProgress(definition, inspectOnly: true) }
        case "inspectProviderHome":
            guard let name = command.params?.provider, let provider = AgentProvider(rawValue: name),
                  provider == .claude || provider == .deepseek || localHarnesses.definition(for: provider) != nil else {
                failure(id: command.id, code: "invalidCommand"); return true
            }
            let local = localHarnesses.definition(for: provider)
            let current = local.map(localHarnessHome) ?? (provider == .claude ? claudeHome : deepseekHome)
            let home = command.params?.sourceHome ?? EngineCodexSourceReport.path(current)
            guard home.utf8.count <= 32768, !home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                failure(id: command.id, code: "invalidCommand"); return true
            }
            let fallback = local.map { $0.defaultHome() } ?? (provider == .claude ? defaultClaudeHome : defaultDeepseekHome), isDemo = demo
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
        case "retryCodexHooks":
            guard codexHookServices != nil, enabled.contains(.codex) else { failure(id: command.id, code: "codexHooksUnavailable"); return true }
            scheduleCodexHooks(force: true)
            publish(notices: [])
        case "retryCodexProgressSetup":
            guard managesCodexProgress, codexProgressRing, enabled.contains(.codex) else { failure(id: command.id, code: "codexProgressSetupUnavailable"); return true }
            scheduleCodexProgressSetup(force: true)
            publish(notices: [])
        case "retryDeepSeekProgressSetup":
            // Turning the switch off can fail too; its retry removes the entry again.
            guard managesDeepSeekProgress, deepseekProgressRing && enabled.contains(.deepseek) || [.conflict, .failed].contains(deepseekProgressSetup) else {
                failure(id: command.id, code: "deepseekProgressSetupUnavailable"); return true
            }
            scheduleDeepSeekProgressSetup(force: true)
            publish(notices: [])
        case "initialize", "configure":
            let plan: ApplicationLifecycleCoordinator.Plan
            let previous = clientSupportsHarnessModules
            if command.method == "initialize", !initialized { clientSupportsHarnessModules = command.supportsHarnessModules == true }
            do { plan = try await configure(command.params) }
            catch { clientSupportsHarnessModules = previous; failure(id: command.id, code: "invalidConfiguration"); return true }
            if command.method == "initialize" { snapshotEmission = .init() }
            initialized = true
            await bindQuotaMonitor()
            if lifecycle.phase == .cold {
                let start = lifecycle.start()
                await performLifecycle(start)
                startWSLMonitoring()
                await refresh(discover: true)
            } else { await performLifecycle(plan) }
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
        case "setAccountCredits":
            guard active, !demo, let name = command.params?.provider, let provider = AgentProvider(rawValue: name),
                  HarnessRegistry.descriptor(for: provider)?.reportsAccountCredits == true else {
                failure(id: command.id, code: "unavailable"); return true
            }
            if let value = command.params?.accountCredits {
                accountCredits[provider] = (value, command.params?.stale == true)
            } else {
                accountCredits[provider] = nil; creditsNoticePolicy.reset(provider)
            }
            if projectionReady { publish(notices: []) }
        case "refreshLocalHarness":
            guard active, let name = command.params?.provider, let provider = AgentProvider(rawValue: name),
                  enabled.contains(provider), localHarnesses[provider] != nil, let refresh = activityAdapters[provider]?.refresh else {
                failure(id: command.id, code: "unavailable"); return true
            }
            await refresh()
        case "refreshWSL":
            guard active, initialized, wslServices != nil else { failure(id: command.id, code: "unavailable"); return true }
            scheduleWSLDiscovery(.init(checkInstalled: true, forceProfiles: true, manual: true))
        case "refreshTaskSources":
            guard active else { failure(id: command.id, code: "unavailable"); return true }
            scheduleConnectionRetry()
        case "reconnectSSH":
            // A network change or the user's return; ignored while asleep or off.
            scheduleSSHReconnect()
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
                for provider in supportedProviders where provider == .codex || enabled.contains(provider) {
                    let policy: ActivityRefreshPolicy = value ? .expanded : .collapsed
                    await activityAdapters[provider]?.updatePolicy(policy, true)
                }
            }
            await claudeCloudMonitor?.setExpanded(value)
            if !value, codexMetricsPending { scheduleCodexMetrics() }
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
        case "checkCodexDelegation":
            checkCodexDelegation(); publish(notices: [])
        case "clearDelegationHistory":
            // Pacer keeps no Codex for Claude history any more; older hosts may still ask.
            publish(notices: [])
        case "reinstallDelegationSkill":
            codexDelegationStatusCache = nil; scheduleClaudeHooks(force: true)
        case "stopDelegation":
            // The runner stops Codex and tells Claude the user stopped it in Pacer. A review run's row is
            // its review sub-thread, which the ledger names only once the run ends.
            guard let id = command.params?.activityID, let link = activityState.codexDelegation(forActivityID: id), link.status == .running,
                  ClaudeCodexDelegation.requestStop(directory: link.directory) else {
                failure(id: command.id, code: "notRunning"); return true
            }
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
        let byProviderID = Dictionary(uniqueKeysWithValues: supportedProviders.map { ($0.rawValue, $0) })
        // A host can know modules this engine doesn't support yet, or the other
        // way round. Ignore those IDs and apply the rest of the update.
        func moduleIDs(_ names: [String]) throws -> [AgentProvider] {
            // Module IDs are lowercase words joined by hyphens; anything else is malformed.
            guard names.count <= 128, names.allSatisfy({ $0.range(of: #"^[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil }) else {
                throw EngineCommand.Failure.invalid
            }
            return names.compactMap { byProviderID[$0] }
        }
        let explicitProviders = try parameters.enabledProviders.map { Set(try moduleIDs($0)) }
        if let minutes = parameters.retentionMinutes, !(0...10080).contains(minutes) { throw EngineCommand.Failure.invalid }
        if let value = parameters.deepseekSettings, !value.isValid { throw EngineCommand.Failure.invalid }
        if let value = parameters.reminderSettings, !value.isValid { throw EngineCommand.Failure.invalid }
        if let value = parameters.expandedPanel, !value.isValid { throw EngineCommand.Failure.invalid }
        let selectedProgress = try parameters.disabledHarnessProgress.map { names -> Set<AgentProvider> in
            let eligible = Set(localHarnesses.definitions.filter { $0.descriptor.hasTaskProgress }.map(\.descriptor.id))
            return Set(try moduleIDs(names).filter(eligible.contains))
        }
        let selectedHiddenCredits = try parameters.hiddenTurnCredits.map { Set(try moduleIDs($0)) }
        let selectedCredits = try parameters.harnessCredits.map { values -> [AgentProvider: HarnessCreditsSettings] in
            _ = try moduleIDs(Array(values.keys))
            var result: [AgentProvider: HarnessCreditsSettings] = [:]
            for (name, value) in values {
                guard let provider = byProviderID[name], HarnessRegistry.descriptor(for: provider)?.reportsAccountCredits == true else { continue }
                result[provider] = value
            }
            return result
        }
        let selectedHomes = try parameters.harnessHomes.map { homes -> [AgentProvider: URL] in
            _ = try moduleIDs(Array(homes.keys))
            var result: [AgentProvider: URL] = [:]
            for (name, path) in homes where !path.isEmpty {
                guard let provider = byProviderID[name], localHarnesses.definition(for: provider) != nil else { continue }
                result[provider] = try Self.home(path)
            }
            return result
        }
        guard parameters.providerModes == nil || explicitProviders == nil else { throw EngineCommand.Failure.invalid }
        var updatedSettings = moduleSettings
        if let explicitProviders {
            for provider in supportedProviders { updatedSettings.setMode(explicitProviders.contains(provider) ? .enabled : .disabled, for: provider) }
        }
        if let modes = parameters.providerModes {
            _ = try moduleIDs(Array(modes.keys))
            for (name, raw) in modes {
                guard let provider = byProviderID[name] else { continue }
                guard let mode = ProviderModuleMode(rawValue: raw) else { throw EngineCommand.Failure.invalid }
                updatedSettings.setMode(mode, for: provider)
            }
        }
        var detected = installation
        if parameters.providerModes != nil {
            let previous = generation
            // The demo's computer has the three original apps; WorkBuddy shows in
            // the demo once turned on, so the reference scenes stay as they were.
            if demo { detected = .init(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true) } else { lastInstallationDetection = now(); detected = withCustomHomes(await detectInstallation(), selectedHomes ?? harnessHomeOverrides) }
            guard generation == previous else { throw EngineCommand.Failure.invalid }
        }
        let selectedProviders = explicitProviders ?? (parameters.providerModes == nil ? nil :
            updatedSettings.enabledProviders(detection: detected ?? .init(installed: []), supported: supportedProviders))
        let changesCodex = codex.map { $0 != codexHome } ?? false
        let changesClaude = claude.map { $0 != claudeHome } ?? false
        let changesDeepSeek = deepseek.map { $0 != deepseekHome } ?? false
        var requestedWSL = parameters.monitorWSL
        if requestedWSL == true, !monitorWSL, !demo, let wslServices {
            let previous = generation
            let availability = await wslServices.discover(monitoring: false)
            guard generation == previous else { throw EngineCommand.Failure.invalid }
            wslAvailability = availability ?? .failed
            if availability != .available {
                if initialized {
                    if projectionReady { projectCollected(at: now()) }
                    throw EngineCommand.Failure.invalid
                }
                if availability == .unavailable { requestedWSL = false }
            }
        }
        let wslProvidersChanged = selectedProviders.map { $0.intersection(WindowsWSLProfile.providers) != enabled.intersection(WindowsWSLProfile.providers) } ?? false
        projectionReady = false
        activityDisplayTask = nil; activityDisplayDeadline = nil
        if let codex, let override = parameters.codexHome {
            codexHome = codex; usesCustomCodexHome = !override.isEmpty
        }
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
        if let value = parameters.codexDelegation, value != codexDelegationSettings { codexDelegationSettings = value; codexDelegationStatusCache = nil }
        if let value = parameters.codexProgressRing { codexProgressRing = value }
        if let value = parameters.deepseekProgressRing { deepseekProgressRing = value }
        if let selectedProgress { disabledHarnessProgress = selectedProgress }
        if let selectedHiddenCredits { hiddenTurnCredits = selectedHiddenCredits }
        if let selectedCredits { creditSettings = selectedCredits }
        // A moved data folder changes the module's source identity, which
        // resets it through the lifecycle plan below.
        if let selectedHomes { harnessHomeOverrides = selectedHomes }
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
        var durableChanged = false
        if let value = parameters.monitorDurable, value != monitorDurable {
            monitorDurable = value; durableChanged = true
            if !value { pendingDesktopEndings = pendingDesktopEndings.filter { $0.value.sourceHostID != DurableActivityCatalog.hostID } }
        }
        if let value = requestedWSL, value != monitorWSL {
            monitorWSL = value; wslNeedsReconcile = true
            stopWSLMonitoring()
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
        if let value = parameters.expandedPanel { panelSettings = value }
        if let minutes = parameters.retentionMinutes { retention = minutes == 0 ? .infinity : Double(minutes) * 60 }
        if changesCodex { codexReader = Self.makeCodexReader() }
        if changesClaude { resetClaudeLocalSource() }
        if changesDeepSeek {
            harnessActivities.remove(.deepseek); deepseekUsage = DeepSeekLocalUsage()
            deepseekNoticePolicy = .init()
        }
        if changesCodex || changesClaude || changesDeepSeek { activityState.clearFirstOutput() }
        if changesCodex || changesClaude || wslProvidersChanged {
            stopWSLMonitoring()
            wslNeedsReconcile = true
        }
        if changesCodex || changesClaude {
            ownedWork.cancel(.init(.discovery, identifier: "ssh"))
            codexRemoteTargets = []; claudeRemoteTargets = []; claudeRemoteStatuses = [:]
        }
        applyClaudeProgressSwitch()
        applyCodexDelegationSwitch()
        // The Dot switch installs or removes the Durable progress plugin.
        scheduleCodexProgressSetup(force: durableChanged)
        scheduleCodexHooks()
        scheduleDeepSeekProgressSetup()
        for definition in localHarnesses.definitions { scheduleLocalHarnessProgress(definition) }
        boundWSLCompletionProfiles = wslCompletionProfiles
        bindCodexCompletionSources()
        bindWSLCompletionSources(.claude)
        inbox.bindSourceHomes(provider: .deepseek, localHome: deepseekHome)
        let plan = lifecycle.settings(lifecycleConfiguration)
        await bindClaudeRemoteSetup()
        await bindCodexRemoteProgress()
        for provider in plan.changedProviders {
            resetSourceState(provider)
            navigationState.cancel(provider: provider)
            navigationOpens = navigationOpens.filter { $0.value.activity.provider != provider }
            hostTracking.cancel(provider: provider, clearApplications: true)
        }
        if durableChanged { bindDurableMonitor() }
        return plan
    }

    private var lifecycleConfiguration: ApplicationLifecycleCoordinator.Configuration {
        var sources: [AgentProvider: String] = [.codex: codexHome.path + "|" + codexExecutable,
            .claude: claudeHome.path,
            .deepseek: deepseekHome.path]
        for definition in localHarnesses.definitions where enabled.contains(definition.descriptor.id) {
            sources[definition.descriptor.id] = localHarnessHome(definition).path
        }
        return .init(enabled: enabled, sources: sources)
    }

    private func localHarnessHome(_ definition: LocalHarnessDefinition) -> URL {
        harnessHomeOverrides[definition.descriptor.id] ??
            definition.resolveHome(override: WindowsEnvironment.value(definition.homeEnvironmentKey, in: ProcessInfo.processInfo.environment),
                isAbsolute: WindowsCodexExecutableDiscovery.absolute)
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
            startWSLMonitoring()
        }
    }

    private func resetClaudeLocalSource() {
        harnessActivities.remove(.claude)
        localStreamStatuses[.claude] = nil
    }

    private func bindActivityMonitor(_ provider: AgentProvider) async {
        guard !demo, active else { return }
        await activityAdapters[provider]?.start()
    }

    private func refreshHarnesses() async {
        for provider in supportedProviders where enabled.contains(provider) {
            await activityAdapters[provider]?.refresh?()
        }
    }

    private func discoverCodexActivityRoutes() async {
        lastRemoteDiscovery = now()
        scheduleRemoteDiscovery()
        await bindDesktopMonitor()
    }

    private func discoverClaudeActivityRoutes() async {
        await bindActivityMonitor(.claude)
        scheduleRemoteDiscovery()
    }

    private func resetCodexActivity() async {
        if enabled.contains(.codex) { await quotaMonitor?.refreshIfDue(expanded: expanded, force: true) }
    }

    private func resetClaudeActivity() async {
        if enabled.contains(.claude) { _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded, force: true) }
        await bindActivityMonitor(.claude)
    }

    private func resetDeepSeekActivity() async {
        if enabled.contains(.deepseek) { _ = await balanceMonitor?.refreshIfDue(active: expanded, requested: true) }
        await bindActivityMonitor(.deepseek)
    }

    private func applyCodexActivityPolicy(_ policy: ActivityRefreshPolicy, flush: Bool) async {
        await desktopMonitor?.updateRefreshPolicy(policy, flushPending: flush && policy == .expanded)
        await updateCodexLogWatches(flushPending: flush && policy == .expanded)
    }

    private func bindClaudeActivity(retryingWSL: Set<String> = []) async {
        guard !demo, active else { return }
        let context = lifecycle.version(.claude)
        scheduleClaudeHooks()
        lastClaudeDiscovery = now()
        if enabled.contains(.claude) {
            await claudeActivityMonitor.start(home: claudeHome, remoteTargets: monitoredRemoteTargets(.claude),
                refreshPolicy: expanded ? .expanded : .collapsed, retryingRemoteSources: retryingWSL) { [weak self] rows, statuses, attention, performance in
                await self?.receiveClaudeLocal(rows, statuses: statuses, attention: attention, performance: performance, context: context)
            }
        } else { await activityAdapters[.claude]?.stop(ShutdownDeadline(), .reset, nil); resetClaudeLocalSource() }
        await bindClaudeRemoteSetup()
    }

    private func bindDeepSeekActivity() async {
        guard !demo, active else { return }
        let context = lifecycle.version(.deepseek)
        if enabled.contains(.deepseek) {
            await deepseekActivityMonitor.start(home: deepseekHome, refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] rows, statuses, attention, performance, usage in
                await self?.receiveDeepSeekLocal(rows, statuses: statuses, attention: attention, performance: performance, usage: usage, context: context)
            }
        } else {
            await activityAdapters[.deepseek]?.stop(ShutdownDeadline(), .reset, nil)
            harnessActivities.remove(.deepseek); deepseekUsage = DeepSeekLocalUsage()
        }
    }

    private func bindLocalHarness(_ provider: AgentProvider) async {
        guard enabled.contains(provider), let definition = localHarnesses.definition(for: provider) else { return }
        let context = lifecycle.version(provider)
        let monitor = localHarnesses.monitor(for: definition)
        let home = localHarnessHome(definition)
        if harnessActivities.isBound(provider) { await monitor.refresh(); return }
        harnessActivities.bind(provider, home: home, generation: context)
        await monitor.start(home: home, policy: expanded ? .expanded : .collapsed) { [weak self] snapshot in
            await self?.receiveHarness(provider, snapshot: snapshot, version: context)
        }
    }

    private func resetLocalHarness(_ provider: AgentProvider) async {
        guard active else { return }
        let context = lifecycle.version(provider)
        if let monitor = localHarnesses.remove(provider), let stop = activityAdapters[provider]?.stop {
            let deadline = ShutdownDeadline()
            await deadline.perform([{ await stop(deadline, .reset, monitor) }])
        }
        guard active, lifecycle.version(provider) == context else { return }
        await bindActivityMonitor(provider)
    }

    private func receiveHarness(_ provider: AgentProvider, snapshot: HarnessActivity, version: UInt64) {
        guard active, lifecycle.version(provider) == version, enabled.contains(provider),
              let update = harnessActivities.receive(provider, snapshot: snapshot) else { return }
        if update.scopeChanged {
            navigationState.cancel(provider: provider)
            navigationOpens = navigationOpens.filter { $0.value.activity.provider != provider }
            activityState.removeHarness(provider)
        }
        if update.needsSourceBinding {
            inbox.bindSourceHomes(provider: provider, localHome: navigationHome(for: provider), localAccountScope: update.activity.scope)
        }
        noteLocalHarnessProgress(provider, snapshot: snapshot)
        if projectionReady, refreshTask == nil { projectCollected(at: now()) }
        else { handOffToCollect(localSnapshot: true) }
    }

    private func moduleProjection(_ provider: AgentProvider) -> EngineModule {
        let definition = localHarnesses.definition(for: provider)
        let descriptor = definition?.descriptor
        let status = descriptor == nil ? nil : harnessActivities[provider]?.status?.rawValue
        var module = EngineModule(provider: provider.rawValue, mode: moduleSettings.mode(for: provider).rawValue,
            installed: installation?.isInstalled(provider), enabled: enabled.contains(provider),
            displayName: descriptor?.name, symbol: descriptor?.symbol, status: status,
            usage: harnessActivities[provider]?.usage,
            progressConnector: descriptor.map(\.progressConnector), hasTaskProgress: descriptor.map(\.hasTaskProgress),
            reportsSessionUsage: descriptor.map(\.reportsSessionUsage), reportsAccountCredits: descriptor.map(\.reportsAccountCredits),
            progressSetup: localProgressStatuses[provider]?.setup,
            progressConnection: localProgressStatuses[provider]?.connection)
        if let registered = HarnessRegistry.descriptor(for: provider) {
            module.brand = .init(registered.brand); module.website = registered.website
            module.balance = registered.balance?.rawValue
        }
        module.prominent = moduleLibrary.entries.first { $0.provider == provider }?.prominent
        if let descriptor, descriptor.progressConnector {
            let state = localProgressStatuses[provider]
            module.progressGuide = HarnessProgressGuide(setup: state?.setup, connection: state?.connection, reported: state?.reported ?? false,
                ringOn: enabled.contains(provider) && !disabledHarnessProgress.contains(provider), name: descriptor.name,
                addedAt: state?.addedAt, removedAt: state?.removedAt, app: localHarnessApps[provider], view: localHarnessViews[provider],
                openedConnectors: openedHarnessConnectors[provider] != nil)
        }
        if let daily = demo && provider == .workbuddy ? DemoScenario.workbuddyDaily(at: now()) : harnessActivities[provider]?.usage?.daily {
            module.week = HarnessWeekPresentation.week(provider: provider, daily: daily, now: now())
        }
        if let definition, let scheme = definition.conversationScheme, let publisher = definition.macSigningOrganization {
            module.launch = .init(scheme: scheme, publisher: publisher, executables: definition.windowsExecutables,
                                  connectorsPath: definition.connectorsPath)
        }
        // The data folder and its default stay in the Settings query.
        if definition != nil { module.local = true }
        if enabled.contains(provider) {
            module.monitoring = EngineStatusRow(monitoring(provider, installed: installation?.isInstalled(provider) == true))
            if provider == .codex {
                module.account = EngineStatusRow(demo ? .signedIn(plan: "pro") : CodexAccountState(quota: codexQuota, error: codexQuotaState?.error),
                                                 opensCodex: codexHooksOpenSettings)
            }
        }
        return module
    }

    /// Whether Pacer reads the module's tasks on this computer, in the words
    /// every module page shares.
    private func monitoring(_ provider: AgentProvider, installed: Bool) -> ModuleMonitoring {
        let sessions = ModuleMonitoring.localSessions(activities, provider: provider, at: now())
        if demo { return .init(.on, sessions: sessions) }
        switch provider {
        case .codex:
            guard codexHookServices != nil else { return .init(.checking) }
            return .codex(executableFound: codexExecutableFound, hooks: codexHookStatus ?? (codexExecutableFound == true ? .notInstalled : nil),
                          sessions: sessions, opensCodex: codexHooksOpenSettings)
        case .claude:
            let setup: ModuleMonitoring.Setup = switch claudeHookSetup?.state {
            case .ready?: .ready
            case .settingUp?, .needsSetup?: .configuring
            case .missingHome?: .missingHome
            case .failed?: .failed
            case .disabled?, nil: .checking
            }
            return .claude(setup, sessions: sessions)
        case .deepseek:
            return .deepseek(found: harnessActivities[.deepseek]?.status.map { $0 == .ready }, sessions: sessions)
        default:
            return .harness(harnessActivities[provider]?.status, detected: installed, sessions: sessions)
        }
    }

    /// A data folder chosen in Settings counts as an installation once it
    /// holds the app's data.
    private func withCustomHomes(_ detection: ProviderInstallationDetection, _ homes: [AgentProvider: URL]) -> ProviderInstallationDetection {
        let custom = homes.filter { localHarnesses.definition(for: $0.key)?.hasLocalData(home: $0.value) == true }.keys
        return custom.isEmpty ? detection : .init(installed: detection.installed.union(custom))
    }

    private var moduleLibrary: ModuleLibrary {
        ModuleLibrary(modules: moduleSettings, detection: installation ?? .init(installed: []), supported: supportedProviders)
    }

    private func scheduleLocalHarnessProgress(_ definition: LocalHarnessDefinition, force: Bool = false, inspectOnly: Bool = false) {
        guard !demo, managesLocalHarnessProgress, clientSupportsHarnessModules, let configFile = definition.progressConfigFile else { return }
        let provider = definition.descriptor.id
        let home = localHarnessHome(definition)
        let reporter = EngineCodexSourceReport.path(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        let wanted = enabled.contains(provider) && !disabledHarnessProgress.contains(provider)
        if inspectOnly {
            guard wanted, localProgressStatuses[provider]?.setup == .configured, localProgressTasks[provider] == nil else { return }
        }
        let target = LocalHarnessProgressSetup.Target(home: home, configFile: configFile, reporter: reporter, enabled: wanted,
                                                       ruleDirectory: definition.progressRuleDirectory)
        guard let ticket = localProgressQueues[provider, default: .init()].request(target, force: force || inspectOnly) else { return }
        if !inspectOnly { localProgressStatuses[provider] = wanted ? .init(.settingUp) : nil }
        let paths = codexProgressPaths
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await LocalHarnessProgressSetup.sync(ticket, storage: WindowsLocalProfileStorage(),
                    connection: definition.progressConnection, inspectOnly: inspectOnly, prepare: { home in
                    // WorkBuddy trusts a command by its path, so its reporter keeps one.
                    guard let command = await Self.prepareProgressReporter(home: home, paths: paths, stablePath: true) else { return nil }
                    return paths.localHarnessCommand(command, home: home)
                }, owns: { paths.ownsLocalHarness($0, arguments: $1, home: $2) })
            }.value
            await self?.receiveLocalHarnessProgress(result, provider: provider, ticket: ticket)
        }
        localProgressQueues[provider]?.track(task)
        localProgressTasks[provider] = task
    }

    private static func prepareProgressReporter(home: URL, paths: WindowsCodexProgressPaths, stablePath: Bool = false) async -> CodexProgressCommand? {
        guard let data = await EngineInstallerHooks.run([stablePath ? "--prepare-local-harness-progress" : "--prepare-codex-progress", paths.root.path, home.path],
                                                        runtimeRoot: paths.root),
              let command = try? JSONDecoder().decode(CodexProgressCommand.self, from: data), paths.owns(command, home: home) else { return nil }
        return command
    }

    /// The first reported estimate confirms the whole chain, so the card
    /// collapses; an app that has just made its folder lets setup continue.
    private func noteLocalHarnessProgress(_ provider: AgentProvider, snapshot: HarnessActivity) {
        guard let definition = localHarnesses.definition(for: provider), let state = localProgressStatuses[provider] else { return }
        if state.setup == .missingHome, localProgressTasks[provider] == nil {
            scheduleLocalHarnessProgress(definition, force: true)
        } else if state.setup == .configured, !state.reported, snapshot.activities.contains(where: { $0.selfReportedProgress != nil }) {
            localProgressStatuses[provider]?.reported = true
            let home = localHarnessHome(definition)
            Task.detached(priority: .utility) { LocalHarnessProgressSetup.markReported(home, storage: WindowsLocalProfileStorage()) }
        }
    }

    private func receiveLocalHarnessProgress(_ status: LocalHarnessProgressSetup.State?, provider: AgentProvider,
                                             ticket: ProgressSetupQueue<LocalHarnessProgressSetup.Target>.Ticket) {
        guard localProgressQueues[provider]?.finish(ticket) == true else { return }
        localProgressTasks[provider] = nil
        // Inspections repeat while the guide waits; only a change is published.
        let changed = localProgressStatuses[provider] != status
        localProgressStatuses[provider] = status
        if projectionReady && changed { publish(notices: []) }
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
        applyCodexDelegationSwitch(setupConfirmed: report.state == .ready)
        codexDelegationStatusCache = nil
        publish(notices: [])
    }
    /// Installs Pacer's Codex hooks while the Codex module is on and removes
    /// them when it is off, as the Claude hooks are; a changed Codex home or CLI
    /// sets up again.
    private func scheduleCodexHooks(force: Bool = false) {
        guard let services = codexHookServices else { return }
        let active = enabled.contains(.codex), home = codexHome, executable = codexExecutable
        guard force || codexHookHome != home || codexHookExecutable != executable || codexHooksEnabled != active else { return }
        codexHookTask?.cancel()
        let previous = codexHooksEnabled && codexHookHome != home ? codexHookHome : nil
        if codexHookHome != home { codexHooksAwaitingApproval = false; codexHooksTrustedAt = nil }
        codexHookHome = home; codexHookExecutable = executable; codexHooksEnabled = active
        let request = UUID(); codexHookRequest = request
        codexHookResult = nil
        codexHookActivity = (nil, nil, nil); codexHookActivityRequest = nil
        #if os(Windows)
        codexHookPackages = Self.codexPackages(); codexUpdateCheckedAt = now()
        #endif
        watchCodexHookTrust(false)
        codexExecutableFound = nil
        codexHookTask = Task { [weak self] in
            if let previous { _ = await services.apply(previous, executable, false) }
            let found = !active || services.findsExecutable(executable)
            let result = await services.apply(home, executable, active)
            let opens = active && services.opensSettings()
            guard !Task.isCancelled else { return }
            await self?.receiveCodexHookSetup(result, opensSettings: opens, executableFound: found, request: request)
        }
    }
    private func receiveCodexHookSetup(_ result: CodexHookSetupResult, opensSettings: Bool, executableFound: Bool, request: UUID) {
        guard codexHookRequest == request else { return }
        codexHookTask = nil; codexHookResult = result; codexHooksOpenSettings = opensSettings; codexExecutableFound = executableFound
        let notices = updateCodexHookState()
        if initialized { publish(notices: notices) }
    }
    /// Codex ran turns while the spool stayed silent: hooks stopped running.
    /// Only the reader's hook state and rollout folder dates are read, at most
    /// once a minute. While the hooks are reported silent, a new hook row is
    /// checked at once, so the notice clears by itself, as on the Mac.
    private func refreshCodexHookActivity() {
        guard codexHooksEnabled, codexHookResult?.installed == true, let home = codexHookHome, codexHookActivityRequest == nil else { return }
        let date = now(), due = date.timeIntervalSince(codexHookActivity.checked ?? .distantPast) >= 60
        guard due || codexHookStatus == .notRunning else { return }
        let request = UUID(), reader = codexReader, seen = codexHookActivity.hook
        codexHookActivityRequest = request
        if due { codexHookActivity.checked = date }
        Task { [weak self] in
            if !due, await reader.lastHookRow == seen {
                await self?.skipCodexHookActivity(request: request)
                return
            }
            let evidence = await reader.hookEvidence(home: home, now: date)
            await self?.receiveCodexHookActivity(hook: evidence.lastHookEvent, turn: evidence.lastCodexTurn, request: request)
        }
    }
    /// No hook row arrived since the silence was found; nothing to recompute.
    private func skipCodexHookActivity(request: UUID) {
        if codexHookActivityRequest == request { codexHookActivityRequest = nil }
    }
    private func receiveCodexHookActivity(hook: Date?, turn: Date?, request: UUID) {
        guard codexHookActivityRequest == request else { return }
        codexHookActivityRequest = nil
        let before = codexHookStatus
        codexHookActivity.hook = hook; codexHookActivity.turn = turn
        let notices = updateCodexHookState()
        if initialized, codexHookStatus != before || !notices.isEmpty { publish(notices: notices) }
    }
    /// After the setup result, the trust or the activity changes: notes when the
    /// user allowed the hooks, sends the one approval notice, and follows the
    /// trust while it waits for the user or after Codex failed to report it.
    private func updateCodexHookState() -> [IslandNotice] {
        var notices: [IslandNotice] = []
        let awaitsTrust = codexHookResult?.awaitsTrust == true
        switch codexHookStatus {
        case .needsApproval?:
            codexHooksAwaitingApproval = true
            notices = codexHooksNotice()
        case .running?, .notRunning?:
            // Just allowed: the turns so far ran without the hooks, so their silence says nothing.
            if codexHooksAwaitingApproval { codexHooksAwaitingApproval = false; codexHooksTrustedAt = now() }
        case nil: break
        case .notInstalled? where awaitsTrust: break // The trust is unknown, not changed.
        default: codexHooksAwaitingApproval = false
        }
        if case .needsApproval? = codexHookStatus { watchCodexHookTrust(true) } else { watchCodexHookTrust(awaitsTrust, due: true) }
        return notices
    }
    /// The one notice asking to allow Pacer's hooks in Codex, the first time approval is needed.
    private func codexHooksNotice() -> [IslandNotice] {
        guard case .needsApproval = codexHookStatus, let marker = codexHookServices?.noticeMarker,
              !FileManager.default.fileExists(atPath: marker.path) else { return [] }
        // Unsaved, the notice would return with every setup pass, so none is sent.
        do {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
        } catch { return [] }
        return [IslandNotice(id: "codex:hooks-approval", kind: .waitingForInput,
                             title: L10n.text("codex.hooks.notice_title"), detail: L10n.text("codex.hooks.notice_body"))]
    }
    /// The user has to act in Codex before local Codex tasks can show.
    private var codexHooksNeedUser: Bool {
        switch codexHookStatus {
        case .needsApproval, .notRunning: return true
        default: return false
        }
    }
    private static let codexTrustKey = ApplicationWorkRegistry.Key(.setup, identifier: "codex-hooks-trust")
    /// While the hooks wait for the user, a change to Codex's config is the cue
    /// to ask Codex for their trust (`CodexHookTrustWatch`); only the trust call
    /// runs, and the plugin stays as it is. After a failed trust read the watch
    /// is `due` and asks at its first check.
    private func watchCodexHookTrust(_ on: Bool, due: Bool = false) {
        guard on, let services = codexHookServices, let home = codexHookHome, let executable = codexHookExecutable else {
            ownedWork.cancel(Self.codexTrustKey); codexTrustWatch = nil; return
        }
        guard ownedWork.task(Self.codexTrustKey) == nil else { return }
        let file = CodexHookTrustWatch.trustFile(home: home)
        codexTrustWatch = CodexHookTrustWatch(stamp: Self.modified(file), now: now(), due: due)
        let owner = ownedWork.begin(Self.codexTrustKey, version: generation)
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(CodexHookTrustWatch.interval))
                guard let engine = self else { return }
                guard !Task.isCancelled, await engine.shouldCheckCodexHookTrust(file: file, owner: owner) else { continue }
                let trust = await services.trust(home, executable)
                await engine.receiveCodexHookTrust(trust, home: home, owner: owner)
            }
        }
        ownedWork.attach(task, to: owner)
    }
    private func shouldCheckCodexHookTrust(file: URL, owner: ApplicationWorkRegistry.Ticket) -> Bool {
        guard ownedWork.owns(owner), codexHookTask == nil, var watch = codexTrustWatch else { return false }
        let check = watch.shouldCheck(stamp: Self.modified(file), now: now())
        codexTrustWatch = watch
        return check
    }
    private func receiveCodexHookTrust(_ trust: [String]?, home: URL, owner: ApplicationWorkRegistry.Ticket) {
        guard ownedWork.owns(owner), codexHookHome == home, codexHookTask == nil, let trust,
              let result = codexHookResult, result.installed == true, trust != result.trust else { return }
        let before = codexHookStatus
        codexHookResult = .init(supportsHooks: result.supportsHooks, installed: result.installed, trust: trust)
        let notices = updateCodexHookState()
        if initialized, codexHookStatus != before || !notices.isEmpty { publish(notices: notices) }
    }
    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
    private var codexHookStatus: CodexHookStatus? {
        guard codexHookServices != nil else { return nil }
        guard codexHooksEnabled else { return .off }
        guard let result = codexHookResult else { return nil }
        return CodexHookStatus.evaluate(enabled: true, supportsHooks: result.supportsHooks, installed: result.installed, trust: result.trust,
                                        lastHookEvent: codexHookActivity.hook, lastCodexTurn: codexHookActivity.turn,
                                        trustedAt: codexHooksTrustedAt, now: now())
    }
    /// Profile files are written off the actor, like the Codex setup.
    private func scheduleDeepSeekProgressSetup(force: Bool = false) {
        guard managesDeepSeekProgress, let ticket = deepseekProgressQueue.request(
            .init(home: deepseekHome, enabled: deepseekProgressRing && enabled.contains(.deepseek)), force: force) else { return }
        deepseekProgressSetup = ticket.target.enabled ? .settingUp : nil
        let task = Task { [weak self] in
            await ticket.waitForPrevious()
            let status = await Self.configureDeepSeekReporter(ticket)
            await self?.receiveDeepSeekProgressSetup(status, ticket: ticket)
        }
        deepseekProgressQueue.track(task); deepseekProgressTask = task
    }

    private static func configureDeepSeekReporter(_ ticket: ProgressSetupQueue<DeepSeekProgressSetup.Target>.Ticket) async -> DeepSeekProgressSetupStatus? {
        DeepSeekProgressSetup.sync(from: ticket.previous, to: ticket.target, storage: WindowsLocalProfileStorage())
    }

    private func receiveDeepSeekProgressSetup(_ status: DeepSeekProgressSetupStatus?, ticket: ProgressSetupQueue<DeepSeekProgressSetup.Target>.Ticket) {
        guard deepseekProgressQueue.finish(ticket) else { return }
        deepseekProgressSetup = status
        if initialized { publish(notices: []) }
    }

    private func scheduleCodexProgressSetup(force: Bool = false) {
        guard managesCodexProgress, let ticket = codexProgressQueue.request(
            .init(home: codexHome, executable: codexExecutable, enabled: codexProgressRing && enabled.contains(.codex)), force: force) else { return }
        let paths = codexProgressPaths, target = ticket.target, durable = monitorDurable
        // Turning reporting off, or leaving a home, takes effect at once: an
        // earlier setup may still be waiting for Codex, and Pacer may exit
        // before the registration itself is removed.
        let gate = codexProgressGate
        let generation = gate.change(home: target.home, wanted: target.enabled, previous: ticket.previous?.home, storage: WindowsLocalProfileStorage())
        codexProgressSetup = target.enabled ? .settingUp : nil
        codexProgressQueue.track(Task { [weak self] in
            await ticket.waitForPrevious()
            if let previous = ticket.previous, previous.home != target.home {
                _ = await Self.configureCodexReporter(home: previous.home, executable: previous.executable, enabled: false, paths: paths)
            }
            let status = await Self.configureCodexReporter(home: target.home, executable: target.executable, enabled: target.enabled, paths: paths,
                                                           durable: durable, gate: gate, request: generation)
            await self?.receiveCodexProgressSetup(status, ticket: ticket)
        })
    }

    private func receiveCodexProgressSetup(_ status: CodexProgressSetupStatus?, ticket: ProgressSetupQueue<CodexProgressSetup.Target>.Ticket) {
        guard codexProgressQueue.finish(ticket) else { return }
        codexProgressSetup = status
        if initialized { publish(notices: []) }
    }

    private static func configureCodexReporter(home: URL, executable: String, enabled: Bool, paths: WindowsCodexProgressPaths,
                                              durable: Bool = false, gate: CodexProgressSwitchGate? = nil,
                                              request: Int = 0) async -> CodexProgressSetupStatus? {
        guard enabled || CodexProgressSetup.wasConfigured(in: home) || WindowsDurableProgressSetup.wasConfigured(in: home) else { return nil }
        let reporter: CodexProgressCommand?
        if enabled {
            guard let command = await prepareProgressReporter(home: home, paths: paths) else { return .failed }
            reporter = command
        } else { reporter = nil }
        let status = await CodexProgressSetup.apply(home: home, reporter: reporter, storage: WindowsLocalProfileStorage(),
                                              gate: gate, request: request, owns: {
            paths.owns($0, home: home) || $0.isNative(named: "PacerEngine.exe", home: home)
        }) {
            CodexClient.findExecutable(customPath: executable).map { CodexClient(executable: $0, home: home, timeout: 3) }
        }
        if !enabled || status == .ready, durable || WindowsDurableProgressSetup.wasConfigured(in: home) {
            // The Dot plugin is best effort: a failed install leaves local
            // sessions reporting and is retried by the next setup. Removal
            // still reports failure so the switch can retry the cleanup.
            // Dot tracking off removes the plugin while local reporting stays.
            let applied = await WindowsDurableProgressSetup.apply(home: home, reporter: durable ? reporter : nil, fallbackExecutable: executable)
            if !enabled, !applied { return .failed }
        }
        return status
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
    /// Codex for Claude's settings file is its switch, written like the
    /// progress ring's: only by an engine that manages the hooks, removed only
    /// where this engine turned it on or its hook setup just confirmed. A
    /// change of the switch brings the plugin's skill current.
    private func applyCodexDelegationSwitch(setupConfirmed: Bool = false) {
        guard claudeHookServices != nil, !demo else { return }
        let wanted = codexDelegationSettings.enabled == true && enabled.contains(.claude) && enabled.contains(.codex)
        if let previous = codexDelegationHome, previous != claudeHome {
            ClaudeCodexDelegation.apply(nil, home: previous); codexDelegationHome = nil
        }
        let config = ClaudeCodexDelegation.configURL(home: claudeHome)
        let before = ClaudeCodexDelegation.isOn(home: claudeHome)
        let trigger = ClaudeCodexDelegation.settings(FileManager.default.contents(atPath: config.path))?.trigger
        if wanted {
            // The runner starts the same Codex program Pacer found, also the one inside Codex Desktop.
            let codex = CodexClient.findExecutable(customPath: codexExecutable)?.path ?? (codexExecutable.isEmpty ? nil : codexExecutable)
            var settings = codexDelegationSettings.settings(codex: codex)
            if usesCustomCodexHome { settings.codexHome = EngineCodexSourceReport.path(codexHome) }
            // The installer owns the pinned Python path. Copy its command once the skill is installed.
            let skill = try? String(contentsOf: ClaudeCodexDelegation.skillURL(home: claudeHome), encoding: .utf8)
            let prefix = "allowed-tools: Bash("
            if let line = skill?.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(":*)") }) {
                settings.command = String(line.dropFirst(prefix.count).dropLast(3))
            }
            if ClaudeCodexDelegation.apply(settings, home: claudeHome) { codexDelegationHome = claudeHome }
        } else if codexDelegationHome == claudeHome || setupConfirmed {
            ClaudeCodexDelegation.apply(nil, home: claudeHome); codexDelegationHome = nil
        }
        codexDelegationQuotaWritten = nil
        // The switch and the trigger are written into the plugin's skill.
        if ClaudeCodexDelegation.isOn(home: claudeHome) != before
            || ClaudeCodexDelegation.settings(FileManager.default.contents(atPath: config.path))?.trigger != trigger {
            codexDelegationStatusCache = nil; scheduleClaudeHooks(force: true)
        }
    }
    /// The ledger, read at most once a second: a run's rollout changes as it
    /// starts, runs and is deleted, so each change brings a reconcile anyway.
    private func codexDelegationLinks(at date: Date) -> [String: CodexDelegationLink] {
        guard !demo, enabled.contains(.claude), enabled.contains(.codex) else { codexDelegationRuns = []; return [:] }
        if let cached = codexDelegationLedger, abs(date.timeIntervalSince(cached.at)) < 1 { return cached.links }
        codexDelegationRuns = ClaudeCodexDelegation.runs(home: claudeHome, runnerExited: WindowsProcessOwnership.hasExited)
        let links = ClaudeCodexDelegation.links(codexDelegationRuns)
        codexDelegationLedger = (date, links); return links
    }
    private func codexDelegationStatus(at date: Date, presentation: ActivityTaskPresentation,
                                       codexQuota: QuotaSnapshot?) -> EngineCodexDelegationStatus? {
        guard !demo, enabled.contains(.claude) else { return nil }
        var value: EngineCodexDelegationStatus
        if let cached = codexDelegationStatusCache, abs(date.timeIntervalSince(cached.at)) < 15 { value = cached.value } else {
            let legacy = ClaudeCodexDelegation.hasLegacySkill(home: claudeHome) ? ClaudeCodexDelegation.legacySkillURL(home: claudeHome).path : nil
            value = EngineCodexDelegationStatus(enabled: ClaudeCodexDelegation.isOn(home: claudeHome),
                skillInstalled: FileManager.default.fileExists(atPath: ClaudeCodexDelegation.skillURL(home: claudeHome).path),
                legacySkill: legacy, codexFound: codexExecutableFound ?? !codexExecutable.isEmpty)
            value.pending = (try? String(contentsOf: ClaudeCodexDelegation.root(home: claudeHome).appendingPathComponent("pending-deletes.txt"), encoding: .utf8))
                .map { Set($0.split(whereSeparator: \.isWhitespace)).count } ?? 0
            value.runsFolder = ClaudeCodexDelegation.root(home: claudeHome).path
            codexDelegationStatusCache = (date, value)
        }
        value.limit = codexDelegationSettings.maxConcurrent ?? 3
        value.login = codexDelegationCheck.login; value.version = codexDelegationCheck.version
        value.checking = codexDelegationCheck.checking ? true : nil
        value.models = codexDelegationCheck.models; value.defaultModel = codexDelegationCheck.defaultModel
        value.defaultEffort = codexDelegationCheck.defaultEffort; value.defaultFast = codexDelegationCheck.defaultFast
        // Runs going now change every second; they come from the task list.
        value.running = presentation.rows.flatMap { row in
            row.delegations.filter { $0.phase == .running }.map { EngineRunningDelegation(parentTitle: row.title, row: EngineTaskRow($0)) }
        }
        // The least quota left, for the runner's quota floor, written when it changes.
        let left = codexQuota?.windows.compactMap(\.remainingPercent).min()
        if value.enabled, codexDelegationQuotaWritten?.left != left || codexDelegationQuotaWritten?.at != codexQuota?.capturedAt {
            if ClaudeCodexDelegation.writeQuota(remainingPercent: left, home: claudeHome, at: codexQuota?.capturedAt ?? date) {
                codexDelegationQuotaWritten = (left, codexQuota?.capturedAt)
            }
        }
        let windows = (codexQuota?.windows ?? []).filter { $0.remainingPercent != nil }.sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
        value.quotaText = windows.isEmpty ? nil : windows.map { $0.label + " " + String(Int($0.remainingPercent!.rounded())) + "%" }.joined(separator: " · ")
        return value
    }
    /// The Collaboration page's self-check: Codex's version, its sign-in, its
    /// model catalog and what its configuration picks for model, effort and
    /// fast mode, from the program Pacer found. No model is called.
    struct CodexDelegationCheck: Equatable {
        var checking = false
        var login: String?
        var version: String?
        var models: [EngineCodexModel]?
        var defaultModel: String?
        var defaultEffort: String?
        var defaultFast: Bool?
    }
    private func checkCodexDelegation() {
        // A demo never runs the user's Codex; its Collaboration page has no status.
        guard !demo, !codexDelegationCheck.checking, let executable = CodexClient.findExecutable(customPath: codexExecutable) else {
            if CodexClient.findExecutable(customPath: codexExecutable) == nil { codexDelegationCheck.login = nil; codexDelegationCheck.version = nil }
            return
        }
        codexDelegationCheck.checking = true
        let home = codexHome
        let environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": EngineCodexSourceReport.path(home)]) { _, home in home }
        Task { [weak self] in
            let version = await WindowsSubprocess.capture(executable: executable, arguments: ["--version"], timeout: 20, limit: 4096, environment: environment)
                .map { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isWhitespace).last.map(String.init) } ?? nil
            // `codex login status` exits non-zero when signed out.
            let login = await WindowsSubprocess.capture(executable: executable, arguments: ["login", "status"], timeout: 20, limit: 4096, environment: environment)
            let catalog = await WindowsSubprocess.capture(executable: executable, arguments: ["debug", "models"], timeout: 60, limit: 1024 * 1024, environment: environment)
            let models = catalog.flatMap(Self.codexModels)
            let check = Self.codexDelegationDefaults(home: home, models: models,
                login: version == nil ? "unknown" : login == nil ? "missing" : "ok", version: version)
            await self?.receiveCodexDelegationCheck(check)
        }
    }
    private func receiveCodexDelegationCheck(_ check: CodexDelegationCheck) {
        codexDelegationCheck = check
        publish(notices: [])
    }
    /// What the runner follows by default: config.toml's model, effort and
    /// service tier, else the catalog's first model and that model's own effort.
    static func codexDelegationDefaults(home: URL, models: [EngineCodexModel]?, login: String, version: String?) -> CodexDelegationCheck {
        let model = configuredValue("model", home: home)
        let effort = configuredValue("model_reasoning_effort", home: home)
            ?? models?.first { $0.slug == model }?.defaultEffort ?? models?.first?.defaultEffort
        let tier = configuredValue("service_tier", home: home)
        return CodexDelegationCheck(checking: false, login: login, version: version, models: models, defaultModel: model ?? models?.first?.slug,
                                    defaultEffort: effort, defaultFast: tier.map { $0 == "priority" || $0 == "fast" } ?? false)
    }
    /// The efforts Settings → Collaboration offers, as on the Mac.
    static let codexDelegationEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
    static func codexModels(_ data: Data) -> [EngineCodexModel]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        let models = list.prefix(64).compactMap { model -> EngineCodexModel? in
            guard let slug = model["slug"] as? String, slug.utf8.count <= 80, [nil, "list"].contains(model["visibility"] as? String) else { return nil }
            let efforts = ((model["supported_reasoning_levels"] as? [Any]) ?? []).prefix(12).compactMap { level -> String? in
                let effort = (level as? [String: Any])?["effort"] as? String ?? level as? String
                return effort.flatMap { codexDelegationEfforts.contains($0) ? $0 : nil }
            }
            let fallback = (model["default_reasoning_level"] as? String).flatMap { codexDelegationEfforts.contains($0) ? $0 : nil }
            return EngineCodexModel(slug: slug, name: ModelDisplay.name(slug, provider: .codex), efforts: efforts.isEmpty ? nil : efforts, defaultEffort: fallback)
        }
        return models.isEmpty ? nil : models
    }
    /// A top-level `key = "…"` of Codex's config.toml.
    static func configuredValue(_ key: String, home: URL) -> String? {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix(key), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let raw = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("\""), let end = raw.dropFirst().firstIndex(of: "\"") else { return nil }
            let value = String(raw[raw.index(after: raw.startIndex)..<end])
            return value.isEmpty || value.utf8.count > 80 ? nil : value
        }
        return nil
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
        harnessActivities.replace(.claude, with: .init(
            activities: Self.measured(rows, performance).filter { allowsRemoteSource($0.sourceHostID, provider: .claude) },
            requests: attention.filter { allowsRemoteSource($0.sourceHostID, provider: .claude) },
            status: status?.connected == true && status?.sourceAvailable != false ? .ready : .unavailable))
        cloudLocalSessions.update(harnessActivities[.claude]?.activities ?? [])
        if projectionReady, refreshTask == nil { projectCollected(at: now()) }
        else { handOffToCollect(localSnapshot: true) }
    }
    private func receiveDeepSeekLocal(_ rows: [SessionActivity], statuses: [String: RuntimeStreamStatus],
        attention: [PendingAttentionRequest], performance: [SessionPerformanceUpdate], usage: DeepSeekLocalUsage, context: UInt64) async {
        guard active, lifecycle.version(.deepseek) == context, enabled.contains(.deepseek) else { return }
        let previous = Set((harnessActivities[.deepseek]?.activities ?? []).filter { $0.phase == .running }.map { $0.id + "|" + ($0.turnID ?? "") })
        deepseekUsage = usage
        let status = statuses["local"]
        localStreamStatuses[.deepseek] = status
        harnessActivities.replace(.deepseek, with: .init(activities: Self.measured(rows, performance), requests: attention,
            status: status?.connected == true && status?.sourceAvailable != false ? .ready : .unavailable))
        updateLocalWallet()
        if projectionReady, refreshTask == nil {
            projectCollected(at: now())
            await bindBalanceMonitor()
            guard active, lifecycle.version(.deepseek) == context else { return }
            let ended = rows.contains { [.completed, .interrupted].contains($0.phase) && previous.contains($0.id + "|" + ($0.turnID ?? "")) }
            _ = await balanceMonitor?.refreshIfDue(active: expanded || rows.contains { $0.phase == .running }, turnEnded: ended)
        } else { handOffToCollect(localSnapshot: true) }
    }
    /// A projection skipped because a collect is running still has to reach the host.
    private func handOffToCollect(localSnapshot: Bool) {
        guard refreshTask != nil, collectHandoff.skippedProjection(localSnapshot: localSnapshot) else { return }
        refreshRequested = true; immediateRefreshRequested = true
    }
    private func updateLocalWallet() {
        var titles = deepseekUsage.titles
        for activity in harnessActivities[.deepseek]?.activities ?? [] {
            if let task = activity.threadID { titles[task] = activity.title ?? activity.project }
        }
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
        // Trusting the tool in the app, or its first report, can happen while
        // nothing polls; a waiting guide is checked each minute so its steps,
        // the Overview line and the sidebar dot clear (11/16 review).
        for definition in localHarnesses.definitions where definition.progressConnection != nil {
            if let state = localProgressStatuses[definition.descriptor.id], state.setup == .configured,
               state.connection != .trusted || !state.reported {
                scheduleLocalHarnessProgress(definition, inspectOnly: true)
            }
        }
        // A setup that failed, such as on a busy runtime folder, tries again every ten minutes.
        if now().timeIntervalSince(lastFailedSetupRetry) >= 600 {
            lastFailedSetupRetry = now()
            for definition in localHarnesses.definitions where localProgressStatuses[definition.descriptor.id]?.setup == .failed {
                scheduleLocalHarnessProgress(definition)
            }
            if codexProgressSetup == .failed { scheduleCodexProgressSetup() }
        }
        // Automatic modules notice a new or removed app within ten minutes;
        // Settings and source changes detect at once through configure.
        if !demo, moduleConfigurationActive, supportedProviders.contains(where: { moduleSettings.mode(for: $0) == .automatic }),
           now().timeIntervalSince(lastInstallationDetection) >= 600 {
            let previous = generation
            lastInstallationDetection = now()
            let detected = withCustomHomes(await detectInstallation(), harnessHomeOverrides)
            guard active, generation == previous, !Task.isCancelled else { return }
            installation = detected
            let next = moduleSettings.enabledProviders(detection: detected, supported: supportedProviders)
            if next != enabled {
                for provider in enabled.subtracting(next) { inbox.remove(provider: provider) }
                if next.intersection(WindowsWSLProfile.providers) != enabled.intersection(WindowsWSLProfile.providers) {
                    stopWSLMonitoring()
                    wslNeedsReconcile = true
                }
                enabled = next; projectionReady = false
                applyCodexDelegationSwitch()
                for definition in localHarnesses.definitions { scheduleLocalHarnessProgress(definition) }
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
        .init(now: now(), expanded: expanded, lastRemoteDiscovery: lastRemoteDiscovery, lastClaudeDiscovery: lastClaudeDiscovery,
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
                default: break
                }
            case .activity(let provider): await bindActivityMonitor(provider)
            case .discoverActivityRoutes(let provider): await activityAdapters[provider]?.discoverRoutes?()
            case .clock: if !demo { restartPresentationClock() }
            case .displayExpiry: scheduleActivityDisplay(at: now())
            case .pruneActivities: activityState.prune(at: now(), retention: retention)
            case .pruneHistory: codexHistory.prune(at: now()); claudeHistory.prune(at: now())
            case .resetSource(let provider):
                await resetSource(provider)
            case .updateActivityPolicy: await updateCodexLogWatches()
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
        await activityAdapters[provider]?.reset()
    }

    private func resetSourceState(_ provider: AgentProvider) {
        localStreamStatuses[provider] = nil
        notificationActivities.removeAll { $0.provider == provider }
        inbox.remove(provider: provider)
        activities.removeAll { $0.provider == provider }
        requests.removeAll { $0.provider == provider }
        harnessActivities.remove(provider)
        activityState.removeHarness(provider)
        switch provider {
        case .codex:
            clearCodexMetricsBatch()
            #if os(Windows)
            watchedCodexLogURLs = []; codexRunningExpiry = nil
            logWatcher.stop()
            #endif
            desktopBinding = UUID(); stopDurable(); durableAccountScope = nil
            bindCodexCompletionSources()
            desktopState = nil; pendingDesktopEndings = [:]
            codexReader = Self.makeCodexReader()
            codexQuotaState = nil; codexQuota = nil; codexQuotaFailed = false; codexQuotaRefreshing = false
            activityState.codexAttention = .init()
        case .claude:
            resetClaudeLocalSource(); claudeQuotaState = nil; cloudState = nil
            cloudLocalSessions.update([])
            claudeQuotaAttention = .init(); activityState.claudeAttention = .init()
        case .deepseek:
            deepseekUsage = .init(); deepseekNoticePolicy = .init()
            balanceState = nil; walletSource = nil; activityState.deepseekAttention = .init()
        default: break
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

    private func updateCodexLogWatches(flushPending: Bool = false) async {
        #if os(Windows)
        guard active, !demo, enabled.contains(.codex) else { return }
        logWatcher.update(watchedCodexLogURLs, interval: Self.codexFileEventCoalescing,
            flushPending: flushPending)
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
        guard projectionReady else { return }
        #if os(Windows)
        // While a local Codex turn runs, a followed rollout that grew is read as
        // a file event would be. Checking costs one handle query per file. A
        // Codex that crashed writes nothing and sends no Stop, and nothing reads
        // on a timer, so a turn is also read once when its evidence expires.
        if !demo, activities.contains(where: { $0.provider == .codex && $0.sourceHostID == nil && [.running, .waitingForInput].contains($0.phase) }) {
            let expired = codexRunningExpiry.map { $0 <= now() } == true
            if codexLogsGrew() || expired {
                if expired { codexRunningExpiry = nil }
                await refresh(discover: false, refreshActivityMonitors: false, fileEvent: true)
                guard active, projectionReady, !Task.isCancelled else { return }
            }
        } else if !codexLogSizes.isEmpty { codexLogSizes = [:] }
        // Codex too old for hooks: the Store replaces the package folder with the
        // new version's, so a changed list is an update and setup runs again.
        if !demo, codexHookStatus == .needsCodexUpdate, now().timeIntervalSince(codexUpdateCheckedAt ?? .distantPast) >= 60 {
            codexUpdateCheckedAt = now()
            if Self.codexPackages() != codexHookPackages { scheduleCodexHooks(force: true) }
        }
        #endif
        // The metadata projection changes on every clock tick. Do not reopen
        // transcript files or rescan source directories while nothing is written.
        guard activities.contains(where: { [.running, .waitingForInput].contains($0.phase) }) || !quota.isEmpty || codexQuota != nil || claudeQuotaState?.snapshot != nil || enabled.contains(.deepseek) && walletSource != nil else { return }
        if refreshTask == nil { publish(notices: []) } else { handOffToCollect(localSnapshot: false) }
    }
    #if os(Windows)
    /// The installed Codex packages' folders, whose names carry their versions.
    private static func codexPackages() -> [String] { WindowsCodexExecutableDiscovery.packageLocations().map(\.path) }
    /// Whether a followed rollout or the hook spool changed size since the last
    /// check. A file seen for the first time counts as changed, so nothing
    /// written between its read and this check is missed.
    private func codexLogsGrew() -> Bool {
        var sizes: [URL: UInt64] = [:], grew = false
        for file in watchedCodexLogURLs where file.pathExtension.lowercased() == "jsonl" {
            guard sizes.count < 32, let size = WindowsFileSystem().metadata(file)?.size else { continue }
            sizes[file] = size
            if codexLogSizes[file] != size { grew = true }
        }
        codexLogSizes = sizes
        return grew
    }
    #endif

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
        claudeQuotaState = state; claudeVerification.receive(state)
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

    private func bindCodexCompletionSources() {
        inbox.bindSourceHomes(provider: .codex, localHome: codexHome,
            remoteHomes: remoteCompletionHomes(.codex), durableAccountScope: durableAccountScope)
    }
    private var wslCompletionProfiles: [WindowsWSLProfile] {
        monitorWSL ? wslServices?.registry.snapshot().profiles ?? [] : []
    }
    private func wslCompletionHomes(_ provider: AgentProvider) -> [String: String] {
        Dictionary(wslCompletionProfiles.compactMap { profile in
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
    private var monitorsWSLTasks: Bool {
        !demo && active && monitorWSL && !enabled.isDisjoint(with: WindowsWSLProfile.providers)
    }
    private func startWSLMonitoring(checkInstalled: Bool = false) {
        wslNeedsReconcile = false
        watchWSLRegistrations()
        scheduleWSLDiscovery(.init(checkInstalled: checkInstalled))
    }
    private func watchWSLRegistrations() {
        guard monitorsWSLTasks, wslWatch == nil, let services = wslServices else { return }
        let id = UUID()
        if let watch = services.watchRegistrations({ [weak self] armed in
            Task { await self?.wslRegistrationsChanged(id: id, armed: armed) }
        }) {
            wslWatchID = id
            wslWatch = watch
        }
    }
    private func stopWSLMonitoring() {
        wslEpoch &+= 1
        ownedWork.cancel(.init(.discovery, identifier: "wsl"))
        wslFallback?.cancel(); wslFallback = nil
        wslWatchID = UUID(); wslWatch?.stop(); wslWatch = nil
        pendingWSLDiscovery = nil; wslRecoverAfter = .distantPast
        wslReconnects.removeAll()
        boundWSLCodex = []; boundWSLClaude = []
        wslServices?.registry.suspend()
        clearWSLChecking()
    }
    private func clearWSLChecking() {
        if wslAvailability == .checking {
            wslAvailability = wslServices?.registry.installations.map { $0.isEmpty ? .unavailable : .available }
        }
    }
    private func wslRegistrationsChanged(id: UUID, armed: Bool) {
        guard wslWatchID == id, monitorsWSLTasks else { return }
        if !armed { wslWatch?.stop(); wslWatch = nil }
        scheduleWSLDiscovery(.init(checkInstalled: true, forceProfiles: true))
    }
    private func wslHelperDisconnected(provider: AgentProvider, source: String) {
        guard monitorsWSLTasks else { return }
        wslReconnects[provider, default: []].insert(source)
        if now() >= wslRecoverAfter {
            wslRecoverAfter = now().addingTimeInterval(10)
            scheduleWSLDiscovery()
        } else {
            armWSLFallback()
        }
    }
    private func armWSLFallback() {
        guard monitorsWSLTasks, wslFallback == nil, let registry = wslServices?.registry else { return }
        let snapshot = registry.snapshot()
        let attached = Set(snapshot.profiles.filter { snapshot.covers($0, providers: enabled) }.map { $0.distro.lowercased() })
        if wslWatch != nil, let installed = registry.installations, installed.prefix(8).allSatisfy({ attached.contains($0.lowercased()) }),
           wslAvailability == .available { return }
        let epoch = wslEpoch
        wslFallback = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            await self?.runWSLFallback(epoch: epoch)
        }
    }
    private func runWSLFallback(epoch: UInt64) {
        guard !Task.isCancelled, epoch == wslEpoch else { return }
        wslFallback = nil
        scheduleWSLDiscovery(.init(checkInstalled: wslWatch == nil || wslAvailability == .failed))
    }
    private func scheduleWSLDiscovery(_ request: WSLDiscoveryRequest = .init()) {
        let key = ApplicationWorkRegistry.Key(.discovery, identifier: "wsl")
        guard !demo, active, let services = wslServices, monitorsWSLTasks || request.manual else { return }
        if ownedWork.task(key) != nil {
            pendingWSLDiscovery = pendingWSLDiscovery?.merging(request) ?? request
            return
        }
        wslFallback?.cancel(); wslFallback = nil
        let monitoring = monitorsWSLTasks, providers = enabled, date = now()
        if request.checkInstalled || services.registry.installations == nil { wslAvailability = .checking }
        let owner = ownedWork.begin(key, version: wslEpoch)
        let task = Task { [weak self] in
            let availability = await services.discover(checkInstalled: request.checkInstalled, monitoring: monitoring,
                forceProfiles: request.forceProfiles, providers: providers, at: date)
            await self?.receiveWSLDiscovery(owner, availability: availability)
        }
        ownedWork.attach(task, to: owner)
        if request.checkInstalled && projectionReady { projectCollected(at: date) }
    }
    private func receiveWSLDiscovery(_ owner: ApplicationWorkRegistry.Ticket, availability: WindowsWSLAvailability?) async {
        guard ownedWork.owns(owner) else { return }
        defer { ownedWork.finish(owner) }
        guard active, wslEpoch == owner.version else { return }
        let previousCodex = boundWSLCodex, previousClaude = boundWSLClaude
        if let availability { wslAvailability = availability }
        else { clearWSLChecking() }
        if availability == .available { watchWSLRegistrations() }
        if availability == .unavailable && monitorWSL {
            ownedWork.finish(owner)
            monitorWSL = false
            stopWSLMonitoring()
        }
        let epoch = wslEpoch
        for (id, state) in wslQuota {
            guard let profile = state.profile, let provider = AgentProvider(rawValue: String(id.prefix { $0 != ":" })) else { continue }
            if wslServices?.registry.profile(id: profile.id, provider: provider) != profile {
                ownedWork.cancel(.init(.quota, provider: provider, identifier: profile.id)); wslQuota.removeValue(forKey: id)
            }
        }
        let codex = monitoredRemoteTargets(.codex).filter { $0.id.hasPrefix(ConnectionSource.wslPrefix) }
        let claude = monitoredRemoteTargets(.claude).filter { $0.id.hasPrefix(ConnectionSource.wslPrefix) }
        let retryCodex = availability == .available ? (wslReconnects[.codex] ?? []).intersection(codex.map(\.id)) : []
        let retryClaude = availability == .available ? (wslReconnects[.claude] ?? []).intersection(claude.map(\.id)) : []
        if availability == .available, !wslReconnects.isEmpty, let registry = wslServices?.registry {
            let retained = Set(registry.snapshot().profiles.map(\.id))
            wslReconnects[.codex] = wslReconnects[.codex]?.intersection(retained).subtracting(retryCodex)
            wslReconnects[.claude] = wslReconnects[.claude]?.intersection(retained).subtracting(retryClaude)
        }
        // A stopped distribution still owns completions until it is unregistered.
        let completionProfiles = wslCompletionProfiles
        if boundWSLCompletionProfiles != completionProfiles {
            boundWSLCompletionProfiles = completionProfiles
            bindCodexCompletionSources(); bindWSLCompletionSources(.claude)
        }
        if previousCodex != codex || previousClaude != claude || !retryCodex.isEmpty || !retryClaude.isEmpty {
            boundWSLCodex = codex; boundWSLClaude = claude
            await desktopMonitor?.retryInactiveHelpers(sources: retryCodex)
            guard active, epoch == wslEpoch else { return }
            await bindClaudeActivity(retryingWSL: retryClaude)
            guard active, epoch == wslEpoch else { return }
            await bindDesktopMonitor(force: true)
        }
        guard active, epoch == wslEpoch else { return }
        ownedWork.finish(owner)
        if projectionReady { projectCollected(at: now()) }
        if let pending = pendingWSLDiscovery {
            pendingWSLDiscovery = nil
            scheduleWSLDiscovery(pending)
        } else { armWSLFallback() }
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
            desktopState = nil; stopDurable()
            await desktopMonitor?.shutdown(); return
        }
        bindDurableMonitor()
        let configuration = "\(context)|\(codexHome.path)|\(codexExecutable)|\(monitorWSL)|\(monitorSSH)"
        let replace = configuration != desktopConfiguration
        guard force || replace || ownedWork.task(key) == nil else { return }
        desktopConfiguration = configuration
        let binding = replace ? UUID() : desktopBinding
        desktopBinding = binding
        let monitor = desktopMonitor, home = codexHome
        let includeWSL = (monitorWSL && wslServices != nil) || (monitorSSH && sshServices != nil)
        let policy: ActivityRefreshPolicy = expanded ? .expanded : .collapsed
        let start: @Sendable () async -> Void = { [weak self] in
            await monitor?.startAsync(home: home, includeSSH: includeWSL, useSSHFallback: true, refreshPolicy: policy) { [weak self] value in
                await self?.receiveDesktop(CodexDesktopState(context: context, activities: value.activities, names: value.names,
                    performance: value.performance, statuses: value.statuses, unavailable: value.unavailableSources), binding: binding)
            }
        }
        // Test fixtures start inline; production owns the start separately
        // from initialize and quota work, since SSH discovery can wait.
        guard desktopServices?.startsInBackground == true else { await start(); return }
        let owner = ownedWork.begin(key, version: context)
        let task = Task { [weak self] in
            await start()
            await self?.finishDesktopStart(owner)
        }
        ownedWork.attach(task, to: owner)
    }
    private func finishDesktopStart(_ owner: ApplicationWorkRegistry.Ticket) { ownedWork.finish(owner) }

    private static let durableKey = ApplicationWorkRegistry.Key(.remote, provider: .codex, identifier: "durable")
    /// Dot tasks come from the catalog poll while the Dot switch and the Codex module are on.
    private func bindDurableMonitor() {
        guard active, !demo, !lifecycle.isSleeping, enabled.contains(.codex), monitorDurable,
              let observe = desktopServices?.observeDurable else { stopDurable(); return }
        let context = lifecycle.version(.codex), home = codexHome
        let configuration = "\(context)|\(home.path)"
        guard configuration != durableConfiguration || ownedWork.task(Self.durableKey) == nil else { return }
        stopDurable()
        durableConfiguration = configuration
        let owner = ownedWork.begin(Self.durableKey, version: context)
        let publish: @Sendable (DurableActivityCatalog?) async -> Void = { [weak self] catalog in
            await self?.receiveDurableCatalog(catalog, owner: owner)
        }
        let history: @Sendable (String, [DurableTurnHistory]) async -> Void = { [weak self] scope, turns in
            await self?.receiveDurableHistory(turns, scope: scope, owner: owner)
        }
        let finish: @Sendable () async -> Void = { [weak self] in await self?.finishDurable(owner) }
        let task = Task.detached(priority: .utility) {
            await observe(home, publish, history)
            await finish()
        }
        ownedWork.attach(task, to: owner)
    }
    private func finishDurable(_ owner: ApplicationWorkRegistry.Ticket) { ownedWork.finish(owner) }

    private func stopDurable() {
        ownedWork.cancel(Self.durableKey)
        durableConfiguration = nil; durableState = DurableActivityState()
        guard !durableActivities.isEmpty || durableAccountScope != nil else { return }
        durableActivities = []; durableAccountScope = nil
        bindCodexCompletionSources()
        if projectionReady { projectCollected(at: now()) }
    }

    private func receiveDurableCatalog(_ catalog: DurableActivityCatalog?, owner: ApplicationWorkRegistry.Ticket) {
        guard ownedWork.owns(owner), lifecycle.owns(owner) else { return }
        durableState.setCatalog(catalog)
        publishDurable()
    }
    private func receiveDurableHistory(_ turns: [DurableTurnHistory], scope: String, owner: ApplicationWorkRegistry.Ticket) {
        guard ownedWork.owns(owner), lifecycle.owns(owner) else { return }
        durableState.observe(turns, scope: scope, at: now())
        publishDurable()
    }
    private func publishDurable() {
        let scope = durableState.scope
        durableActivities = durableState.activities
        durableState.releasePublishedState()
        if scope != durableAccountScope { durableAccountScope = scope; bindCodexCompletionSources() }
        if projectionReady { projectCollected(at: now()) }
        else { activityState.rememberCodexEndings(durableActivities) }
    }

    private func receiveDesktop(_ state: CodexDesktopState, binding: UUID) {
        guard active, desktopBinding == binding, state.context == lifecycle.version(.codex), enabled.contains(.codex), !demo else { return }
        let rows = state.activities.filter { allowsRemoteSource($0.sourceHostID, provider: .codex) }
        desktopState = .init(context: state.context, activities: rows, names: state.names, performance: state.performance,
            statuses: state.statuses.filter { allowsRemoteSource($0.key, provider: .codex) },
            unavailable: state.unavailable.filter { allowsRemoteSource($0, provider: .codex) })
        inbox.updateNames(state.names); inbox.updatePerformance(state.performance)
        // A host that just connected can get the progress tool.
        Task { [weak self] in await self?.bindCodexRemoteProgress() }
        if projectionReady { projectCollected(at: now()) }
        else {
            // Initialization/source reads may be awaiting I/O. Keep endings
            // until the first projection; a later EOF can release the stream.
            activityState.rememberCodexEndings(rows)
        }
    }
    private func allowsRemoteSource(_ source: String?, provider: AgentProvider) -> Bool {
        guard let source else { return true }
        if source == DurableActivityCatalog.hostID { return provider == .codex && monitorDurable && durableAccountScope != nil }
        if source.hasPrefix(ConnectionSource.wslPrefix) { return monitorWSL && wslServices?.registry.profile(id: source, provider: provider) != nil }
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
        await bindCodexRemoteProgress()
        bindRemoteCompletionSources()
        await bindDesktopMonitor(); await bindActivityMonitor(.claude)
    }
    private func bindRemoteCompletionSources() {
        bindCodexCompletionSources(); bindWSLCompletionSources(.claude)
    }

    /// Codex starts MCP servers from the host a task runs on, so connected SSH
    /// and WSL hosts get Pacer's progress tool too. With the ring off, only hosts
    /// this PC set up are visited, to take it away again. Unchanged inputs are
    /// skipped: desktop updates arrive far more often than hosts connect.
    private func bindCodexRemoteProgress() async {
        guard let setup = codexRemoteProgress, let services = codexRemoteProgressServices else { return }
        let ring = codexProgressRing && enabled.contains(.codex)
        let on = active && managesCodexProgress && (monitorSSH || monitorWSL) && enabled.contains(.codex)
        let configured = on && !ring ? services.loadDigests() : [:]
        let targets = on ? monitoredRemoteTargets(.codex).filter { ring || configured[$0.alias] != nil } : []
        let statuses = (desktopState?.statuses ?? [:]).filter { id, _ in targets.contains { $0.id == id } }
        let input = [String(on), String(ring), String(lifecycle.version(.codex))] + targets.map { target in
            target.id + "=" + target.alias + "@" + target.home + ":" + String(statuses[target.id].map { $0.connected && $0.sourceAvailable != false } ?? false)
        }
        guard input.joined(separator: "\n") != codexRemoteProgressInput else { return }
        codexRemoteProgressInput = input.joined(separator: "\n")
        await setup.configure(targets: targets, statuses: statuses, enabled: on, progressRing: ring,
            version: lifecycle.version(.codex), update: { _, _ in })
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
    /// A burst of network changes joins one pending retry of SSH hosts that
    /// are waiting out their backoff; sleep cancels it.
    private func scheduleSSHReconnect() {
        let key = ApplicationWorkRegistry.Key(.discovery, identifier: "ssh-reconnect")
        guard active, !demo, monitorSSH, ownedWork.task(key) == nil else { return }
        let delay = sshReconnect.delay(at: now()), owner = ownedWork.begin(key, version: generation)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reconnectSSH(owner)
        }
        ownedWork.attach(task, to: owner)
    }
    private func reconnectSSH(_ owner: ApplicationWorkRegistry.Ticket) async {
        defer { ownedWork.finish(owner) }
        guard active, ownedWork.owns(owner), owner.version == generation else { return }
        sshReconnect.ran(at: now())
        if enabled.contains(.codex) { await desktopMonitor?.reconnectUnreachableSSH() }
        guard active, ownedWork.owns(owner), owner.version == generation else { return }
        if enabled.contains(.claude) { await claudeActivityMonitor.reconnectUnreachableSSH() }
    }
    private func retryConnections(_ owner: ApplicationWorkRegistry.Ticket) async {
        defer { ownedWork.finish(owner) }
        guard active, owner.version == generation else { return }
        if demo { publish(notices: [], force: true); return }
        scheduleRemoteDiscovery()
        await desktopMonitor?.retryInactiveHelpers()
        guard active, ownedWork.owns(owner), owner.version == generation else { return }
        await bindDesktopMonitor(force: true)
        await refreshHarnesses()
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
                // Local Codex's state is the hook row of the Remote page, not a stream.
                streams[provider] = desktopState?.statuses ?? [:]
            } else {
                streams[provider] = provider == .claude ? claudeRemoteStatuses : [:]
                if let status = localStreamStatuses[provider] { streams[provider, default: [:]]["local"] = status }
                else if let harness = harnessActivities[provider], let health = harness.status {
                    var status = RuntimeStreamStatus()
                    status.connected = health == .ready
                    status.sourceAvailable = health != .missing && health != .incompatible
                    status.attachedThreads = harness.activities.count
                    status.sourceName = provider.displayName
                    streams[provider, default: [:]]["local"] = status
                }
            }
            streams[provider] = streams[provider]?.filter { source, _ in
                if source == "local" { return true }
                if !demo { return allowsRemoteSource(source, provider: provider) }
                if ConnectionSource.isSSHSourceID(source) { return monitorSSH }
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
                if catalog?.permits(profile, for: provider) != true { status.connected = false }
                if profile.target(provider) == nil { status.sourceAvailable = false; status.connected = false }
                streams[provider, default: [:]][profile.id] = status
            }
        }
        return EngineConnectionProjection.make(enabled: enabled, statuses: streams, targets: monitorSSH ? claudeRemoteTargets : [],
            setups: claudeRemoteSetups, wsl: catalog, canRetrySetup: !demo && claudeRemoteServices != nil)
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

    func refresh(discover: Bool, refreshActivityMonitors: Bool = true, fileEvent: Bool = false) async {
        guard active else { return }
        refreshRequested = true; discoveryRequested = discoveryRequested || discover
        refreshActivityMonitorsRequested = refreshActivityMonitorsRequested || refreshActivityMonitors
        immediateRefreshRequested = immediateRefreshRequested || !fileEvent
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
            let batchCodexMetrics = !immediateRefreshRequested
            refreshRequested = false; discoveryRequested = false; refreshActivityMonitorsRequested = false
            immediateRefreshRequested = false
            await collect(discover: discover, refreshMonitors: refreshMonitors, batchCodexMetrics: batchCodexMetrics)
            if refreshRequested { await Task.yield() }
        }
        // Clear inside the actor before the worker completes. A request that
        // arrives afterwards creates a new worker instead of joining a finished one.
        ownedWork.finish(owner)
    }
    private func collect(discover: Bool, refreshMonitors: Bool, batchCodexMetrics: Bool) async {
        defer { collectHandoff.endCollect() }
        let date = now(), revision = generation
        let previousDeepSeekTurns = Set(activities.filter {
            $0.provider == .deepseek && $0.phase == .running
        }.map { $0.id + "|" + ($0.turnID ?? "") })
        let previousCodex = harnessActivities[.codex]
        if demo {
            var rows = DemoScenario.tasks(stage: stage, at: date)
                + [DemoScenario.claudeTask(stage: stage, at: date), DemoScenario.deepseekTask(stage: stage, at: date)]
                + (enabled.contains(.workbuddy) ? [DemoScenario.workbuddyTask(stage: stage, at: date)] : [])
            var requests: [PendingAttentionRequest] = []
            if !claudeWebReference {
                let cloud = DemoScenario.claudeCloud(stage: stage, at: date)
                rows += cloud.activities; requests = cloud.attention
            }
            demoActivity = HarnessActivity(activities: rows, requests: requests)
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
        } else {
            for provider in supportedProviders where enabled.contains(provider) {
                guard let collect = activityAdapters[provider]?.collect else { continue }
                await collect(.init(observedAt: date, discover: discover))
                guard active, generation == revision, !Task.isCancelled else { return }
            }
            if refreshMonitors {
                await refreshHarnesses()
                guard active, generation == revision else { return }
            }
            if enabled.contains(.deepseek) { updateLocalWallet() }
        }
        await bindBalanceMonitor()
        guard active, generation == revision, !Task.isCancelled else { return }
        let deepseekRows = demo ? demoActivity.activities.filter { $0.provider == .deepseek } : harnessActivities[.deepseek]?.activities ?? []
        let ended = deepseekRows.contains { [.completed, .interrupted].contains($0.phase) &&
            previousDeepSeekTurns.contains($0.id + "|" + ($0.turnID ?? "")) }
        let forceBalance = forceBalanceRequested; forceBalanceRequested = false
        _ = await balanceMonitor?.refreshIfDue(active: expanded || deepseekRows.contains { $0.phase == .running },
            force: forceBalance, turnEnded: ended)
        guard active, generation == revision, !Task.isCancelled else { return }
        // Snapshots received from here on were not part of this projection.
        collectHandoff.readLocalSnapshots()
        let codex = harnessActivities[.codex]
        let publishNow = demo || collectHandoff.takePublication() || !batchCodexMetrics || !projectionReady ||
            codex?.status != previousCodex?.status || codexLifecycleChanged(from: previousCodex, to: codex)
        // A Claude, DeepSeek or WorkBuddy ending read during this collect can be
        // newer than its start, so project at the time of publication.
        if publishNow { projectCollected(at: now()) }
        else if codex?.activities != previousCodex?.activities, !codexMetricsPending { scheduleCodexMetrics() }
        guard active, generation == revision, !Task.isCancelled else { return }
        await claudeCloudMonitor?.startAfterPublication()
    }

    private func collectCodexLogs(_ context: ActivityAdapters.Adapter.SnapshotContext) async {
        let revision = generation, home = codexHome
        let result = await codexReader.read(home: home, now: context.observedAt, phaseAwareRate: true, metricsOnly: !context.discover)
        let expiry = await codexReader.nextRunningExpiry
        guard active, generation == revision, !Task.isCancelled else { return }
        #if os(Windows)
        codexRunningExpiry = expiry
        // A hook row can name a new rollout in any read, not only discovery.
        if result.watchURLs != watchedCodexLogURLs {
            watchedCodexLogURLs = result.watchURLs
            await updateCodexLogWatches()
            guard active, generation == revision, !Task.isCancelled else { return }
        }
        #endif
        inbox.remove(activityIDs: result.excludedIDs)
        let found = FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path)
        harnessActivities.replace(.codex, with: .init(activities: result.activities, requests: result.requests,
                                                      status: found ? .ready : .missing))
    }

    /// Whether a Codex log read changed what the island shows beyond its
    /// counters. Counter-only changes wait for the collapsed batch.
    private func codexLifecycleChanged(from old: HarnessActivity?, to new: HarnessActivity?) -> Bool {
        guard (new?.requests ?? []).sorted(by: { $0.id < $1.id }) == (old?.requests ?? []).sorted(by: { $0.id < $1.id }) else { return true }
        let before = Self.codexLogRows(old?.activities ?? []), next = Self.codexLogRows(new?.activities ?? [])
        guard before.keys == next.keys else { return true }
        return next.contains { id, value in
            guard let previous = before[id] else { return true }
            // A conversation's new name shows at once, not with the next counter batch.
            return value.phase != previous.phase || value.turnID != previous.turnID || value.stage != previous.stage || value.title != previous.title ||
                value.turnFailed != previous.turnFailed || value.firstTokenReportedAt != previous.firstTokenReportedAt ||
                value.waitingForApproval != previous.waitingForApproval || value.codexGoalPause != previous.codexGoalPause
        }
    }

    private static func codexLogRows(_ rows: [SessionActivity]) -> [String: SessionActivity] {
        Dictionary(rows.lazy.filter { $0.provider == .codex && $0.lastObserved != nil }.map { ($0.canonicalized().id, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    private func scheduleCodexMetrics() {
        let owner = ownedWork.begin(codexMetricsWork, version: lifecycle.version(.codex))
        codexMetricsPending = true
        let delay = UInt64(presentationInterval() * 1_000_000_000)
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.flushCodexMetrics(owner)
        }
        ownedWork.attach(task, to: owner)
    }

    private func flushCodexMetrics(_ owner: ApplicationWorkRegistry.Ticket) {
        guard lifecycle.owns(owner), ownedWork.finish(owner) else { return }
        codexMetricsPending = false
        if active { projectCollected(at: now()) }
    }

    private func clearCodexMetricsBatch() {
        guard codexMetricsPending else { return }
        codexMetricsPending = false
        ownedWork.cancel(codexMetricsWork)
    }

    private func projectCollected(at date: Date) {
        clearCodexMetricsBatch()
        var current: [SessionActivity] = []
        var status: [EngineSource] = []
        let cloud = usesClaudeWeb && enabled.contains(.claude) && cloudState?.enabled == true ? cloudState : nil
        if demo {
            current = demoActivity.activities
            status = HarnessRegistry.legacyIDs.map { .init(id: $0.rawValue + ":demo", provider: $0.rawValue,
                available: true, transport: "demo", reason: nil) }
            if let cloud { current.append(contentsOf: cloud.activities) }
        } else {
            for provider in supportedProviders where enabled.contains(provider) {
                let observation = harnessActivities[provider]
                var rows = observation ?? HarnessActivity()
                if provider == .claude, let cloud {
                    rows.activities.append(contentsOf: cloud.activities)
                    rows.requests.append(contentsOf: cloud.attention)
                }
                activityState.replaceHarness(provider, with: rows)
                current.append(contentsOf: rows.activities)
                // Keep the source IDs used by the existing connection panels.
                let registeredLocal = localHarnesses.definition(for: provider) != nil
                if observation != nil || !registeredLocal {
                    status.append(.init(id: provider.rawValue + (registeredLocal ? ":local" : ":local-logs"), provider: provider.rawValue,
                        available: observation?.status == .ready, transport: registeredLocal ? "local" : "logs", reason: nil))
                }
            }
        }
        if let availability = cloud?.status {
            status.append(.init(id: "claude:cloud-projects", provider: "claude",
                available: availability.connected && availability.sourceAvailable != false, transport: "https", reason: nil))
        }
        if !demo, monitorWSL, let services = wslServices {
            let catalog = services.registry.snapshot()
            var statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [.codex: desktopState?.statuses ?? [:], .claude: claudeRemoteStatuses]
            for provider in [AgentProvider.codex, .claude] {
                for profile in catalog.profiles {
                    var reading = statuses[provider]?[profile.id] ?? RuntimeStreamStatus()
                    reading.sourceName = "WSL · " + profile.distro
                    reading.remoteHostOnline = catalog.active.contains(profile.id)
                    if !catalog.permits(profile, for: provider) { reading.connected = false }
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
        if !demo, monitorSSH {
            status += claudeRemoteStatuses.filter { ConnectionSource.isSSHSourceID($0.key) }.map { id, value in
                EngineSource(id: "claude:" + id, provider: "claude", available: value.connected && value.sourceAvailable != false,
                    transport: "ssh", reason: nil)
            }
        }
        // SSH and WSL hosts and Dot tasks; local Codex comes from the hook spool through the log reader.
        let codexOn = !demo && enabled.contains(.codex)
        let desktop = codexOn ? desktopState.flatMap { $0.context == lifecycle.version(.codex) ? $0 : nil } : nil
        let durable = codexOn && allowsRemoteSource(DurableActivityCatalog.hostID, provider: .codex) ? durableActivities : []
        activityState.remoteActivities = (desktop?.activities ?? []) + durable
        activityState.codexReceivedRequests = []; activityState.codexAttentionThreadIDs = []
        activityState.codexStreamConnected = false
        if let desktop {
            activityState.applyCodexMetadata(names: desktop.names, performance: desktop.performance, at: date, visibility: activityVisibility)
            if monitorSSH {
                status += desktop.statuses.filter { ConnectionSource.isSSHSourceID($0.key) }.map { id, value in
                    EngineSource(id: "codex:" + id, provider: "codex", available: value.connected && value.sourceAvailable != false, transport: "ssh", reason: nil)
                }
            }
        }
        sources = status.filter { enabled.contains(AgentProvider(rawValue: $0.provider) ?? .codex) }
        let update: ActivityApplicationUpdate
        if demo {
            activityState.demoActivities = current
            activityState.demoRequests = demoActivity.requests + (cloud?.attention ?? [])
            activityState.includesDemoMetadata = true
            inbox.observe(current, at: date, retention: retention)
            update = activityState.applyDemoSnapshot(enabled: enabled, at: date, visibility: activityVisibility)
        } else {
            activityState.codexDelegations = codexDelegationLinks(at: date)
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
        let panelOptions = panelSettings.choices
        var hasBudget = false
        if enabled.contains(.deepseek), let source = walletSource {
            let reading = source.wallet(at: date, configuration: deepseekSettings, reminders: reminderSettings)
            hasBudget = reading.daily != nil || reading.weekly != nil
            compactWallet = .init(reading, preferred: .init(rawValue: deepseekSettings.ringPeriod) ?? .day)
            wallet = source.presentation(wallet: reading, at: date, hideProjects: hideProjects, configuration: deepseekSettings,
                compactUsesBudget: enabled.intersection([.codex, .claude]).count < 2, reminders: reminderSettings, connection: balanceState,
                panel: panelOptions)
            walletNotices = deepseekNoticePolicy.balanceNotices(reading, low: notifies(.lowBalance))
                + deepseekNoticePolicy.spendNotices(reading, spike: notifies(.spendSpike), budget: notifies(.budget),
                    snoozedUntil: spikeSnoozedUntil, now: date)
        }
        let creditModules = HarnessRegistry.ids(where: \.reportsAccountCredits).filter(enabled.contains)
        let credits: [AgentProvider: HarnessAccountCredits] = Dictionary(uniqueKeysWithValues: creditModules.compactMap { provider in
            (demo ? DemoScenario.workbuddyCredits(at: date) : accountCredits[provider]?.credits).map { (provider, $0) }
        })
        walletNotices += creditsNoticePolicy.notices(credits, settings: creditSettings, low: notifies(.lowCredits), now: date)
        // Deadlines are fixed, so the presentation clock's publishes find a reset entering its lead time.
        if enabled.contains(.codex), notifies(.resetExpiry) {
            walletNotices += resetExpiryNoticePolicy.notices(demo ? quota[.codex] : codexQuota,
                leadDays: ResetExpiryReminder.leadDays(reminderSettings.resetDays), now: date)
        }
        let legacy = HarnessRegistry.legacyIDSet
        let selected: Set<String>?
        if activities.count > 256, !enabled.isSubset(of: legacy) {
            let additional = activities.filter { !legacy.contains($0.provider) }
            selected = additional.count > 256 ? HarnessRowBudget.select(activities: additional, maximum: 256) : nil
        } else { selected = nil }
        let visibleActivities = selected.map { ids in activities.filter { legacy.contains($0.provider) || ids.contains($0.id) } } ?? activities
        let visibleRequests = selected.map { ids in requests.filter { legacy.contains($0.provider) || ids.contains($0.activity.id) } } ?? requests
        let visibleNotices = Array(activityState.visibleNotices(notices + walletNotices, visibility: activityVisibility).prefix(256))
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
                    transport: claudeWebFetches ? "webview" : "https", reason: claudeVerification.error(state) ?? state.warning))
            }
        }
        if enabled.contains(.deepseek), let state = balanceState {
            displayedSources.append(.init(id: "deepseek:balance", provider: "deepseek",
                available: state.balance != nil && state.error == nil,
                transport: demo ? "demo" : state.mode == .apiKey ? "https" : "webview",
                reason: state.error?.localizedDescription))
        }
        snapshots = snapshots.filter { enabled.contains($0.key) }
        var presentationOptions = TaskPresentationOptions(hideProjects: hideProjects,
                hostApplications: hostTracking.labels(for: visibleActivities, activities: activities, inbox: inbox) {
                    .init(name: $0.name, isClaudeDesktop: $0.isClaudeDesktop)
                }, showsDeepSeekTurnCost: deepseekSettings.showsTurnCost,
                progressRingProviders: progressRingProviders, pageSize: panelOptions.pageSize,
                showsDelegationRows: true)
        presentationOptions.hiddenTurnCredits = hiddenTurnCredits
        let taskPresentation = selected == nil ? activityState.presentation(at: date, options: presentationOptions) :
            ActivityTaskPresentation(activities: visibleActivities, requests: visibleRequests, inbox: inbox, options: presentationOptions, at: date)
        scheduleActivityDisplay(at: date)
        var failedProviders = Set<AgentProvider>(), refreshingProviders = Set<AgentProvider>(), quotaErrors: [AgentProvider: String] = [:], sourceTexts: [AgentProvider: String] = [:]
        if !demo {
            if codexQuotaFailed { failedProviders.insert(.codex); quotaErrors[.codex] = quotaSource?.reason }
            if codexQuotaRefreshing { refreshingProviders.insert(.codex) }
        }
        if usesClaudeWeb, let state = claudeQuotaState {
                if let error = claudeVerification.error(state) { failedProviders.insert(.claude); quotaErrors[.claude] = error }
                if state.refreshing { refreshingProviders.insert(.claude) }
                if snapshots[.claude] != nil { sourceTexts[.claude] = state.source?.label }
        }
        if snapshots[.codex] != nil { sourceTexts[.codex] = L10n.text("quota.source_codex") }
        let codexSSH = enabled.contains(.codex) ? desktopState.flatMap { $0.context == lifecycle.version(.codex) ? $0 : nil } : nil
        let sshIssue = !demo && monitorSSH && EngineSSHReminder.raised(codex: codexSSH?.statuses ?? [:],
            codexUnavailable: codexSSH?.unavailable ?? [], claude: enabled.contains(.claude) ? claudeRemoteStatuses : [:]) {
                allowsRemoteSource($0, provider: $1)
            }
        let compactWarnings = CompactWarningPresentation.items(enabled: enabled,
            warnings: Set(reminderSettings.warnings.compactMap(CompactIslandLayout.Warning.init(rawValue:))), snapshots: snapshots,
            failed: failedProviders, sshIssue: sshIssue, codexHooksNeedUser: !demo && codexHooksNeedUser, wallet: wallet?.alert,
            credits: credits, creditSettings: creditSettings,
            resetLeadDays: ResetExpiryReminder.leadDays(reminderSettings.resetDays), now: date)
        let compactContext = CompactBarContext(activities: visibleActivities, requests: visibleRequests, completions: inbox.unreadActivities,
            sources: HarnessRegistry.descriptors.filter { $0.hasQuotaDisplay && enabled.contains($0.id) }.map(\.id).map { provider in
                .init(provider: provider, snapshot: snapshots[provider], failed: failedProviders.contains(provider))
            }, wallet: compactWallet, credits: creditModules.map { provider in
                .init(provider: provider, credits: credits[provider], stale: accountCredits[provider]?.stale == true, now: date,
                      figure: creditSettings[provider]?.bar ?? .available, settings: creditSettings[provider] ?? .default)
            }, firstOutput: latestFirstOutput?.seconds, warnings: compactWarnings, groups: taskPresentation.groups, overview: taskPresentation.overview,
            firstOutputs: activityState.firstOutputHistory.values, now: date)
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
                if localHarnesses.definition(for: activity.provider) != nil {
                    return harnessActivities[activity.provider]?.conversationURLs[activity.id] != nil
                }
                if activity.claudeCloud != nil { return activity.threadURL != nil }
                if let host = activity.sourceHostID {
                    if host == DurableActivityCatalog.hostID {
                        return allowsRemoteSource(host, provider: activity.provider) && activity.threadURL != nil
                    }
                    if monitorWSL, wslServices?.registry.profile(id: host, provider: activity.provider) != nil { return true }
                    if ConnectionSource.isSSHSourceID(host) { return allowsRemoteSource(host, provider: activity.provider) && activity.threadID.flatMap(UUID.init(uuidString:)) != nil }
                    return false
                }
                #if os(Windows)
                if activity.provider == .codex, !activity.launchedByEmbeddingApp,
                   !codexDefaultProfile { return false }
                #endif
                return activity.sourceHostID == nil && activity.threadID.flatMap(UUID.init(uuidString:)) != nil
            }
            // Retain a separate navigation view of cold log endings. They do
            // not become visible cards or replay notification baselines.
            var candidates = Dictionary((visibleActivities + notificationActivities).filter {
                enabled.contains($0.provider) && (selected == nil || legacy.contains($0.provider) || selected?.contains($0.id) == true)
            }
                .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.map { $0 }
            let hidden = activityState.hiddenActivityIDs(activityVisibility)
            candidates.removeAll { hidden.contains($0.canonicalized().id) }
            notificationNavigation.update(activities: candidates, requests: visibleRequests, inbox: inbox, cloudContext: cloudNavigationContext) {
                ([.codex, .claude].contains($0.provider) || harnessActivities[$0.provider]?.conversationURLs[$0.id] != nil)
                    && !$0.isInternalReview && !$0.isIgnoredCodexSession
            }
            for (context, operation) in navigationOpens where navigationEntry(context: context) == nil {
                navigationState.abandon(operation); navigationOpens.removeValue(forKey: context)
                navigationHosts.removeValue(forKey: operation.id)
            }
        }
        let notificationProjections = visibleNotices.map { notificationProjection($0, requests: visibleRequests, at: date) }
        var snapshot = EngineSnapshot(sequence: sequence + 1, demo: demo, activities: visibleActivities, requests: visibleRequests,
            sources: displayedSources, quota: displayedQuota,
            notices: visibleNotices, inbox: inbox, hideProjects: hideProjects, now: date, wallet: enabled.contains(.deepseek) ? wallet : nil,
            modules: moduleConfigurationActive ? supportedProviders.map(moduleProjection) : nil,
            quotaDashboard: dashboard, showsDeepSeekTurnCost: deepseekSettings.showsTurnCost,
            progressRingProviders: progressRingProviders,
            compactWarnings: compactWarnings, compactContext: compactContext, taskPresentation: taskPresentation,
            deepseekConnection: balanceState.map { EngineDeepSeekConnection($0, now: date) },
            claudeConnection: claudeQuotaState.map { EngineClaudeConnection($0, paused: claudeWebPaused, verification: claudeVerification) },
            claudeCloudConnection: cloudState.map(EngineClaudeCloudConnection.init), activityLinks: projectionReady ? navigation.links : [],
            notificationProjections: notificationProjections,
            navigationError: navigationState.failure.map(EngineNavigationFailure.init), openingActivityIDs: navigationState.openingActivityIDs.sorted(), claudeSetup: claudeHookSetup.map { setup in
                var value = setup; value.exactRequestSpans = localStreamStatuses[.claude]?.exactRequestSpans == true; return value
            },
            claudeRemoteSetups: claudeRemoteSetups, connections: connectionPresentation(), codexProgressSetup: codexProgressSetup,
            deepseekProgressSetup: deepseekProgressSetup)
        snapshot.expandedPanel = EngineExpandedPanel(settings: panelSettings, enabled: enabled, snapshots: snapshots,
            hasBudget: hasBudget, at: date)
        snapshot.wslAvailability = demo ? .available : wslAvailability
        var hooks = codexHookServices == nil ? nil : codexHookStatus.map(EngineCodexHooks.init) ?? .settingUp
        switch codexHookStatus {
        case .needsApproval?, .needsCodexUpdate?: if codexHooksOpenSettings { hooks?.opensSettings = true }
        default: break
        }
        snapshot.codexHooks = hooks
        snapshot.codexDelegation = codexDelegationStatus(at: date, presentation: taskPresentation, codexQuota: snapshots[.codex])
        refreshCodexHookActivity()
        snapshot.accountCredits = credits.isEmpty ? nil : creditModules.compactMap { provider in
            credits[provider].map { .init(provider: provider.rawValue, credits: $0, stale: accountCredits[provider]?.stale == true,
                                          presentation: HarnessCreditsPresentation(credits: $0, settings: creditSettings[provider] ?? .default, now: date)) }
        }
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
        // A reattached source may report the same rows as before sleep.
        // Send the first rebuilt projection so the host can leave its sleep UI.
        snapshotEmission = .init()
        if !demo { scheduleClaudeHooks(); scheduleCodexHooks(force: true) }
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
        startWSLMonitoring(checkInstalled: true)
        if !demo { restartPresentationClock() }
        startMaintenance()
        await refresh(discover: true)
    }

    func stop() async {
        let plan = lifecycle.shutdown()
        guard plan.actions.contains(.stopSources) else { return }
        // A switch turned off just before quitting still removes Pacer's
        // Harness entry, so Harness stops loading the reporter.
        let progressTasks = Array(localProgressTasks.values) + [deepseekProgressTask].compactMap { $0 }
        await ShutdownDeadline().perform(progressTasks.map { task in { await task.value } })
        initialized = false; projectionReady = false
        releaseHostWork()
        await cleanupSources(quota: quotaMonitor, claude: claudeQuotaMonitor, balance: balanceMonitor, sleeping: false)
    }
    private func releaseHostWork() {
        stopWSLMonitoring()
        wslQuota = [:]
        claudeHookTask?.cancel(); claudeHookTask = nil; claudeHookRequest = nil; claudeHookHome = nil
        webHostPublication.reset(); publishedBalanceContext = nil
        cancelHostTracking(); invalidateNavigation()
        activityDisplayDeadline = nil
        refreshRequested = false; discoveryRequested = false; refreshActivityMonitorsRequested = false
        immediateRefreshRequested = false; collectHandoff = EngineCollectHandoff()
        clearCodexMetricsBatch()
        forceBalanceRequested = false
        #if os(Windows)
        watchedCodexLogURLs = []; codexRunningExpiry = nil
        logWatcher.stop()
        #endif
    }
    private func cleanupSources(quota: CodexQuotaMonitor?, claude: ClaudeQuotaMonitor?, balance: DeepSeekBalanceMonitor?, sleeping: Bool) async {
        let cloud = claudeCloudMonitor, web = webBridge, claudeWeb = claudeWebBridge, remoteSetup = claudeRemoteSetup
        let codexRemote = codexRemoteProgress
        codexRemoteProgressInput = nil
        let deadline = ShutdownDeadline()
        let harnesses = localHarnesses.detach()
        harnessActivities.detachLocalBindings()
        var operations: [ApplicationLifecycleCoordinator.Resource: ApplicationLifecycleCoordinator.Cleanup] = [
            .codexQuota: { await quota?.stop() }, .claudeQuota: { await claude?.stop() },
            .cloud: { if sleeping { await cloud?.suspend() } else { await cloud?.stop() } },
            .balance: { await balance?.stop() }, .remoteSetup: { await remoteSetup?.shutdown(); await codexRemote?.shutdown() }
        ]
        if !sleeping {
            operations[.web] = { await web.setAvailable(false) }
            operations[.claudeWeb] = { await claudeWeb.setAvailable(false) }
        }
        #if os(Windows)
        let watcher = logWatcher, stopWatching = !demo
        operations[.watches] = { if stopWatching { watcher.stop(); _ = await watcher.activeWatchCount() } }
        #endif
        let completed = await ApplicationLifecycleCoordinator.cleanup(operations,
            activity: activityAdapters.cleanup(sleeping ? .sleep : .shutdown, deadline: deadline, detached: harnesses), deadline: deadline)
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
    private func trackActivityHosts() {
        for provider in [AgentProvider.codex, .claude] { trackActivityHosts(for: provider) }
    }
    private func trackActivityHosts(for provider: AgentProvider) {
        let references = activityState.knownActivities(for: provider)
        let decision = hostTracking.prepare(provider: provider, references: references, activities: activities, inbox: inbox,
            version: lifecycle.version(provider), now: now(), active: active, demo: demo)
        let retryKey = ApplicationWorkRegistry.Key(.hostRetry, provider: provider)
        switch decision {
        case .idle: break
        case .cancelRetry: ownedWork.cancel(retryKey)
        case .retry(let retry):
            let owner = ownedWork.begin(retryKey, version: retry.version)
            let task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, retry.delay) * 1_000_000_000)) } catch { return }
                await self?.finishHostRetry(retry, owner: owner)
            }
            ownedWork.attach(task, to: owner)
        case .scan(let scan):
            ownedWork.cancel(retryKey)
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
        ownedWork.finish(owner); trackActivityHosts(for: retry.provider)
    }
    private func finishHostScan(_ scan: HostApplicationTrackingState<ActivityHostApplication>.Scan, found: [String: ActivityHostApplication], owner: ApplicationWorkRegistry.Ticket) {
        defer { ownedWork.finish(owner) }
        let result = hostTracking.complete(scan, found: found, version: lifecycle.version(scan.provider), active: active, cancelled: Task.isCancelled)
        if result.owned { ownedWork.finish(owner) }
        guard result.accepted else { return }
        if result.changed { publish(notices: []) }
        trackActivityHosts(for: scan.provider)
    }
    private func navigationHome(for provider: AgentProvider) -> URL {
        switch provider {
        case .codex: codexHome
        case .claude: claudeHome
        case .deepseek: deepseekHome
        default: localHarnesses.definition(for: provider).map(localHarnessHome) ?? defaultCodexHome
        }
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
        let home = navigationHome(for: provider)
        var fields = ["notification-source-v1", provider.rawValue, home.standardizedFileURL.resolvingSymlinksInPath().path]
        switch provider {
        case .codex:
            fields.append(codexExecutable)
            if scope == DurableActivityCatalog.hostID {
                guard let durableAccountScope else { return nil }
                fields.append(durableAccountScope)
            }
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
        default:
            guard let source = harnessActivities[provider]?.scope else { return nil }
            fields.append(source)
        }
        if scope == "quota" {
            guard enabled.contains(provider) else { return nil }
            // A credits module's alerts belong to its own source, appended above;
            // borrowing Codex's account left them with no action while Codex was off.
            if HarnessRegistry.legacyIDSet.contains(provider) {
                guard let account = (provider == .claude ? claudeQuotaState?.snapshot : codexQuota)?.accountScope else { return nil }
                fields.append(account)
            }
        }
        fields.append(scope)
        return CompletionDismissalStore.digest(fields)
    }
    private func notificationProjection(_ notice: IslandNotice, requests: [PendingAttentionRequest], at date: Date) -> EngineNotice {
        var value = EngineNotice(notice, hideProjects: hideProjects)
        let request = requests.first { "request:" + $0.id == notice.id }
        let requested = request?.activity.id
        let entry = notificationNavigation.entries.values.first { entry in
            entry.members.contains { member in requested == member.id || notice.id.hasPrefix(member.id + ":") }
        }
        let observed = notificationActivities.first { requested == $0.id || notice.id.hasPrefix($0.id + ":") }?.provider
        let fallback = supportedProviders.first { notice.id.hasPrefix($0.rawValue + ":") }
        let provider = entry?.target.provider ?? request?.provider ?? observed ?? fallback ??
            (notice.category?.hasPrefix("deepseek.") == true ? .deepseek : .codex)
        let deepseek = provider == .deepseek
        let scope = entry?.target.sourceHostID == DurableActivityCatalog.hostID ? DurableActivityCatalog.hostID
            : entry?.target.claudeCloud != nil ? "cloud" : deepseek ? "wallet" : notice.kind == .lowQuota ? "quota" : "local"
        guard let source = notificationSource(provider, scope: scope) else { value.actions = []; return value }
        let target = entry.map(EngineNotificationRegistry.target)
        // Allowing Pacer in Codex starts on Codex's page in Settings, as on the Mac.
        let kind = target != nil ? "openTask" : notice.id == "codex:hooks-approval" ? "openCodexSettings"
            : deepseek && notice.kind != .lowQuota ? "openHarness" : "showIsland"
        value.defaultAction = .init(kind: kind, title: L10n.text(kind == "showIsland" ? "main.overview.open" : "common.open_chat"),
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
        else if entry.target.sourceHostID == DurableActivityCatalog.hostID {
            sourceIsCurrent = allowsRemoteSource(DurableActivityCatalog.hostID, provider: entry.target.provider)
        }
        else if let source = entry.target.sourceHostID, source.hasPrefix(ConnectionSource.wslPrefix) {
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
