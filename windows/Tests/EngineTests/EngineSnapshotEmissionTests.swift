import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private final class IdleFrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; frames.append(data) }
    func snapshots() throws -> [EngineSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return frames.compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }
    }
}

final class EngineSnapshotEmissionTests: XCTestCase {
    func testOnlyEnvelopeAndUnusedReferenceTimeAreIgnored() throws {
        var gate = EngineSnapshotEmission()
        func wire(_ sequence: Int, _ time: Double, _ context: [String: Any] = [:]) throws -> Data {
            var context = context; context["now"] = time
            return try JSONSerialization.data(withJSONObject: ["sequence": sequence, "capturedAt": time,
                "compactContext": context, "notices": [], "tasks": [], "sources": []])
        }
        XCTAssertTrue(try gate.accepts(wire(1, 100)))
        for count in 2...101 { XCTAssertFalse(try gate.accepts(wire(count, Double(count + 100))), "An empty unchanged projection does not emit a heartbeat") }
        XCTAssertTrue(try gate.accepts(wire(102, 300, ["rate": 12, "rateFresh": true])))
        XCTAssertFalse(try gate.accepts(wire(103, 301, ["rateFresh": true, "rate": 12])), "JSON key order does not cause a publication")
        XCTAssertTrue(try gate.accepts(wire(104, 302, ["rate": 12, "rateFresh": false])), "Freshness expiry is a real state change")
    }

    func testEveryProjectedChangeAndNoticeIsRetained() throws {
        let changes: [[String: Any]] = [
            ["quota": [["pacePercent": 80.0, "remainingTimePercent": 60.0]]],
            ["quota": [["pacePercent": 80.1, "remainingTimePercent": 59.9]]],
            ["wallet": ["angle": 123.0]], ["wallet": ["angle": 123.1]],
            ["tasks": [["turnTime": "1m", "unread": true]]], ["tasks": [["turnTime": "2m", "unread": true]]],
            ["tasks": [["turnTime": "2m", "unread": false]]],
            ["activityLinks": [["context": "synthetic-owner-one"]]], ["activityLinks": [["context": "synthetic-owner-two"]]],
            ["modules": [["enabled": false]]], ["sources": [["available": false]]],
            ["claudeConnection": ["context": "synthetic-account-two", "refreshing": true]]
        ]
        var gate = EngineSnapshotEmission()
        for (index, change) in changes.enumerated() {
            var content = change; content["sequence"] = index; content["notices"] = []
            let bytes = try JSONSerialization.data(withJSONObject: content)
            XCTAssertTrue(try gate.accepts(bytes), "Business field changes must reach the host")
            XCTAssertFalse(try gate.accepts(bytes), "An identical state is suppressed")
        }
        let notice = try JSONSerialization.data(withJSONObject: ["notices": [["id": "synthetic", "kind": "completed"]]])
        XCTAssertTrue(try gate.accepts(notice)); XCTAssertTrue(try gate.accepts(notice), "Notification events are never suppressed by state comparison")
    }

    func testSuppressedPublicationsDoNotInvalidateTheDisplayedActionSequence() async throws {
        let capture = IdleFrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        _ = await runtime.receive(try command("retryQuota", ["provider": "codex"]))
        let before = try XCTUnwrap(capture.snapshots().last)
        let count = try capture.snapshots().count
        for _ in 0..<5 { _ = await runtime.receive(try command("setExpanded", ["expanded": false])) }
        XCTAssertEqual(try capture.snapshots().count, count, "An unchanged publication cannot advance the sequence")
        _ = await runtime.receive(try command("markAllRead", ["snapshotSequence": before.sequence]))
        let after = try XCTUnwrap(capture.snapshots().last)
        XCTAssertEqual(after.sequence, before.sequence + 1, "Only emitted frames advance the action sequence")
        XCTAssertFalse(after.tasks.contains(where: \.unread), "The action still acknowledges the displayed ending")
        await runtime.stop()
    }
    func testExplicitDemoRetryRetainsItsSnapshotAcknowledgement() async throws {
        let capture = IdleFrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        for _ in 0..<3 {
            let before = try XCTUnwrap(capture.snapshots().last)
            _ = await runtime.receive(try command("retryQuota", ["provider": "codex"]))
            XCTAssertEqual(try capture.snapshots().last?.sequence, before.sequence + 1, "A user retry keeps its existing snapshot acknowledgement even when values are identical")
        }
        await runtime.stop()
    }
    func testInitializationAlwaysPublishesACompleteInitialState() async throws {
        let capture = IdleFrameCapture()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) }, output: { capture.append($0) })
        let params: [String: Any] = ["enabledProviders": []]
        _ = await runtime.receive(try command("initialize", params))
        let before = try XCTUnwrap(capture.snapshots().last)
        XCTAssertTrue(before.tasks.isEmpty)
        let count = try capture.snapshots().count
        _ = await runtime.receive(try command("initialize", params))
        XCTAssertGreaterThan(try capture.snapshots().count, count, "A fresh initialization cannot inherit the previous consumer's emission cache")
        XCTAssertGreaterThan(try XCTUnwrap(capture.snapshots().last).sequence, before.sequence)
        await runtime.stop()
    }
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
    }
}
