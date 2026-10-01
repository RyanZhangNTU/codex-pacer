import XCTest
@testable import PacerCore

final class CompletionInboxTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ activity: inout SessionActivity, _ type: String, turn: String = "first", seconds: Double) {
        let record: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: epoch.addingTimeInterval(seconds)),
            "type": "event_msg", "payload": ["type": type, "turn_id": turn]]
        activity.consume(try! JSONSerialization.data(withJSONObject: record))
    }
    private func running(_ id: String = "local") -> SessionActivity {
        var activity = SessionActivity(id: id)
        event(&activity, "task_started", seconds: 0)
        return activity
    }
    func testNewCompletionSurvivesSourceEvictionAndUsesConfiguredRetention() {
        var inbox = CompletionInbox(), activity = running()
        inbox.observe([activity], at: epoch, retention: 1800)
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(1), retention: 1800)
        inbox.observe([], at: epoch.addingTimeInterval(1200), retention: 1800)
        XCTAssertEqual(inbox.activities.map(\.id), [activity.id])
        XCTAssertTrue(inbox.isUnread(activity))
        inbox.prune(at: epoch.addingTimeInterval(1801), retention: 1800)
        XCTAssertTrue(inbox.activities.isEmpty)
        XCTAssertTrue(inbox.unreadActivities.isEmpty)
    }
    func testClickDismissesOnlyThatTurnAndRepeatedSnapshotsCannotRestoreIt() {
        var inbox = CompletionInbox(), activity = running()
        inbox.observe([activity], at: epoch, retention: 0)
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(1), retention: 0)
        inbox.dismiss(activity)
        inbox.observe([activity], at: epoch.addingTimeInterval(100), retention: 0)
        XCTAssertTrue(inbox.activities.isEmpty)
        event(&activity, "task_started", turn: "second", seconds: 101)
        inbox.observe([activity], at: epoch.addingTimeInterval(101), retention: 0)
        event(&activity, "task_complete", turn: "second", seconds: 102)
        inbox.observe([activity], at: epoch.addingTimeInterval(102), retention: 0)
        XCTAssertEqual(inbox.unreadActivities.count, 1)
    }
    func testStatusChangeReplacesCompletionImmediately() {
        var inbox = CompletionInbox(), activity = running()
        inbox.observe([activity], at: epoch, retention: 1800)
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(1), retention: 1800)
        event(&activity, "task_started", turn: "second", seconds: 2)
        inbox.observe([activity], at: epoch.addingTimeInterval(2), retention: 1800)
        XCTAssertTrue(inbox.activities.isEmpty)
        XCTAssertTrue(inbox.unreadActivities.isEmpty)
    }
    func testStartupCompletionIsRetainedWithoutReplayingReminder() {
        var inbox = CompletionInbox(), activity = running()
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(2), retention: 300)
        XCTAssertEqual(inbox.activities.count, 1)
        XCTAssertTrue(inbox.unreadActivities.isEmpty)
    }
    func testRepeatedUpdatesCannotExtendExpiryOrResurrectExpiredTurn() {
        var inbox = CompletionInbox(), activity = running()
        inbox.observe([activity], at: epoch, retention: 300)
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(1), retention: 300)
        inbox.observe([activity], at: epoch.addingTimeInterval(300), retention: 300)
        inbox.prune(at: epoch.addingTimeInterval(301), retention: 300)
        inbox.observe([activity], at: epoch.addingTimeInterval(302), retention: 3600)
        XCTAssertTrue(inbox.activities.isEmpty)
    }
    func testUntilClickedHasNoTimerExpiryAndShorterSettingPrunes() {
        var inbox = CompletionInbox(), activity = running()
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(1), retention: 0)
        inbox.prune(at: epoch.addingTimeInterval(86400), retention: 0)
        XCTAssertEqual(inbox.activities.count, 1)
        inbox.prune(at: epoch.addingTimeInterval(86400), retention: 300)
        XCTAssertTrue(inbox.activities.isEmpty)
    }
    func testLocalAndSshCompletionsDoNotOverwriteEachOther() {
        var inbox = CompletionInbox(), local = running("local:same"), remote = running("remote:same")
        inbox.observe([local, remote], at: epoch, retention: 1800)
        event(&local, "task_complete", seconds: 1)
        event(&remote, "turn_aborted", seconds: 2)
        inbox.observe([local, remote], at: epoch.addingTimeInterval(2), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.map(\.id), [remote.id, local.id])
        inbox.dismiss(remote)
        XCTAssertEqual(inbox.unreadActivities.map(\.id), [local.id])
    }
    func testInternalReviewAndOrphanCompletionCannotEnterInbox() {
        var inbox = CompletionInbox(), review = running("review"), orphan = SessionActivity(id: "orphan")
        review.consume(Data(#"{"type":"session_meta","payload":{"thread_source":"guardian_review"}}"#.utf8))
        inbox.observe([review, orphan], at: epoch, retention: 1800)
        event(&review, "task_complete", seconds: 1)
        event(&orphan, "task_complete", seconds: 1)
        inbox.observe([review, orphan], at: epoch.addingTimeInterval(1), retention: 1800)
        XCTAssertTrue(inbox.activities.isEmpty)
    }
}
