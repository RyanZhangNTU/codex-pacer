import AppKit
import SwiftUI
import PacerCore
import UserNotifications

private let showExistingIsland = Notification.Name("com.codexpacer.island.showExistingInstance")

@main
enum PacerMain {
    @MainActor static func main() {
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

    private static func diagnoseEvents() async {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
        let monitor = RealtimeActivityMonitor()
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--observe-seconds")
        let seconds = index.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }.map { min(60, max(5, $0)) } ?? 20
        print("Local event endpoint available: \(RealtimeActivityMonitor.localEndpointAvailable(home: home))")
        await monitor.start(home: home) { _, _, _ in }
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
private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
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
            "compactMetric": "remaining", "quotaWindowID": "auto", "showInMenuBar": false])
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
        model.onOpenActivity = { [weak self] activity in self?.openActivity(activity) }
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
                button.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Codex Pacer")
                button.imagePosition = .imageLeading
                button.target = self
                button.action = #selector(statusClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            // Keep left-click independent from the right-click context menu.
            statusItem = item
        }
        statusItem?.button?.title = " " + model.quotaSummary
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
        let url = URL(fileURLWithPath: "/Applications/Codex.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        model.close()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    @objc private func demoStageChanged(_ sender: NSMenuItem) {
        if let stage = DemoTaskStage(rawValue: sender.tag) { model.setDemoStage(stage) }
    }
    private func openActivity(_ activity: SessionActivity) {
        if model.isDemo {
            let window = demoConversationWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("demo.chat_title"); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DemoConversationView(activity: activity) { [weak self] in
                self?.demoConversationWindow?.orderOut(nil); self?.panel.show()
            })
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            demoConversationWindow = window; model.close(); return
        }
        guard model.canOpen(activity), let threadURL = activity.threadURL else { return }
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        model.close()
        NSWorkspace.shared.open([threadURL], withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 670),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("menu.settings_title")
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model, updater: updater) { [weak self] in
            self?.settingsWindow?.orderOut(nil)
        })
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
        panel.stop()
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
