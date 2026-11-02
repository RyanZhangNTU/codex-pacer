import Foundation
import XCTest
@testable import PacerCore

final class WindowsTelemetryTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Data] = []
        func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return bytes }
    }
    private var python: URL { get throws { URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_TEST_PYTHON"])) } }
    func testLoopbackFragmentedIdentityGzipPortConflictAndImmediateRebind() async throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        XCTAssertGreaterThan(receiver.listeningPort, 0)
        let conflict = ClaudeActivityTelemetry(port: receiver.listeningPort) { _ in XCTFail("Conflicting listener cannot own traffic") }
        XCTAssertThrowsError(try conflict.start())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-telemetry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("request.json")
        let attributes: [[String: Any]] = [
            ["key": "session.id", "value": ["stringValue": "fixture-session"]],
            ["key": "prompt.id", "value": ["stringValue": "fixture-prompt"]],
            ["key": "request_id", "value": ["stringValue": "fixture-request"]],
            ["key": "output_tokens", "value": ["intValue": "160"]],
            ["key": "duration_ms", "value": ["doubleValue": 2000]],
            ["key": "user_prompt", "value": ["stringValue": "PRIVATE_SYNTHETIC"]]
        ]
        let span: [String: Any] = ["name": "claude_code.llm_request", "startTimeUnixNano": "1790000000000000000",
            "endTimeUnixNano": "1790000002000000000", "attributes": attributes]
        try JSONSerialization.data(withJSONObject: ["resourceSpans": [["scopeSpans": [["spans": [span]]]]]]).write(to: file)
        let script = #"""
        import gzip,json,socket,sys
        data=open(sys.argv[2],'rb').read();statuses=[]
        for body,encoding in [(data,'identity'),(gzip.compress(data,mtime=0),'gzip')]:
            with socket.create_connection(('127.0.0.1',int(sys.argv[1])),2) as client:
                client.settimeout(2)
                wire=('POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nContent-Encoding: '+encoding+'\r\nContent-Length: '+str(len(body))+'\r\n\r\n').encode()+body
                for offset in range(0,len(wire),17):client.sendall(wire[offset:offset+17])
                reply=b''
                while True:
                    part=client.recv(4096)
                    if not part:break
                    reply+=part
                statuses.append(int(reply.split(b' ')[1]))
        print(json.dumps(statuses))
        """#
        let result = await WindowsSubprocess.capture(executable: try python,
            arguments: ["-S", "-c", script, String(receiver.listeningPort), WindowsCodexExecutableDiscovery.path(file)], timeout: 5, limit: 4096)
        let statuses = try JSONDecoder().decode([Int].self, from: XCTUnwrap(result))
        XCTAssertEqual(statuses, [200, 200]); XCTAssertEqual(frames.all.count, 2)
        XCTAssertFalse(frames.all.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
        XCTAssertEqual(receiver.counters.httpRequests, 2); XCTAssertEqual(receiver.counters.projectedRequests, 2)
        let port = receiver.listeningPort
        receiver.stop()
        let replacement = ClaudeActivityTelemetry(port: port) { _ in }
        try replacement.start(); XCTAssertEqual(replacement.listeningPort, port); replacement.stop()
    }
    func testStopReleasesEightBlockedSocketsAndRejectsNinthClient() async throws {
        let receiver = ClaudeActivityTelemetry(port: 0) { _ in XCTFail("A partial request cannot project activity") }
        try receiver.start(); defer { receiver.stop() }
        let ready = expectation(description: "eight partial clients held and ninth rejected")
        let released = expectation(description: "all eight readers woke after stop")
        final class Lines: @unchecked Sendable {
            let lock = NSLock(); var pending = Data()
            func receive(_ data: Data, ready: XCTestExpectation, released: XCTestExpectation) {
                lock.lock(); defer { lock.unlock() }; pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); pending.removeSubrange(...end)
                    if line == "ready" { ready.fulfill() }
                    else if line == "released:8" { released.fulfill() }
                    else { XCTFail("Unexpected synthetic socket fixture result") }
                }
            }
        }
        let script = #"""
        import socket,sys
        clients=[]
        for index in range(9):
            client=socket.create_connection(('127.0.0.1',int(sys.argv[1])),2);client.settimeout(2)
            if index<8:client.sendall(b'POST /v1/traces HTTP/1.1\r\n')
            clients.append(client)
        try:assert clients[8].recv(1)==b''
        except ConnectionResetError:pass
        print('ready',flush=True);sys.stdin.readline()
        count=0
        for client in clients[:8]:
            try:
                if client.recv(1)==b'':count+=1
            except ConnectionResetError:count+=1
            client.close()
        clients[8].close();print('released:'+str(count),flush=True)
        """#
        let lines = Lines()
        let child = try WindowsHelperProcessLauncher().launch(.init(executable: try python,
            arguments: ["-S", "-u", "-c", script, String(receiver.listeningPort)], environment: ProcessInfo.processInfo.environment),
            output: { lines.receive($0, ready: ready, released: released) }, ended: {})
        defer { child.close() }
        await fulfillment(of: [ready], timeout: 4)
        XCTAssertEqual(child.errorMessage(), "", "The synthetic socket fixture must reach its ready boundary")
        let started = ProcessInfo.processInfo.systemUptime; receiver.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait)
        try child.write(Data("stopped\n".utf8))
        await fulfillment(of: [released], timeout: 3)
        child.close()
        let exited = await child.waitForExit()
        XCTAssertTrue(exited)
    }
}
