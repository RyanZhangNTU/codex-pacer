import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class SessionNameTests: XCTestCase {
    func testDeviceNameArrivingAfterRunningTaskUpdatesItsLabelWithoutReplacingActivity() async throws {
        let model = IslandModel(demo: true)
        let host = "remote-control:fixture", thread = UUID().uuidString.lowercased()
        let at = Date().timeIntervalSince1970 - 2
        var activity = SessionActivity(id: host + ":" + thread, sourceHost: "Remote Control", sourceHostID: host, phaseAwareRate: true)
        activity.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": at])
        activity.consumeLive(["method": "item/agentMessage/delta", "threadId": thread, "turnId": "first", "at": at + 0.5, "hasText": true])
        model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: [])
        let original = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(model.taskSourceName(original), "Remote Control")
        var status = RuntimeStreamStatus(); status.connected = true; status.sourceName = "Workstation"
        model.receiveRemoteUpdate([activity], statuses: [host: status], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.taskSourceName(try XCTUnwrap(model.activities.first)), "Workstation")
        XCTAssertEqual(model.activities, [original], "Device metadata must preserve routing, turn state, timing and measurements")
        status.sourceName = "Renamed workstation"
        model.receiveRemoteUpdate([activity], statuses: [host: status], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.taskSourceName(original), "Renamed workstation")
        XCTAssertEqual(model.activities, [original])
        await model.shutdown()
    }
    func testLateDeviceNameAlsoReachesRetainedCompletionAndAttentionRows() async throws {
        let model = IslandModel(demo: true)
        let host = "remote-control:fixture", thread = UUID().uuidString.lowercased()
        let at = Date().timeIntervalSince1970 - 2
        var activity = SessionActivity(id: host + ":" + thread, sourceHost: "Remote Control", sourceHostID: host, phaseAwareRate: true)
        activity.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "first", "at": at])
        model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: [])
        activity.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "first", "status": "completed", "at": at + 1])
        model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: [])
        let original = try XCTUnwrap(model.activities.first)
        XCTAssertEqual(original.phase, .completed)
        var status = RuntimeStreamStatus(); status.sourceName = "Workstation"
        model.receiveRemoteUpdate([], statuses: [host: status], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.activities, [original])
        XCTAssertEqual(model.taskSourceName(try XCTUnwrap(model.activities.first)), "Workstation")
        let request = PendingAttentionRequest(id: "question", threadID: thread, sourceHostID: host,
            sourceName: "Remote Control", kind: .input, detectedAt: Date())
        XCTAssertEqual(model.taskSourceName(request.activity), "Workstation")
        let otherProvider = SessionActivity(id: "other", sourceHost: "Claude host", sourceHostID: host, provider: .claude)
        XCTAssertEqual(model.taskSourceName(otherProvider), "Claude host", "Provider labels must not cross source namespaces")
        XCTAssertNil(model.taskSourceName(SessionActivity(id: thread)))
        await model.shutdown()
    }
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
