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
        let reference = demo && CommandLine.arguments.contains("--reference-fixture")
        let claudeReference = CommandLine.arguments.contains("--claude-web-fixture")
        guard !claudeReference || reference else { return }
        if reference { NSTimeZone.default = TimeZone(secondsFromGMT: 0)! }
        let clock: @Sendable () -> Date = { reference ? Date(timeIntervalSince1970: 1_800_000_000) : Date() }
        let runtime = EngineRuntime(demo: demo, now: clock,
            dismissalStore: readOnly ? nil : .applicationDefault,
            quotaServices: demo || readOnly ? nil : .live, desktopServices: demo ? nil : .platformLive,
            balanceServices: readOnly ? nil : demo ? .demo(now: clock) : .live,
            allowsLiveClaudeWeb: !demo && !readOnly, claudeWebReference: claudeReference)
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
                    if !(await runtime.receive(frame)) {
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
    private var expanded = false
    private var projectionReady = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
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
    private var inbox: CompletionInbox
    private var policy = AttentionPolicy()
    private var activities: [SessionActivity] = []
    private var requests: [PendingAttentionRequest] = []
    private var sources: [EngineSource] = []
    private var loggedActivities: [SessionActivity] = []
    private var loggedRequests: [PendingAttentionRequest] = []
    private var loggedSources: [EngineSource] = []
    private let desktopServices: CodexDesktopServices?
    private var desktopState: CodexDesktopState?
    private var pendingDesktopEndings: [String: SessionActivity] = [:]
    private var latestFirstOutput: (at: Date, seconds: Double)?
    private lazy var desktopMonitor: CodexDesktopMonitor? = desktopServices.map { services in
        CodexDesktopMonitor(services: services) { [weak self] state in await self?.receiveDesktop(state) }
    }
    private var quota: [AgentProvider: QuotaSnapshot] = [:]
    private var codexQuota: QuotaSnapshot?
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
    private var cloudState: ClaudeCloudState?
    private lazy var claudeWebBridge = ClaudeWebBridge { [weak self] message in await self?.sendClaudeHostMessage(message) }
    private lazy var claudeQuotaMonitor: ClaudeQuotaMonitor? = {
        let services = claudeServices ?? (claudeWebReference ? .reference(bridge: claudeWebBridge, now: now) : allowsLiveClaudeWeb ? .live(bridge: claudeWebBridge) : nil)
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
    private var maintenance: Task<Void, Never>?
    private var presentationClock: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
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
         quotaServices: CodexQuotaServices? = nil,
         desktopServices: CodexDesktopServices? = nil,
         balanceServices: DeepSeekBalanceServices? = nil,
         claudeServices: ClaudeQuotaServices? = nil,
         cloudServices: ClaudeCloudServices? = nil,
         navigationServices: ActivityNavigationServices? = nil,
         allowsLiveClaudeWeb: Bool = false,
         claudeWebReference: Bool = false,
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
        self.claudeWebReference = claudeWebReference && demo
        self.detectInstallation = installationDetection
        self.inbox = CompletionInbox(dismissalStore: demo ? nil : dismissalStore)
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
    }

    func hello() {
        send(["protocolVersion": EngineProtocol.version, "type": "hello", "engine": "PacerEngine"])
    }

    func receive(_ data: Data) async -> Bool {
        let command: EngineCommand
        do { command = try EngineCommand.decode(data) }
        catch { failure(id: EngineCommand.correlationID(data), code: "invalidCommand"); return true }
        guard initialized || command.method == "initialize" || command.method == "shutdown" else {
            failure(id: command.id, code: "initializeRequired"); return true
        }
        switch command.method {
        case "prepareActivityOpen":
            guard let context = command.params?.context, context.utf8.count <= 128,
                  let entry = navigation.entry(context: context), navigationIsCurrent(entry) else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            let target = entry.target, home = target.provider == .claude ? claudeHome : codexHome
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
                let plan = try await navigationServices.resolve(.init(context: context, activity: target, home: home, transcript: transcript))
                guard navigationIsCurrent(entry), home == (target.provider == .claude ? claudeHome : codexHome),
                      plan.context == context, plan.provider == target.provider.rawValue else {
                    failure(id: command.id, code: "staleActivityOpen"); return true
                }
                struct Result: Encodable {
                    let protocolVersion = EngineProtocol.version, type = "result", ok = true
                    let id: String, value: EngineNavigationPlan
                }
                if let bytes = try? JSONEncoder().encode(Result(id: command.id, value: plan)), bytes.count < 8192 { output(bytes + Data([10])) }
                else { failure(id: command.id, code: "navigationUnavailable") }
            } catch ActivityNavigationError.missingClaudeHost { failure(id: command.id, code: "missingClaudeHost") }
              catch ActivityNavigationError.missingCodexHost { failure(id: command.id, code: "missingCodexHost") }
              catch { failure(id: command.id, code: "navigationUnavailable") }
            return true
        case "completeActivityOpen":
            guard let context = command.params?.context, let entry = navigation.entry(context: context), navigationIsCurrent(entry),
                  navigation.acknowledge(context: context, inbox: &inbox) else {
                failure(id: command.id, code: "staleActivityOpen"); return true
            }
            activities = activities.filter { ![.completed, .interrupted].contains($0.phase) } + inbox.activities
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
                enabled: usesClaudeWeb && enabled.contains(.claude) && !claudeWebPaused, context: generation, reset: true)
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
        case "initialize", "configure":
            do { try await configure(command.params) }
            catch { failure(id: command.id, code: "invalidConfiguration"); return true }
            initialized = true
            await bindActivityMonitors()
            await updateSourceWatches()
            if !demo, presentationClock == nil { restartPresentationClock() }
            if maintenance == nil {
                maintenance = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        guard !Task.isCancelled else { return }
                        await self?.maintenanceRefresh()
                    }
                }
            }
            await refresh(discover: true)
            await quotaMonitor?.refreshIfDue(expanded: expanded)
            _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded)
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
            if demo { publish(notices: []) }
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
            await desktopMonitor?.setExpanded(value)
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
            let hidden = hiddenEmbeddedActivityIDs
            let grouped = ActivityTaskGroup.make(activities.filter { !hidden.contains($0.id) })
            let eligible = grouped.filter { !$0.isRunning && !$0.isWaiting }
            let selected = command.method == "markAllRead" ? eligible : eligible.filter { $0.primary.id == command.params?.activityID }
            let pending = Set(requests.map { $0.activity.id })
            let selectedIDs = Set(selected.filter { $0.members.allSatisfy({ !pending.contains($0.id) }) }.flatMap { $0.members.map(\.id) })
            // Grouping can apply parent evidence to a child's display copy.
            // Acknowledge the retained source identity, not that display copy.
            for activity in inbox.unreadActivities where selectedIDs.contains(activity.canonicalized().id) && [.completed, .interrupted].contains(activity.phase) {
                _ = inbox.dismiss(activity)
            }
            activities = activities.filter { ![.completed, .interrupted].contains($0.phase) } + inbox.activities
            publish(notices: [])
        case "demoStage":
            guard demo, let value = command.params?.demoStage, let next = DemoTaskStage(rawValue: value) else {
                failure(id: command.id, code: "demoOnly"); return true
            }
            stage = next; await refresh(discover: false)
        case "shutdown":
            send(["protocolVersion": EngineProtocol.version, "type": "result", "id": command.id, "ok": true])
            return false
        default: failure(id: command.id, code: "unknownMethod"); return true
        }
        send(["protocolVersion": EngineProtocol.version, "type": "result", "id": command.id, "ok": true])
        return true
    }

    private func configure(_ parameters: EngineCommand.Parameters?) async throws {
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
        if changesCodex || changesClaude { navigation.invalidate() }
        let changesDeepSeek = deepseek.map { $0 != deepseekHome } ?? false
        generation += 1; projectionReady = false
        desktopState = nil; pendingDesktopEndings = [:]
        if let codex { codexHome = codex }
        if let claude { claudeHome = claude }
        if let organization = parameters.claudeOrganization { claudeOrganization = organization.lowercased() }
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
        if changesCodex || changesClaude || changesDeepSeek { latestFirstOutput = nil }
        inbox.bindSourceHomes(provider: .codex, localHome: codexHome)
        inbox.bindSourceHomes(provider: .claude, localHome: claudeHome)
        inbox.bindSourceHomes(provider: .deepseek, localHome: deepseekHome)
        await bindQuotaMonitor()
    }

    private func bindQuotaMonitor() async {
        codexHistory.bind(home: codexHome, customPath: codexExecutable)
        await quotaMonitor?.configure(home: codexHome, customPath: codexExecutable,
            enabled: !demo && enabled.contains(.codex), context: generation)
        claudeHistory.bind(home: claudeHome, customPath: claudeOrganization)
        await claudeQuotaMonitor?.configure(home: claudeHome, organization: claudeOrganization,
            enabled: usesClaudeWeb && enabled.contains(.claude) && !claudeWebPaused, context: generation)
        await bindClaudeCloudMonitor()
        await desktopMonitor?.configure(home: codexHome, enabled: !demo && enabled.contains(.codex),
            expanded: expanded, context: generation)
        await bindBalanceMonitor()
    }

    private func resetClaudeLocalSource() {
        claudeLocal = LocalActivitySnapshot()
    }

    private func bindActivityMonitors() async {
        guard !demo else { return }
        let context = generation
        if enabled.contains(.claude) {
            await claudeActivityMonitor.start(home: claudeHome, refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] rows, statuses, attention, performance in
                await self?.receiveClaudeLocal(rows, statuses: statuses, attention: attention, performance: performance, context: context)
            }
        } else { await claudeActivityMonitor.shutdown(); claudeLocal = LocalActivitySnapshot() }
        guard initialized, generation == context else { return }
        if enabled.contains(.deepseek) {
            await deepseekActivityMonitor.start(home: deepseekHome, refreshPolicy: expanded ? .expanded : .collapsed) { [weak self] rows, statuses, attention, performance, usage in
                await self?.receiveDeepSeekLocal(rows, statuses: statuses, attention: attention, performance: performance, usage: usage, context: context)
            }
        } else {
            await deepseekActivityMonitor.shutdown(); deepseekLocal = LocalActivitySnapshot(); deepseekUsage = DeepSeekLocalUsage()
        }
    }
    private static func measured(_ rows: [SessionActivity], _ performance: [SessionPerformanceUpdate]) -> [SessionActivity] {
        var result = rows
        for index in result.indices { for sample in performance where sample.id == result[index].id { sample.apply(to: &result[index]) } }
        return result
    }
    private func receiveClaudeLocal(_ rows: [SessionActivity], statuses: [String: RuntimeStreamStatus],
        attention: [PendingAttentionRequest], performance: [SessionPerformanceUpdate], context: UInt64) async {
        guard initialized, generation == context, enabled.contains(.claude) else { return }
        let exclusions = await claudeActivityMonitor.excludedLocalActivityIDs()
        guard initialized, generation == context else { return }
        inbox.remove(activityIDs: exclusions)
        let status = statuses["local"]
        claudeLocal = LocalActivitySnapshot(activities: Self.measured(rows, performance), requests: attention,
            available: status?.connected == true && status?.sourceAvailable != false)
        if projectionReady, refreshTask == nil { projectLocal(.claude, snapshot: claudeLocal) }
    }
    private func receiveDeepSeekLocal(_ rows: [SessionActivity], statuses: [String: RuntimeStreamStatus],
        attention: [PendingAttentionRequest], performance: [SessionPerformanceUpdate], usage: DeepSeekLocalUsage, context: UInt64) async {
        guard initialized, generation == context, enabled.contains(.deepseek) else { return }
        let previous = Set(deepseekLocal.activities.filter { $0.phase == .running }.map { $0.id + "|" + ($0.turnID ?? "") })
        deepseekUsage = usage
        let status = statuses["local"]
        deepseekLocal = LocalActivitySnapshot(activities: Self.measured(rows, performance), requests: attention,
            available: status?.connected == true && status?.sourceAvailable != false)
        updateLocalWallet()
        if projectionReady, refreshTask == nil {
            projectLocal(.deepseek, snapshot: deepseekLocal)
            await bindBalanceMonitor()
            guard initialized, generation == context else { return }
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
            recentProvider: demo ? "deepseek-account" : deepseekUsage.provider, context: generation)
        let state = await monitor.currentState()
        receiveBalance(state)
    }

    private func bindClaudeCloudMonitor(reset: Bool = false) async {
        await claudeCloudMonitor?.configure(home: claudeHome, organization: claudeOrganization,
            enabled: usesClaudeWeb && enabled.contains(.claude) && showClaudeCloudProjects && !claudeWebPaused,
            webAvailable: cloudWebAvailable, context: generation, reset: reset)
        await claudeCloudMonitor?.setExpanded(expanded)
    }

    func maintenanceRefresh() async {
        guard initialized else { return }
        if !demo, moduleConfigurationActive, AgentProvider.allCases.contains(where: { moduleSettings.mode(for: $0) == .automatic }) {
            let previous = generation
            let detected = await detectInstallation()
            guard initialized, generation == previous, !Task.isCancelled else { return }
            installation = detected
            let next = moduleSettings.enabledProviders(detection: detected)
            if next != enabled {
                for provider in enabled.subtracting(next) { inbox.remove(provider: provider) }
                if enabled.contains(.claude), !next.contains(.claude) { resetClaudeLocalSource() }
                enabled = next; generation += 1; projectionReady = false
                await bindQuotaMonitor()
                await bindActivityMonitors()
                await updateSourceWatches()
            }
        }
        await refresh(discover: true, refreshActivityMonitors: false)
        await quotaMonitor?.refreshIfDue(expanded: expanded)
        _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded)
        _ = await balanceMonitor?.refreshIfDue(active: expanded || activities.contains { $0.provider == .deepseek && $0.phase == .running })
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
        guard initialized, !Task.isCancelled else { return }
        await quotaMonitor?.refreshIfDue(expanded: expanded)
        _ = await claudeQuotaMonitor?.refreshIfDue(expanded: expanded)
        _ = await balanceMonitor?.refreshIfDue(active: expanded || activities.contains { $0.provider == .deepseek && $0.phase == .running })
        guard projectionReady, refreshTask == nil else { return }
        // Only the metadata projection changes on a clock tick. Do not reopen
        // transcript files or rescan source directories while nothing is written.
        if activities.contains(where: { [.running, .waitingForInput].contains($0.phase) }) || !quota.isEmpty || codexQuota != nil || claudeQuotaState?.snapshot != nil || enabled.contains(.deepseek) && walletSource != nil {
            publish(notices: [])
        }
    }

    private func receiveBalance(_ state: DeepSeekBalanceState) {
        guard state.context == generation else { return }
        let changed = balanceState != state
        if balanceState?.token != state.token { deepseekNoticePolicy = .init() }
        balanceState = state
        if var source = walletSource {
            source.balance = state.balance; source.connected = state.error == nil || state.balance != nil
            source.history = state.history; walletSource = source
        }
        if changed && initialized && projectionReady { publish(notices: []) }
    }
    private func sendWebHostMessage(_ message: DeepSeekWebHostMessage) {
        guard initialized, let bytes = try? JSONEncoder().encode(message), bytes.count <= EngineProtocol.maximumCommandBytes else { return }
        output(bytes + Data([10]))
    }

    private func receiveQuota(_ state: CodexQuotaState) {
        guard initialized, state.context == generation else { return }
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
        guard initialized, state.context == generation, usesClaudeWeb else { return }
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
        guard initialized, state.context == generation, usesClaudeWeb else { return }
        if let previous = cloudState, previous.purgeRevision != state.purgeRevision {
            let ids = Set((activities + inbox.activities).filter { $0.claudeCloud != nil }.map(\.id))
            inbox.remove(activityIDs: ids)
        }
        cloudState = state
        if projectionReady { projectCollected(at: now()) }
    }

    private func sendClaudeHostMessage(_ message: ClaudeWebHostMessage) {
        guard initialized, let bytes = try? JSONEncoder().encode(message), bytes.count <= EngineProtocol.maximumCommandBytes else { return }
        output(bytes + Data([10]))
    }

    private func receiveDesktop(_ state: CodexDesktopState) {
        guard initialized, state.context == generation, enabled.contains(.codex), !demo else { return }
        desktopState = state
        inbox.updateNames(state.names); inbox.updatePerformance(state.performance)
        if projectionReady { projectCollected(at: now()) }
        else {
            // Initialization/source reads may be awaiting I/O. Keep endings
            // until the first projection; a later EOF can release the stream.
            for value in state.activities where [.completed, .interrupted].contains(value.phase) { pendingDesktopEndings[value.id] = value }
            if pendingDesktopEndings.count > 256 {
                for id in pendingDesktopEndings.keys.sorted(by: {
                    (pendingDesktopEndings[$0]?.phaseChangedAt ?? .distantPast) > (pendingDesktopEndings[$1]?.phaseChangedAt ?? .distantPast)
                }).dropFirst(256) { pendingDesktopEndings.removeValue(forKey: id) }
            }
        }
    }

    func refresh(discover: Bool, refreshActivityMonitors: Bool = true) async {
        guard initialized else { return }
        refreshRequested = true; discoveryRequested = discoveryRequested || discover
        refreshActivityMonitorsRequested = refreshActivityMonitorsRequested || refreshActivityMonitors
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await self.drainRefreshes() }
        refreshTask = task
        await task.value
    }
    private func drainRefreshes() async {
        while initialized, refreshRequested, !Task.isCancelled {
            let discover = discoveryRequested, refreshMonitors = refreshActivityMonitorsRequested
            refreshRequested = false; discoveryRequested = false; refreshActivityMonitorsRequested = false
            await collect(discover: discover, refreshMonitors: refreshMonitors)
            if refreshRequested { await Task.yield() }
        }
        // Clear inside the actor before the worker completes. A request that
        // arrives afterwards creates a new worker instead of joining a finished one.
        refreshTask = nil
    }
    private func collect(discover: Bool, refreshMonitors: Bool) async {
        let date = now(), revision = generation
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
            var history = QuotaCycleHistory()
            for sample in DemoScenario.quota(.codex, at: date) { history.record(sample) }
            codexHistory.receive(snapshot: quota[.codex], history: history, warning: nil)
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
                guard initialized, generation == revision else { return }
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
        guard initialized, generation == revision, !Task.isCancelled else { return }
        let ended = current.contains { $0.provider == .deepseek && [.completed, .interrupted].contains($0.phase) &&
            previousDeepSeekTurns.contains($0.id + "|" + ($0.turnID ?? "")) }
        let forceBalance = forceBalanceRequested; forceBalanceRequested = false
        _ = await balanceMonitor?.refreshIfDue(active: expanded || current.contains { $0.provider == .deepseek && $0.phase == .running },
            force: forceBalance, turnEnded: ended)
        guard initialized, generation == revision, !Task.isCancelled else { return }
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
        guard initialized, generation == revision, !Task.isCancelled else { return }
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
        if !demo, enabled.contains(.codex), let desktop = desktopState, desktop.context == generation {
            let streamed = ActivitySourceMerger.merge(logged: Array(pendingDesktopEndings.values), streamed: desktop.activities)
            current = ActivitySourceMerger.merge(logged: current, streamed: streamed)
            for index in current.indices {
                for name in desktop.names where name.id == current[index].id { name.apply(to: &current[index]) }
                for metrics in desktop.performance where metrics.id == current[index].id { metrics.apply(to: &current[index]) }
            }
            let authoritative = desktop.attentionThreads.filter { thread in
                if desktop.attention.contains(where: { $0.threadID == thread }) { return true }
                guard desktop.status.connected, let live = desktop.activities.first(where: { $0.threadID == thread && $0.hasLiveEvidence }) else { return false }
                let logged = loggedActivities.first { $0.provider == .codex && $0.threadID == thread }
                return logged?.turnID == nil || logged?.turnID == live.turnID
            }
            pending.removeAll { $0.provider == .codex && authoritative.contains($0.threadID) }
            pending += desktop.attention
            status.append(.init(id: "codex:desktop-runtime", provider: "codex",
                available: desktop.status.connected && desktop.status.sourceAvailable == true, transport: "desktop-ipc", reason: nil))
        }
        current = current.filter { enabled.contains($0.provider) }
        pending = pending.filter { enabled.contains($0.provider) }
        sources = status.filter { enabled.contains(AgentProvider(rawValue: $0.provider) ?? .codex) }
        requests = pending
        let observed = inbox.observe(current, at: date, retention: retention)
        pendingDesktopEndings = [:]
        // The original Mac demo can replay a stage on the same synthetic turn.
        // Real sources keep the inbox's conservative lifecycle reconciliation.
        let active = observed.filter { ![.completed, .interrupted].contains($0.phase) }
        let activeIDs = Set(active.map(\.id))
        activities = demo ? current : active + inbox.activities.filter { !activeIDs.contains($0.id) }
        let notices = policy.requestNotices(pending) + policy.activityNotices(current, at: date)
        projectionReady = true
        publish(notices: AttentionPolicy.excludingPendingReplies(notices, activityIDs: Set(pending.map { $0.activity.id })))
    }

    private var hiddenEmbeddedActivityIDs: Set<String> {
        var hidden = showEmbeddedCodexSessions ? Set<String>() : EmbeddedSessionVisibility.embeddedActivityIDs(activities.filter { $0.provider == .codex })
        if !showClaudeCloudProjects { hidden.formUnion(activities.filter { $0.claudeCloud != nil }.map(\.id)) }
        return hidden
    }

    private func publish(notices: [IslandNotice]) {
        sequence += 1
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
        let hidden = hiddenEmbeddedActivityIDs
        let visibleActivities = activities.filter { !hidden.contains($0.id) }
        let visibleRequests = requests.filter { !hidden.contains($0.activity.canonicalized().id) }
        let hiddenRequestNotices = Set(requests.filter { hidden.contains($0.activity.canonicalized().id) }.map { "request:" + $0.id })
        let visibleNotices = (notices + walletNotices).filter { notice in
            !hiddenRequestNotices.contains(notice.id) && (notice.kind == .lowQuota || !hidden.contains { notice.id.hasPrefix($0 + ":") })
        }
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
        for value in visibleActivities {
            guard !value.isInternalReview, let latency = value.firstTokenLatency, latency.isFinite, (0...3600).contains(latency),
                  let reported = value.firstTokenReportedAt, reported <= date,
                  latestFirstOutput.map({ reported > $0.at }) ?? true else { continue }
            latestFirstOutput = (reported, latency)
        }
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
            }, wallet: compactWallet, firstOutput: latestFirstOutput?.seconds, warnings: compactWarnings, now: date)
        let displayedQuota = AgentProvider.allCases.compactMap { provider in snapshots[provider].map { EngineQuota($0, provider: provider, at: date) } }
        let weekly = QuotaDashboardPresentation.Reading(provider: .codex, period: .weekly, snapshot: snapshots[.codex],
            failed: !demo && codexQuotaFailed, refreshing: !demo && codexQuotaRefreshing,
            sourceText: snapshots[.codex] == nil ? nil : L10n.text("quota.source_codex"), now: date)
        var history: [AgentProvider: QuotaHistoryPresentation] = enabled.contains(.codex) ? [.codex:
            codexHistory.presentation(provider: .codex, snapshot: snapshots[.codex], weekly: weekly,
                error: quotaErrors[.codex], refreshing: !demo && codexQuotaRefreshing, now: date)] : [:]
        if usesClaudeWeb, enabled.contains(.claude), let state = claudeQuotaState {
            let weekly = QuotaDashboardPresentation.Reading(provider: .claude, period: .weekly, snapshot: snapshots[.claude],
                failed: failedProviders.contains(.claude), refreshing: state.refreshing, sourceText: sourceTexts[.claude], now: date)
            history[.claude] = claudeHistory.presentation(provider: .claude, snapshot: snapshots[.claude], weekly: weekly,
                error: quotaErrors[.claude], refreshing: state.refreshing, now: date)
        }
        let dashboard = EngineQuotaDashboard(enabled: enabled, snapshots: snapshots,
            failed: failedProviders, refreshing: refreshingProviders, sourceText: sourceTexts, errorText: quotaErrors, history: history, at: date)
        if projectionReady {
            #if os(Windows)
            let codexDefaultProfile = demo || WindowsActivityNavigation.isDefaultProfile(codexHome, provider: .codex)
            #endif
            navigation.update(activities: visibleActivities, requests: visibleRequests, inbox: inbox,
                cloudContext: cloudNavigationContext) { activity in
                guard [.claude, .codex].contains(activity.provider), !activity.isInternalReview, !activity.isIgnoredCodexSession else { return false }
                if demo { return true }
                if activity.claudeCloud != nil { return activity.threadURL != nil }
                #if os(Windows)
                if activity.provider == .codex, !activity.launchedByEmbeddingApp,
                   !codexDefaultProfile { return false }
                #endif
                return activity.sourceHostID == nil && activity.threadID.flatMap(UUID.init(uuidString:)) != nil
            }
        }
        let snapshot = EngineSnapshot(sequence: sequence, demo: demo, activities: visibleActivities, requests: visibleRequests,
            sources: displayedSources, quota: displayedQuota,
            notices: visibleNotices, inbox: inbox, hideProjects: hideProjects, now: date, wallet: enabled.contains(.deepseek) ? wallet : nil,
            modules: moduleConfigurationActive ? AgentProvider.allCases.map {
                .init(provider: $0.rawValue, mode: moduleSettings.mode(for: $0).rawValue,
                    installed: installation?.isInstalled($0), enabled: enabled.contains($0))
            } : nil, quotaDashboard: dashboard, showsDeepSeekTurnCost: deepseekSettings.showsTurnCost,
            compactWarnings: compactWarnings, compactContext: compactContext,
            deepseekConnection: balanceState.map { EngineDeepSeekConnection($0, now: date) },
            claudeConnection: claudeQuotaState.map { EngineClaudeConnection($0, paused: claudeWebPaused) },
            claudeCloudConnection: cloudState.map(EngineClaudeCloudConnection.init), activityLinks: projectionReady ? navigation.links : [])
        guard let bytes = try? JSONEncoder().encode(snapshot), bytes.count <= EngineProtocol.maximumSnapshotBytes else {
            failure(id: nil, code: "snapshotLimit"); return
        }
        output(bytes + Data([10]))
    }

    func stop() async {
        navigation.invalidate()
        generation += 1; initialized = false; projectionReady = false
        maintenance?.cancel(); maintenance = nil
        presentationClock?.cancel(); presentationClock = nil
        refreshTask?.cancel(); refreshRequested = false; discoveryRequested = false
        forceBalanceRequested = false
        let quota = quotaMonitor, claude = claudeQuotaMonitor, cloud = claudeCloudMonitor
        let desktop = desktopMonitor, balance = balanceMonitor, web = webBridge, claudeWeb = claudeWebBridge
        let watcher = logWatcher, stopWatching = !demo
        let deadline = ShutdownDeadline(), claudeActivity = claudeActivityMonitor, deepseekActivity = deepseekActivityMonitor
        await deadline.perform([
            { await quota?.stop() }, { await claude?.stop() }, { await cloud?.stop() },
            { await desktop?.stop() }, { await balance?.stop() },
            { await claudeActivity.shutdown(deadline: deadline) }, { await deepseekActivity.shutdown() },
            { await web.setAvailable(false) }, { await claudeWeb.setAvailable(false) },
            { if stopWatching { watcher.stop(); _ = await watcher.activeWatchCount() } }
        ])
    }
    private var cloudNavigationContext: String? { cloudState.map { $0.connectionContext + "|" + claudeOrganization } }
    private func navigationIsCurrent(_ entry: ActivityNavigationRegistry.Entry) -> Bool {
        initialized && projectionReady && navigation.entry(context: entry.link.context)?.link == entry.link && enabled.contains(entry.target.provider) &&
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
