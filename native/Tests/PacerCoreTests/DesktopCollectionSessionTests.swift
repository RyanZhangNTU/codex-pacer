import Foundation
import XCTest
@testable import PacerCore

final class DesktopCollectionSessionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1000)
    func testHandshakeDeadlineAndHeartbeatUseTheInjectedServiceTime() throws {
        var stalled = try DesktopCollectionSession(hosts: ["local"], at: epoch) { _ in }
        try stalled.service(at: epoch)
        XCTAssertEqual(stalled.nextServiceDate, epoch.addingTimeInterval(5))
        XCTAssertThrowsError(try stalled.service(at: epoch.addingTimeInterval(5.01))) { error in
            XCTAssertTrue(error is DesktopCollectionSession.Failure)
        }
        var ready = try DesktopCollectionSession(hosts: ["local"], at: epoch) { _ in }
        try ready.receive(JSONSerialization.data(withJSONObject: ["type": "response", "method": "initialize",
            "resultType": "success", "result": ["clientId": "019a0000-0000-7000-8000-000000000010"]]))
        try ready.service(at: epoch)
        XCTAssertEqual(ready.nextServiceDate, epoch.addingTimeInterval(15))
        XCTAssertFalse(ready.takeFrames().isEmpty)
        try ready.service(at: epoch.addingTimeInterval(14))
        XCTAssertTrue(ready.takeFrames().isEmpty)
        try ready.service(at: epoch.addingTimeInterval(15))
        XCTAssertFalse(ready.takeFrames().isEmpty)
        XCTAssertEqual(ready.nextServiceDate, epoch.addingTimeInterval(30))
    }
    func testEofFlushAndHostRemovalRetainTheSameSessionProtocol() throws {
        final class Sent { var values: [[String: Any]] = [] }
        let sent = Sent(), thread = "019a0000-0000-7000-8000-000000000001"
        let host = "remote-control:env_fixture", client = "019a0000-0000-7000-8000-000000000010"
        var session = try DesktopCollectionSession(hosts: ["local", host], at: epoch) { sent.values.append($0) }
        func bytes(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        try session.receive(bytes(["type": "response", "method": "initialize", "resultType": "success", "result": ["clientId": client]]))
        try session.discover([.init(host: host, thread: thread)])
        XCTAssertTrue(sent.values.contains { ($0["params"] as? [String: Any])?["conversationId"] as? String == thread })
        try session.setHosts(["local"])
        XCTAssertEqual(session.hosts, ["local"])
        XCTAssertTrue(sent.values.contains { ($0["params"] as? [String: Any])?["following"] as? Bool == false })
        try session.setHosts(["local", host], resetting: [host])
        XCTAssertEqual(session.hosts, ["local", host])
        let frames = session.finish(flush: true)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(session.takeFrames().isEmpty)
    }
}
