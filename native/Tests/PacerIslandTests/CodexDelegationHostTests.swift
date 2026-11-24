import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport
import PacerMacSupport

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
        XCTAssertEqual(CodexDelegationPreferences(defaults: defaults), CodexDelegationPreferences(), "Off, following Codex, until chosen")
        XCTAssertEqual(CodexDelegationPreferences().settings(codex: nil), .init(), "The defaults follow Codex and write in the project with network")
        var chosen = CodexDelegationPreferences()
        chosen.enabled = true; chosen.trigger = .command
        chosen.followModel = false; chosen.model = "gpt-5.5-codex"; chosen.followEffort = false; chosen.effort = "xhigh"
        chosen.followFast = false; chosen.fast = true; chosen.records = .timed; chosen.recordsHours = 6
        chosen.sandbox = .readOnly; chosen.worktree = true; chosen.instructions = "Answer in English."; chosen.memory = true
        chosen.maxConcurrent = 2; chosen.quotaFloor = 20
        chosen.save(to: defaults)
        XCTAssertEqual(CodexDelegationPreferences(defaults: defaults), chosen)
        XCTAssertEqual(chosen.settings(codex: "/usr/local/bin/codex"),
            .init(codex: "/usr/local/bin/codex", model: "gpt-5.5-codex", effort: "xhigh", fast: true, trigger: .command, records: .timed,
                  recordsHours: 6, sandbox: .readOnly, worktree: true, instructions: "Answer in English.", memory: true, maxConcurrent: 2, quotaFloor: 20))
        var following = chosen; following.followModel = true; following.followEffort = true; following.followFast = true
        let settings = following.settings(codex: nil)
        XCTAssertNil(settings.model); XCTAssertNil(settings.effort); XCTAssertNil(settings.fast)
        XCTAssertEqual(following.model, "gpt-5.5-codex", "A pick is remembered while following Codex")
        XCTAssertEqual(chosen.restoringDefaults(), { var value = CodexDelegationPreferences(); value.enabled = true; return value }(),
                       "Restoring the defaults keeps the switch")

        defaults.set("rm -rf", forKey: CodexDelegationPreferences.modelKey)
        defaults.set("turbo", forKey: CodexDelegationPreferences.effortKey)
        defaults.set("later", forKey: CodexDelegationPreferences.triggerKey)
        defaults.set("forever", forKey: CodexDelegationPreferences.recordsKey)
        defaults.set(5, forKey: CodexDelegationPreferences.recordsHoursKey)
        defaults.set("root", forKey: CodexDelegationPreferences.sandboxKey)
        defaults.set(6, forKey: CodexDelegationPreferences.concurrencyKey)
        defaults.set(15, forKey: CodexDelegationPreferences.quotaFloorKey)
        let fallback = CodexDelegationPreferences(defaults: defaults)
        XCTAssertEqual([fallback.model, fallback.effort], ["", "high"])
        XCTAssertEqual(fallback.trigger, .ask); XCTAssertEqual(fallback.records, .turn); XCTAssertEqual(fallback.sandbox, .workspaceWriteNetwork)
        XCTAssertEqual([fallback.recordsHours, fallback.maxConcurrent, fallback.quotaFloor], [24, 3, 0])
        XCTAssertFalse(CodexDelegationPreferences.validModel("-x"))
        XCTAssertTrue(CodexDelegationPreferences.validModel("gpt-5.5-codex"))
    }

    func testDefaultValuedPicksSurviveFollowingAndReloading() throws {
        let defaults = try fixture().defaults
        var choices = CodexDelegationPreferences()
        choices.setFollowEffort(false, fallback: "low")
        choices.setFollowFast(false, fallback: true)
        XCTAssertEqual(choices.effort, "low"); XCTAssertTrue(choices.fast)
        choices.effort = "high"; choices.fast = false
        choices.setFollowEffort(true, fallback: nil); choices.setFollowFast(true, fallback: nil)
        choices.save(to: defaults)
        choices = CodexDelegationPreferences(defaults: defaults)
        choices.setFollowEffort(false, fallback: "low"); choices.setFollowFast(false, fallback: true)
        XCTAssertEqual(choices.effort, "high"); XCTAssertFalse(choices.fast)
    }

    func testChangingTheTriggerBringsTheSkillCurrent() throws {
        let fixture = try fixture(codex: .enabled), model = fixture.model, home = fixture.home
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.save(to: fixture.defaults)
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home))
        XCTAssertFalse(model.applyCodexDelegationSwitch(home: home))
        chosen.trigger = .command; chosen.save(to: fixture.defaults)
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home), "The trigger is written into the skill, so the hooks are brought current")
        XCTAssertEqual(try stored(home).trigger, .command)
    }

    func testTheSwitchWritesTheChoicesAndRemovesOnlyItsOwnFile() throws {
        let fixture = try fixture(codex: .enabled), model = fixture.model, home = fixture.home, defaults = fixture.defaults
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        let config = ClaudeCodexDelegation.configURL(home: home)
        // A leftover stays until setup confirms that Pacer manages this home.
        try FileManager.default.createDirectory(at: ClaudeCodexDelegation.root(home: home), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: config)
        XCTAssertFalse(model.applyCodexDelegationSwitch(home: home))
        XCTAssertTrue(exists(config))
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home, setupConfirmed: true))
        XCTAssertFalse(exists(config))

        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.followEffort = false; chosen.effort = "high"; chosen.records = .keep
        chosen.save(to: defaults)
        XCTAssertTrue(model.applyCodexDelegationSwitch(home: home))
        XCTAssertEqual(try stored(home).codexHome, fixture.root.standardizedFileURL.path)
        XCTAssertEqual(try stored(home).effort, "high")
        XCTAssertEqual(try stored(home).records, .keep)
        XCTAssertEqual(try stored(home).sandbox, .workspaceWriteNetwork)
        chosen.effort = "low"; chosen.save(to: defaults)
        XCTAssertFalse(model.applyCodexDelegationSwitch(home: home), "A changed choice is no switch change")
        XCTAssertEqual(try stored(home).effort, "low", "but the runner reads it at once")

        for override in ["", nil] as [String?] {
            defaults.set(override, forKey: "codexHome")
            model.applyCodexDelegationSwitch(home: home)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            XCTAssertNil(json["codexHome"], "A shell-launched runner inherits its own CODEX_HOME")
        }

        ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(exists(config), "Turning the Claude module off turns the switch off")
    }

    func testLocalSetupInstallsTheSkillWhileOnAndRemovesItWhenOff() async throws {
        let fixture = try fixture(codex: .enabled), model = fixture.model, home = fixture.home
        var chosen = CodexDelegationPreferences(); chosen.enabled = true; chosen.save(to: fixture.defaults)
        model.retryClaudeLocalSetup()
        try await TestWait.until { model.claudeLocalSetup == .ready && self.exists(ClaudeCodexDelegation.skillURL(home: home)) }
        XCTAssertTrue(exists(ClaudeCodexDelegation.configURL(home: home)), "Setup creates Pacer's folder; the same pass writes the switch")
        XCTAssertTrue(exists(ClaudeCodexDelegation.runnerURL(home: home)))
        let skill = try String(contentsOf: ClaudeCodexDelegation.skillURL(home: home), encoding: .utf8)
        let command = try XCTUnwrap(stored(home).command)
        XCTAssertFalse(command.contains("\""), "A path without spaces needs no quotes")
        let allowed = skill.split(separator: "\n").first { $0.hasPrefix("allowed-tools:") }.map(String.init)
        XCTAssertEqual(allowed, "allowed-tools: Bash(" + command + ":*)", "Claude runs the Mac's runner command without asking")

        for provider in [AgentProvider.codex, .claude] {
            var modules = ProviderModules.load(from: fixture.defaults)
            modules.setMode(.disabled, for: provider); modules.save(to: fixture.defaults)
            model.applySettings(sourceChanged: false)
            XCTAssertFalse(exists(ClaudeCodexDelegation.configURL(home: home)))
            try await TestWait.until { !self.exists(ClaudeCodexDelegation.skillURL(home: home)) }
            XCTAssertTrue(CodexDelegationPreferences(defaults: fixture.defaults).enabled)
            modules.setMode(.enabled, for: provider); modules.save(to: fixture.defaults)
            model.applySettings(sourceChanged: false)
            try await TestWait.until { model.claudeLocalSetup == .ready && self.exists(ClaudeCodexDelegation.skillURL(home: home)) }
            XCTAssertTrue(exists(ClaudeCodexDelegation.configURL(home: home)))
        }

        chosen.enabled = false; chosen.save(to: fixture.defaults)
        model.applyCodexDelegationPreferences()
        XCTAssertFalse(exists(ClaudeCodexDelegation.configURL(home: home)), "Turning it off removes the switch at once")
        try await TestWait.until { !self.exists(ClaudeCodexDelegation.skillURL(home: home)) }
        XCTAssertFalse(exists(ClaudeCodexDelegation.skillURL(home: home)), "and the skill with the next setup")
    }

    func testMacRecognizesAReapedRunnerPID() throws {
        XCTAssertFalse(ProcessOwnership.hasExited(Int(ProcessInfo.processInfo.processIdentifier)))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue(ProcessOwnership.hasExited(Int(process.processIdentifier)))
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
    }
}
