import XCTest
@testable import PacerCore

/// Codex for Claude: the runner's ledger, and how its runs show under the
/// Claude task that started them. Synthetic identifiers and folders only.
final class ClaudeCodexDelegationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let visible = ActivityVisibilityOptions()
    private func thread(_ number: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", number) }

    private func run(_ number: Int, parent: Int? = nil, ended: Bool = false, delegated: Bool = true) -> SessionActivity {
        let id = thread(number)
        var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id))
        value.consumeLive(["method": "turn/started", "threadId": id, "turnId": "first", "at": now.addingTimeInterval(-5).timeIntervalSince1970])
        if let parent { value.updateParent(thread(parent)) }
        value.setCodexOrigin(.init(embedded: true, ignored: false, delegated: delegated))
        if ended { value.consumeLive(["method": "turn/completed", "threadId": id, "turnId": "first", "status": "completed", "at": now.timeIntervalSince1970]) }
        return value
    }
    private func link(to claude: SessionActivity, label: String? = "Review login changes", status: ClaudeCodexDelegation.Status = .running,
                      write: Bool = false) -> CodexDelegationLink {
        .init(parentID: claude.id, label: label, mode: .review, write: write, worktree: false, status: status,
              started: now.addingTimeInterval(-5), directory: FileManager.default.temporaryDirectory.appendingPathComponent("pacer-no-run"))
    }

    func testARunShowsUnderItsClaudeTaskAndNeverOnItsOwn() {
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now), codex = run(1)
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [claude]))
        state.localActivities = [codex]
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertFalse(state.activities.contains { $0.id == codex.id }, "A delegated thread no ledger entry names never shows")
        XCTAssertEqual(state.presentation(at: now).rows.map(\.activity.id), [claude.id])

        state.codexDelegations = [codex.id: link(to: claude)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        var rows = state.presentation(at: now).rows
        XCTAssertEqual(rows.map(\.activity.id), [claude.id], "The run is no task of its own")
        XCTAssertEqual(rows[0].delegatedCount, 1)
        XCTAssertEqual(rows[0].subagents, 0, "Codex runs are not Claude subagents")
        XCTAssertEqual(rows[0].delegations.map(\.title), ["Review login changes"])
        XCTAssertEqual(rows[0].delegations[0].phase, .running)
        XCTAssertTrue(rows[0].delegations[0].canStopDelegation)
        XCTAssertTrue(rows[0].delegations[0].status.hasPrefix(L10n.text("delegation.mode.review") + " · " + L10n.text("delegation.read_only")),
            "A review says so; a plain task leaves its mode out")
        XCTAssertEqual(rows[0].delegations[0].delegation?.parentID, claude.id)
        XCTAssertEqual(state.presentation(at: now).header(symbol: \.rawValue).delegatedRunning, 1, "The badge counts the run working for Claude")
        XCTAssertEqual(state.presentation(at: now).header(symbol: \.rawValue).activeCount, 1, "Claude and its run are one task")

        // Codex's embedded-app preference does not hide a run whose Claude task shows.
        state.reconcile(at: now, retention: 300, visibility: ActivityVisibilityOptions(embeddedProviders: [.claude, .deepseek]))
        XCTAssertEqual(state.presentation(at: now).rows.first?.delegatedCount, 1)

        // Count only: no rows, the number stays.
        let counted = state.presentation(at: now, options: .init(showsDelegationRows: false)).rows
        XCTAssertEqual(counted.first?.delegatedCount, 1)
        XCTAssertEqual(counted.first?.delegations.count, 0)

        // A sub-thread the run spawned belongs to it, not to Claude's subagents.
        state.localActivities = [codex, run(2, parent: 1)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        rows = state.presentation(at: now).rows
        XCTAssertEqual(rows.map(\.activity.id), [claude.id])
        XCTAssertEqual(rows[0].subagents, 0)
        XCTAssertEqual(rows[0].delegatedCount, 1)
    }

    func testRunsLeaveWithTheirLedgerEntryOrTheirClaudeTask() {
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [claude]))
        state.localActivities = [run(1)]
        state.codexDelegations = [run(1).id: link(to: claude)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        state.localActivities = [run(1, ended: true)]
        state.codexDelegations = [run(1).id: link(to: claude, status: .ok)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        let finished = state.presentation(at: now).rows.first?.delegations.first
        XCTAssertEqual(finished?.status.hasSuffix(L10n.text("delegation.status.ok")), true)
        XCTAssertEqual(finished?.canStopDelegation, false)

        // The turn ended and the runner cleaned up: the entry and the thread are gone.
        state.codexDelegations = [:]
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertFalse(state.activities.contains { $0.provider == .codex })
        XCTAssertFalse(state.inbox.activities.contains { $0.provider == .codex }, "A cleaned-up run leaves no ending behind")
        XCTAssertEqual(state.presentation(at: now).rows.first?.delegatedCount, 0)

        // Without its Claude task, a run never stands alone.
        var orphan = ActivityApplicationState()
        orphan.localActivities = [run(3)]
        orphan.codexDelegations = [run(3).id: link(to: claude)]
        orphan.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertTrue(orphan.presentation(at: now).rows.isEmpty)

        // An ordinary Codex task is untouched.
        var plain = ActivityApplicationState()
        plain.localActivities = [run(4, delegated: false)]
        plain.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(plain.presentation(at: now).rows.map(\.activity.id), [run(4).id])
    }

    func testTheLedgerKeepsIdentifiersAndTheLatestRunDescribesAThread() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-delegation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = "00000000-0000-4000-8000-000000000003"
        func write(_ folder: String, _ value: [String: Any], session: String = session) throws {
            let directory = ClaudeCodexDelegation.runsURL(home: home).appendingPathComponent(session).appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("meta.json"))
        }
        try write("1-review", ["created": 1_800_000_000.5, "thread": thread(1), "mode": "review", "label": "  Review\n login   changes ",
                               "status": "ok", "ended": 1_800_000_060.0, "childThreads": [thread(2)], "write": false])
        try write("2-resume", ["created": 1_800_000_100.0, "thread": thread(1), "mode": "resume", "status": "running", "write": true,
                               "worktree": "C:/synthetic/worktree"])
        try write("3-starting", ["created": 1_800_000_200.0, "status": "running"])
        try write("4-broken", ["thread": thread(5)])
        try write("5-elsewhere", ["created": 1_800_000_000.0, "thread": thread(6)], session: "not a session!")
        let runs = ClaudeCodexDelegation.runs(home: home)
        XCTAssertEqual(runs.count, 3, "Entries without a creation time or under an invalid session are skipped")
        XCTAssertEqual(runs[0].label, "Review login changes")
        XCTAssertNil(runs[2].thread, "A run still starting has no thread yet")
        let links = ClaudeCodexDelegation.links(runs)
        let main = try XCTUnwrap(links[AgentProvider.codex.activityID(sessionID: thread(1))])
        XCTAssertEqual(main.mode, .resume); XCTAssertEqual(main.status, .running); XCTAssertTrue(main.write); XCTAssertTrue(main.worktree)
        XCTAssertEqual(main.parentID, AgentProvider.claude.activityID(sessionID: session))
        XCTAssertEqual(links[AgentProvider.codex.activityID(sessionID: thread(2))]?.mode, .review, "Sub-threads keep the run that spawned them")
        XCTAssertNil(links[AgentProvider.codex.activityID(sessionID: thread(6))])
    }

    func testSettingsSwitchQuotaAndRunnerCommand() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-delegation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(ClaudeCodexDelegation.apply(nil, home: home))
        XCTAssertFalse(ClaudeCodexDelegation.apply(.init(), home: home), "Nothing is written before Pacer's hook folder exists")
        XCTAssertFalse(ClaudeCodexDelegation.writeQuota(remainingPercent: 50, home: home), "nor the quota")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        let settings = ClaudeCodexDelegation.Settings(codex: "C:/synthetic/codex.exe", effort: "high", fast: true, records: .timed, recordsHours: 5,
                                                      sandbox: .workspaceWrite, instructions: "  Answer in English.\n ", maxConcurrent: 9, quotaFloor: 15)
        XCTAssertEqual(settings.recordsHours, 24); XCTAssertEqual(settings.maxConcurrent, 3); XCTAssertNil(settings.quotaFloor)
        XCTAssertEqual(settings.instructions, "Answer in English.")
        XCTAssertNil(ClaudeCodexDelegation.Settings(instructions: " \n ").instructions)
        XCTAssertEqual(ClaudeCodexDelegation.Settings(instructions: String(repeating: "a", count: 5000)).instructions?.count, 4000)
        XCTAssertTrue(ClaudeCodexDelegation.apply(settings, home: home))
        XCTAssertTrue(ClaudeCodexDelegation.isOn(home: home))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeCodexDelegation.configURL(home: home))) as? [String: Any]
        XCTAssertEqual(written?["sandbox"] as? String, "workspace-write"); XCTAssertEqual(written?["effort"] as? String, "high")
        XCTAssertEqual(written?["fast"] as? Bool, true); XCTAssertNil(written?["model"])
        XCTAssertEqual(written?["records"] as? String, "timed"); XCTAssertEqual(written?["recordsHours"] as? Int, 24)
        XCTAssertEqual(written?["memory"] as? Bool, false); XCTAssertNil(written?["quotaFloor"])

        // A file from an earlier build still reads; what it no longer knows takes the defaults.
        let earlier = Data(#"{"sandbox":"workspace-write","timeoutMinutes":45,"initiative":"review","maxConcurrent":6,"effort":"low"}"#.utf8)
        let read = try XCTUnwrap(ClaudeCodexDelegation.settings(earlier))
        XCTAssertEqual(read.sandbox, .workspaceWrite); XCTAssertEqual(read.effort, "low"); XCTAssertEqual(read.maxConcurrent, 3)
        XCTAssertEqual(read.trigger, .ask); XCTAssertEqual(read.records, .turn)
        XCTAssertEqual(ClaudeCodexDelegation.settings(Data("{}".utf8)), .init())

        XCTAssertTrue(ClaudeCodexDelegation.writeQuota(remainingPercent: 123, home: home, at: now))
        let quota = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeCodexDelegation.quotaURL(home: home))) as? [String: Any]
        XCTAssertEqual(quota?["remainingPercent"] as? Double, 100)
        XCTAssertEqual(quota?["at"] as? Double, (now.timeIntervalSince1970 * 1000).rounded() / 1000)
        XCTAssertTrue(ClaudeCodexDelegation.writeQuota(remainingPercent: nil, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeCodexDelegation.quotaURL(home: home).path), "No reading removes it")

        XCTAssertTrue(ClaudeCodexDelegation.writeQuota(remainingPercent: 40, home: home, at: now))
        XCTAssertTrue(ClaudeCodexDelegation.apply(nil, home: home))
        XCTAssertFalse(ClaudeCodexDelegation.isOn(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeCodexDelegation.quotaURL(home: home).path), "Turning it off drops the quota reading")

        let plain = ClaudeCodexDelegation.command(python: "C:\\Pacer\\python.exe", home: URL(fileURLWithPath: "/Users/someone/.claude"))
        XCTAssertTrue(plain.hasPrefix("C:/Pacer/python.exe -S "), plain)
        XCTAssertTrue(plain.hasSuffix("/.claude/pacer/codex/runner.py"), plain)
        let spaced = ClaudeCodexDelegation.command(python: "/opt/py thon/python3", home: URL(fileURLWithPath: "/Users/some one/.claude"))
        XCTAssertTrue(spaced.hasPrefix("\"/opt/py thon/python3\" -S \""), spaced)
        let skill = try XCTUnwrap(ClaudeCodexDelegation.skill(command: plain).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertFalse(skill.contains("{{"), "Every placeholder is filled")
        XCTAssertTrue(skill.contains("allowed-tools: Bash(" + plain + ":*)"))
        XCTAssertNotNil(ClaudeCodexDelegation.runnerScript())
    }

    func testRunRowsStaySimpleAndTheirDetailIsKeptForVoiceOver() {
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [claude]))
        var codex = run(1); codex.applyRuntime(["method": "metadata", "threadId": thread(1), "at": now.timeIntervalSince1970, "model": "gpt-6.2-astra", "reasoningEffort": "low"])
        state.localActivities = [codex]
        var link = link(to: claude); link.fast = true
        state.codexDelegations = [codex.id: link]
        state.reconcile(at: now, retention: 300, visibility: visible)
        let child = try? XCTUnwrap(state.presentation(at: now).rows.first?.delegations.first)
        XCTAssertEqual(child?.model, "Astra 6.2")
        let detail = Dictionary(uniqueKeysWithValues: (child?.delegationDetail ?? []).map { ($0.label, $0.value) })
        XCTAssertEqual(detail[L10n.text("delegation.detail.mode")], L10n.text("delegation.mode.review") + " · " + L10n.text("delegation.read_only"))
        XCTAssertTrue(detail[L10n.text("delegation.detail.model")]?.contains(L10n.text("delegation.detail.fast")) == true)
        XCTAssertNil(detail[L10n.text("delegation.detail.result")], "A running run has no result yet")

        var ended = link; ended = CodexDelegationLink(parentID: link.parentID, label: link.label, mode: link.mode, write: true, worktree: false,
            status: .ok, started: link.started, directory: link.directory)
        ended.ended = now; ended.commands = 7; ended.changedFiles = 2; ended.usage = .init(input: 52_311, cached: 40_960, output: 2_210)
        let lines = ActivityTaskRowPresentation.delegationDetail(ended, activity: codex, phase: .completed, model: "Astra 6.2", effort: "Low", at: now)
        let values = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0.value) })
        XCTAssertEqual(values[L10n.text("delegation.detail.result")], L10n.text("delegation.status.ok"))
        XCTAssertEqual(values[L10n.text("delegation.detail.work")], L10n.text("delegation.detail.commands", 7) + " · " + L10n.text("delegation.detail.files", 2))
        XCTAssertTrue(values[L10n.text("delegation.detail.tokens")]?.contains("52K") == true)
        XCTAssertEqual(ClaudeCodexDelegation.compactCount(940), "940")
        XCTAssertEqual(ClaudeCodexDelegation.compactCount(2_210), "2.2K")
        XCTAssertEqual(ClaudeCodexDelegation.compactCount(4_200_000), "4.2M")
    }

    func testTheSkillFollowsTheTriggerAndAsksNothingOfClaudesReply() throws {
        let ask = try XCTUnwrap(ClaudeCodexDelegation.skill(command: "RUNNER").map { String(decoding: $0, as: UTF8.self) })
        let command = try XCTUnwrap(ClaudeCodexDelegation.skill(command: "RUNNER", trigger: .command).map { String(decoding: $0, as: UTF8.self) })
        let header = { (skill: String) in String(skill.components(separatedBy: "\n---\n").first ?? "") }
        XCTAssertFalse(header(ask).contains("disable-model-invocation"), "When asked: Claude may start it when the user asks")
        XCTAssertTrue(header(command).contains("disable-model-invocation: true"), "Command only: just /pacer:codex")
        XCTAssertTrue(command.hasPrefix("---\nname: codex\n"))
        for skill in [ask, command] {
            XCTAssertFalse(skill.contains("{{"), "Every placeholder is filled")
            XCTAssertFalse(skill.contains("Reply in your own words"), "The skill says how to use the tool, not how Claude replies")
            XCTAssertTrue(skill.contains("run_in_background: true"), "Runs go in the background, so Claude is never blocked on Codex")
            XCTAssertFalse(skill.contains("--timeout 9"), "No foreground runs under the Bash tool's limit")
        }
        let settings = ClaudeCodexDelegation.Settings(trigger: .command)
        XCTAssertEqual(ClaudeCodexDelegation.settings(settings.data())?.trigger, .command)
    }

    func testTheExecutorClientIsRecognizedAsDelegated() {
        XCTAssertEqual(CodexSessionOrigin.classify(originator: ClaudeCodexDelegation.originator, cwd: nil)?.delegated, true)
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "codex_exec", cwd: nil)?.delegated, false)
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "Zotero", cwd: nil)?.delegated, false)
    }
}
