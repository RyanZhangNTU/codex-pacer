import XCTest
@testable import PacerCore

final class CompletionInboxTests: XCTestCase {
    func testLateSshNameUpdatesRetainedEndingWithoutRecreatingActivity() {
        let thread = UUID().uuidString.lowercased(), host = "remote-ssh-discovered:fixture"
        for initialName in [nil, "Original name"] as [String?] {
            for ending in ["completed", "failed"] {
                var state = RuntimeEventState(sourceID: host, sourceName: "SSH"), inbox = CompletionInbox()
                func event(_ method: String, _ seconds: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
                    var values = fields
                    values["method"] = method; values["threadId"] = thread
                    values["at"] = epoch.timeIntervalSince1970 + seconds
                    return ["kind": "runtime", "event": values]
                }
                state.consume(["kind": "status", "connected": true])
                var metadata: [String: Any] = ["cwd": "/synthetic/project"]
                if let initialName { metadata["name"] = initialName }
                state.consume(event("metadata", 0, metadata))
                state.consume(event("turn/started", 1, ["turnId": "first"]))
                inbox.observe(state.activities, at: epoch.addingTimeInterval(1), retention: 300)
                state.consume(event("turn/completed", 2, ["turnId": "first", "status": ending]))
                state.consume(event("stream/released", 2))
                inbox.observe(state.activities, at: epoch.addingTimeInterval(2), retention: 300)
                let before = inbox.activities[0]
                state.releasePublishedState()
                XCTAssertTrue(state.activities.isEmpty)
                // Automatic naming may finish after both the ending and release.
                state.consume(event("metadata", 3, ["name": "Generated session name"]))
                state.consume(event("thread/observed", 3, ["status": "idle"]))
                XCTAssertTrue(state.activities.isEmpty, "A name cannot invent a running or completed task")
                inbox.updateNames(state.nameUpdates)
                inbox.observe(state.activities, at: epoch.addingTimeInterval(3), retention: 300)
                let renamed = inbox.activities[0]
                XCTAssertEqual(renamed.title, "Generated session name")
                XCTAssertEqual(renamed.phase, before.phase)
                XCTAssertEqual(renamed.turnID, before.turnID)
                XCTAssertEqual(renamed.phaseChangedAt, before.phaseChangedAt)
                XCTAssertEqual(renamed.lastObserved, before.lastObserved)
                XCTAssertEqual(renamed.turnFailed, before.turnFailed)
                XCTAssertEqual(inbox.unreadActivities.count, 1)
                // A subsequent older completed log cannot undo that display name.
                inbox.observe([before], at: epoch.addingTimeInterval(4), retention: 300)
                XCTAssertEqual(inbox.activities[0].title, "Generated session name")
                state.consume(event("thread/name/updated", 5, ["name": NSNull()]))
                inbox.updateNames(state.nameUpdates)
                inbox.observe([before], at: epoch.addingTimeInterval(5), retention: 300)
                XCTAssertNil(inbox.activities[0].title, "An explicit removal must not restore a cached title")
                XCTAssertEqual(inbox.unreadActivities.count, 1)
                inbox.dismiss(inbox.activities[0])
                state.consume(event("metadata", 6, ["name": "Another name"]))
                inbox.updateNames(state.nameUpdates)
                inbox.observe([before], at: epoch.addingTimeInterval(6), retention: 300)
                XCTAssertTrue(inbox.activities.isEmpty, "Renaming cannot resurrect a dismissed completion")
            }
        }
    }

    func testCompletionNameUpdatesAreIsolatedByHostAndDoNotExtendRetention() {
        let thread = UUID().uuidString.lowercased(), host = "remote-ssh-discovered:fixture"
        var finished = SessionActivity(id: host + ":" + thread, sourceHostID: host)
        finished.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": epoch.timeIntervalSince1970])
        finished.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "first", "status": "completed", "at": epoch.timeIntervalSince1970 + 1])
        var inbox = CompletionInbox()
        inbox.observe([finished], at: epoch.addingTimeInterval(1), retention: 300)
        var sibling = SessionActivity(id: "local:" + thread)
        sibling.consumeLive(["method": "metadata", "threadId": thread, "name": "Other host", "at": epoch.timeIntervalSince1970 + 2])
        inbox.updateNames([SessionNameUpdate(sibling)!])
        XCTAssertNil(inbox.activities[0].title)
        finished.consumeLive(["method": "metadata", "threadId": thread, "name": "Same host", "at": epoch.timeIntervalSince1970 + 250])
        inbox.updateNames([SessionNameUpdate(finished)!])
        XCTAssertEqual(inbox.activities[0].title, "Same host")
        inbox.prune(at: epoch.addingTimeInterval(301), retention: 300)
        inbox.updateNames([SessionNameUpdate(finished)!])
        XCTAssertTrue(inbox.activities.isEmpty, "A display update cannot extend expiry or recreate a card")
    }

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
    func testRecreatedUnknownSourceCannotRevokeRetainedOrDismissedEnding() {
        let thread = UUID().uuidString.lowercased()
        var finished = running("local:" + thread)
        event(&finished, "task_complete", seconds: 1)
        for dismiss in [false, true] {
            var inbox = CompletionInbox()
            inbox.observe([finished], at: epoch.addingTimeInterval(2), retention: 1800)
            if dismiss { inbox.dismiss(finished) }
            var fresh = SessionActivity(id: finished.id)
            fresh.consumeLive(["method": "thread/status/changed", "threadId": thread, "status": "notLoaded", "at": epoch.addingTimeInterval(3).timeIntervalSince1970])
            XCTAssertEqual(fresh.phase, .unknown)
            XCTAssertTrue(inbox.observe([fresh], at: epoch.addingTimeInterval(4), retention: 1800).isEmpty)
            XCTAssertEqual(inbox.activities.count, dismiss ? 0 : 1)
            fresh.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "next", "at": epoch.addingTimeInterval(5).timeIntervalSince1970])
            fresh.markUnconfirmed()
            XCTAssertEqual(inbox.observe([fresh], at: epoch.addingTimeInterval(6), retention: 1800).first?.turnID, "next", "A proven later turn may replace the old ending even if its connection subsequently fails")
            XCTAssertTrue(inbox.activities.isEmpty)
        }
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
