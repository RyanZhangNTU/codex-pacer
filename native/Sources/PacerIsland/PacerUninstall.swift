import AppKit
import Foundation
import PacerCore
import PacerMacSupport
import ServiceManagement
import WebKit

/// Pacer's own uninstall. It removes what Pacer added outside its bundle:
/// Claude hooks on this Mac and on the SSH hosts it set up, the Codex
/// reporter, saved sign-ins and the login item, then moves the app to the
/// Trash. Each removal keeps the ownership rules of the setup that added it.
enum PacerUninstall {
    /// A place where Pacer's entries stayed behind.
    enum Leftover: Hashable, Sendable {
        case claude(URL), codex(URL), host(alias: String, name: String)

        var label: String {
            switch self {
            case .claude(let home): L10n.text("uninstall.leftover_claude", PacerUninstall.display(home))
            case .codex(let home): L10n.text("uninstall.leftover_codex", PacerUninstall.display(home))
            case .host(_, let name): L10n.text("uninstall.leftover_host", name)
            }
        }
    }

    struct Plan: Sendable {
        var claudeHomes: [URL]
        var codexHomes: [URL]
        var codexExecutable: String
        var hosts: [RemoteActivityTarget]
    }

    struct Services: Sendable {
        var removeClaude: @Sendable (URL) throws -> Void
        /// True when the home keeps nothing of Pacer's.
        var removeCodex: @Sendable (URL, String) async -> Bool
        var removeHost: @Sendable (RemoteActivityTarget) async throws -> Void
        /// A removed host must be set up again if Pacer returns.
        var forgetHost: @Sendable (String) -> Void
    }

    static func display(_ home: URL) -> String { (home.path as NSString).abbreviatingWithTildeInPath }

    /// The selected homes, plus the environment's and the default, since the
    /// selection may have changed after setup. The hosts are the ones Pacer
    /// recorded as set up, whether or not SSH monitoring is still on.
    static func plan(claudeHome: URL, codexHome: URL, codexExecutable: String, configuredHosts: [String],
                     knownTargets: [RemoteActivityTarget], environment: [String: String], userHome: URL) -> Plan {
        func homes(_ selected: URL, variable: String, name: String) -> [URL] {
            let named = environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            var seen = Set<String>()
            return ([selected] + [named].compactMap { $0 } + [userHome.appendingPathComponent(name)])
                .map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        }
        let hosts = configuredHosts.sorted().map { alias in
            knownTargets.first { $0.alias == alias } ?? RemoteActivityTarget(id: "ssh:" + alias, name: alias, alias: alias, home: "~/.claude")
        }
        return Plan(claudeHomes: homes(claudeHome, variable: "CLAUDE_CONFIG_DIR", name: ".claude"),
                    codexHomes: homes(codexHome, variable: "CODEX_HOME", name: ".codex"),
                    codexExecutable: codexExecutable, hosts: hosts)
    }

    /// A retry visits only the places that kept entries.
    static func plan(_ plan: Plan, retrying leftovers: [Leftover]) -> Plan {
        var next = plan
        next.claudeHomes = plan.claudeHomes.filter { leftovers.contains(.claude($0)) }
        next.codexHomes = plan.codexHomes.filter { leftovers.contains(.codex($0)) }
        next.hosts = plan.hosts.filter { host in
            leftovers.contains { leftover in
                if case .host(let alias, _) = leftover { alias == host.alias } else { false }
            }
        }
        return next
    }

    /// Every place at once: an unreachable host costs its own timeout only.
    static func removeConfiguration(_ plan: Plan, services: Services) async -> [Leftover] {
        await withTaskGroup(of: Leftover?.self) { group in
            for home in plan.claudeHomes {
                group.addTask { (try? services.removeClaude(home)) == nil ? .claude(home) : nil }
            }
            for home in plan.codexHomes {
                group.addTask { await services.removeCodex(home, plan.codexExecutable) ? nil : .codex(home) }
            }
            for host in plan.hosts {
                group.addTask {
                    do { try await services.removeHost(host); services.forgetHost(host.alias); return nil }
                    catch { return .host(alias: host.alias, name: host.name) }
                }
            }
            var leftovers: [Leftover] = []
            for await leftover in group { if let leftover { leftovers.append(leftover) } }
            return leftovers.sorted { $0.label < $1.label }
        }
    }

    static func live(remote: ClaudeRemoteSetup, reporterName: String) -> Services {
        Services(
            removeClaude: { home in
                // A home Pacer never set up is left unread: its settings may be
                // anything, and there is nothing of Pacer's to remove.
                let manager = FileManager.default
                guard manager.fileExists(atPath: home.appendingPathComponent("pacer").path) else { return }
                if manager.fileExists(atPath: home.appendingPathComponent("pacer/installation.json").path) {
                    try ClaudeHookInstaller.uninstall(home: home)
                }
                let flag = ClaudeProgressRingSwitch.flagURL(home: home)
                if manager.fileExists(atPath: flag.path) { try manager.removeItem(at: flag) }
            },
            removeCodex: { home, executable in
                await CodexProgressSetup.apply(home: home, reporter: nil, storage: MacClaudeHookStorage(),
                    owns: { $0.isNative(named: reporterName, home: home) }) {
                    CodexClient.findExecutable(customPath: executable).map { CodexClient(executable: $0, home: home, timeout: 3) }
                } == nil
            },
            removeHost: { target in _ = try await remote.uninstall(target: target) },
            forgetHost: { alias in ClaudeRemoteAutoSetup.forget(alias: alias) })
    }

    /// Pacer's own folders inside a Claude or Codex home. A folder stays while
    /// the home's settings still name it, so a hook that could not be removed
    /// never points at a missing script.
    static func ownedFolders(plan: Plan, leftovers: [Leftover]) -> [URL] {
        var folders: [URL] = []
        for home in plan.claudeHomes where !leftovers.contains(.claude(home)) {
            let folder = home.appendingPathComponent("pacer", isDirectory: true)
            let settings = (try? String(contentsOf: home.appendingPathComponent("settings.json"), encoding: .utf8)) ?? ""
            if !settings.contains(folder.path) { folders.append(folder) }
        }
        for home in plan.codexHomes where !leftovers.contains(.codex(home)) {
            folders.append(home.appendingPathComponent("pacer/codex-progress", isDirectory: true))
        }
        return folders
    }

    /// Saved sign-ins and the login item always go; settings, history and
    /// Pacer's folders in other apps' homes only when the user asks.
    @MainActor static func finish(deleteData: Bool, plan: Plan, leftovers: [Leftover], bundleIdentifier: String) async {
        DeepSeekAPIKeyStore.remove()
        ClaudeQuotaCredentialCache.removeAll()
        await DeepSeekWebSessionStore.signOut()
        await ClaudeWebSessionStore.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        if SMAppService.mainApp.status != .notRegistered { try? await SMAppService.mainApp.unregister() }
        guard deleteData else { return }
        let manager = FileManager.default
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        var folders = [library.appendingPathComponent("Application Support/CodexPacerIsland", isDirectory: true),
                       library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true)]
        folders += ["Caches", "HTTPStorages", "WebKit"].map { library.appendingPathComponent($0).appendingPathComponent(bundleIdentifier) }
        folders += ownedFolders(plan: plan, leftovers: leftovers)
        for folder in folders where manager.fileExists(atPath: folder.path) { try? manager.removeItem(at: folder) }
        for home in plan.codexHomes {
            let parent = home.appendingPathComponent("pacer", isDirectory: true)
            if (try? manager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true { try? manager.removeItem(at: parent) }
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
    }

    /// A copy opened from the Trash to finish an earlier removal stays there.
    @MainActor static func moveToTrash(_ bundle: URL) async -> Bool {
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: bundle, create: false),
           bundle.standardizedFileURL.path.hasPrefix(trash.standardizedFileURL.path + "/") { return true }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([bundle]) { trashed, error in
                continuation.resume(returning: error == nil && trashed[bundle] != nil)
            }
        }
    }
}

/// The menu command's dialogs. Monitoring stops first, so nothing sets up
/// again while entries are removed; Cancel relaunches Pacer as it was.
@MainActor
final class PacerUninstallController {
    private enum Choice { case retry, proceed, cancel }
    private let model: IslandModel
    private let relaunch: () -> Void
    private var progress: NSPanel?
    private var running = false

    init(model: IslandModel, relaunch: @escaping () -> Void) {
        self.model = model; self.relaunch = relaunch
    }

    /// Data stays unless the box is checked; Return confirms, Escape cancels.
    static func confirmation() -> (alert: NSAlert, deleteData: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("uninstall.title")
        alert.informativeText = L10n.text("uninstall.detail")
        let deleteData = NSButton(checkboxWithTitle: L10n.text("uninstall.delete_data"), target: nil, action: nil)
        deleteData.state = .off
        alert.accessoryView = deleteData
        alert.addButton(withTitle: L10n.text("uninstall.confirm")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.text("common.cancel")).keyEquivalent = "\u{1b}"
        return (alert, deleteData)
    }

    func begin() {
        guard !running, !model.isDemo else { return }
        let (alert, deleteData) = Self.confirmation()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        running = true
        let removesData = deleteData.state == .on
        Task { await perform(deleteData: removesData) }
    }

    private func perform(deleteData: Bool) async {
        showProgress()
        let plan = model.uninstallPlan()
        await model.shutdown()
        let services = PacerUninstall.live(remote: ClaudeRemoteSetup(),
            reporterName: Bundle.main.executableURL?.lastPathComponent ?? "CodexPacerIsland")
        var leftovers = await PacerUninstall.removeConfiguration(plan, services: services)
        var attempt = plan
        while !leftovers.isEmpty {
            hideProgress()
            switch ask(about: leftovers) {
            case .retry:
                showProgress()
                attempt = PacerUninstall.plan(attempt, retrying: leftovers)
                leftovers = await PacerUninstall.removeConfiguration(attempt, services: services)
            case .proceed:
                showProgress()
                await finish(plan: plan, leftovers: leftovers, deleteData: deleteData)
                return
            case .cancel:
                running = false
                relaunch()
                return
            }
        }
        await finish(plan: plan, leftovers: [], deleteData: deleteData)
    }

    private func finish(plan: PacerUninstall.Plan, leftovers: [PacerUninstall.Leftover], deleteData: Bool) async {
        await PacerUninstall.finish(deleteData: deleteData, plan: plan, leftovers: leftovers,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.codexpacer.app")
        let bundle = Bundle.main.bundleURL
        let trashed = await PacerUninstall.moveToTrash(bundle)
        hideProgress()
        if !trashed {
            let alert = NSAlert()
            alert.messageText = L10n.text("uninstall.trash_failed")
            alert.informativeText = L10n.text("uninstall.trash_failed_detail")
            alert.addButton(withTitle: L10n.text("uninstall.show_in_finder"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
        }
        NSApp.terminate(nil)
    }

    /// Retry visits only the listed places; Cancel keeps Pacer and restarts it.
    static func leftoverAlert(_ leftovers: [PacerUninstall.Leftover]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("uninstall.leftovers_title")
        alert.informativeText = L10n.text("uninstall.leftovers_detail", leftovers.map { "• " + $0.label }.joined(separator: "\n"))
        alert.addButton(withTitle: L10n.text("connections.retry"))
        alert.addButton(withTitle: L10n.text("uninstall.anyway"))
        alert.addButton(withTitle: L10n.text("common.cancel")).keyEquivalent = "\u{1b}"
        return alert
    }

    private func ask(about leftovers: [PacerUninstall.Leftover]) -> Choice {
        let alert = Self.leftoverAlert(leftovers)
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .proceed
        default: return .cancel
        }
    }

    private func showProgress() {
        guard progress == nil else { progress?.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = L10n.text("uninstall.title_short")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: L10n.text("uninstall.progress"))
        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        panel.contentView = row
        panel.center()
        panel.orderFrontRegardless()
        progress = panel
    }

    private func hideProgress() {
        progress?.orderOut(nil); progress = nil
    }
}
