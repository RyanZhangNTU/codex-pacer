@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsDesktopTransportTests: XCTestCase {
    private final class Fixture {
        let root: URL, executable: URL, ready: URL, endpoint: String
        let process = Process()
        init(_ mode: String) throws {
            executable = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_DESKTOP_PIPE_FIXTURE"]))
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-pipe-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ready = root.appendingPathComponent("ready"); endpoint = "PacerFixture." + UUID().uuidString
            process.executableURL = executable; process.arguments = [mode, endpoint, WindowsCodexExecutableDiscovery.path(ready)]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { try? FileManager.default.removeItem(at: root); throw error }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard FileManager.default.fileExists(atPath: ready.path) else { stop(); throw WindowsDesktopTransport.Failure.unavailable }
        }
        func connect(root: URL? = nil, family: String? = nil) throws -> WindowsDesktopTransport {
            try .init(endpoint: endpoint, peerRoot: root ?? executable.deletingLastPathComponent(), packageFamily: family)
        }
        func stop() {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        var received: Bool { FileManager.default.fileExists(atPath: ready.path + ".received") }
    }
    func testAuthenticatedLocalDuplexPreservesFragmentedUnicodeBytes() throws {
        let fixture = try Fixture("echo"); defer { fixture.stop() }
        let transport = try fixture.connect(); defer { transport.cancel() }
        let peer = try XCTUnwrap(transport.peerIdentity)
        XCTAssertEqual(peer.pid, UInt32(fixture.process.processIdentifier))
        XCTAssertEqual(WindowsProcessOwnership.inspect(peer.pid, started: peer.started)?.identity, peer)
        let bytes = Data(String(repeating: "中文 ✓ fragment\n", count: 40).utf8)
        try transport.write(bytes)
        XCTAssertEqual(try transport.readExactly(bytes.count, deadline: Date().addingTimeInterval(2)), bytes)
        XCTAssertTrue(fixture.received)
    }
    func testFullDuplexCanReadWhileAWriteExceedsThePipeQuota() async throws {
        let fixture = try Fixture("echo"); defer { fixture.stop() }
        let transport = try fixture.connect(); defer { transport.cancel() }
        let bytes = Data(repeating: 65, count: 64 * 1024), completed = expectation(description: "duplex writer finishes")
        DispatchQueue.global().async {
            do { try transport.write(bytes, deadline: Date().addingTimeInterval(5)) }
            catch { XCTFail("The concurrent writer failed: \(error)") }
            completed.fulfill()
        }
        XCTAssertEqual(try transport.readExactly(bytes.count, deadline: Date().addingTimeInterval(5)), bytes)
        await fulfillment(of: [completed], timeout: 6)
    }
    func testPeerPathBoundaryAndPackageIdentityAreCheckedBeforeSending() throws {
        for kind in 0..<3 {
            let fixture = try Fixture("echo"); defer { fixture.stop() }
            let actual = WindowsCodexExecutableDiscovery.path(fixture.executable.deletingLastPathComponent())
            let expected = kind == 0 ? actual + "-wrong" : kind == 1 ? String(actual.dropLast()) : actual
            XCTAssertThrowsError(try fixture.connect(root: URL(fileURLWithPath: expected), family: kind == 2 ? "OpenAI.Codex_2p2nqsd0c76g0" : nil)) {
                XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .identityMismatch)
            }
            XCTAssertFalse(fixture.received, "Rejecting a peer cannot send an initialization or other payload")
        }
    }
    func testTimeoutCompletesItsOverlappedReadBeforeTheNextRead() throws {
        let fixture = try Fixture("echo"); defer { fixture.stop() }
        let transport = try fixture.connect(); defer { transport.cancel() }
        XCTAssertThrowsError(try transport.readExactly(1, deadline: Date().addingTimeInterval(0.05))) {
            XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .timedOut)
        }
        let next = Data([31, 32, 33]); try transport.write(next)
        XCTAssertEqual(try transport.readExactly(next.count, deadline: Date().addingTimeInterval(2)), next)
    }
    func testCancelInterruptsAnIdleReaderAndRemainsIdempotent() async throws {
        let fixture = try Fixture("silent"); defer { fixture.stop() }
        let transport = try fixture.connect(), completed = expectation(description: "owned read cancelled")
        DispatchQueue.global().async {
            do { _ = try transport.readExactly(4); XCTFail("The idle read was not cancelled") }
            catch { XCTAssertEqual(error as? WindowsDesktopTransport.Failure, .cancelled) }
            completed.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000); transport.cancel(); transport.cancel()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertThrowsError(try transport.write(Data([1]))) { XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .cancelled) }
    }
    func testCancelInterruptsAWriterWhenThePeerStopsReading() async throws {
        let fixture = try Fixture("silent"); defer { fixture.stop() }
        let transport = try fixture.connect(), completed = expectation(description: "owned write cancelled")
        DispatchQueue.global().async {
            do { try transport.write(Data(repeating: 65, count: 1024 * 1024)); XCTFail("The blocked write was not cancelled") }
            catch { XCTAssertEqual(error as? WindowsDesktopTransport.Failure, .cancelled) }
            completed.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000); transport.cancel()
        await fulfillment(of: [completed], timeout: 3)
    }
    func testProjectedFrameDropsTranscriptWhileReadingFragmentedPayload() throws {
        let fixture = try Fixture("frame"); defer { fixture.stop() }
        let transport = try fixture.connect(); defer { transport.cancel() }
        let frame = try transport.receive()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.data) as? [String: Any])
        XCTAssertEqual(fields["method"] as? String, "initialize")
        XCTAssertEqual((fields["result"] as? [String: Any])?["clientId"] as? String, "00000000-0000-4000-8000-000000000010")
        XCTAssertFalse(String(decoding: frame.data, as: UTF8.self).contains("PRIVATE-TRANSCRIPT"))
        XCTAssertLessThanOrEqual(frame.peakBufferedBytes, 64 * 1024)
        XCTAssertLessThan(frame.data.count, 1024, "The transport must retain the shared metadata projection, not the wire transcript")
    }
    func testHistoryLargerThanSixteenMegabytesStillAcceptsTheNextCurrentTurnPatch() throws {
        let fixture = try Fixture("large-frame"); defer { fixture.stop() }
        let transport = try fixture.connect(); defer { transport.cancel() }
        var session = try NativeDesktopSession(hosts: ["local"]) { _ in }
        try session.receive(JSONSerialization.data(withJSONObject: ["type": "response", "method": "initialize", "resultType": "success",
            "result": ["clientId": "019a0000-0000-7000-8000-000000000010"]]))
        try session.discover([.init(host: "local", thread: "019a0000-0000-7000-8000-000000000001")]); _ = session.takeFrames()
        let snapshot = try transport.receive()
        XCTAssertLessThan(snapshot.data.count, 4096); XCTAssertLessThanOrEqual(snapshot.peakBufferedBytes, 64 * 1024)
        XCTAssertFalse(String(decoding: snapshot.data, as: UTF8.self).contains("PRIVATE-"))
        try session.receive(snapshot.data, at: Date(timeIntervalSince1970: 1), projectedItems: true)
        XCTAssertEqual(session.retainedItemCount, 1)
        let patch = try transport.receive(observedTurnIDs: ["current"])
        XCTAssertFalse(String(decoding: patch.data, as: UTF8.self).contains("PRIVATE-"))
        try session.receive(patch.data, at: Date(timeIntervalSince1970: 3), projectedItems: true); try session.publishEvents()
        let events = try session.takeFrames().flatMap { bytes in
            (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["events"] as? [[String: Any]] ?? []
        }
        XCTAssertTrue(events.contains { $0["method"] as? String == "turn/attached" && $0["turnId"] as? String == "current" })
        XCTAssertFalse(events.contains { $0["turnId"] as? String == "old" })
        let usage = try XCTUnwrap(events.firstIndex { $0["method"] as? String == "thread/tokenUsage/updated" && $0["cached"] as? Bool != true })
        let completed = try XCTUnwrap(events.firstIndex { $0["method"] as? String == "turn/completed" })
        XCTAssertLessThan(usage, completed)
    }
    func testPeerEofAndTruncatedHeaderHaveBoundedFailures() throws {
        for mode in ["close", "partial-header"] {
            let fixture = try Fixture(mode); defer { fixture.stop() }
            let transport = try fixture.connect(); defer { transport.cancel() }
            if mode == "close" { try transport.write(Data([1])) }
            XCTAssertThrowsError(try transport.receive()) { XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, mode == "close" ? .closed : .timedOut) }
        }
    }
    func testRemoteNamesAndInvalidRootsCannotReachAnEndpoint() {
        let root = FileManager.default.temporaryDirectory
        for name in ["", "../codex-ipc", #"\\remote\pipe\codex-ipc"#, "Pacer/fixture", String(repeating: "x", count: 101)] {
            XCTAssertThrowsError(try WindowsDesktopTransport(endpoint: name, peerRoot: root)) {
                XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .invalidEndpoint)
            }
        }
        XCTAssertThrowsError(try WindowsDesktopTransport(endpoint: "fixture", peerRoot: URL(fileURLWithPath: #"\\untrusted.invalid\share"#))) {
            XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .invalidEndpoint)
        }
        XCTAssertThrowsError(try WindowsDesktopTransport(endpoint: "fixture", peerRoot: URL(string: "https://untrusted.invalid/")!)) {
            XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .invalidEndpoint)
        }
        XCTAssertThrowsError(try WindowsDesktopTransport(endpoint: "fixture", peerRoot: root, packageFamily: "")) {
            XCTAssertEqual($0 as? WindowsDesktopTransport.Failure, .invalidEndpoint)
        }
    }
}
#endif
