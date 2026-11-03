import XCTest
@testable import PacerCore

final class SharedTelemetryTransportTests: XCTestCase {
    private final class Client: TelemetryConnection, @unchecked Sendable {
        private let condition = NSCondition()
        private var input: Data
        private var interrupted = false
        private var reply = Data()
        private let finished: @Sendable () -> Void
        var waitForMore = false
        init(_ input: Data, finished: @escaping @Sendable () -> Void) { self.input = input; self.finished = finished }
        func read(maximumBytes: Int, timeout: TimeInterval) throws -> Data {
            condition.lock(); defer { condition.unlock() }
            if input.isEmpty && waitForMore && !interrupted { _ = condition.wait(until: Date().addingTimeInterval(timeout)) }
            if interrupted { throw TelemetryTransportFailure.closed }
            if input.isEmpty && waitForMore { throw TelemetryTransportFailure.timeout }
            let bytes = Data(input.prefix(min(7, maximumBytes))); input.removeFirst(bytes.count)
            return bytes
        }
        func write(_ data: Data) throws { condition.lock(); reply.append(data); condition.unlock() }
        func interrupt() { condition.lock(); interrupted = true; condition.broadcast(); condition.unlock() }
        func close() { interrupt(); finished() }
        func response() -> String { condition.lock(); defer { condition.unlock() }; return String(decoding: reply, as: UTF8.self) }
    }
    private final class Transport: TelemetryTransport, @unchecked Sendable {
        private final class Listener: TelemetryListener, @unchecked Sendable {
            let port: UInt16 = 4319
            func stop() {}
        }
        private let lock = NSLock()
        private var accepted: (@Sendable (any TelemetryConnection) -> Void)?
        func listen(port: UInt16, backlog: Int, accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws -> any TelemetryListener {
            XCTAssertEqual(backlog, 8)
            lock.lock(); self.accepted = accepted; lock.unlock()
            return Listener()
        }
        func deliver(_ client: Client) { lock.lock(); let callback = accepted; lock.unlock(); callback?(client) }
    }
    private func request(_ body: Data, headers: String = "", method: String = "POST", path: String = "/v1/traces", length: String? = nil) -> Data {
        Data("\(method) \(path) HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(length ?? String(body.count))\r\n\(headers)\r\n".utf8) + body
    }
    func testFragmentedHTTPAndAllFramingRejectionsUseTheSharedParser() async throws {
        let transport = Transport(), body = Data(#"{"resourceSpans":[]}"#.utf8)
        let receiver = ClaudeActivityTelemetry(transport: transport) { _ in XCTFail("Empty spans cannot create activity") }
        try receiver.start(); defer { receiver.stop() }
        let cases: [(Data, Int)] = [
            (request(body), 200),
            (request(body, method: "GET"), 405),
            (request(body, path: "/other"), 404),
            (request(body, headers: "Content-Length: 1\r\n"), 400),
            (request(body, headers: "Transfer-Encoding: chunked\r\n"), 400),
            (request(body, headers: "Content-Encoding: br\r\n"), 415),
            (request(body, length: "-1"), 400),
            (request(body, length: "0"), 413),
            (request(body, length: String(ClaudeActivityTelemetry.maximumBodyBytes + 1)), 413),
            (request(body, length: "1"), 400),
            (request(Data("{".utf8)), 400),
            (Data(("POST /v1/traces HTTP/1.1\r\nX: " + String(repeating: "x", count: ClaudeActivityTelemetry.maximumHeaderBytes) + "\r\n\r\n").utf8), 431)
        ]
        for (bytes, status) in cases {
            let finished = expectation(description: "bounded request completed")
            let client = Client(bytes) { finished.fulfill() }
            transport.deliver(client)
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertTrue(client.response().hasPrefix("HTTP/1.1 \(status) "), "Expected status \(status)")
        }
        XCTAssertEqual(receiver.counters.httpRequests, cases.count - 1)
        XCTAssertEqual(receiver.counters.projectedRequests, 0)
        XCTAssertEqual(receiver.counters.rejectedRequests, cases.count - 1)
    }
    func testEightConnectionLimitStopInterruptsReadersAndLateAcceptsAreClosed() async throws {
        let transport = Transport(), receiver = ClaudeActivityTelemetry(transport: transport) { _ in XCTFail("Partial requests cannot project frames") }
        try receiver.start()
        var clients: [Client] = [], completions: [XCTestExpectation] = []
        for _ in 0..<8 {
            let done = expectation(description: "partial client released")
            let client = Client(Data("POST /v1/traces HTTP/1.1\r\n".utf8)) { done.fulfill() }; client.waitForMore = true
            clients.append(client); completions.append(done); transport.deliver(client)
        }
        let rejected = expectation(description: "ninth connection closed without a worker")
        transport.deliver(Client(Data()) { rejected.fulfill() })
        await fulfillment(of: [rejected], timeout: 1)
        let started = ProcessInfo.processInfo.systemUptime
        receiver.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait)
        await fulfillment(of: completions, timeout: 2)
        XCTAssertEqual(receiver.listeningPort, 0)
        XCTAssertTrue(clients.allSatisfy { $0.response().isEmpty })
        let late = expectation(description: "accept from the stopped generation is rejected")
        transport.deliver(Client(Data()) { late.fulfill() })
        await fulfillment(of: [late], timeout: 1)
    }
}
