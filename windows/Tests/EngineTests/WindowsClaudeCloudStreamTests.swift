@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK
import XCTest
@testable import PacerCore

private final class CloudStreamOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var finishedValue = false
    private var linesValue: [Data] = []
    private var failureValue: Error?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return finishedValue }
    var lines: [Data] { lock.lock(); defer { lock.unlock() }; return linesValue }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return failureValue }
    func line(_ data: Data) { lock.lock(); linesValue.append(data); lock.unlock() }
    func end(_ error: Error? = nil) { lock.lock(); failureValue = error; finishedValue = true; lock.unlock() }
}

final class WindowsClaudeCloudStreamTests: XCTestCase {
    private static let path = "/v1/code/channels/chan_fixture1/messages/stream?from=tail&caught_up=true"

    /// The production stream, with only its connection redirected to `server`.
    private func fixture(idleTimeout: TimeInterval = 4, lifetime: TimeInterval = 60, viaProxy: Bool = false)
        throws -> (LoopbackHTTPServer, ClaudeCloudReplyStreams.Lines, URLRequest) {
        let server = try LoopbackHTTPServer()
        var options = WindowsClaudeCloudStream.Options()
        options.idleTimeout = idleTimeout; options.lifetime = lifetime
        let port = server.port
        options.proxy = { _ in .success(viaProxy ? "127.0.0.1:\(port)" : nil) }
        options.target = { url in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            return viaProxy ? .init(host: "pacer-fixture.invalid", port: 80, secure: false, path: path)
                : .init(host: "127.0.0.1", port: port, secure: false, path: path)
        }
        var request = URLRequest(url: URL(string: "https://claude.ai" + Self.path)!)
        request.setValue("sessionKey=synthetic-fixture", forHTTPHeaderField: "Cookie")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("PacerFixture/1", forHTTPHeaderField: "User-Agent")
        return (server, WindowsClaudeCloudStream.lines(options), request)
    }
    private func consume(_ stream: AsyncThrowingStream<Data, Error>, into outcome: CloudStreamOutcome) -> Task<Void, Never> {
        Task { do { for try await line in stream { outcome.line(line) }; outcome.end() } catch { outcome.end(error) } }
    }
    private func until(_ condition: () -> Bool) async throws {
        if try await TestWait.until(condition) { return }
        XCTFail("The loopback WinHTTP stream did not finish its bounded operation")
        throw URLError(.timedOut)
    }
    private func processorSeconds() -> TimeInterval {
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) else { return .infinity }
        func seconds(_ time: FILETIME) -> TimeInterval { TimeInterval(UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)) / 10_000_000 }
        return seconds(kernel) + seconds(user)
    }

    func testActualTransportDeliversSplitUtf8LinesAndCancellationClosesTheConnection() async throws {
        let (server, lines, request) = try fixture(); defer { server.stop() }
        let result = CloudStreamOutcome(), task = consume(lines(request), into: result); defer { task.cancel() }
        try await until { server.opened }
        let head = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(head.hasPrefix("GET \(Self.path) HTTP/1.1\r\n"))
        XCTAssertTrue(head.contains("\r\nCookie: sessionKey=synthetic-fixture\r\n"))
        XCTAssertTrue(head.contains("\r\nAccept: text/event-stream\r\n"))
        XCTAssertEqual(head.components(separatedBy: "User-Agent:").count, 2, "The agent is sent exactly once")
        XCTAssertTrue(head.contains("\r\nUser-Agent: PacerFixture/1\r\n"))
        server.respond()
        let content = Data("event: fixture\r\ndata: 合成回复\n\n".utf8), split = content.count - 5
        server.send(content.prefix(split)); try await Task.sleep(nanoseconds: 50_000_000)
        server.send(content.suffix(content.count - split)); server.finish()
        try await until { result.finished }
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.lines.compactMap { String(data: $0, encoding: .utf8) }, ["event: fixture", "data: 合成回复"])

        let (second, secondLines, secondRequest) = try fixture(); defer { second.stop() }
        let pending = CloudStreamOutcome(), waiting = consume(secondLines(secondRequest), into: pending)
        try await until { second.opened }; waiting.cancel()
        try await until { second.closed && pending.finished }
        XCTAssertTrue(pending.lines.isEmpty)
    }

    /// FoundationNetworking keeps polling an open response on Windows; the
    /// stream must instead wait for data without using the processor.
    func testOpenIdleStreamWaitsWithoutUsingTheProcessor() async throws {
        let (server, lines, request) = try fixture(idleTimeout: 30); defer { server.stop() }
        let result = CloudStreamOutcome(), task = consume(lines(request), into: result); defer { task.cancel() }
        try await until { server.opened }
        server.respond(); server.send(": keepalive\nevent: ready\n")
        try await until { result.lines.count == 2 }
        let start = processorSeconds(), clock = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let used = processorSeconds() - start, elapsed = ProcessInfo.processInfo.systemUptime - clock
        XCTAssertLessThan(used, 0.1 * elapsed, "An idle open stream used \(used) s of CPU in \(elapsed) s")
        XCTAssertFalse(result.finished)
        server.send("data: after idle\n")
        try await until { result.lines.count == 3 }
        task.cancel()
        try await until { server.closed }
    }

    func testStatusRedirectAndHtmlFailuresAreTypedAndNeverDeliverResponseContent() async throws {
        let cases: [(Int, String, [String: String], ClaudeCloudFailure)] = [
            (401, "text/event-stream", [:], .signedOut), (403, "text/event-stream", [:], .denied),
            (200, "text/html", [:], .challenge), (404, "text/event-stream", [:], .notEnabled),
            (429, "text/event-stream", ["Retry-After": "120"], .throttled(nil)),
            (302, "text/event-stream", ["Location": "https://claude.ai" + Self.path], .invalidReply)]
        for (code, mime, headers, expected) in cases {
            let (server, lines, request) = try fixture(); defer { server.stop() }
            let result = CloudStreamOutcome(), task = consume(lines(request), into: result); defer { task.cancel() }
            try await until { server.opened }
            server.respond(code, mime: mime, headers: headers); server.send("data: private\n")
            try await until { result.finished }
            if case .throttled = expected {
                guard case .throttled(let date) = result.failure as? ClaudeCloudFailure else { XCTFail("Expected throttling"); continue }
                XCTAssertNotNil(date, "Retry-After reaches the shared failure mapping")
            } else { XCTAssertEqual(result.failure as? ClaudeCloudFailure, expected) }
            XCTAssertTrue(result.lines.isEmpty)
            try await until { server.closed }
            XCTAssertEqual(server.requests.count, 1, "Redirects are never followed")
        }
    }

    func testOversizedLinesAndSlowConsumersStopTheTransport() async throws {
        for oversized in [false, true] {
            let (server, lines, request) = try fixture(); defer { server.stop() }
            let stream = lines(request)
            try await until { server.opened }; server.respond()
            server.send(oversized ? Data(repeating: 120, count: ClaudeCloudLineBuffer.maximumLine + 1) : Data(String(repeating: "fixture\n", count: 1000).utf8))
            try await until { server.closed }
            let result = CloudStreamOutcome(), task = consume(stream, into: result); defer { task.cancel() }
            try await until { result.finished }
            XCTAssertEqual(result.failure as? ClaudeCloudFailure, oversized ? .invalidReply : .connection)
            XCTAssertLessThan(result.lines.count, 1000, "A stalled consumer cannot accumulate an unbounded stream")
        }
    }

    func testSilentConnectionsAndExpiredStreamsEnd() async throws {
        let (silent, silentLines, silentRequest) = try fixture(idleTimeout: 1); defer { silent.stop() }
        let quiet = CloudStreamOutcome(), quietTask = consume(silentLines(silentRequest), into: quiet); defer { quietTask.cancel() }
        try await until { silent.opened }; silent.respond()
        try await until { quiet.finished && silent.closed }
        XCTAssertEqual(quiet.failure as? ClaudeCloudFailure, .connection)

        let (busy, busyLines, busyRequest) = try fixture(idleTimeout: 5, lifetime: 1); defer { busy.stop() }
        let result = CloudStreamOutcome(), task = consume(busyLines(busyRequest), into: result); defer { task.cancel() }
        try await until { busy.opened }; busy.respond()
        let sender = Task { while !Task.isCancelled { busy.send(": keepalive\n"); try? await Task.sleep(nanoseconds: 100_000_000) } }
        defer { sender.cancel() }
        try await until { result.finished && busy.closed }
        XCTAssertEqual(result.failure as? ClaudeCloudFailure, .connection)
    }

    func testForeignOriginsMethodsPathsAndHeadersNeverReachTheNetwork() async throws {
        let (server, lines, request) = try fixture(); defer { server.stop() }
        var foreign: [URLRequest] = []
        for address in ["http://claude.ai/v1/code/channels/chan_fixture1/messages/stream", "https://claude.ai.example.test/v1/code/channels/chan_fixture1/messages/stream",
                        "https://claude.ai:444/v1/code/channels/chan_fixture1/messages/stream", "https://user@claude.ai/v1/code/channels/chan_fixture1/messages/stream",
                        "https://claude.ai/api/organizations"] {
            var value = request; value.url = URL(string: address); foreign.append(value)
        }
        var write = request; write.httpMethod = "POST"; foreign.append(write)
        for value in foreign {
            let result = CloudStreamOutcome(), task = consume(lines(value), into: result); defer { task.cancel() }
            try await until { result.finished }; XCTAssertEqual(result.failure as? ClaudeCloudFailure, .invalidReply)
        }
        XCTAssertFalse(server.opened)
        // URLRequest already drops some unsafe values; the transport rejects
        // any that would start another header or line.
        XCTAssertEqual(WindowsHTTPStream.headerBlock([("Accept", "text/event-stream"), ("Cookie", "a=b\tc")]),
                       Array("Accept: text/event-stream\r\nCookie: a=b\tc".utf16) + [0])
        for header in [("anthropic-client-feature", "ccr\r\nX-Injected: 1"), ("Cookie", "a\nb"), ("Cookie", "a\u{0}b"),
                       ("Bad Name", "value"), ("Bad:Name", "value"), ("", "value")] {
            XCTAssertNil(WindowsHTTPStream.headerBlock([header]), header.0)
        }
    }

    func testProxyFollowsTheCurlEnvironmentAndIsNeverBypassed() async throws {
        func proxy(_ environment: [String: String]) -> String?? {
            guard case .success(let value) = WindowsHTTPProxy.forHTTPS(host: "claude.ai", environment: environment) else { return .none }
            return .some(value)
        }
        XCTAssertEqual(proxy([:]), .some(nil))
        XCTAssertEqual(proxy(["HTTPS_PROXY": "http://127.0.0.1:7890"]), .some("127.0.0.1:7890"))
        XCTAssertEqual(proxy(["https_proxy": "127.0.0.2:8000/", "HTTPS_PROXY": "127.0.0.3:8000"]), .some("127.0.0.2:8000"))
        XCTAssertEqual(proxy(["Https_Proxy": "proxy.example.test"]), .some("proxy.example.test:1080"))
        XCTAssertEqual(proxy(["ALL_PROXY": "http://[::1]:3128"]), .some("[::1]:3128"))
        XCTAssertEqual(proxy(["HTTPS_PROXY": "http://127.0.0.1:7890", "NO_PROXY": "example.test, .claude.ai"]), .some(nil))
        XCTAssertEqual(proxy(["HTTPS_PROXY": "http://127.0.0.1:7890", "no_proxy": "*"]), .some(nil))
        XCTAssertEqual(proxy(["HTTPS_PROXY": "http://127.0.0.1:7890", "NO_PROXY": "laude.ai,claude.ai.example.test"]), .some("127.0.0.1:7890"))
        for unusable in ["socks5://127.0.0.1:1080", "http://user:secret@127.0.0.1:8080", "https://127.0.0.1:8443", "http://127.0.0.1:8080/path", "::1:80"] {
            XCTAssertEqual(proxy(["HTTPS_PROXY": unusable]), .none, unusable)
        }

        let (server, lines, request) = try fixture(viaProxy: true); defer { server.stop() }
        let result = CloudStreamOutcome(), task = consume(lines(request), into: result); defer { task.cancel() }
        try await until { server.opened }
        XCTAssertTrue(try XCTUnwrap(server.requests.first).hasPrefix("GET http://pacer-fixture.invalid\(Self.path) HTTP/1.1\r\n"))
        server.respond(); server.send("data: proxied\n"); server.finish()
        try await until { result.finished }
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.lines, [Data("data: proxied".utf8)])

        // An unusable proxy fails before any connection, never falling back to a direct one.
        var refused = WindowsClaudeCloudStream.Options(); refused.proxy = { _ in .failure(.failed) }
        let blocked = CloudStreamOutcome(), blockedTask = consume(WindowsClaudeCloudStream.lines(refused)(request), into: blocked)
        defer { blockedTask.cancel() }
        try await until { blocked.finished }
        XCTAssertEqual(blocked.failure as? ClaudeCloudFailure, .connection)
    }
}
#endif
