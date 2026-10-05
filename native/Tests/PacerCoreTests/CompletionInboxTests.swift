import XCTest
@testable import PacerCore

final class CompletionInboxTests: XCTestCase {
    func testDistinctNewLogTurnSurvivesDelayedLiveCompletionButOlderTurnDoesNot() {
        let thread = UUID().uuidString.lowercased()
        var live = SessionActivity(id: "local:" + thread)
        live.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": epoch.timeIntervalSince1970])
        var inbox = CompletionInbox()
        inbox.observe([live], at: epoch, retention: 0)
        live.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "first", "at": epoch.addingTimeInterval(3).timeIntervalSince1970, "status": "completed"])
        inbox.observe([live], at: epoch.addingTimeInterval(3), retention: 0)
        var older = SessionActivity(id: live.id)
        event(&older, "task_started", turn: "older", seconds: -10)
        XCTAssertTrue(inbox.observe([older], at: epoch.addingTimeInterval(4), retention: 0).isEmpty)
        var next = SessionActivity(id: live.id)
        event(&next, "task_started", turn: "next", seconds: 2)
        XCTAssertEqual(inbox.observe([next], at: epoch.addingTimeInterval(4), retention: 0).first?.turnID, "next")
        XCTAssertTrue(inbox.activities.isEmpty)
    }
    func testReleasedStreamCannotResurrectOlderLogOrDismissedCompletion() {
        var inbox = CompletionInbox(), activity = running()
        let oldLog = activity
        inbox.observe([activity], at: epoch, retention: 0)
        event(&activity, "task_complete", seconds: 1)
        inbox.observe([activity], at: epoch.addingTimeInterval(1), retention: 0)
        let accepted = inbox.observe([oldLog], at: epoch.addingTimeInterval(2), retention: 0)
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(inbox.isUnread(activity))
        inbox.dismiss(activity)
        XCTAssertTrue(inbox.observe([oldLog], at: epoch.addingTimeInterval(3), retention: 0).isEmpty)
        inbox.observe([activity], at: epoch.addingTimeInterval(3), retention: 0)
        XCTAssertTrue(inbox.activities.isEmpty)
        event(&activity, "task_started", turn: "new", seconds: 4)
        XCTAssertEqual(inbox.observe([activity], at: epoch.addingTimeInterval(4), retention: 0).first?.phase, .running)
        event(&activity, "task_complete", turn: "new", seconds: 5)
        inbox.observe([activity], at: epoch.addingTimeInterval(5), retention: 0)
        XCTAssertTrue(inbox.isUnread(activity))
    }
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
    func testUnixTimestampRoundingCannotDropAnImmediateCompletion() {
        for ahead in [0.0000005, 5.0] {
            let thread = UUID().uuidString.lowercased()
            var activity = SessionActivity(id: "local:" + thread), inbox = CompletionInbox()
            activity.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "turn", "at": epoch.timeIntervalSince1970 - 1])
            inbox.observe([activity], at: epoch, retention: 1800)
            activity.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "turn", "status": "completed", "at": epoch.timeIntervalSince1970 + ahead])
            inbox.observe([activity], at: epoch, retention: 1800)
            XCTAssertEqual(inbox.unreadActivities.count, ahead < 0.001 ? 1 : 0)
        }
    }
    func testLiveStartAndEndingInOneBatchStillCreatesUnreadReminder() {
        let thread = UUID().uuidString.lowercased()
        var runtime = RuntimeEventState(sourceID: nil, sourceName: nil), inbox = CompletionInbox()
        runtime.consume(["kind": "status", "connected": true])
        runtime.consume(["kind": "runtimeBatch", "events": [
            ["method": "thread/observed", "threadId": thread, "status": "active", "at": epoch.timeIntervalSince1970],
            ["method": "turn/completed", "threadId": thread, "turnId": "quiet-turn", "status": "completed", "at": epoch.timeIntervalSince1970 + 0.1],
            ["method": "stream/released", "threadId": thread, "at": epoch.timeIntervalSince1970 + 0.1]
        ]])
        inbox.observe(runtime.activities, at: epoch.addingTimeInterval(0.2), retention: 1800)
        runtime.releasePublishedState()
        inbox.observe(runtime.activities, at: epoch.addingTimeInterval(1), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.count, 1)
        XCTAssertEqual(inbox.unreadActivities.first?.turnID, "quiet-turn")
    }
    func testObservedActiveTurnKeepsItsProvenanceWhenFirstItemSuppliesTurnID() {
        let thread = UUID().uuidString.lowercased(), host = "remote-ssh-discovered:fixture"
        var old = SessionActivity(id: host + ":" + thread, sourceHost: "SSH", sourceHostID: host)
        event(&old, "task_started", seconds: 0)
        event(&old, "task_complete", seconds: 1)
        var state = RuntimeEventState(sourceID: host, sourceName: "SSH"), inbox = CompletionInbox()
        state.replaceLocalFallback([old]); state.consume(["kind": "status", "connected": true])
        inbox.observe(state.activities, at: epoch.addingTimeInterval(1), retention: 1800)
        state.consume(["kind": "runtimeBatch", "events": [
            ["method": "thread/observed", "threadId": thread, "status": "active", "at": epoch.timeIntervalSince1970 + 2],
            ["method": "item/started", "threadId": thread, "turnId": "second", "itemId": "tool", "itemType": "dynamicToolCall", "at": epoch.timeIntervalSince1970 + 2.1]
        ]])
        XCTAssertEqual(state.activities.first?.turnID, "second", "The old completed log must not replace the confirmed new turn")
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertEqual(state.activities.first?.liveTurnStarted, true)
        XCTAssertEqual(state.activities.first?.turnStartedAt, epoch.addingTimeInterval(2))
        inbox.observe(state.activities, at: epoch.addingTimeInterval(2.2), retention: 1800)
        XCTAssertTrue(inbox.activities.isEmpty)
        state.consume(["kind": "runtimeBatch", "events": [
            ["method": "turn/completed", "threadId": thread, "turnId": "second", "status": "completed", "at": epoch.timeIntervalSince1970 + 3],
            ["method": "stream/released", "threadId": thread, "at": epoch.timeIntervalSince1970 + 3.1]
        ]])
        inbox.observe(state.activities, at: epoch.addingTimeInterval(3.2), retention: 1800)
        state.releasePublishedState()
        inbox.observe(state.activities, at: epoch.addingTimeInterval(4), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.first?.turnID, "second")

        var orphan = SessionActivity(id: old.id, sourceHost: "SSH", sourceHostID: host)
        orphan.consumeLive(["method": "item/started", "threadId": thread, "turnId": "unconfirmed", "itemId": "item", "itemType": "agentMessage", "at": epoch.timeIntervalSince1970 + 5])
        XCTAssertFalse(orphan.liveTurnStarted, "An item alone still cannot establish a different new turn over a completed log")
        XCTAssertEqual(ActivitySourceMerger.merge(logged: [old], streamed: [orphan]).first?.turnID, "first")
    }
    func testRuntimeIdleMetadataSuppressesOldRunningLogWithoutInventingCompletion() {
        let thread = UUID().uuidString.lowercased()
        var old = SessionActivity(id: "local:" + thread)
        event(&old, "task_started", seconds: 0)
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.replaceLocalFallback([old]); state.consume(["kind": "status", "connected": true])
        state.consume(["kind": "runtime", "event": ["method": "thread/observed", "threadId": thread, "status": "idle", "at": epoch.timeIntervalSince1970 + 1]])
        XCTAssertTrue(state.activities.isEmpty)
        XCTAssertTrue(state.isConfirmedIdle(thread: thread))
        event(&old, "task_started", turn: "next", seconds: 2)
        state.replaceLocalFallback([old])
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertFalse(state.isConfirmedIdle(thread: thread))
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
