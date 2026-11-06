@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import XCTest
@testable import PacerCore

private final class CompatibilityLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    private var ended = false
    private var error: Error?
    var lines: [Data] { lock.lock(); defer { lock.unlock() }; return values }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }
    func append(_ value: Data) { lock.lock(); values.append(value); lock.unlock() }
    func finish(_ error: Error? = nil) { lock.lock(); self.error = error; ended = true; lock.unlock() }
}

final class WindowsURLSessionCompatibilityTests: XCTestCase {
    private func until(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        guard try await TestWait.until(condition) else {
            XCTFail("The compatibility transport did not finish", file: file, line: line)
            throw URLError(.timedOut)
        }
    }
    private func client(_ fixture: URLSessionHTTPFixture, maximumBytes: Int = 1024, readsBody: @escaping @Sendable (Int) -> Bool = { _ in true }) -> WindowsHTTPClient {
        var options = WindowsHTTPClient.Options(idleTimeout: 5, totalTimeout: 10, maximumBytes: maximumBytes, readsBody: readsBody)
        options.proxy = { _ in WindowsHTTPProxy.forHTTPS(host: "claude.ai", environment: ["ALL_PROXY": "https://127.0.0.1:8443"]) }
        options.target = { _ in .init(host: "127.0.0.1", port: 0, secure: false, path: "/") }
        options.compatibilityConfiguration = { fixture.configuration() }
        return WindowsHTTPClient(options)
    }
    private func stream(_ fixture: URLSessionHTTPFixture) -> AsyncThrowingStream<Data, Error> {
        var options = WindowsClaudeCloudStream.Options()
        options.proxy = { _ in WindowsHTTPProxy.forHTTPS(host: "claude.ai", environment: ["HTTPS_PROXY": "https://fixture:password@127.0.0.1:8443"]) }
        options.target = { _ in .init(host: "127.0.0.1", port: 0, secure: false, path: "/") }
        options.compatibilityConfiguration = { fixture.configuration() }
        return WindowsClaudeCloudStream.lines(options)(fixture.request(URL(string: "https://claude.ai/v1/code/channels/chan_fixture1/messages/stream")!))
    }
    private func consume(_ stream: AsyncThrowingStream<Data, Error>, into result: CompatibilityLines) -> Task<Void, Never> {
        Task { do { for try await line in stream { result.append(line) }; result.finish() } catch { result.finish(error) } }
    }

    func testCompatibilityReadReturnsResponsesWithoutPersistingCookies() async throws {
        let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
        let client = client(fixture)
        let request = fixture.request(URL(string: "https://claude.ai/api/fixture")!)
        for count in 1...2 {
            let task = Task { try await client.data(for: request) }
            try await until { fixture.requests.count == count }
            fixture.respond(302, headers: ["Set-Cookie": "private=fixture", "Location": "https://outside.invalid/", "Retry-After": "30"])
            fixture.send(Data("{}".utf8)); fixture.finish()
            let (data, response) = try await task.value
            XCTAssertEqual(response.statusCode, 302)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Retry-After"), "30")
            XCTAssertEqual(data, Data("{}".utf8))
            XCTAssertFalse(try XCTUnwrap(fixture.requests.last).httpShouldHandleCookies)
            XCTAssertNil(fixture.requests.last?.value(forHTTPHeaderField: "Cookie"))
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testCompatibilityReadKeepsDeclaredAndStreamedBoundsAndCanSkipErrorBodies() async throws {
        for declared in [false, true] {
            let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
            let client = client(fixture), request = fixture.request(URL(string: "https://claude.ai/api/fixture")!)
            let task = Task { try await client.data(for: request) }
            try await until { fixture.opened }
            fixture.respond(headers: declared ? ["Content-Length": "1025"] : [:])
            // Keep the stream open so the size limit must cancel it. A
            // normally completed URLProtocol need not receive stopLoading.
            if !declared { fixture.send(Data(repeating: 32, count: 1025)) }
            do { _ = try await task.value; XCTFail("An oversized compatibility response must fail") }
            catch let error as URLError { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
            try await until { fixture.stopped }
        }
        let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
        let client = client(fixture, readsBody: { $0 == 200 }), request = fixture.request(URL(string: "https://claude.ai/api/fixture")!)
        let task = Task { try await client.data(for: request) }
        try await until { fixture.opened }
        fixture.respond(429, headers: ["Content-Length": "2000", "Retry-After": "30"])
        let (data, response) = try await task.value
        XCTAssertTrue(data.isEmpty); XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Retry-After"), "30")
    }

    func testCancellationAndInvalidationStopCompatibilityReads() async throws {
        for invalidate in [false, true] {
            let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
            let client = client(fixture), request = fixture.request(URL(string: "https://claude.ai/api/fixture")!)
            let task = Task { try await client.data(for: request) }
            try await until { fixture.opened }; fixture.respond()
            if invalidate { client.invalidate() } else { task.cancel() }
            do { _ = try await task.value; XCTFail("A cancelled compatibility read must fail") }
            catch is CancellationError { XCTAssertFalse(invalidate) }
            catch let error as URLError { XCTAssertTrue(invalidate); XCTAssertEqual(error.code, .cancelled) }
            try await until { fixture.stopped }
            if invalidate {
                do { _ = try await client.data(for: request); XCTFail("An invalidated compatibility client must reject new reads") }
                catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
                XCTAssertEqual(fixture.requests.count, 1)
            }
        }
    }

    func testCompatibilityStreamDeliversSplitLinesAndCancelsItsTransport() async throws {
        let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
        let result = CompatibilityLines(), task = consume(stream(fixture), into: result); defer { task.cancel() }
        try await until { fixture.opened }; fixture.respond(mime: "text/event-stream")
        let content = Data("data: 合成回复\n".utf8)
        fixture.send(content.prefix(content.count - 5)); fixture.send(content.suffix(5))
        try await until { result.lines.count == 1 }
        XCTAssertEqual(result.lines, [Data("data: 合成回复".utf8)])
        task.cancel()
        try await until { fixture.stopped && result.finished }
    }

    func testCompatibilityStreamKeepsFailuresAndMemoryLimits() async throws {
        for (code, mime, expected) in [(401, "text/event-stream", ClaudeCloudFailure.signedOut),
                                      (200, "text/html", .challenge), (302, "text/event-stream", .invalidReply)] {
            let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
            let result = CompatibilityLines(), task = consume(stream(fixture), into: result); defer { task.cancel() }
            try await until { fixture.opened }; fixture.respond(code, mime: mime, headers: ["Location": "https://outside.invalid/"])
            try await until { result.finished && fixture.stopped }
            XCTAssertEqual(result.failure as? ClaudeCloudFailure, expected)
            XCTAssertTrue(result.lines.isEmpty)
        }
        for oversized in [false, true] {
            let fixture = URLSessionHTTPFixture(); defer { fixture.close() }
            let stream = stream(fixture)
            try await until { fixture.opened }; fixture.respond(mime: "text/event-stream")
            fixture.send(oversized ? Data(repeating: 120, count: ClaudeCloudLineBuffer.maximumLine + 1) : Data(String(repeating: "fixture\n", count: 1000).utf8))
            try await until { fixture.stopped }
            let result = CompatibilityLines(), task = consume(stream, into: result); defer { task.cancel() }
            try await until { result.finished }
            XCTAssertEqual(result.failure as? ClaudeCloudFailure, oversized ? .invalidReply : .connection)
            XCTAssertLessThan(result.lines.count, 1000)
        }
    }
}
#endif
