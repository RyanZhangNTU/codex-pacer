@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

final class EnginePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testActiveChildrenKeepOneRunningRowWithoutAnUnreadParentEnding() throws {
        var activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        activities[0].applyRuntime(["method": "turn/completed", "threadId": activities[0].threadID!,
            "turnId": "demo-turn", "status": "completed", "at": now.timeIntervalSince1970])
        XCTAssertEqual(activities[0].phase, .completed)
        var inbox = CompletionInbox()
        inbox.observe(activities, at: now, retention: 1800)
        let presentation = EnginePresentation(activities: activities, requests: [], inbox: inbox, hideProjects: false, at: now)
        let row = try XCTUnwrap(presentation.rows.first)
        XCTAssertEqual(presentation.rows.count, 1)
        XCTAssertEqual(row.phase, "running")
        XCTAssertEqual(row.symbol, "sparkle")
        XCTAssertEqual(row.subagents, 3)
        XCTAssertFalse(row.unread)
        XCTAssertEqual(presentation.header.activeCount, 1)
        XCTAssertEqual(presentation.header.orbit, ["codex": 1])
        XCTAssertNil(presentation.header.ending)
        let childrenRate = activities.dropFirst().compactMap { $0.displayedOutputEstimate(at: now)?.value }.reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(row.tokensPerSecond), childrenRate, accuracy: 1e-9)
    }

    func testChildApprovalBelongsToItsFamilyButAnotherHostRemainsSeparate() throws {
        let activities = DemoScenario.subagentTasks(stage: .tool, at: now)
        let session = try XCTUnwrap(activities[1].threadID)
        func request(host: String?) -> PendingAttentionRequest {
            .init(id: host ?? "local", threadID: session, sourceHostID: host, sourceName: host,
                  kind: .approval, detectedAt: now)
        }
        let local = EnginePresentation(activities: activities, requests: [request(host: nil)], inbox: CompletionInbox(), hideProjects: false, at: now)
        XCTAssertEqual(local.rows.count, 1)
        XCTAssertEqual(local.rows[0].attention, "approval")
        XCTAssertEqual(local.rows[0].symbol, "hand.raised")
        let remote = EnginePresentation(activities: activities, requests: [request(host: "remote-control:other")],
            inbox: CompletionInbox(), hideProjects: false, at: now)
        XCTAssertEqual(remote.rows.count, 2)
        XCTAssertNil(remote.rows.first { $0.id == activities[0].id }?.attention)
        XCTAssertEqual(remote.rows.first?.attention, "approval")
    }

    func testReadEndingsDimAndTaskPagesKeepTheirCapacity() throws {
        let tasks = DemoScenario.tasks(stage: .completed, at: now)
            + [DemoScenario.claudeTask(stage: .completed, at: now), DemoScenario.deepseekTask(stage: .completed, at: now)]
        var inbox = CompletionInbox()
        inbox.observe(tasks, at: now, retention: 1800)
        let unread = EnginePresentation(activities: tasks, requests: [], inbox: inbox, hideProjects: false, at: now)
        XCTAssertEqual(unread.rowCapacity, 3)
        XCTAssertEqual(unread.pageCount, 2)
        let ended = try XCTUnwrap(tasks.first { $0.phase == .completed })
        XCTAssertTrue(inbox.dismiss(ended))
        let read = EnginePresentation(activities: tasks, requests: [], inbox: inbox, hideProjects: false, at: now)
        let row = try XCTUnwrap(read.rows.first { $0.id == ended.canonicalized().id })
        XCTAssertFalse(row.unread)
        XCTAssertTrue(row.dimmed)
        XCTAssertNotNil(row.turnTime)
        XCTAssertEqual(read.rowCapacity, unread.rowCapacity)
        XCTAssertEqual(read.pageCount, unread.pageCount)
    }

    func testPresentationHidesCloudProjectNamesBeforeEncoding() throws {
        let cloud = DemoScenario.claudeCloud(stage: .tool, at: now)
        let visible = EnginePresentation(activities: cloud.activities, requests: cloud.attention,
            inbox: CompletionInbox(), hideProjects: false, at: now)
        let hidden = EnginePresentation(activities: cloud.activities, requests: cloud.attention,
            inbox: CompletionInbox(), hideProjects: true, at: now)
        XCTAssertTrue(hidden.rows.allSatisfy { $0.title == L10n.text("activity.hidden_name") })
        XCTAssertTrue(hidden.rows.allSatisfy { $0.source == L10n.text("connections.kind.claude_cloud") })
        let encoded = String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self)
        for source in Set(visible.rows.compactMap(\.source)) { XCTAssertFalse(encoded.contains(source)) }
    }

    func testSyntheticWalletAtMidnightHasNoFutureHistoryInterval() {
        let midnight = Calendar.current.startOfDay(for: now)
        let wallet = EngineWallet.demo(at: midnight)
        XCTAssertEqual(wallet.balance, 86.4)
        XCTAssertEqual(wallet.hourly.count, 24)
        XCTAssertEqual(wallet.angle, 0)
        XCTAssertTrue(wallet.today.isFinite)
    }

    func testWireKeepsEndingProviderAndMacOrderForAnEndedParentWithRunningChildren() throws {
        var activities = DemoScenario.subagentTasks(stage: .thinking, at: now)
        activities[0].consumeLive(["method": "turn/completed", "threadId": activities[0].threadID!, "turnId": "demo-turn",
                                  "status": "completed", "at": now.timeIntervalSince1970])
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        let ended = DemoScenario.deepseekTask(stage: .completed, at: now)
        activities += [claude, ended]
        var inbox = CompletionInbox()
        inbox.observe(activities, at: now, retention: 300)
        let presentation = EnginePresentation(activities: activities, requests: [], inbox: inbox, hideProjects: false, at: now)
        XCTAssertEqual(presentation.rows.count, 3)
        XCTAssertEqual(presentation.rows.first?.id, claude.id, "Mac sorts by the primary's observed phase, even when its children keep the family running")
        XCTAssertEqual(presentation.header.endingProvider, "deepseek")
        XCTAssertEqual(presentation.header.activeCount, 2)
        XCTAssertFalse(presentation.header.endingIsCore)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(presentation.rows[0])) as? [String: Any])
        XCTAssertNotNil(fields["phase"])
        XCTAssertNotNil(fields["symbol"])
        XCTAssertNotNil(fields["rateIsFresh"])
        XCTAssertNil(fields["activity"], "Core values do not leak into the version 1 row DTO")
    }

    /// Codex for Claude runs reach the badge as a name and as the Claude task
    /// they work for, never as a count drawn on it.
    func testHeaderNamesCodexForClaudeRunsAndTheTaskTheyWorkFor() throws {
        var value = HeaderActivity(core: .count(2), activeCount: 2, orbit: [.claude: 2],
            tasks: [.init(provider: .claude, fraction: 0.4, helpers: 2), .init(provider: .claude, fraction: nil)])
        value.delegatedRunning = 2
        let header = EngineHeader(value)
        XCTAssertEqual(header.delegatedRunning, 2)
        XCTAssertEqual(header.delegatedText, L10n.text("delegation.badge", 2))
        XCTAssertEqual(header.progressTasks?.map(\.helpers), [2, nil])
        let tasks = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(header.progressTasks)) as? [[String: Any]])
        XCTAssertEqual(tasks[0]["helpers"] as? Int, 2)
        XCTAssertNil(tasks[1]["helpers"], "A task without runs leaves the field out")
        value.delegatedRunning = 0
        XCTAssertNil(EngineHeader(value).delegatedText)
    }

    /// A Claude task's older ended Codex for Claude runs reach the island as
    /// one folded line's text; a task with every run on a line leaves it out.
    func testOlderEndedCodexForClaudeRunsReachTheRowAsOneFoldedLine() throws {
        let claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        func thread(_ number: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", number) }
        func run(_ number: Int, ended: Bool) -> SessionActivity {
            let id = thread(number)
            var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id))
            value.consumeLive(["method": "turn/started", "threadId": id, "turnId": "first", "at": now.addingTimeInterval(-5).timeIntervalSince1970])
            value.setCodexOrigin(.init(embedded: true, ignored: false, delegated: true))
            if ended { value.consumeLive(["method": "turn/completed", "threadId": id, "turnId": "first", "status": "completed", "at": now.timeIntervalSince1970]) }
            return value
        }
        func ledger(_ number: Int, ended: Bool) -> CodexDelegationLink {
            var value = CodexDelegationLink(parentID: claude.id, label: "Run \(number)", mode: .task, write: false, worktree: false,
                status: ended ? .ok : .running, started: now.addingTimeInterval(Double(number) - 60),
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("pacer-run-\(number)"))
            if ended { value.ended = now.addingTimeInterval(-2) }
            return value
        }
        func row(_ count: Int) throws -> EngineTaskRow {
            let runs = (1...count).map { run($0, ended: $0 < count) }
            var state = ActivityApplicationState()
            state.replaceHarness(.claude, with: .init(activities: [claude]))
            state.localActivities = runs
            state.codexDelegations = Dictionary(uniqueKeysWithValues: zip(runs.map(\.id), (1...count).map { ledger($0, ended: $0 < count) }))
            state.reconcile(at: now, retention: 300, visibility: ActivityVisibilityOptions())
            return EngineTaskRow(try XCTUnwrap(state.presentation(at: now).rows.first))
        }
        // Four ended runs and one running: the running one and the two most recent ended ones show.
        let folded = try row(5)
        XCTAssertEqual(folded.delegations?.map(\.title), ["Run 3", "Run 4", "Run 5"])
        XCTAssertEqual(folded.delegationsFolded, L10n.text("delegation.folded", 2))
        XCTAssertEqual(folded.delegatedText, L10n.text("delegation.badge", 1), "The chip counts only the runs still running")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(folded)) as? [String: Any])
        XCTAssertEqual(fields["delegationsFolded"] as? String, L10n.text("delegation.folded", 2))
        let whole = try row(3)
        XCTAssertEqual(whole.delegations?.count, 3)
        let wholeFields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(whole)) as? [String: Any])
        XCTAssertNil(wholeFields["delegationsFolded"], "Nothing folds while every run has its line")
    }
}
