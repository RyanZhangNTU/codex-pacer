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
