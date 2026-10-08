import XCTest
import PacerCore
@testable import PacerIsland

@MainActor
final class ActivityOpeningTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    private func completion() throws -> (IslandModel, SessionActivity, Clock) {
        let clock = Clock()
        let model = IslandModel(demo: true, demoClock: { clock.now })
        model.setDemoStage(.completed)
        let activity = try XCTUnwrap(model.activities.first { $0.phase == .completed })
        XCTAssertTrue(model.isUnreadCompletion(activity))
        return (model, activity, clock)
    }

    func testVisibilitySwitchesAutomaticCadenceAndKeepsCompletionCards() throws {
        let (model, _, _) = try completion()
        let before = model.activities
        model.close()
        XCTAssertEqual(model.activityRefreshPolicy.interval, 5)
        model.hover(true)
        XCTAssertEqual(model.activityRefreshPolicy.interval, 1)
        model.togglePin(); model.close()
        XCTAssertEqual(model.activityRefreshPolicy.interval, 5)
        model.setInteractionSuspended(true); model.hover(true)
        XCTAssertEqual(model.activityRefreshPolicy.interval, 5)
        model.setInteractionSuspended(false); model.setExpanded(true)
        XCTAssertEqual(model.activityRefreshPolicy.interval, 1)
        XCTAssertEqual(model.activities, before)
    }

    func testSubagentRowsAndTotalsRemainWhenAnotherTaskStartsOrToolsRun() throws {
        let clock = Clock(), model = IslandModel(demo: true, demoClock: { clock.now })
        let formatter = ISO8601DateFormatter()
        func task(_ n: Int, parent: Int? = nil, tokens: Int = 600) throws -> SessionActivity {
            func id(_ value: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", value) }
            var value = SessionActivity(id: id(n), phaseAwareRate: true)
            var meta: [String: Any] = ["id": id(n)]
            if let parent { meta["parent_thread_id"] = id(parent) }
            value.consume(try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta]))
            for (type, ago, payload) in [("event_msg", -10.0, ["type": "task_started", "turn_id": "turn"]),
                ("response_item", 0.0, ["type": "message", "role": "assistant"]),
                ("token_usage_record", 0.0, ["thread_id": id(n), "turn_id": "turn", "response_id": "response", "usage": ["output_tokens": tokens]])]
                as [(String, Double, [String: Any])] {
                value.consume(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: clock.now.addingTimeInterval(ago)), "payload": payload]))
            }
            return value
        }
        var parent = try task(1), child = try task(2, parent: 1, tokens: 300)
        let otherChild = try task(3, parent: 1, tokens: 200)
        func log(_ a: inout SessionActivity, _ type: String, _ payload: [String: Any]) throws {
            a.consume(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: clock.now), "payload": payload]))
        }
        clock.now = clock.now.addingTimeInterval(1)
        try log(&parent, "response_item", ["type": "function_call", "name": "wait", "call_id": "tool"])
        model.now = clock.now; model.activities = [parent, child, otherChild]
        XCTAssertEqual(model.visibleActivities.count, 1)
        XCTAssertEqual(model.taskGroup(for: parent)?.runningSubagentCount, 2)
        XCTAssertEqual(model.rate, 110)
        XCTAssertEqual(model.headerRateText, "110")
        XCTAssertTrue(model.rateIsFresh)
        clock.now = clock.now.addingTimeInterval(1)
        try log(&parent, "event_msg", ["type": "task_started", "turn_id": "new"])
        var new = SessionActivity(id: "019a0000-0000-7000-8000-000000000004", phaseAwareRate: true)
        try log(&new, "event_msg", ["type": "task_started", "turn_id": "another"])
        model.now = clock.now; model.activities = [parent, child, otherChild, new]
        XCTAssertEqual(model.visibleActivities.count, 2)
        XCTAssertEqual(model.taskGroup(for: parent)?.displayedRate(at: clock.now)?.value, 110)
        XCTAssertEqual(model.rate, 110)
        XCTAssertEqual(model.headerRateText, "110")
        XCTAssertTrue(model.rateIsFresh)
        model.now = clock.now.addingTimeInterval(15)
        XCTAssertEqual(model.headerRateText, "110")
        XCTAssertFalse(model.rateIsFresh)
        model.now = clock.now
        try log(&child, "event_msg", ["type": "task_complete", "turn_id": "turn"])
        model.activities = [parent, child, otherChild, new]
        XCTAssertEqual(model.visibleActivities.count, 2)
        XCTAssertEqual(model.taskGroup(for: parent)?.runningSubagentCount, 1)
        XCTAssertEqual(model.rate, 80)
    }

    func testFailedOpenPreservesCardAndUnreadReminder() async throws {
        let (model, activity, _) = try completion()
        let finished = expectation(description: "open attempted")
        model.onOpenActivity = { _ in finished.fulfill(); return "Synthetic open failure" }
        model.open(activity)
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertTrue(model.activities.contains { $0.id == activity.id })
        XCTAssertTrue(model.isUnreadCompletion(activity))
        XCTAssertEqual(model.navigationError, "Synthetic open failure")
    }

    func testSuccessfulOpenDismissesOnlyRequestedCompletion() async throws {
        let (model, activity, _) = try completion()
        let finished = expectation(description: "open succeeded")
        model.onOpenActivity = { _ in finished.fulfill(); return nil }
        model.open(activity)
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertFalse(model.activities.contains { $0.id == activity.id })
        XCTAssertFalse(model.isUnreadCompletion(activity))
        XCTAssertTrue(model.activities.contains { $0.sourceHostID != nil })
        XCTAssertNil(model.navigationError)
    }

    func testLateOpenAcknowledgementCannotDismissNewerCompletion() async throws {
        let (model, old, clock) = try completion()
        let started = expectation(description: "opening")
        let finish = expectation(description: "finished")
        model.onOpenActivity = { _ in
            started.fulfill()
            try? await Task.sleep(nanoseconds: 40_000_000)
            finish.fulfill()
            return nil
        }
        model.open(old)
        await fulfillment(of: [started], timeout: 2)
        clock.now = clock.now.addingTimeInterval(31)
        model.setDemoStage(.thinking)
        model.setDemoStage(.completed)
        let latest = try XCTUnwrap(model.activities.first { $0.id == old.id })
        XCTAssertNotEqual(latest.phaseChangedAt, old.phaseChangedAt)
        await fulfillment(of: [finish], timeout: 2)
        await Task.yield()
        XCTAssertTrue(model.activities.contains { $0.id == latest.id && $0.phaseChangedAt == latest.phaseChangedAt })
        XCTAssertTrue(model.isUnreadCompletion(latest))
    }

    func testDuplicateClickDoesNotLaunchTwiceWhileOpening() async throws {
        let (model, activity, _) = try completion()
        let finish = expectation(description: "finished")
        var launches = 0
        model.onOpenActivity = { _ in
            launches += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            finish.fulfill(); return nil
        }
        model.open(activity); model.open(activity)
        await fulfillment(of: [finish], timeout: 2)
        XCTAssertEqual(launches, 1)
    }

    func testLateOpenCannotClearANewerNotice() async throws {
        let (model, activity, _) = try completion()
        let started = expectation(description: "opening"), finished = expectation(description: "finished")
        model.notice = IslandNotice(id: activity.id + ":demo-turn:completed:old", kind: .completed, title: "Old", detail: "Synthetic")
        model.onOpenActivity = { _ in
            started.fulfill(); try? await Task.sleep(nanoseconds: 20_000_000)
            finished.fulfill(); return nil
        }
        model.open(activity)
        await fulfillment(of: [started], timeout: 2)
        model.notice = IslandNotice(id: activity.id + ":new-turn:waiting:later", kind: .waitingForInput, title: "New", detail: "Synthetic")
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertEqual(model.notice?.title, "New")
    }
}
