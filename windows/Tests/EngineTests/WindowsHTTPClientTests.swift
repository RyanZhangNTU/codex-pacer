@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK
import XCTest

final class WindowsHTTPClientTests: XCTestCase {
    private func fixture(idleTimeout: TimeInterval = 5, maximumBytes: Int = 1024) throws -> (LoopbackHTTPServer, WindowsHTTPClient) {
        let server = try LoopbackHTTPServer(), port = server.port
        var options = WindowsHTTPClient.Options(idleTimeout: idleTimeout, totalTimeout: 20, maximumBytes: maximumBytes)
        options.proxy = { _ in .success(.winHTTP(nil)) }
        options.target = { url in
            guard WindowsHTTPStream.httpsTarget(url) != nil else { return nil }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            return .init(host: "127.0.0.1", port: port, secure: false,
                         path: components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? ""))
        }
        return (server, WindowsHTTPClient(options))
    }
    private let request = URLRequest(url: URL(string: "https://claude.ai/v1/code/fixture?page=1")!)
    private func until(_ condition: () -> Bool) async throws {
        if try await TestWait.until(condition) { return }
        XCTFail("The loopback WinHTTP request did not finish its bounded operation")
        throw URLError(.timedOut)
    }
    private func processorSeconds() -> TimeInterval {
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) else { return .infinity }
        func seconds(_ time: FILETIME) -> TimeInterval { TimeInterval(UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)) / 10_000_000 }
        return seconds(kernel) + seconds(user)
    }

    /// A URLSession request keeps a thread busy until its response ends; a
    /// request waiting for a slow reply must not use the processor.
    func testPendingRequestWaitsWithoutUsingTheProcessorAndReturnsRedirectsAsResponses() async throws {
        let (server, client) = try fixture(); defer { server.stop() }
        let task = Task { try await client.data(for: request) }
        try await until { server.opened }
        XCTAssertTrue(try XCTUnwrap(server.requests.first).hasPrefix("GET /v1/code/fixture?page=1 HTTP/1.1\r\n"))
        let start = processorSeconds(), clock = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let used = processorSeconds() - start, elapsed = ProcessInfo.processInfo.systemUptime - clock
        XCTAssertLessThan(used, 0.1 * elapsed, "A pending request used \(used) s of CPU in \(elapsed) s")
        server.respond(302, mime: "application/json", headers: ["Location": "https://outside.invalid/", "Retry-After": "30",
                                                               "X-Fixture": "first", "x-fixture": "second", "Content-Length": "2"])
        server.send("{}")
        let (data, response) = try await task.value
        XCTAssertEqual(response.statusCode, 302, "Redirects are returned, never followed")
        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(response.value(forHTTPHeaderField: "retry-after"), "30")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(Set((response.value(forHTTPHeaderField: "X-Fixture") ?? "").components(separatedBy: ", ")), ["first", "second"])
        XCTAssertEqual(server.requests.count, 1)
    }

    func testInvalidationCancelsRequestsInProgressAndLater() async throws {
        let (server, client) = try fixture(); defer { server.stop() }
        let task = Task { try await client.data(for: request) }
        try await until { server.opened }
        client.invalidate()
        do { _ = try await task.value; XCTFail("An invalidated read must fail") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        try await until { server.closed }
        do { _ = try await client.data(for: request); XCTFail("An invalidated client must not read") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertEqual(server.requests.count, 1)

        let (other, live) = try fixture(); defer { other.stop() }
        let cancelled = Task { try await live.data(for: request) }
        try await until { other.opened }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A cancelled read must fail") } catch is CancellationError { }
        try await until { other.closed }
    }

    func testTimeoutsSizeLimitsAndUnsupportedRequestsFailClosed() async throws {
        let (silent, quiet) = try fixture(idleTimeout: 1); defer { silent.stop() }
        let waiting = Task { try await quiet.data(for: request) }
        try await until { silent.opened }; silent.respond(200, mime: "application/json")
        do { _ = try await waiting.value; XCTFail("A silent response must time out") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }

        for declared in [false, true] {
            let (server, client) = try fixture(maximumBytes: 1024); defer { server.stop() }
            let task = Task { try await client.data(for: request) }
            try await until { server.opened }
            server.respond(200, mime: "application/json", headers: declared ? ["Content-Length": "1025"] : [:])
            server.send(Data(repeating: 32, count: declared ? 10 : 1025)); server.finish()
            do { _ = try await task.value; XCTFail("An oversized body must fail") }
            catch let error as URLError { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
            try await until { server.closed }
        }

        let (unused, client) = try fixture(); defer { unused.stop() }
        var post = request; post.httpMethod = "POST"
        var plain = request; plain.url = URL(string: "http://claude.ai/v1/code/fixture")
        for value in [post, plain] {
            do { _ = try await client.data(for: value); XCTFail("An unsupported request reached IO") } catch is URLError { }
        }
        XCTAssertFalse(unused.opened)
    }

    func testPrematureEOFRejectsEvenACompleteJSONPrefix() async throws {
        let body = Data("{\"items\":[]}".utf8)
        for chunked in [false, true] {
            let (server, client) = try fixture(); defer { server.stop() }
            let task = Task { try await client.data(for: request) }
            try await until { server.opened }
            server.respond(200, mime: "application/json", headers: chunked ? ["Transfer-Encoding": "chunked"] : ["Content-Length": "100"])
            if chunked { server.send("64\r\n") }
            server.send(body); server.finish()
            do { _ = try await task.value; XCTFail("An incomplete HTTP body must not become a successful JSON response") }
            catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        }
    }

    func testCompleteBodiesUseWireLengthsAndAllowBodylessStatuses() async throws {
        let body = Data("{\"items\":[]}".utf8), expanded = Data(repeating: 120, count: 1200)
        let gzip = Data([31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 171, 168, 24, 5, 163, 96, 20, 140, 130, 161, 1, 0, 79, 104, 234, 131, 176, 4, 0, 0])
        // WinHTTP's deflate decoder consumes the raw DEFLATE stream.
        let deflate = Data([171, 168, 24, 5, 163, 96, 20, 140, 130, 161, 1, 0])
        let cases: [(Int, [String: String], Data, Data)] = [
            (200, ["Content-Length": String(body.count)], body, body),
            (200, [:], body, body),
            (200, ["Content-Length": "0"], Data(), Data()),
            (204, [:], Data(), Data()),
            (304, ["Content-Length": "100"], Data(), Data()),
            (200, ["Transfer-Encoding": "chunked"], Data("c\r\n{\"items\":[]}\r\n0\r\n\r\n".utf8), body),
            (200, ["Content-Encoding": "gzip", "Content-Length": String(gzip.count)], gzip, expanded),
            (200, ["Content-Encoding": "deflate", "Content-Length": String(deflate.count)], deflate, expanded)]
        for (status, headers, wire, expected) in cases {
            let (server, client) = try fixture(maximumBytes: 2048); defer { server.stop() }
            let task = Task { try await client.data(for: request) }
            try await until { server.opened }; server.respond(status, mime: "application/json", headers: headers)
            server.send(wire); server.finish()
            do {
                let (data, response) = try await task.value
                XCTAssertEqual(response.statusCode, status); XCTAssertEqual(data, expected)
            } catch { XCTFail("Complete response rejected: status=\(status), headers=\(headers), error=\(error)") }
        }
        for truncated in [false, true] {
            let (server, client) = try fixture(maximumBytes: truncated ? 2048 : 1024); defer { server.stop() }
            let task = Task { try await client.data(for: request) }
            try await until { server.opened }
            server.respond(200, mime: "application/json", headers: ["Content-Encoding": "gzip", "Content-Length": truncated ? "100" : String(gzip.count)])
            server.send(gzip); server.finish()
            do { _ = try await task.value; XCTFail("Truncated or oversized decompressed bodies must fail") }
            catch let error as URLError {
                if !truncated { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
            }
        }
    }
}
#endif
