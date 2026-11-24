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
        XCTAssertEqual(state.presentation(at: now).header(symbol: \.rawValue).tasks.map(\.helpers), [1], "and the Claude task it works for")
        XCTAssertEqual(state.presentation(at: now).header(symbol: \.rawValue).activeCount, 1, "Claude and its run are one task")

        // Codex's embedded-app preference does not hide a run whose Claude task shows.
        state.reconcile(at: now, retention: 300, visibility: ActivityVisibilityOptions(embeddedProviders: [.claude, .deepseek]))
        XCTAssertEqual(state.presentation(at: now).rows.first?.delegatedCount, 1)

        // Count only: no rows, the number stays.
        let counted = state.presentation(at: now, options: .init(showsDelegationRows: false)).rows
        XCTAssertEqual(counted.first?.delegatedCount, 1)
        XCTAssertEqual(counted.first?.delegations.count, 0)

        // A sub-thread the run spawned belongs to it, not to Claude's subagents.
        // The ledger names it only once the run ends; until then it finds the run
        // through its parent. The run keeps one line, its own thread's.
        state.localActivities = [codex, run(2, parent: 1)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        rows = state.presentation(at: now).rows
        XCTAssertEqual(rows.map(\.activity.id), [claude.id])
        XCTAssertEqual(rows[0].subagents, 0)
        XCTAssertEqual(rows[0].delegatedCount, 1)
        XCTAssertEqual(rows[0].delegations.map(\.activity.threadID), [thread(1)])
        state.codexDelegations = [codex.id: link(to: claude), run(2).id: link(to: claude)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(state.presentation(at: now).rows.first?.delegations.map(\.activity.threadID), [thread(1)])
    }

    /// `codex exec review` works in a `review` sub-thread, and Codex's hook names
    /// the run's thread with that sub-thread's rollout. Until the run ends the
    /// ledger knows only the run's thread. The run still shows, once, under Claude.
    func testAReviewRunShowsThroughItsReviewSubThread() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-delegation-review-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(), start = now.addingTimeInterval(-60)
        let folder = home.appendingPathComponent("sessions/2026/11/24", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func entry(_ type: String, _ payload: [String: Any]) -> [String: Any] {
            ["type": type, "timestamp": ISO8601DateFormatter().string(from: start), "payload": payload]
        }
        func record(_ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: entry(type, payload)) + Data([10])
        }
        func meta(_ id: Int, review: Bool) -> [String: Any] {
            var value: [String: Any] = ["id": thread(id), "originator": ClaudeCodexDelegation.originator, "cwd": "/fixture",
                                        "source": "exec", "thread_source": "user"]
            if review {
                value["source"] = ["subagent": "review"]; value["thread_source"] = "subagent"
                value["parent_thread_id"] = thread(1); value["session_id"] = thread(1)
            }
            return value
        }
        /// Codex's record of an accepted `report_progress` call in a thread's turn.
        func report(_ id: Int, _ percent: Int) -> [String: Any] {
            ["type": "item_completed", "thread_id": thread(id), "turn_id": "t1", "item": [
                "type": "McpToolCall", "id": "call-\(id)", "server": "pacer_progress", "tool": "report_progress",
                "arguments": ["percent": percent], "status": "completed",
                "result": ["isError": false, "content": [["type": "text", "text": "pacer-progress:accepted"]]]]]
        }
        for (id, review) in [(1, false), (2, true)] {
            try (record("session_meta", meta(id, review: review)) + record("event_msg", ["type": "task_started", "turn_id": "t1"])
                + record("event_msg", report(id, 40)))
                .write(to: folder.appendingPathComponent("rollout-2026-11-24T09-33-00-\(thread(id)).jsonl"))
        }
        try CodexHookFixture.announce([folder.appendingPathComponent("rollout-2026-11-24T09-33-00-\(thread(2)).jsonl")], home: home,
                                      turn: "t1", thread: thread(1), at: start)
        let read = await LocalActivityReader().read(home: home, now: now)
        let review = try XCTUnwrap(read.activities.first { $0.threadID == thread(2) }, "The review sub-thread is followed")
        XCTAssertTrue(review.isCodexReviewRun)
        XCTAssertFalse(review.isInternalReview, "A delegated review's sub-thread is the run, not Codex's own review")
        XCTAssertEqual(review.currentProgress?.percent, 40, "The reviewer's estimate is the run's")

        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [claude]))
        state.localActivities = read.activities
        state.codexDelegations = [AgentProvider.codex.activityID(sessionID: thread(1)): link(to: claude)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        var rows = state.presentation(at: now, options: .init(progressRingProviders: [.codex])).rows
        XCTAssertEqual(rows.map(\.activity.id), [claude.id], "The review is no task of its own")
        XCTAssertEqual(rows[0].delegations.map(\.title), ["Review login changes"])
        XCTAssertEqual(rows[0].delegations.first?.phase, .running)
        XCTAssertEqual(rows[0].delegations.first?.canStopDelegation, true)
        XCTAssertEqual(rows[0].delegations.first?.progressRing?.state, .reported, "The run's line draws the reviewer's estimate")
        XCTAssertEqual(rows[0].delegations.first?.progressRing?.percent, 40)

        // Any other sub-thread's estimate stays its own, in a run or not.
        var spawned = SessionActivity(id: AgentProvider.codex.activityID(sessionID: thread(4)))
        var spawnedMeta = meta(4, review: false); spawnedMeta["parent_thread_id"] = thread(1)
        for value in [entry("session_meta", spawnedMeta), entry("event_msg", ["type": "task_started", "turn_id": "t1"]),
                      entry("event_msg", report(4, 60))] { spawned.consume(value) }
        XCTAssertEqual(spawned.phase, .running)
        XCTAssertNil(spawned.currentProgress)
        // Stop names the row it shows, the review sub-thread, before the ledger lists that sub-thread.
        let shown = try XCTUnwrap(rows[0].delegations.first?.activity.id)
        XCTAssertNil(state.codexDelegations[shown])
        XCTAssertEqual(state.codexDelegation(forActivityID: shown)?.parentID, claude.id, "Stop finds a running review run by its row")

        // Should the run's own thread show too, the review sub-thread still stands for the run.
        state.localActivities = read.activities + [run(1)]
        state.reconcile(at: now, retention: 300, visibility: visible)
        rows = state.presentation(at: now).rows
        XCTAssertEqual(rows.first?.delegations.map(\.activity.threadID), [thread(2)])

        // A review sub-thread the user's own Codex starts stays Codex's internal work.
        var own = SessionActivity(id: AgentProvider.codex.activityID(sessionID: thread(3)))
        var payload = meta(3, review: true); payload["originator"] = "codex-tui"
        own.consume(["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: start), "payload": payload])
        XCTAssertTrue(own.isInternalReview)
        XCTAssertFalse(own.isCodexReviewRun)
    }

    func testLedgerEndingFinishesTheStillRunningActivity() throws {
        let owner = DemoScenario.claudeTask(stage: .completed, at: now)
        var worker = run(1)
        worker.reportProgress(40, at: now.addingTimeInterval(-3), turnID: "first")
        let cases: [(ClaudeCodexDelegation.Status, ActivityPhase, TaskSymbol, TaskProgressRing.Mode)] = [
            (.ok, .completed, .completed, .done), (.stopped, .interrupted, .interrupted, .interrupted),
            (.timedOut, .interrupted, .interrupted, .interrupted), (.failed, .interrupted, .failed, .failed)
        ]
        for (status, phase, symbol, ring) in cases {
            var state = ActivityApplicationState()
            state.replaceHarness(.claude, with: .init(activities: [owner]))
            state.localActivities = [worker]
            state.codexDelegations[worker.id] = link(to: owner)
            state.reconcile(at: now, retention: 300, visibility: visible)
            XCTAssertEqual(state.taskGroups().first?.isRunning, true)

            var ending = link(to: owner, status: status)
            ending.ended = now.addingTimeInterval(-1)
            state.codexDelegations[worker.id] = ending
            state.reconcile(at: now, retention: 300, visibility: visible)
            let later = now.addingTimeInterval(65)
            let view = state.presentation(at: later, options: .init(progressRingProviders: [.codex]))
            let row = try XCTUnwrap(view.rows.first?.delegations.first)
            XCTAssertEqual(row.phase, phase); XCTAssertEqual(row.symbol, symbol)
            XCTAssertEqual(row.activity.phaseChangedAt, ending.ended)
            XCTAssertEqual(row.turnTime, CompactDuration.text(4))
            XCTAssertEqual(row.progressRing?.mode, ring)
            XCTAssertFalse(row.canStopDelegation)
            XCTAssertEqual(view.groups.first?.isRunning, false)
            XCTAssertEqual(view.header(symbol: \.rawValue).delegatedRunning, 0)
            XCTAssertEqual(view.header(symbol: \.rawValue).activeCount, 0)

            state.replaceHarness(.claude, with: .init(activities: [DemoScenario.claudeTask(stage: .thinking, at: later)]))
            state.reconcile(at: later, retention: 300, visibility: visible)
            XCTAssertEqual(state.presentation(at: later).header(symbol: \.rawValue).tasks.map(\.helpers), [0])
        }
    }

    func testRunningLedgerEntryWhoseRunnerExitedShowsStopped() throws {
        let owner = DemoScenario.claudeTask(stage: .thinking, at: now), worker = run(1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let meta = directory.appendingPathComponent("meta.json"), events = directory.appendingPathComponent("events.jsonl")
        let lastEvent = now.addingTimeInterval(-1), lastMeta = now.addingTimeInterval(-4)
        func entry(pid: Int32?) throws -> ClaudeCodexDelegation.Run {
            var json: [String: Any] = ["created": now.addingTimeInterval(-10).timeIntervalSince1970,
                                       "thread": thread(1), "status": "running"]
            if let pid { json["runner"] = ["pid": pid] }
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: meta)
            try FileManager.default.setAttributes([.modificationDate: lastMeta], ofItemAtPath: meta.path)
            return try XCTUnwrap(ClaudeCodexDelegation.run(data, session: try XCTUnwrap(owner.threadID), directory: directory,
                runnerExited: { $0 == 42 }))
        }
        XCTAssertEqual(try entry(pid: nil).status, .running)
        XCTAssertEqual(try entry(pid: 41).status, .running)
        XCTAssertEqual(try entry(pid: 42).ended, lastMeta)
        try Data().write(to: events)
        try FileManager.default.setAttributes([.modificationDate: lastEvent], ofItemAtPath: events.path)
        let stopped = try entry(pid: 42)
        XCTAssertEqual(stopped.ended, lastEvent)
        XCTAssertEqual(stopped.status, .stopped)
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [owner]))
        state.localActivities = [worker]; state.codexDelegations = ClaudeCodexDelegation.links([stopped])
        state.reconcile(at: now, retention: 300, visibility: visible)
        let row = try XCTUnwrap(state.presentation(at: now).rows.first?.delegations.first)
        XCTAssertEqual(row.phase, .interrupted)
        XCTAssertEqual(row.activity.phaseChangedAt, lastEvent)
        let later = state.presentation(at: now.addingTimeInterval(120)).rows.first?.delegations.first
        XCTAssertEqual(later?.turnTime, row.turnTime)
        XCTAssertEqual(later?.delegationDetail, row.delegationDetail, "VoiceOver also keeps the elapsed time at the ending")
        XCTAssertFalse(row.canStopDelegation)

        // The next turn arrives while the old stopped entry is still cached.
        var resumed = worker
        resumed.consumeLive(["method": "turn/started", "threadId": thread(1), "turnId": "second", "at": now.timeIntervalSince1970])
        state.localActivities = [resumed]
        state.reconcile(at: now, retention: 300, visibility: visible)
        let next = try XCTUnwrap(state.presentation(at: now).rows.first?.delegations.first)
        XCTAssertEqual(next.phase, .running)
        XCTAssertFalse(next.status.contains(L10n.text("delegation.status.stopped")))
        state.codexDelegations[worker.id] = link(to: owner)
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(state.presentation(at: now).rows.first?.delegations.first?.canStopDelegation, true)
    }

    func testPruningTheOwnerDoesNotMakeItsRetainedRunAStandaloneTask() throws {
        let owner = DemoScenario.claudeTask(stage: .completed, at: now.addingTimeInterval(-6))
        let worker = run(1, ended: true)
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [owner]))
        state.localActivities = [worker]; state.codexDelegations[worker.id] = link(to: owner, status: .ok)
        state.reconcile(at: now, retention: 10, visibility: visible)
        XCTAssertEqual(state.presentation(at: now).rows.first?.delegations.map(\.activity.id), [worker.id])
        let later = now.addingTimeInterval(5)
        state.prune(at: later, retention: 10)
        XCTAssertFalse(state.inbox.activities.contains { $0.id == owner.id })
        XCTAssertTrue(state.inbox.activities.contains { $0.id == worker.id })
        state.replacePendingRequests(for: .codex, with: [.init(id: "input", threadID: thread(1), sourceHostID: nil,
            sourceName: nil, kind: .input, detectedAt: now)])
        let view = state.presentation(at: later)
        XCTAssertTrue(view.groups.isEmpty); XCTAssertTrue(view.rows.isEmpty)
        XCTAssertNil(view.header(symbol: \.rawValue).attention)
    }

    func testSynthesizedSubagentStaysWithItsDelegation() throws {
        let owner = DemoScenario.claudeTask(stage: .completed, at: now)
        var worker = run(2)
        worker.consumeLive(["method": "subagents/updated", "turnId": "first", "threadId": thread(2),
                            "at": now.timeIntervalSince1970, "states": [thread(1): "running"]])
        var state = ActivityApplicationState()
        state.replaceHarness(.claude, with: .init(activities: [owner]))
        state.localActivities = [worker]; state.codexDelegations[worker.id] = link(to: owner)
        state.reconcile(at: now, retention: 300, visibility: visible)
        let group = try XCTUnwrap(state.taskGroups().first)
        XCTAssertEqual(group.members.first { $0.threadID == thread(1) }?.codexDelegation, link(to: owner))
        XCTAssertEqual(group.runningSubagentCount, 0)
        XCTAssertEqual(group.delegations.map(\.id), [worker.id])
        XCTAssertEqual(state.presentation(at: now).header(symbol: \.rawValue).delegatedRunning, 1)

        var ending = link(to: owner, status: .stopped); ending.ended = now
        state.codexDelegations[worker.id] = ending
        state.reconcile(at: now, retention: 300, visibility: visible)
        XCTAssertEqual(state.taskGroups().first?.isRunning, false, "A parent's running hint cannot outlive its run")
        XCTAssertEqual(state.taskGroups().first?.delegations.map(\.id), [worker.id])
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
        let runs = ClaudeCodexDelegation.runs(home: home, runnerExited: { _ in XCTFail("No runner PID in these entries"); return false })
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

    func testWindowsAdmissionLockTimeoutAsksForRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try XCTUnwrap(ClaudeCodexDelegation.runnerScript()).write(to: root.appendingPathComponent("runner.py"))
        let script = """
        import os, sys
        from types import SimpleNamespace
        sys.path.insert(0, os.getcwd())
        import runner
        def timeout(fd, mode, size):
            raise OSError("lock timeout")
        sys.modules['msvcrt'] = SimpleNamespace(locking=timeout, LK_LOCK=1)
        runner.WINDOWS = True
        with runner.admission_lock():
            raise AssertionError("admitted despite lock timeout")
        """
        let process = Process(), errors = Pipe()
        process.arguments = ["-S", "-c", script]
        process.currentDirectoryURL = root; process.standardError = errors
        let fixture = try PythonFixture.prepare(process)
        defer { fixture.remove() }
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 4, message)
        XCTAssertTrue(message.contains("Try again"), message)
    }

    func testRunnerAdmissionReviewAndWorktreeLifecycle() throws {
        #if os(Windows)
        throw XCTSkip("This integration fixture uses a POSIX shell executable and sends SIGTERM to the runner.")
        #else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try XCTUnwrap(ClaudeCodexDelegation.runnerScript()).write(to: root.appendingPathComponent("runner.py"))
        let checks = #"""
        import json, os, signal, subprocess, sys, time
        from pathlib import Path
        import ntpath
        from unittest.mock import patch
        from contextlib import redirect_stdout
        from io import StringIO
        os.environ.update(CLAUDE_PID='', CLAUDE_CODE_SESSION_ID='fixture')
        sys.path.insert(0, os.getcwd())
        import runner as r
        with patch.object(os, 'path', ntpath):
            assert r.change_path('D:/output.txt', 'C:/repo') == 'D:/output.txt'

        root = Path.cwd()
        repo = root / 'repo'
        sub = repo / 'sub'
        sub.mkdir(parents=True)
        def git(*args, cwd=repo):
            return subprocess.check_output(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', *args], cwd=cwd).decode().strip()
        git('init', '-q')
        (repo / 'base').write_text('base')
        git('add', '.')
        git('commit', '-qm', 'base')
        thread = '12345678-1234-1234-1234-123456789abc'
        fake = root / 'fake-codex'
        fake.write_text('''#!/bin/sh
        if [ "$1" = delete ]; then echo delete >> "$TRACE"; exit 0; fi
        pwd > "$TRACE.cwd"
        echo "$CODEX_HOME" > "$TRACE.home"
        cat > "$TRACE"
        echo '{"type":"thread.started","thread_id":"12345678-1234-1234-1234-123456789abc"}'
        if [ -n "$ADD_FILE" ]; then
            echo "committed $ADD_FILE" > "$TEST_TREE/$ADD_FILE"
            git -C "$TEST_TREE" add -- "$ADD_FILE" || exit 1
            git -C "$TEST_TREE" -c user.name=Test -c user.email=test@example.invalid commit -qm change || exit 1
        fi
        if [ "$SLOW" = yes ]; then sleep 30; fi
        ''')
        fake.chmod(0o755)
        trace = root / 'trace'
        env = dict(os.environ, CODEX_BIN=str(fake), TRACE=str(trace), CLAUDE_PID='', CLAUDE_CODE_SESSION_ID=r.SESSION)
        command = [sys.executable, '-S', str(root / 'runner.py')]
        def call(*args, code=0):
            result = subprocess.run(command + list(args), cwd=repo, env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == code, (args, result.stdout, result.stderr)
            return result.stdout
        settings = dict(command='python3 -S "(test)/runner.py"', codexHome=str(root / 'custom'), sandbox='workspace-write')
        def configure(**changes):
            r.CONFIG.write_text(json.dumps(dict(settings, **changes)))
        configure()
        for scope, text in [(['--base','main'], 'base branch main'), (['--commit','abc'], 'commit abc'), (['--uncommitted'], 'untracked')]:
            args = ['review', *scope]
            if scope[0] == '--commit':
                args += ['--title','Storage changes']
            native = json.loads(call(*args, '--dry-run'))['command']
            assert scope[0] in native
            if '--title' in args: assert native[native.index('--title')+1] == 'Storage changes'
            configure(instructions='standing')
            line = json.loads(call(*args, '--dry-run'))['command']
            assert scope[0] not in line and line[-1] == '-' and 'sandbox_mode="read-only"' in line
            assert '--title' not in line
            output = call(*args)
            if '--title' in args: assert 'Storage changes' in trace.read_text()
            assert text in trace.read_text() and 'standing' in trace.read_text()
            assert settings['command'] + ' resume' in output
            configure()
        call('review','--uncommitted','--worktree',code=2)
        call('resume',thread,'--worktree',code=2)
        args = json.loads(call('-C','sub','--dry-run','brief'))['command']
        assert 'sandbox_workspace_write.network_access=false' in args
        call('-C','sub','brief')
        assert Path(str(trace)+'.cwd').read_text().strip() == str(sub)
        assert Path(str(trace)+'.home').read_text().strip() == settings['codexHome']
        # Start two writers together. The admitted child waits for a signal.
        for limit, message in [(1,'most Pacer allows'), (3,'already changing')]:
            configure(maxConcurrent=limit)
            workers = [subprocess.Popen(command + ['brief'], cwd=repo, env=dict(env,SLOW='yes'), stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
            try:
                for _ in range(200):
                    if any(p.poll() is not None for p in workers): break
                    time.sleep(.025)
                rejected, admitted = sorted(workers,key=lambda p:p.poll() is None)
                assert rejected.returncode == 4 and message.encode() in rejected.stderr.read()
                admitted.send_signal(signal.SIGTERM)
                assert admitted.wait(timeout=10) == 130
                last = r.load_runs()[-1]
                assert last['status'] == 'stopped' and last['stoppedBy'] == 'claude' and last['ended']
            finally:
                for p in workers:
                    if p.poll() is None: p.terminate()
                    p.wait(timeout=10)
        # A rollout inside one of two registered worktrees identifies the right one.
        tree = root / 'chosen'
        git('worktree','add','--detach','-q',str(root / 'other'))
        git('worktree','add','--detach','-q',str(tree))
        home = Path(settings['codexHome'])
        rollouts = home / 'sessions' / time.strftime('%Y/%m/%d')
        rollouts.mkdir(parents=True)
        (rollouts / (thread+'.jsonl')).write_text(json.dumps(dict(type='turn_context',payload=dict(cwd=str(tree)))))
        env.update(TEST_TREE=str(tree),ADD_FILE='outside')
        output = call('--worktree','-C','sub','brief')
        del env['ADD_FILE']
        assert 'changed files (1): A outside' in output
        latest = r.find_run(thread)
        assert latest['worktree'] == str(tree) and latest['worktreeBase'] == git('rev-parse','HEAD')
        assert latest['changedFiles'] == latest['worktreeChanges'] == 1
        assert r.worktree_changes(latest) == ['A outside']
        call('apply',thread)
        assert (repo / 'outside').read_text().strip() == 'committed outside'
        applied = r.find_run(thread)['appliedTree']
        assert applied == git('rev-parse','HEAD^{tree}',cwd=tree)
        active = subprocess.Popen(command + ['resume',thread,'more'], cwd=repo, env=dict(env,SLOW='yes'), stdout=subprocess.PIPE)
        try:
            for _ in range(200):
                if r.is_running(r.find_run(thread)): break
                time.sleep(.025)
            call('apply',thread,code=2)
            call('resume',thread,'more',code=2)
            call('stop',thread)
            assert active.wait(timeout=10) == 130
        finally:
            if active.poll() is None: active.terminate()
            active.wait(timeout=10)
        # Inspect the very first save of the resume, before Codex starts.
        register = r.save
        first = []
        def capture(meta):
            if not first: first.append((meta.get('worktreeBase'), meta.get('appliedTree')))
            register(meta)
        with patch.dict(os.environ,dict(env,ADD_FILE='second',CODEX_HOME=str(home))), patch.object(r,'save',capture), redirect_stdout(StringIO()) as output:
            assert r.run_job(r.parse(['resume',thread,'more'])) == 0
        assert first == [(latest['worktreeBase'],applied)]
        assert 'changed files (1): A second' in output.getvalue()
        latest = r.find_run(thread)
        assert latest['changedFiles'] == latest['worktreeChanges'] == 1
        assert 'applied 1 file(s)' in call('apply',thread)
        assert (repo / 'second').read_text().strip() == 'committed second'
        assert not r.pending_worktree(r.find_run(thread))
        env['ADD_FILE'] = 'pending'
        call('resume',thread,'save the next patch')
        latest = r.find_run(thread)
        assert r.worktree_changes(latest) == ['A pending']
        assert latest['worktreeBase'] == git('rev-parse','HEAD')
        configure(records='timed',recordsHours=2)
        for entry in r.load_runs()[:-1]:
            entry['ended'] = time.time()-9000
            r.save(entry)
        r.clean_session(r.SESSION,[str(fake)],'alive')
        assert tree.exists() and len(r.load_runs()) > 1
        # Disable delegation with an outstanding deletion and an unavailable patch directory.
        r.CONFIG.unlink()
        r.PENDING.write_text(thread)
        r.PATCHES.touch()
        call('turn-end','--session',r.SESSION)
        call('sweep')
        assert tree.exists() and r.find_run(thread) and 'delete' not in trace.read_text()
        r.PATCHES.unlink()
        first = r.save_patch(latest)
        first.write_text('previous patch')
        configure(records='timed',recordsHours=2)
        call('sweep')
        assert not tree.exists() and r.find_run(thread), 'gone session exports the worktree before timed records expire'
        assert 'delete' not in trace.read_text()
        assert first.read_text() == 'previous patch'
        backups = [p.read_text() for p in r.PATCHES.glob('*.patch') if p != first]
        assert len(backups) == 1 and 'committed pending' in backups[0] and 'committed second' not in backups[0]
        r.CONFIG.unlink()
        call('sweep')
        assert not r.load_runs() and 'delete' not in trace.read_text()
        """#
        let process = Process()
        process.arguments = ["-S", "-c", checks]
        process.currentDirectoryURL = root
        let fixture = try PythonFixture.prepare(process)
        defer { fixture.remove() }
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        #endif
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
            XCTAssertTrue(skill.contains("-f - <<'EOF'"), "The brief goes on standard input, never into a file in the user's project")
            XCTAssertTrue(skill.unicodeScalars.allSatisfy(\.isASCII), "The skill is English only, to keep the user's tokens down")
            let description = skill.split(separator: "\n").first { $0.hasPrefix("description: ") }.map(String.init) ?? ""
            XCTAssertTrue(description.hasPrefix("description: Hands ") && description.count <= 400,
                          "A short third-person description, well under the 1,024-character limit, loaded in every session")
            XCTAssertTrue(description.contains("only when the user explicitly asks"), "Claude starts Codex only when the user asks")
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
