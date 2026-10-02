import AppKit
import SwiftUI
import PacerCore
import UserNotifications

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
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
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
        guard let executable = CodexClient.findExecutable() else {
            print("Codex CLI unavailable"); exit(1)
        }
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
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
            let remote = RemoteActivityMonitor()
            await remote.start(home: home) { _, _ in }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let remoteActivities = await remote.currentActivities()
            let combined = ActivityOverview(activities: local.activities + remoteActivities, at: Date())
            print("SSH running tasks: \(remoteActivities.filter { $0.observedPhase(at: Date()) == .running }.count)")
            print("Combined running user tasks: \(combined.running.count)")
            print("Unavailable SSH sources: \(await remote.unavailableSources().count)")
            await remote.shutdown()
            await client.disconnect()
        } catch {
            print((error as? CodexClientError)?.errorDescription ?? "Quota unavailable")
            await client.disconnect()
            exit(1)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: IslandModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["lowQuotaReminder": true, "inputReminder": true,
            "completionReminder": true, "completedRetentionMinutes": 30, "systemNotifications": false, "compactMetric": "remaining", "quotaWindowID": "auto"])
        model = IslandModel(demo: CommandLine.arguments.contains("--demo"), initiallyExpanded: CommandLine.arguments.contains("--expanded"))
        panel = PanelController(model: model)
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onOpenActivity = { [weak self] activity in self?.openActivity(activity) }
        model.onStatusChange = { [weak self] in self?.updateStatusItem() }
        UNUserNotificationCenter.current().delegate = self
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex Pacer", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Codex Pacer")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // The status item has no bound menu, so its left-click action remains independent.
        updateStatusItem()
        model.start()
    }

    private func updateStatusItem() {
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
        for (title, selector) in [("显示状态岛", #selector(showIsland)), ("打开 Codex", #selector(openCodex)), ("刷新额度", #selector(refresh)), ("设置…", #selector(showSettings)), ("退出 Codex Pacer", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
    }
    @objc private func showIsland() { panel.show() }
    @objc private func refresh() { model.refreshQuota() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openCodex() {
        let url = URL(fileURLWithPath: "/Applications/Codex.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        model.close()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    private func openActivity(_ activity: SessionActivity) {
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
            window.title = "Codex Pacer 设置"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model) { [weak self] in
            self?.settingsWindow?.orderOut(nil)
        })
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        panel.stop()
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
