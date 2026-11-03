@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import XCTest
@testable import PacerCore

private final class CloudStreamFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudStreamProtocol?
    private var stoppedValue = false
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stoppedValue }
    func open(_ value: CloudStreamProtocol) { lock.lock(); self.value = value; lock.unlock() }
    func stop() { lock.lock(); stoppedValue = true; lock.unlock() }
    private func protocolValue() -> CloudStreamProtocol? { lock.lock(); defer { lock.unlock() }; return value }
    func respond(_ code: Int = 200, mime: String = "text/event-stream", headers: [String: String] = [:]) {
        guard let value = protocolValue() else { return }
        value.client?.urlProtocol(value, didReceive: HTTPURLResponse(url: value.request.url!, statusCode: code, httpVersion: nil,
            headerFields: headers.merging(["Content-Type": mime]) { first, _ in first })!, cacheStoragePolicy: .notAllowed)
    }
    func data(_ value: Data) { guard let item = protocolValue() else { return }; item.client?.urlProtocol(item, didLoad: value) }
    func finish() { guard let item = protocolValue() else { return }; item.client?.urlProtocolDidFinishLoading(item) }
}
private final class CloudStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CloudStreamFixture] = [:]
    func put(_ id: String, _ value: CloudStreamFixture?) { lock.lock(); values[id] = value; lock.unlock() }
    func get(_ id: String) -> CloudStreamFixture? { lock.lock(); defer { lock.unlock() }; return values[id] }
}
private final class CloudStreamProtocol: URLProtocol {
    static let registry = CloudStreamRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Fixture-ID") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.registry.get(request.value(forHTTPHeaderField: "X-Fixture-ID") ?? "")?.open(self) }
    override func stopLoading() { Self.registry.get(request.value(forHTTPHeaderField: "X-Fixture-ID") ?? "")?.stop() }
}
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
    private func fixture() -> (String, CloudStreamFixture, ClaudeCloudReplyStreams.Lines, URLRequest) {
        let id = UUID().uuidString, site = CloudStreamFixture()
        CloudStreamProtocol.registry.put(id, site)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudStreamProtocol.self]
        configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 4
        var request = URLRequest(url: URL(string: "https://claude.ai/v1/code/channels/chan_fixture1/messages/stream?from=tail&caught_up=true")!)
        request.setValue(id, forHTTPHeaderField: "X-Fixture-ID")
        request.setValue("sessionKey=synthetic-fixture", forHTTPHeaderField: "Cookie")
        return (id, site, WindowsClaudeCloudStream.lines(configuration: configuration), request)
    }
    private func consume(_ stream: AsyncThrowingStream<Data, Error>, into outcome: CloudStreamOutcome) -> Task<Void, Never> {
        Task { do { for try await line in stream { outcome.line(line) }; outcome.end() } catch { outcome.end(error) } }
    }
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("The intercepted FoundationNetworking stream did not finish its bounded operation")
        throw URLError(.timedOut)
    }
    func testActualSessionDeliversSplitUtf8LinesAndCancelsOwnedTransport() async throws {
        let (id, site, lines, request) = fixture(); defer { CloudStreamProtocol.registry.put(id, nil) }
        let result = CloudStreamOutcome(), task = consume(lines(request), into: result); defer { task.cancel() }
        try await until { site.opened }; site.respond()
        let content = Data("event: fixture\r\ndata: 合成回复\n\n".utf8), split = content.count - 5
        site.data(content.prefix(split)); site.data(content.suffix(content.count - split)); site.finish()
        try await until { result.finished }
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.lines.compactMap { String(data: $0, encoding: .utf8) }, ["event: fixture", "data: 合成回复"])

        let (secondID, secondSite, secondLines, secondRequest) = fixture(); defer { CloudStreamProtocol.registry.put(secondID, nil) }
        let pending = consume(secondLines(secondRequest), into: .init()); defer { pending.cancel() }
        try await until { secondSite.opened }; pending.cancel()
        try await until { secondSite.stopped }
    }
    func testStatusAndHtmlFailuresAreTypedAndNeverDeliverResponseContent() async throws {
        for (code, mime, expected) in [(401, "text/event-stream", ClaudeCloudFailure.signedOut),
                                      (403, "text/event-stream", .denied), (200, "text/html", .challenge)] {
            let (id, site, lines, request) = fixture(); defer { CloudStreamProtocol.registry.put(id, nil) }
            let result = CloudStreamOutcome(), task = consume(lines(request), into: result); defer { task.cancel() }
            try await until { site.opened }; site.respond(code, mime: mime)
            try await until { result.finished }
            XCTAssertEqual(result.failure as? ClaudeCloudFailure, expected); XCTAssertTrue(result.lines.isEmpty)
        }
    }
    func testOversizedLinesAndSlowConsumersStopTheTransport() async throws {
        for oversized in [false, true] {
            let (id, site, lines, request) = fixture(); defer { CloudStreamProtocol.registry.put(id, nil) }
            let stream = lines(request)
            try await until { site.opened }; site.respond()
            site.data(oversized ? Data(repeating: 120, count: ClaudeCloudLineBuffer.maximumLine + 1) : Data(String(repeating: "fixture\n", count: 1000).utf8))
            try await until { site.stopped }
            let result = CloudStreamOutcome(), task = consume(stream, into: result); defer { task.cancel() }
            try await until { result.finished }
            XCTAssertEqual(result.failure as? ClaudeCloudFailure, oversized ? .invalidReply : .connection)
            XCTAssertLessThan(result.lines.count, 1000, "A stalled consumer cannot accumulate an unbounded stream")
        }
    }
    func testForeignOriginsMethodsAndPathsNeverReachTheNetwork() async throws {
        let (id, site, lines, request) = fixture(); defer { CloudStreamProtocol.registry.put(id, nil) }
        for address in ["http://claude.ai/v1/code/channels/chan_fixture1/messages/stream", "https://claude.ai.example.test/v1/code/channels/chan_fixture1/messages/stream",
                        "https://claude.ai:444/v1/code/channels/chan_fixture1/messages/stream", "https://user@claude.ai/v1/code/channels/chan_fixture1/messages/stream",
                        "https://claude.ai/api/organizations"] {
            var foreign = request; foreign.url = URL(string: address)
            let result = CloudStreamOutcome(), task = consume(lines(foreign), into: result); defer { task.cancel() }
            try await until { result.finished }; XCTAssertEqual(result.failure as? ClaudeCloudFailure, .invalidReply)
        }
        var write = request; write.httpMethod = "POST"
        let result = CloudStreamOutcome(), task = consume(lines(write), into: result); defer { task.cancel() }
        try await until { result.finished }; XCTAssertEqual(result.failure as? ClaudeCloudFailure, .invalidReply)
        XCTAssertFalse(site.opened)
    }
    func testRedirectDelegateRejectsEvenSameOriginRedirects() {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://claude.ai/v1/code/channels/chan_fixture1/messages/stream")!
        let task = session.dataTask(with: url); defer { task.cancel() }
        let delegate = WindowsClaudeCloudStream()
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                            newRequest: URLRequest(url: url)) { request in called = true; XCTAssertNil(request) }
        XCTAssertTrue(called)
    }
}
#endif
