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
}
