import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

/// What the Mac host feeds every module page's Status card, and what Remote
/// still counts once this computer's sources moved to their modules' pages.
@MainActor
final class ModuleStatusHostTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func model() throws -> IslandModel {
        let domain = testDefaultsName("ModuleStatusHostTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { removeTestDefaults(domain) }
        ProviderModules(codexMode: .enabled, claudeMode: .disabled, deepseekMode: .disabled).save(to: defaults)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-status-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        defaults.set(home.path, forKey: "codexHome"); defaults.set(false, forKey: "monitorSSH")
        defaults.set(false, forKey: "systemNotifications")
        let model = IslandModel(demo: false, defaults: defaults, installation: .init(codexInstalled: true, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: home.appendingPathComponent("dismissals.json")))
        addTeardownBlock { await model.shutdown() }
        return model
    }

    private func task(_ thread: String, host: String? = nil, ended: Bool = false) -> SessionActivity {
        var activity = SessionActivity(id: thread, sourceHostID: host, sessionID: thread)
        activity.applyRuntime(["method": "turn/started", "threadId": thread, "turnId": "turn-" + thread, "at": epoch.timeIntervalSince1970])
        if ended {
            activity.applyRuntime(["method": "turn/completed", "threadId": thread, "turnId": "turn-" + thread,
                                   "at": epoch.addingTimeInterval(5).timeIntervalSince1970, "status": "completed"])
        }
        return activity
    }

    func testMonitoringCountsOnlyThisComputersRunningSessions() throws {
        let model = try model()
        model.receiveLocalUpdate([task("019a0000-0000-7000-8000-0000000000b1"), task("019a0000-0000-7000-8000-0000000000b2"),
                                  task("019a0000-0000-7000-8000-0000000000b3", ended: true)], requests: [])
        model.receiveRemoteUpdate([task("019a0000-0000-7000-8000-0000000000b4", host: "remote-ssh-discovered:host"),
                                   task("019a0000-0000-7000-8000-0000000000b5", host: DurableActivityCatalog.hostID)],
                                  statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.localRunningSessions(.codex), 2, "Ended tasks, other hosts and Dot are not this computer's running sessions")
        XCTAssertEqual(model.localRunningSessions(.claude), 0)
        let monitoring = ModuleMonitoring.codex(executableFound: true, hooks: .running, sessions: model.localRunningSessions(.codex), opensCodex: true)
        XCTAssertEqual(monitoring.tone, .positive)
        XCTAssertTrue(monitoring.text.contains("2"), "Running sessions follow the state while monitoring is on")
    }

    func testRemoteCountsOnlyHostsAndTheHooksAreCodexsOwn() async throws {
        let model = try model()
        model.codexHookSetupOverride = { _, _, enabled in
            .init(supportsHooks: true, installed: enabled, trust: Array(repeating: "untrusted", count: 7))
        }
        model.syncCodexHooks()
        try await TestWait.until { model.codexHookStatus == .needsApproval(count: 7) }
        XCTAssertTrue(model.codexHooksNeedUser)
        XCTAssertEqual(SettingsConnectionsPane.problemCount(model), 0, "Hooks waiting for approval are Codex's page's, not Remote's")
        let monitoring = ModuleMonitoring.codex(executableFound: true, hooks: model.codexHookStatus, sessions: 0, opensCodex: true)
        XCTAssertTrue(monitoring.needsUser)
        XCTAssertEqual(monitoring.action, .openCodex)
    }

    func testCodexAccountFollowsTheQuotaRead() throws {
        let model = try model()
        XCTAssertEqual(model.codexAccount, .checking, "Nothing read yet")
        XCTAssertEqual(model.codexAccount.tone, .neutral)
    }
}
