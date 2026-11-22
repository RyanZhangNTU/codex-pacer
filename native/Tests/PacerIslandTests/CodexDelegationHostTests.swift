import UserNotifications
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

/// The Mac's side of Codex for Claude: Settings → Collaboration's choices, the
/// switch file they keep in the selected Claude home, the skill the hook setup
/// adds, and the runs shown under their Claude task. Synthetic data only.
@MainActor
final class CodexDelegationHostTests: XCTestCase {
    private struct Fixture {
        let model: IslandModel
        let defaults: UserDefaults
        let home: URL
        let root: URL
    }
    private func fixture(codex: ProviderModuleMode = .disabled) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-delegation-" + UUID().uuidString)
        let home = root.appendingPathComponent("claude-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let domain = testDefaultsName("codex-delegation-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(root.path, forKey: "codexHome")
        defaults.set(home.path, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        defaults.set(false, forKey: "systemNotifications")
        ProviderModules(codexMode: codex, claudeMode: .enabled, deepseekMode: .disabled).save(to: defaults)
        let model = IslandModel(demo: false, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: codex == .enabled, claudeInstalled: true),
            completionDismissalStore: CompletionDismissalStore(fileURL: root.appendingPathComponent("dismissals.json")))
        model.hostApplicationResolver = { _, _, _ in [:] }
        addTeardownBlock {
            await model.shutdown()
            removeTestDefaults(domain)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(model: model, defaults: defaults, home: home, root: root)
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func stored(_ home: URL) throws -> ClaudeCodexDelegation.Settings {
        try JSONDecoder().decode(ClaudeCodexDelegation.Settings.self, from: Data(contentsOf: ClaudeCodexDelegation.configURL(home: home)))
    }

    func testStoredChoicesBecomeTheRunnersDefaultsAndInvalidOnesFallBack() throws {
        let fixture = try fixture(), defaults = fixture.defaults
        XCTAssertEqual(CodexDelegationPreferences(defaults: defaults), CodexDelegationPreferences(), "Off, with rows and Codex's own choices, until chosen")
        var chosen = CodexDelegationPreferences()
        chosen.enabled = true; chosen.rows = false; chosen.model = "gpt-5.5-codex"; chosen.effort = "high"; chosen.fast = "on"
        chosen.write = true; chosen.timeoutMinutes = 120; chosen.maxConcurrent = 2
        chosen.save(to: defaults)
        XCTAssertEqual(CodexDelegationPreferences(defaults: defaults), chosen)
        XCTAssertEqual(chosen.settings(codex: "/usr/local/bin/codex"),
            .init(codex: "/usr/local/bin/codex", model: "gpt-5.5-codex", effort: "high", fast: true, sandbox: .workspaceWrite,
                  timeoutMinutes: 120, maxConcurrent: 2))
        XCTAssertEqual(CodexDelegationPreferences().settings(codex: nil), .init(), "Empty choices follow Codex's configuration")

        defaults.set("rm -rf", forKey: CodexDelegationPreferences.modelKey)
        defaults.set("turbo", forKey: CodexDelegationPreferences.effortKey)
        defaults.set("maybe", forKey: CodexDelegationPreferences.fastKey)
        defaults.set(7, forKey: CodexDelegationPreferences.timeoutKey)
        defaults.set(5, forKey: CodexDelegationPreferences.concurrencyKey)
        let fallback = CodexDelegationPreferences(defaults: defaults)
        XCTAssertEqual([fallback.model, fallback.effort, fallback.fast], ["", "", ""])
        XCTAssertEqual([fallback.timeoutMinutes, fallback.maxConcurrent], [60, 3])
        XCTAssertFalse(CodexDelegationPreferences.validModel("-x"))
        XCTAssertTrue(CodexDelegationPreferences.validModel("gpt-5.5-codex"))

        // Version 2's choices: Claude starts runs only when asked, failures alert, long runs do not, 30 days of statistics.
        let fresh = CodexDelegationPreferences()
        XCTAssertEqual(fresh.initiative, .ask); XCTAssertTrue(fresh.failureAlerts)
        XCTAssertEqual([fresh.longRunMinutes, fresh.statsDays], [0, 30]); XCTAssertFalse(fresh.coachShown)
        defaults.set("eager", forKey: CodexDelegationPreferences.initiativeKey)
        defaults.set(45, forKey: CodexDelegationPreferences.longRunKey)
        defaults.set(14, forKey: CodexDelegationPreferences.statsDaysKey)
        let invalid = CodexDelegationPreferences(defaults: defaults)
        XCTAssertEqual(invalid.initiative, .ask)
        XCTAssertEqual([invalid.longRunMinutes, invalid.statsDays], [0, 30])
        var review = CodexDelegationPreferences(); review.initiative = .review
        XCTAssertEqual(review.settings(codex: nil).initiative, .review)
        XCTAssertNil(CodexDelegationPreferences().settings(codex: nil).initiative, "Asking is the default, stored as no value")
    }

    func testChangingTheInitiativeBringsTheSkillCurrent() throws {
        let fixture = try fixture(), model = fixture.model, home = fixture.home
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.save(to: fixture.defaults)
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home))
        XCTAssertFalse(model.applyCodexDelegationSwitch(home: home))
        chosen.initiative = .suggest; chosen.save(to: fixture.defaults)
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home), "The initiative is written into the skill, so the hooks are brought current")
        XCTAssertEqual(try stored(home).initiative, .suggest)
    }

    func testTheOneTimeHintStaysClosedOnceDismissed() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.model.showsDelegationCoach)
        fixture.model.dismissDelegationCoach()
        XCTAssertFalse(fixture.model.showsDelegationCoach)
        XCTAssertTrue(CodexDelegationPreferences(defaults: fixture.defaults).coachShown)
    }

    func testAFailedRunNotifiesOnlyWhileFailureAlertsAreOn() async throws {
        let fixture = try fixture(codex: .enabled), model = fixture.model, now = Date()
        fixture.defaults.set(true, forKey: "systemNotifications")
        var delivered: [UNNotificationRequest] = []
        model.notifications = NotificationDelivery(defaults: fixture.defaults, authorizationStatus: { .authorized }, addRequest: { delivered.append($0) })
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.save(to: fixture.defaults)
        model.applyCodexDelegationSwitch(home: model.claudeHome)
        let session = "00000000-0000-4000-8000-000000000003"
        func file(_ name: String, status: String) throws -> URL {
            let run = ClaudeCodexDelegation.runsURL(home: fixture.home).appendingPathComponent(session).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["created": now.addingTimeInterval(-30).timeIntervalSince1970, "label": "Check the parser",
                "mode": "task", "status": status, "reason": "quota"]).write(to: run.appendingPathComponent("meta.json"))
            return run
        }
        let first = try file("run-1", status: "running")
        model.receiveClaudeUpdate([DemoScenario.claudeTask(stage: .thinking, at: now)], statuses: [:], requests: [])
        model.applyCodexDelegationPreferences()
        XCTAssertTrue(delivered.isEmpty, "The first look at the ledger is a baseline")
        _ = try file("run-1", status: "failed")
        model.applyCodexDelegationPreferences()
        try await TestWait.until { delivered.count == 1 }
        XCTAssertEqual(delivered.first?.identifier, "pacer-delegation:" + first.path + ":failed")

        chosen.failureAlerts = false; chosen.save(to: fixture.defaults)
        _ = try file("run-2", status: "running")
        model.applyCodexDelegationPreferences()
        _ = try file("run-2", status: "failed")
        model.applyCodexDelegationPreferences()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(delivered.count, 1, "With failure alerts off, a failed run says nothing")
    }

    func testTheSwitchWritesTheChoicesAndRemovesOnlyItsOwnFile() throws {
        let fixture = try fixture(), model = fixture.model, home = fixture.home, defaults = fixture.defaults
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        let config = ClaudeCodexDelegation.configURL(home: home)
        // A leftover stays until setup confirms that Pacer manages this home.
        try FileManager.default.createDirectory(at: ClaudeCodexDelegation.root(home: home), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: config)
        XCTAssertFalse(model.applyCodexDelegationSwitch(home: home))
        XCTAssertTrue(exists(config))
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home, setupConfirmed: true))
        XCTAssertFalse(exists(config))

        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.effort = "high"; chosen.timeoutMinutes = 30
        chosen.save(to: defaults)
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home))
        XCTAssertEqual(try stored(home).effort, "high")
        XCTAssertEqual(try stored(home).timeoutMinutes, 30)
        XCTAssertEqual(try stored(home).sandbox, .readOnly)
        chosen.effort = "low"; chosen.save(to: defaults)
        XCTAssertFalse(model.applyCodexDelegationSwitch(home: home), "A changed choice is no switch change")
        XCTAssertEqual(try stored(home).effort, "low", "but the runner reads it at once")

        ProviderModules(codexMode: .disabled, claudeMode: .disabled).save(to: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(exists(config), "Turning the Claude module off turns the switch off")
    }

    func testLocalSetupInstallsTheSkillWhileOnAndRemovesItWhenOff() async throws {
        let fixture = try fixture(), model = fixture.model, home = fixture.home
        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.save(to: fixture.defaults)
        model.retryClaudeLocalSetup()
        try await TestWait.until { model.claudeLocalSetup == .ready && self.exists(ClaudeCodexDelegation.skillURL(home: home)) }
        XCTAssertTrue(exists(ClaudeCodexDelegation.configURL(home: home)), "Setup creates Pacer's folder; the same pass writes the switch")
        XCTAssertTrue(exists(ClaudeCodexDelegation.runnerURL(home: home)))
        let skill = try String(contentsOf: ClaudeCodexDelegation.skillURL(home: home), encoding: .utf8)
        let command = ClaudeCodexDelegation.command(python: "python3", home: model.claudeHome)
        XCTAssertFalse(command.contains("\""), "A path without spaces needs no quotes")
        let allowed = skill.split(separator: "\n").first { $0.hasPrefix("allowed-tools:") }.map(String.init)
        XCTAssertEqual(allowed, "allowed-tools: Bash(" + command + ":*)", "Claude runs the Mac's runner command without asking")

        chosen.enabled = false; chosen.save(to: fixture.defaults)
        model.applyCodexDelegationPreferences()
        XCTAssertFalse(exists(ClaudeCodexDelegation.configURL(home: home)), "Turning it off removes the switch at once")
        try await TestWait.until { !self.exists(ClaudeCodexDelegation.skillURL(home: home)) }
        XCTAssertFalse(exists(ClaudeCodexDelegation.skillURL(home: home)), "and the skill with the next setup")
    }

    func testARunShowsUnderItsClaudeTaskAndStopsFromPacer() throws {
        let fixture = try fixture(codex: .enabled), model = fixture.model, now = Date()
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        // The demo Claude task's session, which files the run in the ledger.
        let session = "00000000-0000-4000-8000-000000000003", thread = "019a0000-0000-7000-8000-000000000071"
        XCTAssertEqual(claude.id, AgentProvider.claude.activityID(sessionID: session))
        let run = ClaudeCodexDelegation.runsURL(home: fixture.home).appendingPathComponent(session).appendingPathComponent("run-1")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["created": now.addingTimeInterval(-5).timeIntervalSince1970, "thread": thread,
            "label": "Review login changes", "mode": "review", "status": "running"]).write(to: run.appendingPathComponent("meta.json"))
        var codex = SessionActivity(id: AgentProvider.codex.activityID(sessionID: thread))
        codex.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": now.addingTimeInterval(-4).timeIntervalSince1970])
        codex.setCodexOrigin(.init(embedded: true, ignored: false, delegated: true))

        model.receiveClaudeUpdate([claude], statuses: [:], requests: [])
        model.receiveLocalUpdate([codex], requests: [])
        let rows = model.taskPresentation.rows
        XCTAssertEqual(rows.map(\.activity.id), [claude.id], "The run is no task of its own")
        XCTAssertEqual(rows.first?.delegatedCount, 1)
        XCTAssertEqual(rows.first?.delegations.map(\.title), ["Review login changes"])
        XCTAssertEqual(model.taskPresentation.header(symbol: \.rawValue).delegatedRunning, 1, "The badge counts it")
        let line = try XCTUnwrap(rows.first?.delegations.first)
        XCTAssertTrue(line.canStopDelegation)
        XCTAssertTrue(model.stopDelegation(line.activity))
        XCTAssertTrue(exists(run.appendingPathComponent("stop")), "The runner stops Codex when it sees this")

        fixture.defaults.set(false, forKey: CodexDelegationPreferences.rowsKey)
        XCTAssertEqual(model.taskPresentation.rows.first?.delegations.count, 0, "Count only")
        XCTAssertEqual(model.taskPresentation.rows.first?.delegatedCount, 1)
    }
}
