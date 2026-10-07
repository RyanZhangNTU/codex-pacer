import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class SessionNameTests: XCTestCase {
    func testRemoteNameAfterCompletionReachesTheDisplayedCard() async {
        let model = IslandModel(demo: true)
        let thread = UUID().uuidString.lowercased(), host = "remote-ssh-discovered:fixture"
        let at = Date().timeIntervalSince1970 - 2
        var activity = SessionActivity(id: host + ":" + thread, project: "Project", sourceHostID: host)
        activity.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": at])
        model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: [])
        activity.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "first", "status": "completed", "at": at + 1])
        model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.activities.first?.title, nil)
        XCTAssertEqual(model.activities.first?.project, "Project")
        // No runtime task remains when automatic naming finally completes.
        var metadata = SessionActivity(id: host + ":" + thread, sourceHostID: host)
        metadata.consumeLive(["method": "metadata", "threadId": thread, "name": "Session name", "at": at + 2])
        model.receiveRemoteUpdate([], statuses: [:], unavailable: [], requests: [], names: [SessionNameUpdate(metadata)!])
        XCTAssertEqual(model.activities.count, 1)
        XCTAssertEqual(model.activities.first?.title, "Session name")
        XCTAssertEqual(model.activities.first?.phase, .completed)
        XCTAssertEqual(model.activities.first?.turnID, "first")
        XCTAssertEqual(model.activities.first?.phaseChangedAt, activity.phaseChangedAt)
        // Even a later stale log containing the project-only ending cannot undo it.
        model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.activities.first?.title, "Session name")
        await model.shutdown()
    }
}
