import XCTest
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
        for index in 0..<300 { history.record(try weekly(100 - Double(index) / 10, at: epoch.addingTimeInterval(Double(index) * 600))) }
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
    func testEstimateFreshnessAndRetentionFollowTurnLifecycle() throws {
        var rate = OutputRate()
        rate.observe(totalOutput: 100, at: epoch)
        XCTAssertNil(rate.tokensPerSecond(at: epoch))
        XCTAssertNil(rate.estimate(at: epoch))
        rate.observe(totalOutput: 150, at: epoch.addingTimeInterval(5))
        XCTAssertEqual(rate.tokensPerSecond(at: epoch.addingTimeInterval(6)), 10)
        XCTAssertTrue(try XCTUnwrap(rate.estimate(at: epoch.addingTimeInterval(19.9))).isFresh)
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(20)))
        XCTAssertNil(rate.tokensPerSecond(at: epoch.addingTimeInterval(21)))

        rate.startTurn(at: epoch.addingTimeInterval(100))
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(100)))
        rate.observe(totalOutput: 170, at: epoch.addingTimeInterval(102))
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(102)))
        rate.observe(totalOutput: 190, at: epoch.addingTimeInterval(104))
        XCTAssertEqual(rate.tokensPerSecond(at: epoch.addingTimeInterval(104)), 10)
        XCTAssertEqual(rate.estimate(at: epoch.addingTimeInterval(104))?.value, 10)
        rate.finishTurn()
        XCTAssertNil(rate.tokensPerSecond(at: epoch.addingTimeInterval(105)))
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(105)))
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
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(200)))
    }
    func testBurstsAccumulateAndDuplicateCountersDoNotRefreshOrShortenTheWindow() throws {
        var rate = OutputRate()
        rate.observe(totalOutput: 100, at: epoch)
        for i in 1...10 {
            rate.observe(totalOutput: 100 + i * 5, at: epoch.addingTimeInterval(Double(i) * 0.05))
        }
        XCTAssertEqual(try XCTUnwrap(rate.tokensPerSecond(at: epoch.addingTimeInterval(0.5))), 100, accuracy: 0.001)
        // Repeated cached counts are neither new zero-speed samples nor new baselines.
        rate.observe(totalOutput: 150, at: epoch.addingTimeInterval(10))
        XCTAssertEqual(rate.estimate(at: epoch.addingTimeInterval(10))?.reportedAt, epoch.addingTimeInterval(0.5))
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(15.5)))
        rate.observe(totalOutput: 300, at: epoch.addingTimeInterval(20))
        XCTAssertEqual(try XCTUnwrap(rate.tokensPerSecond(at: epoch.addingTimeInterval(20))), 10, accuracy: 0.001)
    }
    func testPendingBurstRollbackAndOutOfOrderCountersResetSafely() throws {
        var rate = OutputRate()
        rate.observe(totalOutput: 100, at: epoch)
        rate.observe(totalOutput: 200, at: epoch.addingTimeInterval(0.1))
        rate.observe(totalOutput: 150, at: epoch.addingTimeInterval(0.2))
        XCTAssertNil(rate.estimate(at: epoch.addingTimeInterval(0.2)))
        rate.observe(totalOutput: 190, at: epoch.addingTimeInterval(2.2))
        XCTAssertEqual(try XCTUnwrap(rate.tokensPerSecond(at: epoch.addingTimeInterval(2.2))), 20, accuracy: 0.001)
        rate.observe(totalOutput: 5000, at: epoch.addingTimeInterval(1))
        rate.observe(totalOutput: 230, at: epoch.addingTimeInterval(4.2))
        XCTAssertEqual(try XCTUnwrap(rate.tokensPerSecond(at: epoch.addingTimeInterval(4.2))), 20, accuracy: 0.001)
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
    func testFastLiveEndingsNotifyOnceEvenWithoutAnIntermediateRunningPublication() {
        let thread = "019a0000-0000-7000-8000-000000000001"
        for initialPublication in [false, true] {
            var policy = AttentionPolicy(), inbox = CompletionInbox()
            var activity = SessionActivity(id: thread, phaseAwareRate: true)
            if !initialPublication { XCTAssertTrue(policy.activityNotices([], at: epoch).isEmpty) }
            for (index, status) in ["completed", "completed", "interrupted", "failed"].enumerated() {
                let turn = "turn-\(index)", time = epoch.addingTimeInterval(Double(index * 3 + 1))
                activity.consumeLive(["method": "turn/started", "threadId": thread, "turnId": turn, "at": time.timeIntervalSince1970])
                activity.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": turn, "at": time.timeIntervalSince1970 + 0.1, "status": status])
                let now = time.addingTimeInterval(0.2)
                inbox.observe([activity], at: now, retention: 1800)
                XCTAssertEqual(inbox.unreadActivities.count, 1)
                let notices = policy.activityNotices([activity], at: now)
                XCTAssertEqual(notices.count, 1)
                XCTAssertEqual(notices.first?.kind, status == "completed" ? .completed : .interrupted)
                XCTAssertTrue(policy.activityNotices([activity], at: now).isEmpty)
                _ = policy.activityNotices([], at: now)
                XCTAssertTrue(policy.activityNotices([activity], at: now).isEmpty, "Reappearing retained cards must not alert twice")
            }
            XCTAssertTrue(policy.activityNotices([activity], at: epoch.addingTimeInterval(120)).isEmpty)
        }
        var historical = SessionActivity(id: thread)
        historical.consume(log("task_started", at: epoch, payload: ["turn_id": "history"]))
        historical.consume(log("task_complete", at: epoch.addingTimeInterval(1), payload: ["turn_id": "history"]))
        var policy = AttentionPolicy()
        XCTAssertTrue(policy.activityNotices([historical], at: epoch.addingTimeInterval(2)).isEmpty)
        _ = policy.activityNotices([], at: epoch.addingTimeInterval(3))
        XCTAssertTrue(policy.activityNotices([historical], at: epoch.addingTimeInterval(4)).isEmpty, "Historical log discovery stays quiet")
    }
    func testLowQuotaDoesNotRepeatEveryRefreshAndRearmsAfterRecovery() throws {
        var policy = AttentionPolicy()
        XCTAssertEqual(policy.quotaNotices(try weekly(10), at: epoch).count, 1)
        XCTAssertTrue(policy.quotaNotices(try weekly(9, at: epoch.addingTimeInterval(1)), at: epoch.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(policy.quotaNotices(try weekly(30, at: epoch.addingTimeInterval(2)), at: epoch.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(policy.quotaNotices(try weekly(10, at: epoch.addingTimeInterval(3)), at: epoch.addingTimeInterval(3)).count, 1)
    }
}

final class RuntimeStateTests: XCTestCase {
    private func running(_ id: String, rate: Int, model: String = "gpt-test") -> SessionActivity {
        var activity = SessionActivity(id: id)
        activity.consume(log("task_started", at: epoch, payload: ["turn_id": id]))
        activity.consume(log("context", at: epoch, payload: ["model": model, "turn_id": id], type: "turn_context"))
        activity.consume(log("token_count", at: epoch.addingTimeInterval(1), payload: ["info": ["total_token_usage": ["output_tokens": 100]]]))
        activity.consume(log("token_count", at: epoch.addingTimeInterval(3), payload: ["info": ["total_token_usage": ["output_tokens": 100 + rate * 2]]]))
        return activity
    }
    func testGlobalRateAddsRunningTasksAndExcludesReviewWaitAndEndedTurns() {
        let first = running("first", rate: 10)
        let second = running("second", rate: 20)
        let review = running("review", rate: 500, model: "codex-auto-review")
        var waiting = running("waiting", rate: 100)
        waiting.consume(log("function_call", at: epoch.addingTimeInterval(4), payload: ["name": "request_user_input", "call_id": "ask"], type: "response_item"))
        var ended = running("ended", rate: 200)
        ended.consume(log("task_complete", at: epoch.addingTimeInterval(4), payload: ["turn_id": "ended"]))
        let overview = ActivityOverview(activities: [ended, first, review, waiting, second], at: epoch.addingTimeInterval(5))
        XCTAssertEqual(overview.running.count, 2)
        XCTAssertEqual(overview.activities.count, 4)
        XCTAssertEqual(overview.tokensPerSecond, 30)
        XCTAssertEqual(overview.phase, .running)
        XCTAssertEqual(overview.title, L10n.text("activity.running_count", 2))
        XCTAssertNil(ActivityOverview(activities: [first, second], at: epoch.addingTimeInterval(20)).tokensPerSecond)
    }
    func testEndedConversationCannotOverrideUnknownOrRunningUserTask() {
        var ended = running("ended", rate: 200)
        ended.consume(log("task_complete", at: epoch.addingTimeInterval(4), payload: ["turn_id": "ended"]))
        let unknown = SessionActivity(id: "unknown")
        XCTAssertEqual(ActivityOverview(activities: [ended, unknown], at: epoch.addingTimeInterval(5)).phase, .unknown)
        XCTAssertEqual(ActivityOverview(activities: [ended, running("active", rate: 10)], at: epoch.addingTimeInterval(5)).phase, .running)
        XCTAssertEqual(ActivityOverview(activities: [ended], at: epoch.addingTimeInterval(5)).title, L10n.text("activity.idle"))
    }
    func testVerifiedIdleDoesNotDecayIntoAnUnknownActiveTask() {
        var activity = running("ended", rate: 10)
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(4), payload: ["turn_id": "ended"]))
        XCTAssertEqual(activity.observedPhase(at: epoch.addingTimeInterval(600)), .completed)
        XCTAssertEqual(ActivityOverview(activities: [activity], at: epoch.addingTimeInterval(600)).title, L10n.text("activity.idle"))
    }
    func testOrphanCompletionCannotDeclareAnUnobservedTaskEnded() {
        var activity = SessionActivity(id: "unknown")
        activity.consume(log("task_complete", at: epoch, payload: ["turn_id": "unobserved"]))
        XCTAssertEqual(activity.phase, .unknown)
        XCTAssertNil(activity.phaseChangedAt)
    }
    func testTurnContextRecoversMissingStartAndRejectsOldCompletion() {
        var activity = running("old", rate: 10)
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(4), payload: ["turn_id": "old"]))
        activity.consume(log("context", at: epoch.addingTimeInterval(5), payload: ["turn_id": "new", "model": "gpt-test"], type: "turn_context"))
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(6), payload: ["turn_id": "old"]))
        XCTAssertEqual(activity.phase, .running)
        XCTAssertEqual(activity.turnID, "new")
        XCTAssertEqual(activity.lastObserved, epoch.addingTimeInterval(5))
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(7), payload: ["turn_id": "new"]))
        XCTAssertEqual(activity.phase, .completed)
        activity.consume(log("context", at: epoch.addingTimeInterval(8), payload: ["turn_id": "new", "model": "gpt-test"], type: "turn_context"))
        XCTAssertEqual(activity.phase, .completed)
    }
    func testFreshWorkAfterAnEndedTurnRestoresActivityWithoutAcceptingOldEnd() {
        var activity = running("old", rate: 10)
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(4), payload: ["turn_id": "old"]))
        activity.consume(log("function_call", at: epoch.addingTimeInterval(5), payload: ["name": "exec", "call_id": "current"], type: "response_item"))
        XCTAssertEqual(activity.phase, .running)
        activity.consume(log("task_complete", at: epoch.addingTimeInterval(6), payload: ["turn_id": "old"]))
        XCTAssertEqual(activity.phase, .running)
        XCTAssertNil(activity.turnID)
    }
    func testReviewProvenanceSurvivesGapsAndDoesNotUseProjectName() {
        var review = SessionActivity(id: "review")
        review.consume(log("meta", at: epoch, payload: ["source": ["subagent": ["other": "guardian"]], "thread_source": "guardian_review"], type: "session_meta"))
        review.markDiscontinuity()
        review.consume(log("task_started", at: epoch, payload: ["turn_id": "review"]))
        XCTAssertTrue(review.isInternalReview)
        let real = SessionActivity(id: "real", project: "autoreview")
        XCTAssertFalse(real.isInternalReview)
        var policy = AttentionPolicy()
        _ = policy.activityNotices([], at: epoch)
        review.consume(log("function_call", at: epoch.addingTimeInterval(1), payload: ["name": "request_user_input", "call_id": "ask"], type: "response_item"))
        XCTAssertTrue(policy.activityNotices([review], at: epoch.addingTimeInterval(1)).isEmpty)
    }
    func testReaderRecoversLongRunningTurnOutsideStartupTailAndPreservesMetadata() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/\(formatter.string(from: epoch))")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("real.jsonl")
        let uuid = "11111111-1111-4111-8111-111111111111"
        let meta = log("meta", at: epoch, payload: ["cwd": "/projects/real", "id": uuid, "thread_source": "user"], type: "session_meta")
        let start = log("task_started", at: epoch, payload: ["turn_id": "current"])
        let filler = log("function_call_output", at: epoch.addingTimeInterval(1), payload: ["call_id": "large", "output": String(repeating: "x", count: 800000)], type: "response_item")
        let tail = log("token_count", at: epoch.addingTimeInterval(2), payload: [:])
        try ([meta, start, filler, tail].reduce(Data()) { $0 + $1 + Data([10]) }).write(to: file)
        let reader = LocalActivityReader()
        let initial = await reader.read(home: home, now: epoch.addingTimeInterval(6))
        XCTAssertEqual(initial.activities.first?.phase, .running)
        XCTAssertEqual(initial.activities.first?.turnID, "current")
        XCTAssertEqual(initial.activities.first?.threadID, uuid)
        XCTAssertEqual(initial.activities.first?.project, "real")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        let newStart = log("task_started", at: epoch.addingTimeInterval(3), payload: ["turn_id": "next"])
        let large = log("function_call_output", at: epoch.addingTimeInterval(4), payload: ["call_id": "huge", "output": String(repeating: "y", count: 200000)], type: "response_item")
        let oldEnd = log("task_complete", at: epoch.addingTimeInterval(5), payload: ["turn_id": "current"])
        try handle.write(contentsOf: [newStart, large, oldEnd].reduce(Data()) { $0 + $1 + Data([10]) }); try handle.close()
        let caughtUp = await reader.read(home: home, now: epoch.addingTimeInterval(6))
        XCTAssertEqual(caughtUp.activities.first?.phase, .running)
        XCTAssertEqual(caughtUp.activities.first?.turnID, "next")
        XCTAssertEqual(caughtUp.activities.first?.threadID, uuid)
    }
    func testReviewsCannotCrowdUserTasksOutOfDiscoverySlots() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = home.appendingPathComponent("sessions/\(formatter.string(from: epoch))")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let user = day.appendingPathComponent("user.jsonl")
        try (log("task_started", at: epoch, payload: ["turn_id": "user"]) + Data([10])).write(to: user)
        try FileManager.default.setAttributes([.modificationDate: epoch], ofItemAtPath: user.path)
        for index in 0..<20 {
            let file = day.appendingPathComponent("review-\(index).jsonl")
            let meta = log("meta", at: epoch, payload: ["thread_source": "guardian_review", "source": ["subagent": ["other": "guardian"]]], type: "session_meta")
            try (meta + Data([10]) + log("task_started", at: epoch, payload: ["turn_id": "review"]) + Data([10])).write(to: file)
        }
        let result = await LocalActivityReader().read(home: home, now: epoch.addingTimeInterval(6))
        XCTAssertEqual(result.activities.count, 1)
        XCTAssertEqual(result.activities.first?.id, "user.jsonl")
        XCTAssertEqual(result.activities.first?.phase, .running)
    }
}
