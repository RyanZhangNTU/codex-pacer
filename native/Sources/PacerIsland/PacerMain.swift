import AppKit
import SwiftUI
import PacerCore
import UserNotifications

private let showExistingIsland = Notification.Name("com.codexpacer.island.showExistingInstance")

@main
enum PacerMain {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--diagnose-claude-cache") {
            let action = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : ""
            let result = ClaudeQuotaClient.credentialCacheDiagnostics(action: action)
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        if CommandLine.arguments.contains("--diagnose-claude") {
            Task.detached { await diagnoseClaude(); exit(0) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--diagnose-task") {
            Task.detached { await diagnoseTask(); exit(0) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--diagnose-events") {
            Task.detached { await diagnoseEvents(); exit(0) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--diagnose") {
            Task.detached { await diagnose(); exit(0) }
            dispatchMain()
        }
        // AppKit owns the main run loop. An async MainActor.run closure around
        // app.run() would hold the actor job and block all refresh tasks.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let lockURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/instance.lock")
        let instance: IslandInstanceLock
        do { instance = try IslandInstanceLock(at: lockURL) }
        catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("app.launch_failed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        guard instance.acquired else {
            DistributedNotificationCenter.default().postNotificationName(showExistingIsland,
                object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime((delegate, instance)) { app.run() }
    }

    /// Read-only protocol/counter checks; no identities, titles or transcripts.
    private static func diagnoseClaude() async {
        let defaults = UserDefaults.standard
        let configured = defaults.string(forKey: "claudeHome") ?? ""
        let home = URL(fileURLWithPath: CodexExecutableResolver.normalize(configured.isEmpty
            ? (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") : configured))
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--observe-seconds")
        let seconds = index.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }.map { min(60, max(5, $0)) } ?? 20
        print("Claude Desktop installed: \(ClaudeApplicationResolver.find() != nil)")
        print("Claude CLI available: \(ClaudeApplicationResolver.findExecutable() != nil)")
        let setup = ClaudeHookInstaller.details(home: home)
        print("Task hooks configured: \(setup.hooksConfigured); request telemetry configured: \(setup.telemetryConfigured)")
        if !args.contains("--skip-quota") {
            let client = ClaudeQuotaClient(home: home)
            do {
                let snapshot = try await client.readQuota()
                print("Claude quota connected: \(snapshot.windows.count) windows; reset timestamps: \(snapshot.windows.filter { $0.resetsAt != nil }.count); account scope verified: \(snapshot.accountScope != nil)")
                print("Quota source: \(await client.currentSource()?.rawValue ?? "unavailable")")
            } catch { print((error as? LocalizedError)?.errorDescription ?? "Claude quota unavailable") }
            await client.shutdown()
        }
        let monitor = ClaudeActivityMonitor()
        let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        let targets = args.contains("--desktop-only") ? [] : RemoteActivityTarget.claudeConfigured(codexHome: codexHome,
            additionalAliases: defaults.string(forKey: "claudeSSHHosts") ?? "")
        await monitor.start(home: home, remoteTargets: targets) { values, statuses, requests, performance in
            let groups = ActivityTaskGroup.make(values), now = Date()
            let summary: [String: Any] = ["connectedSources": statuses.values.filter(\.connected).count,
                "runningTasks": groups.filter(\.isRunning).count, "waitingTasks": groups.filter(\.isWaiting).count,
                "completedTasks": values.filter { [.completed, .interrupted].contains($0.phase) }.count,
                "subagents": groups.reduce(0) { $0 + $1.runningSubagentCount }, "pendingRequests": requests.count,
                "availableRates": values.filter { $0.displayedOutputEstimate(at: now) != nil }.count,
                "availableFirstOutput": values.filter { $0.firstTokenLatency != nil }.count,
                "numericUpdates": performance.count]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        if let bytes = try? JSONSerialization.data(withJSONObject: await monitor.diagnostics(), options: [.sortedKeys]),
           let text = String(data: bytes, encoding: .utf8) { print(text) }
        await monitor.shutdown()
    }

    /// Read-only numeric summary; never prints task names, text or account data.
    private static func diagnoseTask() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--thread-id"), index + 1 < args.count,
              let thread = UUID(uuidString: args[index + 1])?.uuidString.lowercased() else {
            print("A valid --thread-id is required."); return
        }
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        let hostIndex = args.firstIndex(of: "--host-id")
        let host = hostIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "local"
        guard host == "local" || host.range(of: #"^remote-control:[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            print("A valid local or Remote Control --host-id is required."); return
        }
        let monitor = RealtimeActivityMonitor()
        await monitor.start(home: home, includeSSH: false, useSSHFallback: false) { _, _, _ in }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let streamed = await monitor.activities()
        var evidence: [String: SessionActivity.SubagentEvidence] = [:]
        for value in streamed where value.sourceHostID == nil { evidence.merge(value.subagentStates) { old, new in old.observedAt > new.observedAt ? old : new } }
        let reader = LocalActivityReader()
        let logged = await reader.read(home: home, phaseAwareRate: true, includeCoveredMetrics: true, subagentStates: evidence)
        let merged = ActivitySourceMerger.merge(logged: logged.activities, streamed: streamed)
        let group = ActivityTaskGroup.make(merged).first { $0.primary.threadID == thread && ($0.primary.sourceHostID ?? "local") == host }
        let now = Date()
        let summary: [String: Any] = ["observed": group != nil,
            "liveParentObserved": group?.primary.hasLiveEvidence ?? false,
            "runningSubagents": group?.runningSubagentCount ?? 0,
            "observedSubagents": max(0, (group?.members.count ?? 1) - 1),
            "taskTPS": group?.displayedRate(at: now)?.value as Any? ?? NSNull(),
            "estimated": group?.rateIsEstimated(at: now) ?? true]
        if let bytes = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
           let text = String(data: bytes, encoding: .utf8) { print(text) }
        await monitor.shutdown()
    }

    private static func diagnoseEvents() async {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        let monitor = RealtimeActivityMonitor()
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--observe-seconds")
        let seconds = index.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }.map { min(60, max(5, $0)) } ?? 20
        print("Local event endpoint available: \(RealtimeActivityMonitor.localEndpointAvailable(home: home))")
        await monitor.start(home: home, useSSHFallback: !args.contains("--desktop-only")) { _, _, _ in }
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        let statuses = await monitor.statuses()
        for (source, status) in statuses.sorted(by: { $0.key < $1.key }) {
            print("Source \(source): connected=\(status.connected), attached=\(status.attachedThreads), notifications=\(status.notifications), fallbackScans=\(status.fallbackScans), fileWatch=\(status.watchingLogs), helperCPU=\(status.helperCpuSeconds)s, loopIterations=\(status.helperLoopIterations)")
        }
        let activities = await monitor.activities()
        print("Stream-evidenced tasks: \(activities.filter(\.hasLiveEvidence).count)")
        print("Candidate session records: \(activities.count); internal reviews: \(activities.filter(\.isInternalReview).count)")
        await monitor.shutdown()
    }

    private static func diagnose() async {
        let discovery = CodexExecutableResolver.discover(customPath: UserDefaults.standard.string(forKey: "codexExecutable") ?? "")
        guard let selection = discovery.selected else {
            print(discovery.issue ?? "Codex CLI unavailable"); exit(1)
        }
        let executable = selection.url
        print("CLI source: \(selection.source)")
        print("CLI path: \(executable.path)")
        let configuredHome = UserDefaults.standard.string(forKey: "codexHome") ?? ""
        let home = URL(fileURLWithPath: CodexExecutableResolver.normalize(configuredHome.isEmpty
            ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") : configuredHome))
        print("Codex home: \(home.path)")
        let client = CodexClient(executable: executable, home: home)
        do {
            let snapshot = try await client.readQuota()
            // Only protocol availability is printed; no identity, credentials or task text.
            print("Quota connected: \(snapshot.buckets.count) buckets, \(snapshot.windows.count) windows")
            print("Window durations: \(snapshot.windows.compactMap(\.durationMinutes)) minutes")
            print("Workspace identity verified: \(snapshot.accountScope != nil)")
            print("Reset summary available: \(snapshot.resetCredits != nil)")
            print("Reset expiry details complete: \(snapshot.resetCredits?.hasCompleteDetails == true)")
            print("Credit balance available: \(snapshot.credits?.amount != nil || snapshot.credits?.unlimited == true)")
            let local = await LocalActivityReader().read(home: home)
            let overview = ActivityOverview(activities: local.activities, at: Date())
            print("User task states: \(overview.running.count) running, \(overview.waiting.count) waiting")
            print("Internal review tasks included: \(overview.activities.filter(\.isInternalReview).count)")
            print("Fresh aggregate output rate available: \(overview.tokensPerSecond != nil)")
            let remote = RealtimeActivityMonitor()
            await remote.start(home: home) { _, _, _ in }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let remoteActivities = await remote.activities()
            let combined = ActivityOverview(activities: local.activities + remoteActivities, at: Date())
            print("SSH running tasks: \(remoteActivities.filter { $0.observedPhase(at: Date()) == .running }.count)")
            print("Combined running user tasks: \(combined.running.count)")
            print("Connected sources: \(await remote.statuses().values.filter(\.connected).count)")
            await remote.shutdown()
            await client.disconnect()
        } catch {
            print(CodexDiagnosticText.description(of: error))
            await client.disconnect()
            exit(1)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    private var model: IslandModel!
    private var updater: AppUpdater!
    private var panel: PanelController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var demoConversationWindow: NSWindow?
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferencesMigration.migrate(to: .standard, from:
            UserDefaults.standard.persistentDomain(forName: "com.codexpacer.island.preview") ?? [:])
        UserDefaults.standard.register(defaults: ["lowQuotaReminder": true, "inputReminder": true,
            "completionReminder": true, "completedRetentionMinutes": 30, "systemNotifications": false,
            "compactMetric": "remaining", "quotaWindowID": "auto", "showInMenuBar": false,
            "islandWidthMode": IslandWidthSettings.Mode.adaptive.rawValue])
        model = IslandModel(demo: CommandLine.arguments.contains("--demo"), initiallyExpanded: CommandLine.arguments.contains("--expanded"))
        updater = AppUpdater(enabled: !model.isDemo)
        panel = PanelController(model: model)
        updater.onPresentationChange = { [weak self] active in
            self?.panel.setUpdatePresentationActive(active)
        }
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: showExistingIsland,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.panel.show() }
            }
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onQuit = { [weak self] in self?.quit() }
        model.onRelaunch = { [weak self] in self?.relaunchForLanguage() }
        model.onClaudeLogin = { [weak self] in
            self?.model.close()
            ClaudeWebLogin.open { [weak self] in self?.model.retryClaudeWebConnection(afterSignIn: true) }
        }
        model.onClaudeOrganizationSelection = { [weak self] organizations in
            self?.model.close()
            ClaudeWebLogin.chooseOrganization(organizations) { [weak self] organization in
                self?.model.retryClaudeWebConnection(organizationID: organization)
            }
        }
        ClaudeWebLogin.onVisibilityChange = { [weak self] visible in
            self?.model.setInteractionSuspended(visible)
        }
        model.onOpenActivity = { [weak self] activity in
            guard let self else { return .failed(L10n.text("activity.open_failed")) }
            return await self.openActivity(activity)
        }
        model.onStatusChange = { [weak self] in self?.updateStatusItem() }
        UNUserNotificationCenter.current().delegate = self
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let settingsItem = NSMenuItem(title: L10n.text("common.settings_menu"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        let updateItem = NSMenuItem(title: L10n.text("updates.check"), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        applicationMenu.addItem(updateItem)
        if model.isDemo {
            for stage in DemoTaskStage.allCases {
                let item = NSMenuItem(title: L10n.text("demo.menu", stage.label), action: #selector(demoStageChanged(_:)), keyEquivalent: String(stage.rawValue + 1))
                item.tag = stage.rawValue; item.target = self; applicationMenu.addItem(item)
            }
        }
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.text("common.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let fileItem = NSMenuItem(title: L10n.text("common.file_menu"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.text("common.file_menu"))
        let closeItem = NSMenuItem(title: L10n.text("common.close_window"),
            action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // Resolve through the focused window, including WebKit/SSO and
        // Settings. A borderless island is not an auxiliary close target.
        closeItem.target = nil
        fileMenu.addItem(closeItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
        updateStatusItem()
        model.start()
        updater.start()
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }

    private func updateStatusItem() {
        guard model.showInMenuBar else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Codex Pacer")
                button.imagePosition = .imageLeading
                button.target = self
                button.action = #selector(statusClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            // Keep left-click independent from the right-click context menu.
            statusItem = item
        }
        statusItem?.button?.title = " " + model.enabledProviders.map { provider in
            provider.displayName + " " + model.compactQuotaText(provider)
        }.joined(separator: " · ")
        statusItem?.button?.toolTip = "Codex Pacer · \(model.compactStatus) · \(model.freshnessText)"
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            DispatchQueue.main.async { [weak self] in self?.showMenu() }
        } else if model.expanded { model.close() }
        else { panel.show() }
    }
    private func showMenu() {
        let menu = NSMenu()
        for (title, selector) in [(L10n.text("menu.show_island"), #selector(showIsland)), (L10n.text("menu.open_codex"), #selector(openCodex)), (L10n.text("menu.refresh_quota"), #selector(refresh)), (L10n.text("updates.check"), #selector(checkForUpdates)), (L10n.text("common.settings_menu"), #selector(showSettings)), (L10n.text("common.quit"), #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if model.isModuleEnabled(.claude) {
            let item = NSMenuItem(title: L10n.text("menu.open_claude"), action: #selector(openClaude), keyEquivalent: "")
            item.target = self; menu.insertItem(item, at: 2)
        }
        if let button = statusItem?.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
    }
    @objc private func showIsland() { panel.show() }
    @objc private func refresh() { model.refreshQuota() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? updater.canCheck : true
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func relaunchForLanguage() -> String? {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "PacerRelaunch") else {
            return L10n.text("language.missing_helper")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath, "--settings"]
            + CommandLine.arguments.filter { ["--demo", "--demo-notch"].contains($0) }
        do { try process.run() }
        catch { return CodexDiagnosticText.description(of: error) }
        // Schedule outside both the actor job and main dispatch-queue drain.
        // terminateLater's nested AppKit loop must be able to run shutdown tasks.
        perform(#selector(quit), with: nil, afterDelay: 0)
        return nil
    }
    @objc private func openCodex() {
        guard let url = CodexApplicationResolver.find() else {
            model.navigationError = L10n.text("activity.app_missing"); panel.show(); return
        }
        model.close()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            let message = L10n.text("activity.open_failed_detail", CodexDiagnosticText.description(of: error))
            Task { @MainActor in self?.model.navigationError = message; self?.panel.show() }
        }
    }
    @objc private func openClaude() {
        guard let url = ClaudeApplicationResolver.find() else {
            model.navigationError = L10n.text("activity.open_failed"); panel.show(); return
        }
        model.close()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.model.navigationError = L10n.text("activity.open_failed"); self?.panel.show() }
        }
    }
    @objc private func demoStageChanged(_ sender: NSMenuItem) {
        if let stage = DemoTaskStage(rawValue: sender.tag) { model.setDemoStage(stage) }
    }
    private func openActivity(_ activity: SessionActivity) async -> ActivityOpenOutcome {
        if model.isDemo {
            let window = demoConversationWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("demo.chat_title"); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DemoConversationView(activity: activity) { [weak self] in
                self?.demoConversationWindow?.orderOut(nil); self?.panel.show()
            })
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            demoConversationWindow = window; model.close(); return .openedConversation
        }
        if activity.provider == .claude {
            guard model.canOpen(activity) else { return .failed(L10n.text("activity.open_failed")) }
            model.close()
            return await ClaudeConversationOpener.open(activity, home: model.claudeHome)
        }
        guard model.canOpen(activity), let threadURL = activity.threadURL else { return .failed(L10n.text("activity.open_failed")) }
        guard let appURL = CodexApplicationResolver.find() else { return .failed(L10n.text("activity.app_missing")) }
        model.close()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([threadURL], withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                continuation.resume(returning: error.map { .failed(L10n.text("activity.open_failed_detail", CodexDiagnosticText.description(of: $0))) } ?? .openedConversation)
                }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in self?.panel.show() }
        completionHandler()
    }

    @objc private func showSettings() {
        model.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("menu.settings_title")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model, updater: updater) { [weak self] in
            self?.closeSettings()
        })
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeSettings() {
        settingsWindow?.orderOut(nil)
        settingsWindow?.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
        closing.contentView = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ClaudeWebLogin.close()
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
        panel.stop()
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
