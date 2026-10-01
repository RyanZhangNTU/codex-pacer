import XCTest
import CoreGraphics
@testable import PacerCore

private let epoch = Date(timeIntervalSince1970: 1_000_000)
private func weekly(_ remaining: Double, at date: Date = epoch, reset: Date = epoch.addingTimeInterval(604800), scope: String? = "account-A") throws -> QuotaSnapshot {
    var snapshot = try QuotaSnapshot.decode(Data("""
    {"rateLimits":{"limitId":"codex","primary":{"usedPercent":\(100 - remaining),"windowDurationMins":10080,"resetsAt":\(reset.timeIntervalSince1970)}}}
    """.utf8), capturedAt: date)
    snapshot.accountScope = scope
    return snapshot
}
private func log(_ kind: String, at date: Date, payload: [String: Any], type: String = "event_msg") -> Data {
    let formatter = ISO8601DateFormatter()
    var body = payload; body["type"] = kind
    return try! JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: date), "type": type, "payload": body])
}

final class CycleTests: XCTestCase {
    func testPaceUsesOriginalRatioAndExpiredWindowIsUnavailable() throws {
        let window = try weekly(50).windows[0]
        XCTAssertEqual(window.pacePercent(at: epoch.addingTimeInterval(302400)), 100)
        XCTAssertEqual(window.pacePercent(at: epoch), 50)
        XCTAssertNil(window.pacePercent(at: epoch.addingTimeInterval(604800)))
        XCTAssertEqual(window.pacePercent(at: epoch.addingTimeInterval(604799)), 1000)
    }
    func testEarlyResetStartsFreshCurveAndPaceWindow() throws {
        var history = QuotaCycleHistory()
        history.record(try weekly(80))
        history.record(try weekly(50, at: epoch.addingTimeInterval(3600)))
        XCTAssertEqual(history.cycles[0].points.count, 2)
        let newStart = epoch.addingTimeInterval(7200)
        let fresh = try weekly(100, at: newStart, reset: newStart.addingTimeInterval(604800))
        history.record(fresh)
        XCTAssertEqual(history.cycles[0].points.count, 1)
        XCTAssertEqual(history.cycles[0].startedAt, newStart)
        XCTAssertEqual(history.cycles[0].points[0].remaining, 100)
        XCTAssertEqual(fresh.windows[0].pacePercent(at: newStart), 100)
    }
    func testSmallTimestampCorrectionPreservesCurveButEarlyResetStillClearsIt() throws {
        var history = QuotaCycleHistory()
        history.record(try weekly(80))
        history.record(try weekly(79, at: epoch.addingTimeInterval(20), reset: epoch.addingTimeInterval(604810)))
        XCTAssertEqual(history.cycles[0].points.count, 2)
        history.record(try weekly(100, at: epoch.addingTimeInterval(30), reset: epoch.addingTimeInterval(604830)))
        XCTAssertEqual(history.cycles[0].points.count, 1)
    }
    func testNormalRolloverAndAccountChangeDiscardPreviousCurve() throws {
        var history = QuotaCycleHistory()
        history.record(try weekly(80))
        let next = epoch.addingTimeInterval(604810)
        history.record(try weekly(98, at: next, reset: next.addingTimeInterval(604800)))
        XCTAssertEqual(history.cycles[0].startedAt, next)
        XCTAssertEqual(history.cycles[0].points.count, 1)
        history.record(try weekly(60, at: next.addingTimeInterval(10), reset: next.addingTimeInterval(604800), scope: "account-B"))
        XCTAssertEqual(history.cycles[0].points.count, 1)
        XCTAssertEqual(history.accountScope, "account-B")
    }
    func testOlderResponseCannotRewindActiveCycle() throws {
        var history = QuotaCycleHistory()
        let newer = try weekly(50, at: epoch.addingTimeInterval(60))
        history.record(newer)
        history.record(try weekly(80))
        XCTAssertEqual(history.cycles[0].points[0].remaining, 50)
        XCTAssertEqual(history.lastCapturedAt, newer.capturedAt)
    }
    func testAnonymousDataIsNotRecordedAndExpiredCurveIsHidden() throws {
        var history = QuotaCycleHistory()
        history.record(try weekly(80, scope: nil))
        XCTAssertTrue(history.cycles.isEmpty)
        let snapshot = try weekly(80)
        history.record(snapshot)
        XCTAssertNil(history.currentCycle(for: snapshot.windows[0], at: epoch.addingTimeInterval(604801)))
    }
    func testCacheRequiresMatchingHomeAndVerifiedAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = QuotaCycleCache(directory: directory)
        let home = URL(fileURLWithPath: "/test-home")
        let snapshot = try weekly(80)
        var history = QuotaCycleHistory(); history.record(snapshot)
        try cache.save(home: home, snapshot: snapshot, history: history)
        XCTAssertNotNil(cache.load(home: home, accountScope: "account-A", now: epoch))
        XCTAssertNil(cache.load(home: home, accountScope: "account-B", now: epoch))
        XCTAssertNil(cache.load(home: URL(fileURLWithPath: "/other-home"), accountScope: "account-A", now: epoch))
        XCTAssertNil(cache.load(home: home, accountScope: "account-A", now: epoch.addingTimeInterval(604801)))
    }
    func testDisplaySamplingKeepsActualEndpoints() throws {
        var history = QuotaCycleHistory()
        for index in 0..<300 { history.record(try weekly(100 - Double(index) / 10, at: epoch.addingTimeInterval(Double(index)))) }
        let cycle = history.cycles[0]
        let points = cycle.displayPoints(limit: 20)
        XCTAssertEqual(points.count, 20)
        XCTAssertEqual(points.first, cycle.points.first)
        XCTAssertEqual(points.last, cycle.points.last)
        XCTAssertEqual(cycle.points.count, 300)
    }
    func testExpiredCycleIsPrunedBeforeAnotherFreshReading() throws {
        var history = QuotaCycleHistory()
        history.record(try weekly(80))
        history.record(try weekly(70, at: epoch.addingTimeInterval(604801)))
        XCTAssertTrue(history.cycles.isEmpty)
    }
}

final class OutputRateTests: XCTestCase {
    func testInsufficientAndStaleSamplesAreUnavailable() {
        var rate = OutputRate()
        rate.observe(totalOutput: 100, at: epoch)
        XCTAssertNil(rate.tokensPerSecond(at: epoch))
        rate.observe(totalOutput: 150, at: epoch.addingTimeInterval(5))
        XCTAssertEqual(rate.tokensPerSecond(at: epoch.addingTimeInterval(6)), 10)
        XCTAssertNil(rate.tokensPerSecond(at: epoch.addingTimeInterval(21)))
    }
    func testCounterRollbackAndIdleGapDoNotCreateFalseRate() {
        var rate = OutputRate()
        rate.observe(totalOutput: 100, at: epoch)
        rate.observe(totalOutput: 120, at: epoch.addingTimeInterval(2))
        rate.observe(totalOutput: 10, at: epoch.addingTimeInterval(3))
        XCTAssertNil(rate.tokensPerSecond(at: epoch.addingTimeInterval(3)))
        rate.observe(totalOutput: 50, at: epoch.addingTimeInterval(5))
        XCTAssertEqual(rate.tokensPerSecond(at: epoch.addingTimeInterval(5)), 20)
        rate.observe(totalOutput: 100, at: epoch.addingTimeInterval(200))
        XCTAssertNil(rate.tokensPerSecond(at: epoch.addingTimeInterval(200)))
    }
    func testNewTurnExcludesIdleTimeAndCompletionClearsRate() {
        var rate = OutputRate()
        rate.observe(totalOutput: 100, at: epoch)
        rate.startTurn(at: epoch.addingTimeInterval(100))
        rate.observe(totalOutput: 120, at: epoch.addingTimeInterval(102))
        XCTAssertEqual(rate.tokensPerSecond(at: epoch.addingTimeInterval(102)), 10)
        rate.finishTurn()
        XCTAssertNil(rate.tokensPerSecond(at: epoch.addingTimeInterval(102)))
    }
    func testInputTokensAreNotCountedAsOutputRate() {
        var activity = SessionActivity(id: "rate")
        activity.consume(log("task_started", at: epoch, payload: ["turn_id": "turn"]))
        for (seconds, output) in [(1.0, 100), (3.0, 120)] {
            activity.consume(log("token_count", at: epoch.addingTimeInterval(seconds), payload: [
                "info": ["total_token_usage": ["output_tokens": output, "input_tokens": 100000, "total_tokens": 100000 + output]]]))
        }
        XCTAssertEqual(activity.tokensPerSecond(at: epoch.addingTimeInterval(3)), 10)
    }
}

final class InteractionTests: XCTestCase {
    func testConversationLinkOnlyAcceptsUUIDWithoutPromptInjection() {
        let id = "01a0f65c-8c61-76f2-8363-6f53e5c2a1b8"
        var activity = SessionActivity(id: "rollout-2026-10-01-\(id).jsonl")
        XCTAssertEqual(activity.threadURL?.absoluteString, "codex://threads/" + id)
        activity.consume(log("session_meta", at: epoch, payload: ["id": "bad?prompt=send", "cwd": "/test"], type: "session_meta"))
        XCTAssertEqual(activity.threadURL?.absoluteString, "codex://threads/" + id)
    }
    func testNewlyDiscoveredInputWaitIsActionableAfterInitialScan() {
        var policy = AttentionPolicy()
        XCTAssertTrue(policy.activityNotices([], at: epoch).isEmpty)
        var activity = SessionActivity(id: "new")
        activity.consume(log("function_call", at: epoch.addingTimeInterval(1), payload: ["name": "request_user_input", "call_id": "ask"], type: "response_item"))
        XCTAssertEqual(policy.activityNotices([activity], at: epoch.addingTimeInterval(1)).first?.kind, .waitingForInput)
    }
    func testOnlySynchronousInputCallWaitsAndMatchingResultResumes() {
        var activity = SessionActivity(id: "input")
        activity.consume(log("task_started", at: epoch, payload: ["turn_id": "turn"]))
        activity.consume(log("function_call", at: epoch.addingTimeInterval(1), payload: ["name": "request_user_input_async", "call_id": "async"], type: "response_item"))
        XCTAssertEqual(activity.phase, .running)
        activity.consume(log("function_call", at: epoch.addingTimeInterval(2), payload: ["name": "request_user_input", "call_id": "ask"], type: "response_item"))
        XCTAssertEqual(activity.phase, .waitingForInput)
        activity.consume(log("function_call_output", at: epoch.addingTimeInterval(3), payload: ["call_id": "other"], type: "response_item"))
        XCTAssertEqual(activity.phase, .waitingForInput)
        activity.consume(log("function_call_output", at: epoch.addingTimeInterval(4), payload: ["call_id": "ask"], type: "response_item"))
        XCTAssertEqual(activity.phase, .running)
    }
    func testNewTurnCannotBeResumedByOldInputResult() {
        var activity = SessionActivity(id: "input")
        activity.consume(log("task_started", at: epoch, payload: ["turn_id": "old"]))
        activity.consume(log("function_call", at: epoch.addingTimeInterval(1), payload: ["name": "request_user_input", "call_id": "ask"], type: "response_item"))
        activity.consume(log("task_started", at: epoch.addingTimeInterval(2), payload: ["turn_id": "new"]))
        activity.consume(log("function_call_output", at: epoch.addingTimeInterval(3), payload: ["call_id": "ask"], type: "response_item"))
        XCTAssertEqual(activity.turnID, "new")
        XCTAssertEqual(activity.stage, .starting)
    }
    func testStartupEventsAreQuietAndCompletionAlertsOnlyOnce() {
        var activity = SessionActivity(id: "test")
        activity.consume(log("task_started", at: epoch, payload: ["turn_id": "turn"]))
        var policy = AttentionPolicy()
        XCTAssertTrue(policy.activityNotices([activity], at: epoch).isEmpty)
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(1), payload: ["turn_id": "turn"]))
        XCTAssertEqual(policy.activityNotices([activity], at: epoch.addingTimeInterval(1)).first?.kind, .completed)
        XCTAssertTrue(policy.activityNotices([activity], at: epoch.addingTimeInterval(2)).isEmpty)
    }
    func testLowQuotaDoesNotRepeatEveryRefreshAndRearmsAfterRecovery() throws {
        var policy = AttentionPolicy()
        XCTAssertEqual(policy.quotaNotices(try weekly(10), at: epoch).count, 1)
        XCTAssertTrue(policy.quotaNotices(try weekly(9, at: epoch.addingTimeInterval(1)), at: epoch.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(policy.quotaNotices(try weekly(30, at: epoch.addingTimeInterval(2)), at: epoch.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(policy.quotaNotices(try weekly(10, at: epoch.addingTimeInterval(3)), at: epoch.addingTimeInterval(3)).count, 1)
    }
    func testFloatingFrameStaysInsideNegativeOriginExternalDisplay() {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: -100, width: 1920, height: 1040)
        let frame = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: 0, topHeight: 38, expanded: true, attached: false)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
    }
    func testNotchAndSmallDisplayKeepTopAnchorAndClampHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let small = CGRect(x: 0, y: 0, width: 480, height: 280)
        let notch = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: 190, topHeight: 32, expanded: true, attached: true)
        XCTAssertEqual(notch.maxY, screen.maxY)
        let clamped = IslandGeometry.frame(screen: small, visible: small, notchWidth: 0, topHeight: 38, expanded: true, attached: false)
        XCTAssertGreaterThanOrEqual(clamped.minY, small.minY + 8)
        XCTAssertLessThanOrEqual(clamped.width, small.width - 24)
    }
}
