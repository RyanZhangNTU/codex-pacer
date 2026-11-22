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

    func testSettingsSwitchSummaryAndRunnerCommand() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-delegation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(ClaudeCodexDelegation.apply(nil, home: home))
        XCTAssertFalse(ClaudeCodexDelegation.apply(.init(), home: home), "Nothing is written before Pacer's hook folder exists")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
        let settings = ClaudeCodexDelegation.Settings(codex: "C:/synthetic/codex.exe", effort: "high", fast: true, sandbox: .workspaceWrite,
                                                      timeoutMinutes: 45, maxConcurrent: 9)
        XCTAssertEqual(settings.timeoutMinutes, 60); XCTAssertEqual(settings.maxConcurrent, 3)
        XCTAssertTrue(ClaudeCodexDelegation.apply(settings, home: home))
        XCTAssertTrue(ClaudeCodexDelegation.isOn(home: home))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeCodexDelegation.configURL(home: home))) as? [String: Any]
        XCTAssertEqual(written?["sandbox"] as? String, "workspace-write"); XCTAssertEqual(written?["effort"] as? String, "high")
        XCTAssertEqual(written?["fast"] as? Bool, true); XCTAssertNil(written?["model"])
        XCTAssertTrue(ClaudeCodexDelegation.apply(nil, home: home))
        XCTAssertFalse(ClaudeCodexDelegation.isOn(home: home))

        let stats = [["at": now.addingTimeInterval(-60).timeIntervalSince1970, "seconds": 90.0, "status": "ok", "input": 40_000, "output": 2_000],
                     ["at": now.addingTimeInterval(-3600).timeIntervalSince1970, "seconds": 30.0, "status": "failed", "input": 1_000, "output": 0],
                     ["at": now.addingTimeInterval(-8 * 86400).timeIntervalSince1970, "seconds": 999.0, "status": "ok", "input": 9, "output": 9]]
        let lines = try stats.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\nnot json\n"
        try FileManager.default.createDirectory(at: ClaudeCodexDelegation.root(home: home), withIntermediateDirectories: true)
        try Data(lines.utf8).write(to: ClaudeCodexDelegation.statsURL(home: home))
        let summary = ClaudeCodexDelegation.summary(home: home, since: now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(summary.runs, 2); XCTAssertEqual(summary.failures, 1); XCTAssertEqual(summary.seconds, 120); XCTAssertEqual(summary.tokens, 43_000)

        let plain = ClaudeCodexDelegation.command(python: "C:\\Pacer\\python.exe", home: URL(fileURLWithPath: "/Users/someone/.claude"))
        XCTAssertTrue(plain.hasPrefix("C:/Pacer/python.exe -S "), plain)
        XCTAssertTrue(plain.hasSuffix("/.claude/pacer/codex/runner.py"), plain)
        let spaced = ClaudeCodexDelegation.command(python: "/opt/py thon/python3", home: URL(fileURLWithPath: "/Users/some one/.claude"))
        XCTAssertTrue(spaced.hasPrefix("\"/opt/py thon/python3\" -S \""), spaced)
        let skill = try XCTUnwrap(ClaudeCodexDelegation.skill(command: plain).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertFalse(skill.contains("{{RUN}}"))
        XCTAssertTrue(skill.contains("allowed-tools: Bash(" + plain + ":*)"))
        XCTAssertNotNil(ClaudeCodexDelegation.runnerScript())
    }

    func testStatisticsCountThePeriodAndKeepNoContent() throws {
        let calendar = Calendar(identifier: .gregorian)
        func row(_ daysAgo: Double, _ status: String, seconds: Double = 60, mode: String = "task", model: String? = "gpt-6.2-sol", label: String? = "Review login",
                 project: String? = "codex-pacer", reason: String? = nil) -> CodexDelegationStatistics.Row {
            .init(at: now.addingTimeInterval(-daysAgo * 86400), seconds: seconds, status: status, mode: mode, model: model, effort: "high", fast: false,
                  reason: reason, label: label, project: project, input: 10_000, cached: 6_000, output: 1_000)
        }
        let rows = [row(0, "ok", seconds: 300, mode: "review"), row(1, "ok"), row(2, "stopped"), row(3, "failed", reason: "login"),
                    row(4, "refused", seconds: 0, reason: "concurrency"), row(10, "ok"), row(40, "ok")]
        let week = CodexDelegationStatistics(rows: rows, days: 7, at: now, calendar: calendar)
        XCTAssertEqual(week.runs, 4, "Refused runs never ran; older rows are outside the week")
        XCTAssertEqual(week.chart.count, 7)
        XCTAssertEqual(week.chart.reduce(0) { $0 + $1.ok + $1.stopped + $1.failed }, 4)
        XCTAssertEqual(week.kpis[1].value, "50%", "Two of four runs finished")
        XCTAssertEqual(week.breakdowns.first?.shares.map(\.count).reduce(0, +), 4)
        XCTAssertTrue(week.breakdowns[1].shares.contains { $0.name == "Sol 6.2" }, "Models read as on the task rows")
        XCTAssertTrue(week.breakdowns.contains { $0.title == L10n.text("collaboration.stats.by_reason") }, "Failures and refusals have reasons")
        XCTAssertEqual(week.recent.count, rows.count)
        XCTAssertEqual(week.recent.first?.title, "Review login")
        XCTAssertEqual(week.recent.first?.project, "codex-pacer")
        let hidden = CodexDelegationStatistics(rows: rows, days: 30, hideProjects: true, at: now, calendar: calendar)
        XCTAssertEqual(hidden.runs, 5)
        XCTAssertNil(hidden.recent.first?.project, "Hide Project Names hides labels and projects")
        XCTAssertEqual(hidden.recent.first?.title, L10n.text("delegation.mode.review"))
        XCTAssertFalse(hidden.breakdowns.contains { $0.title == L10n.text("collaboration.stats.by_project") })

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-delegation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: ClaudeCodexDelegation.root(home: home), withIntermediateDirectories: true)
        try Data((#"{"at":1800000000,"seconds":12.5,"status":"ok","mode":"review","label":"Check it","project":"demo","input":5,"output":2}"# + "\n").utf8)
            .write(to: ClaudeCodexDelegation.statsURL(home: home))
        XCTAssertEqual(CodexDelegationStatistics.rows(home: home).first?.label, "Check it")
        XCTAssertTrue(CodexDelegationStatistics.clearHistory(home: home))
        let cleared = try XCTUnwrap(CodexDelegationStatistics.rows(home: home).first)
        XCTAssertNil(cleared.label); XCTAssertNil(cleared.project); XCTAssertEqual(cleared.seconds, 12.5, "Clearing history keeps the numbers")
    }

    func testRunRowsStaySimpleAndTheHoverCardHoldsTheDetail() {
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

    func testNoticesFollowFailuresLongRunsAndTheFirstFinish() {
        func run(_ status: ClaudeCodexDelegation.Status, minutes: Double = 1, reason: String? = nil, folder: String = "run-1") -> ClaudeCodexDelegation.Run {
            var value = ClaudeCodexDelegation.Run(session: "00000000-0000-4000-8000-000000000003", thread: thread(1), childThreads: [], mode: .task,
                label: "Find the race", write: false, worktree: false, status: status, created: now.addingTimeInterval(-minutes * 60), ended: nil,
                directory: URL(fileURLWithPath: "/synthetic/" + folder))
            value.reason = reason; return value
        }
        var policy = CodexDelegationNoticePolicy()
        XCTAssertTrue(policy.notices([run(.running)], titles: [:], failures: true, longRunMinutes: nil, firstRunFinished: false, at: now).isEmpty,
            "The first look is a baseline")
        let failed = policy.notices([run(.failed, reason: "login")], titles: [:], failures: true, longRunMinutes: nil, firstRunFinished: false, at: now)
        XCTAssertEqual(failed.map(\.title), [L10n.text("delegation.notice.failed")])
        XCTAssertTrue(failed[0].detail.contains(L10n.text("delegation.reason.login")))
        XCTAssertTrue(policy.notices([run(.failed, reason: "login")], titles: [:], failures: true, longRunMinutes: nil, firstRunFinished: false, at: now).isEmpty,
            "A failure is announced once")
        var quiet = CodexDelegationNoticePolicy()
        _ = quiet.notices([run(.running, folder: "a")], titles: [:], failures: false, longRunMinutes: 20, firstRunFinished: false, at: now)
        XCTAssertTrue(quiet.notices([run(.timedOut, folder: "a")], titles: [:], failures: false, longRunMinutes: 20, firstRunFinished: false, at: now).isEmpty,
            "Failure alerts can be off")
        var long = CodexDelegationNoticePolicy()
        _ = long.notices([], titles: [:], failures: true, longRunMinutes: 20, firstRunFinished: false, at: now)
        XCTAssertEqual(long.notices([run(.running, minutes: 25, folder: "b")], titles: [:], failures: true, longRunMinutes: 20, firstRunFinished: false, at: now).count, 1)
        XCTAssertTrue(long.notices([run(.running, minutes: 26, folder: "b")], titles: [:], failures: true, longRunMinutes: 20, firstRunFinished: false, at: now).isEmpty)
        var first = CodexDelegationNoticePolicy()
        _ = first.notices([run(.running, folder: "c")], titles: [:], failures: true, longRunMinutes: nil, firstRunFinished: false, at: now)
        XCTAssertEqual(first.notices([run(.ok, folder: "c")], titles: [:], failures: true, longRunMinutes: nil, firstRunFinished: true, at: now).map(\.title),
            [L10n.text("delegation.notice.first")])
    }

    func testTheSkillFollowsTheChosenInitiative() throws {
        let ask = try XCTUnwrap(ClaudeCodexDelegation.skill(command: "RUNNER").map { String(decoding: $0, as: UTF8.self) })
        let review = try XCTUnwrap(ClaudeCodexDelegation.skill(command: "RUNNER", initiative: .review).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(ask.contains("start a run only when the user asks"))
        XCTAssertTrue(review.contains("RUNNER review --uncommitted"))
        XCTAssertFalse(review.contains("{{"), "Every placeholder is filled")
        let settings = ClaudeCodexDelegation.Settings(initiative: .suggest)
        XCTAssertEqual(ClaudeCodexDelegation.settings(settings.data())?.initiative, .suggest)
        XCTAssertNil(ClaudeCodexDelegation.Settings().initiative, "The default is left out of the file")
    }

    func testTheExecutorClientIsRecognizedAsDelegated() {
        XCTAssertEqual(CodexSessionOrigin.classify(originator: ClaudeCodexDelegation.originator, cwd: nil)?.delegated, true)
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "codex_exec", cwd: nil)?.delegated, false)
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "Zotero", cwd: nil)?.delegated, false)
    }
}
