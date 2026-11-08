#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import XCTest
@testable import PacerCore

final class ClaudeCloudReplyStreamTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let project = ClaudeCloudProject(id: "chan_project1", name: "Launch plan", coordinatorSessionID: "cse_coordinator1")
    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    private func data(_ line: String) -> Data { Data(line.utf8) }
    private func parse(_ event: String, _ row: [String: Any], thread: String? = nil) throws -> ClaudeCloudStreamEvent? {
        var parser = ClaudeCloudStreamParser(thread: thread)
        XCTAssertNil(parser.consume(data("event: " + event)))
        return parser.consume(data("data: ") + (try JSONSerialization.data(withJSONObject: row)))
    }

    // MARK: Parsing

    func testAPartialReplyKeepsOnlyNumbersAndItsServerTime() throws {
        let event = try parse("session_partial_reply", ["session_id": "cse_worker1", "thread_root_id": "cmsg_thread1", "tool_use_id": "toolu_1",
            "text": "Private reply", "at": "2026-11-01T02:03:17.957972614Z"])
        guard case let .partialReply(thread, block, tokens, sentAt)? = event else { return XCTFail("not a partial reply") }
        XCTAssertEqual(thread, "cmsg_thread1")
        XCTAssertEqual(block, "toolu_1")
        XCTAssertEqual(tokens, 13 * 0.3, accuracy: 0.001)
        XCTAssertEqual(sentAt?.timeIntervalSince1970 ?? 0, 1_793_498_597.958, accuracy: 0.01, "the server stamps nine fractional digits")
        XCTAssertFalse(String(describing: event).contains("Private"))
    }

    func testACoordinatorsOwnEventsHaveNoThreadAndAThreadsStreamNamesItsOwn() throws {
        let row: [String: Any] = ["session_id": "cse_coordinator1", "thread_root_id": NSNull(), "tool_use_id": "toolu_1", "text": "Short"]
        XCTAssertNil(try parse("session_partial_reply", row), "a project's stream also carries its coordinator")
        XCTAssertNil(try parse("session_activity", ["session_id": "cse_coordinator1", "thread_root_id": NSNull(), "working": true]))
        guard case let .partialReply(thread, _, _, _)? = try parse("session_partial_reply", row, thread: "cmsg_thread1") else { return XCTFail("not a partial reply") }
        XCTAssertEqual(thread, "cmsg_thread1")
    }

    func testAThreadStartsWithItsAnnouncementOrItsSessionWorking() throws {
        XCTAssertEqual(try parse("thread_starting", ["session_id": "cse_coordinator1", "thread_root_id": "cmsg_thread1", "title": "Draft"]),
                       .threadStarting(thread: "cmsg_thread1", session: nil), "this event names the coordinator's session, not the thread's")
        XCTAssertEqual(try parse("session_activity", ["session_id": "cse_worker1", "thread_root_id": "cmsg_thread1", "working": true, "reason": "waking"]),
                       .threadStarting(thread: "cmsg_thread1", session: "cse_worker1"))
        XCTAssertEqual(try parse("session_activity", ["session_id": "cse_worker1", "thread_root_id": "cmsg_thread1", "working": false]),
                       .threadStopped(thread: "cmsg_thread1", session: "cse_worker1"))
        XCTAssertNil(try parse("session_activity", ["session_id": "cse_worker1", "thread_root_id": "cmsg_thread1"]))
    }

    func testMessageBodiesAndOtherLinesAreSkippedUnread() throws {
        XCTAssertNil(try parse("channel_message", ["thread_root_id": "cmsg_thread1", "body": "Private body", "text": "Private text", "tool_use_id": "toolu_1"]))
        var parser = ClaudeCloudStreamParser()
        for line in [":keepalive", "id: cmsg_1", "retry: 1000", "event: session_partial_reply", "data: not json", "data: [1, 2]"] {
            XCTAssertNil(parser.consume(data(line)))
        }
        XCTAssertNil(try parse("session_partial_reply", ["thread_root_id": "not a thread", "tool_use_id": "toolu_1", "text": "Text"]))
        XCTAssertNil(try parse("session_partial_reply", ["thread_root_id": "cmsg_thread1", "text": "No block"]))
    }

    func testLinesSplitOnNewlinesAndOneCannotGrowWithoutBound() throws {
        var buffer = ClaudeCloudLineBuffer()
        var lines: [Data] = []
        for byte in "event: a\r\ndata: b\n\n:ping\n".utf8 { if let line = try buffer.append(byte) { lines.append(line) } }
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["event: a", "data: b", ":ping"])

        var long = ClaudeCloudLineBuffer()
        for _ in 0..<ClaudeCloudLineBuffer.maximumLine { XCTAssertNil(try long.append(65)) }
        XCTAssertThrowsError(try long.append(65))
    }

    func testAStreamMustAnswerWithEventsFromClaude() {
        func response(_ code: Int, type: String = "text/event-stream; charset=utf-8", host: String = "claude.ai", headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://\(host)/v1/code/channels")!, statusCode: code, httpVersion: nil,
                headerFields: ["Content-Type": type].merging(headers) { $1 })!
        }
        XCTAssertNil(ClaudeCloudFailure(streamResponse: response(200), at: base))
        XCTAssertEqual(ClaudeCloudFailure(streamResponse: response(200, type: "text/html"), at: base), .challenge)
        XCTAssertEqual(ClaudeCloudFailure(streamResponse: response(200, host: "example.com"), at: base), .invalidReply)
        XCTAssertEqual(ClaudeCloudFailure(streamResponse: response(401), at: base), .signedOut)
        XCTAssertEqual(ClaudeCloudFailure(streamResponse: response(404), at: base), .notEnabled)
        XCTAssertEqual(ClaudeCloudFailure(streamResponse: response(429, headers: ["Retry-After": "120"]), at: base), .throttled(at(120)))
    }

    func testARefusedStreamWaitsAndAnEndedOneComesBack() {
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: nil, failures: 0, at: base), 2)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .connection, failures: 1, at: base), 5)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .connection, failures: 3, at: base), 20)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .connection, failures: 20, at: base), 300)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .signedOut, failures: 1, at: base), 900)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .challenge, failures: 1, at: base), 900)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .throttled(at(120)), failures: 1, at: base), 120)
        XCTAssertEqual(ClaudeCloudReplyStreams.retryDelay(after: .throttled(nil), failures: 1, at: base), 60)
    }

    // MARK: Estimating

    func testWideCharactersCountAboutThreeTimesLatinOnes() {
        XCTAssertEqual(ClaudeCloudReplyMeter.tokens(in: "潮汐"), 2.18, accuracy: 0.001)
        XCTAssertEqual(ClaudeCloudReplyMeter.tokens(in: "tide"), 1.2, accuracy: 0.001)
        XCTAssertEqual(ClaudeCloudReplyMeter.tokens(in: "潮汐 tide。"), 2.18 + 1.5 + 1.09, accuracy: 0.001)
        XCTAssertEqual(ClaudeCloudReplyMeter.tokens(in: ""), 0)
    }

    /// Writes at a steady rate, in the stream's own steps.
    private func write(_ meter: inout ClaudeCloudReplyMeter, block: String = "b1", from start: TimeInterval, for seconds: TimeInterval, rate: Double, tokens initial: Double = 0) {
        var elapsed = 0.0
        while elapsed <= seconds {
            meter.observe(block: block, tokens: initial + elapsed * rate, at: at(start + elapsed))
            elapsed += 0.44
        }
    }

    func testASteadyReplyReadsAtItsRateOnceItHasRunLongEnough() {
        var meter = ClaudeCloudReplyMeter()
        meter.observe(block: "b1", tokens: 40, at: at(0))
        XCTAssertNil(meter.tokensPerSecond, "the first update only sets where the reply stands")
        meter.observe(block: "b1", tokens: 80, at: at(0.44))
        XCTAssertNil(meter.tokensPerSecond, "half a second is too little to say")
        write(&meter, from: 1, for: 5, rate: 90, tokens: 130)
        XCTAssertEqual(meter.tokensPerSecond ?? 0, 90, accuracy: 3)
    }

    func testAPauseIsNotWritingAndTheEstimateFollowsTheLatestPace() {
        var meter = ClaudeCloudReplyMeter()
        write(&meter, from: 0, for: 4, rate: 100)
        // A long tool call, then the same reply carries on.
        write(&meter, from: 30, for: 4, rate: 100, tokens: 500)
        XCTAssertEqual(meter.tokensPerSecond ?? 0, 100, accuracy: 3, "the 26 seconds between do not lower it")
        // The older pace leaves the window.
        write(&meter, from: 34.5, for: 12, rate: 50, tokens: 900)
        XCTAssertEqual(meter.tokensPerSecond ?? 0, 50, accuracy: 3)
    }

    func testAnotherBlockSharesTheEstimateAndCarriesNoJumpFromTheFirst() {
        var meter = ClaudeCloudReplyMeter()
        write(&meter, block: "b1", from: 0, for: 3, rate: 80)
        write(&meter, block: "b2", from: 3.5, for: 3, rate: 80, tokens: 5)
        XCTAssertEqual(meter.tokensPerSecond ?? 0, 80, accuracy: 3)
    }

    func testAShorterReplyOrAnOlderStampCountsForNothing() {
        var meter = ClaudeCloudReplyMeter()
        write(&meter, from: 0, for: 4, rate: 80)
        let before = meter.tokensPerSecond
        meter.observe(block: "b1", tokens: 10, at: at(4.5))
        XCTAssertEqual(meter.tokensPerSecond, before, "a replaced reply is not negative speed")
        meter.observe(block: "b1", tokens: 900, at: at(1))
        XCTAssertEqual(meter.tokensPerSecond, before, "out of order")
    }

    func testARateNoModelCanReachIsDropped() {
        var meter = ClaudeCloudReplyMeter()
        write(&meter, from: 0, for: 4, rate: 80_000)
        XCTAssertNil(meter.tokensPerSecond)
    }

    // MARK: Rows

    private func thread(_ status: ClaudeCloudThreadStatus, working: Bool = false, unread: Bool = false, reply: TimeInterval = 0, sessions: [String] = ["cse_worker1"]) -> ClaudeCloudThread {
        ClaudeCloudThread(id: "cmsg_thread1", projectID: project.id, status: status, isWorking: working, hasUnread: unread,
            lastReplyAt: at(reply), title: "Draft the outline", sessionIDs: sessions)
    }
    private func snapshot(_ thread: ClaudeCloudThread, coordinator: ClaudeCloudSession.Worker? = nil) -> ClaudeCloudSnapshot {
        var sessions: [String: ClaudeCloudSession] = [:]
        if let coordinator { sessions["cse_coordinator1"] = ClaudeCloudSession(id: "cse_coordinator1", worker: coordinator) }
        return ClaudeCloudSnapshot(projects: [project], threads: [project.id: [thread]], sessions: sessions)
    }
    private func row(_ state: ClaudeCloudProjectState, _ id: String = "cmsg_thread1") -> SessionActivity? { state.activities.first { $0.threadID == id } }
    private func writeReply(_ state: inout ClaudeCloudProjectState, _ id: String = "cmsg_thread1", from start: TimeInterval, rate: Double = 90) {
        for step in 0...10 {
            let elapsed = Double(step) * 0.44
            state.applyReplyProgress(thread: id, block: "b\(Int(start))", tokens: elapsed * rate, sentAt: at(start + elapsed), at: at(start + elapsed))
        }
    }

    func testARunningThreadShowsAnEstimateThatGoesStaleLikeAnyOther() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot(thread(.working, working: true)), at: at(0))
        XCTAssertNil(row(state)?.displayedOutputEstimate(at: at(1)), "nothing written yet")
        writeReply(&state, from: 1)
        let writing = try XCTUnwrap(row(state))
        let live = try XCTUnwrap(writing.displayedOutputEstimate(at: at(6)))
        XCTAssertEqual(live.value, 90, accuracy: 3)
        XCTAssertTrue(live.isFresh)
        XCTAssertTrue(writing.displayedRateIsEstimated(at: at(6)))
        XCTAssertEqual(writing.tokensPerSecond(at: at(6)) ?? 0, 90, accuracy: 3)
        XCTAssertEqual(writing.rateExpiresAt, at(1 + 4.4 + 15))
        // A long tool call: the last value stays, stale, as on a local row.
        XCTAssertEqual(writing.displayedOutputEstimate(at: at(40))?.isFresh, false)
        XCTAssertNil(writing.tokensPerSecond(at: at(40)))
    }

    func testAnEstimateNeverOutlivesTheRunningThread() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot(thread(.working, working: true)), at: at(0))
        writeReply(&state, from: 1)
        state.apply(snapshot(thread(.resolved, unread: true, reply: 20)), at: at(20))
        XCTAssertEqual(row(state)?.phase, .completed)
        XCTAssertNil(row(state)?.displayedOutputEstimate(at: at(21)), "an ending without a result has no speed, not the estimate")
        XCTAssertFalse(state.applyReplyProgress(thread: "cmsg_thread1", block: "late", tokens: 900, sentAt: at(22), at: at(22)))

        state.applyTurnResult(ClaudeCloudTurnResult(id: "event1", completedAt: at(20), outputTokens: 2000, streaming: 25), thread: "cmsg_thread1", at: at(23))
        XCTAssertEqual(row(state)?.displayedOutputEstimate(at: at(23))?.value ?? 0, 80, accuracy: 0.01, "the real speed")

        state.apply(snapshot(thread(.working, working: true, reply: 20)), at: at(40))
        XCTAssertEqual(row(state)?.phase, .running)
        XCTAssertNil(row(state)?.displayedOutputEstimate(at: at(41)), "the new run starts empty")
    }

    func testAnEstimateWaitsOutAQuestionAndARunAfterItStartsEmpty() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot(thread(.working, working: true)), at: at(0))
        writeReply(&state, from: 1)
        state.apply(snapshot(thread(.needsInput, reply: 10)), at: at(10))
        XCTAssertEqual(row(state)?.phase, .waitingForInput)
        XCTAssertFalse(state.applyReplyProgress(thread: "cmsg_thread1", block: "b9", tokens: 900, sentAt: at(11), at: at(11)))
        state.apply(snapshot(thread(.working, working: true, reply: 10)), at: at(30))
        XCTAssertNil(row(state)?.displayedOutputEstimate(at: at(31)))
    }

    func testACoordinatorHasNoEstimateAndNoStream() throws {
        var state = ClaudeCloudProjectState()
        state.apply(snapshot(thread(.working, working: true), coordinator: .running), at: at(0))
        writeReply(&state, "cse_coordinator1", from: 1)
        XCTAssertNil(row(state, "cse_coordinator1")?.displayedOutputEstimate(at: at(6)))
        XCTAssertEqual(state.runningThreads.map(\.thread), ["cmsg_thread1"])
        XCTAssertEqual(state.runningThreads.first?.project, project.id)
        XCTAssertTrue(state.isRunning(thread: "cmsg_thread1"))
        XCTAssertFalse(state.isRunning(thread: "cmsg_other"))
    }

    // MARK: Streams

    private final class FakeStreams: @unchecked Sendable {
        private let lock = NSLock()
        private var open: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]
        private var seen: [URLRequest] = []
        var lines: ClaudeCloudReplyStreams.Lines {
            { [self] request in
                AsyncThrowingStream { continuation in
                    let key = request.url!.absoluteString
                    lock.withLock { open[key] = continuation; seen.append(request) }
                    continuation.onTermination = { [self] _ in lock.withLock { open[key] = nil } }
                }
            }
        }
        var openPaths: Set<String> { lock.withLock { Set(open.keys.map { String($0.dropFirst("https://claude.ai".count)) }) } }
        var requests: [URLRequest] { lock.withLock { seen } }
        func send(_ path: String, _ event: String, _ row: [String: Any]) throws {
            let body = try JSONSerialization.data(withJSONObject: row)
            let continuation = lock.withLock { open["https://claude.ai" + path] }
            continuation?.yield(Data("event: \(event)".utf8))
            continuation?.yield(Data("data: ".utf8) + body)
        }
    }
    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("never happened: " + what)
    }
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ date: Date) { value = date }
        var date: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }
    private final class Sink: @unchecked Sendable { var activities: [SessionActivity] = [] }
    private static func cookies() -> ClaudeWebSession {
        ClaudeWebSession(cookieHeader: "sessionKey=sk-ant-sid01-abcdefghijklmnop", sessionHash: ClaudeQuotaDecoder.digest("sk-ant-sid01-abcdefghijklmnop"),
            organizationID: "00000000-0000-4000-8000-000000000001", userAgent: "Pacer-Test")
    }
    /// A project with one thread that `working` keeps running; the last activity is recent.
    private func monitor(streams: FakeStreams, clock: Box, working: Bool = true, activity: TimeInterval = -60,
                         cookies: @escaping ClaudeWebQuotaClient.CookieProvider = { ClaudeCloudReplyStreamTests.cookies() },
                         local: @escaping ClaudeCloudProjectMonitor.LocalSessions = { [] }) -> ClaudeCloudProjectMonitor {
        let stamp = ISO8601DateFormatter().string(from: base.addingTimeInterval(activity))
        return ClaudeCloudProjectMonitor(cookieProvider: cookies, localSessions: local, transport: { request in
            let path = request.url!.path
            let body: [String: Any]
            if path == "/v1/code/channels" {
                body = ["channels": [["id": "chan_project1", "name": "Launch plan", "overview_session_id": "cse_coordinator1", "last_message_at": stamp]]]
            } else if path.hasSuffix("/threads") {
                body = ["sections": [["data": [["id": "cmsg_thread1", "thread_status": working ? "working" : "resolved", "thread_any_session_working": working,
                                                 "bound_sessions": [["id": "cse_worker1", "title": "Draft"]]]]]]]
            } else {
                body = ["response_shape": ["id": path.hasSuffix("cse_worker1") ? "cse_worker1" : "cse_coordinator1", "worker_status": "idle"]]
            }
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }, streamLines: streams.lines, now: { clock.date })
    }
    private let projectPath = "/v1/code/channels/chan_project1/messages/stream?from=tail&caught_up=true"
    private let threadPath = "/v1/code/channels/chan_project1/messages/stream?scope=thread&thread_id=cmsg_thread1&from=tail&caught_up=true"

    func testAPollFollowsTheProjectAndItsRunningThreadThenPublishesTheEstimate() async throws {
        let streams = FakeStreams(), clock = Box(base), sink = Sink()
        let monitor = monitor(streams: streams, clock: clock)
        await monitor.observe { values, _, _ in sink.activities = values }
        await monitor.pollOnce()
        try await eventually("both streams opened") { streams.openPaths == [projectPath, threadPath] }
        let request = try XCTUnwrap(streams.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-uuid"), "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-client-feature"), "ccr")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(sink.activities.first { $0.threadID == "cmsg_thread1" }?.displayedOutputEstimate(at: base))

        let formatter = ISO8601DateFormatter()
        for step in 0...10 {
            let elapsed = Double(step) * 0.5
            // 150 characters a second, at 0.3 tokens each.
            try streams.send(threadPath, "session_partial_reply", ["thread_root_id": "cmsg_thread1", "tool_use_id": "toolu_1",
                "text": String(repeating: "a", count: step * 75), "at": formatter.string(from: base.addingTimeInterval(elapsed))])
        }
        try await eventually("the estimate reached the row") {
            await monitor.publishSpeed()
            guard let rate = sink.activities.first(where: { $0.threadID == "cmsg_thread1" })?.displayedOutputEstimate(at: base)?.value else { return false }
            return abs(rate - 45) < 1
        }
        await monitor.suspend()
        try await eventually("suspending closes every stream") { streams.openPaths.isEmpty }
        let delay = await monitor.pollOnce()
        XCTAssertEqual(delay, 20)
        try await eventually("a later poll listens again") { streams.openPaths == [projectPath, threadPath] }
        await monitor.shutdown()
    }

    func testAnAnnouncedThreadIsHeardBeforeAnyPollSeesIt() async throws {
        let streams = FakeStreams(), clock = Box(base)
        let monitor = monitor(streams: streams, clock: clock, working: false)
        await monitor.pollOnce()
        try await eventually("the project's stream opened") { streams.openPaths == [projectPath] }
        XCTAssertFalse(streams.openPaths.contains(threadPath), "nothing is running")
        try streams.send(projectPath, "thread_starting", ["session_id": "cse_coordinator1", "thread_root_id": "cmsg_new0001", "title": "Private title"])
        let newThread = "/v1/code/channels/chan_project1/messages/stream?scope=thread&thread_id=cmsg_new0001&from=tail&caught_up=true"
        try await eventually("the new thread's stream opened") { streams.openPaths.contains(newThread) }
        await monitor.shutdown()
        try await eventually("closed") { streams.openPaths.isEmpty }
    }

    func testStartDuringAReadAndStopDuringSleepBothBringTheNextSnapshotForward() async throws {
        actor Replies {
            let old: String
            let fresh: String
            var sessionReads = 0
            var waiting = false
            var firstRead: CheckedContinuation<Void, Never>?
            var latestPhase: ActivityPhase?
            init(old: String, fresh: String) { self.old = old; self.fresh = fresh }
            func endFirstRead() { firstRead?.resume(); firstRead = nil }
            func askQuestion() { waiting = true }
            func update(_ activities: [SessionActivity]) { latestPhase = activities.first?.phase }
            func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = try XCTUnwrap(request.url)
                let body: [String: Any]
                switch url.path {
                case "/v1/code/channels":
                    body = ["channels": [["id": "chan_project1", "name": "Synthetic project", "last_message_at": old]]]
                case "/v1/code/channels/chan_project1/threads":
                    body = ["sections": [["data": [["id": "cmsg_thread1", "thread_status": waiting ? "needs_input" : "idle",
                        "last_reply_at": waiting ? fresh : old, "has_unread": waiting,
                        "bound_sessions": [["id": "cse_worker1"]]]]]]]
                case "/v1/code/sessions/cse_worker1":
                    sessionReads += 1
                    let running = sessionReads > 1 && !waiting
                    if sessionReads == 1 { await withCheckedContinuation { firstRead = $0 } }
                    body = ["session": ["id": "cse_worker1", "worker_status": running ? "running" : "idle"]]
                default:
                    throw ClaudeCloudFailure.invalidReply
                }
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let formatter = ISO8601DateFormatter()
        let replies = Replies(old: formatter.string(from: at(-60)), fresh: formatter.string(from: at(11)))
        let streams = FakeStreams(), clock = Box(base)
        let monitor = ClaudeCloudProjectMonitor(cookieProvider: { Self.cookies() }, transport: { try await replies.respond($0) },
            streamLines: streams.lines, now: { clock.date })
        await monitor.start(expanded: false) { activities, _, _ in await replies.update(activities) }
        defer { Task { await monitor.shutdown() } }

        try await eventually("first session read is suspended") { await replies.firstRead != nil }
        clock.date = at(6)
        await monitor.received(.threadStarting(thread: "cmsg_thread1", session: "cse_worker1"), project: project.id)
        await replies.endFirstRead()
        try await eventually("the unchanged idle thread was checked again") { await replies.latestPhase == .running }
        let reads = await replies.sessionReads
        XCTAssertEqual(reads, 2, "the stream hint bypasses the two-minute interval for this thread")

        try await eventually("project stream opened") { streams.openPaths.contains(projectPath) }
        clock.date = at(12)
        await replies.askQuestion()
        try streams.send(projectPath, "session_activity", ["session_id": "cse_worker1", "thread_root_id": "cmsg_thread1", "working": false])
        try await eventually("a poll confirms the question") { await replies.latestPhase == .waitingForInput }
        let finalReads = await replies.sessionReads
        XCTAssertEqual(finalReads, 3)
        await monitor.shutdown()
    }

    func testAThreadDesktopRunsHereStaysLocal() async throws {
        let streams = FakeStreams(), clock = Box(base)
        let monitor = monitor(streams: streams, clock: clock, working: false, local: { ["worker2"] })
        await monitor.pollOnce()
        try await eventually("the project's stream opened") { streams.openPaths == [projectPath] }
        await monitor.received(.threadStarting(thread: "cmsg_local001", session: "cse_worker2"), project: project.id)
        await monitor.received(.threadStarting(thread: "cmsg_cloud001", session: "cse_worker3"), project: project.id)
        try await eventually("the cloud thread's stream opened") { streams.openPaths.count == 2 }
        XCTAssertFalse(streams.openPaths.contains { $0.contains("cmsg_local001") })
        await monitor.shutdown()
    }

    func testAQuietProjectHasNoStreamAndSigningOutClosesThem() async throws {
        let quiet = FakeStreams(), clock = Box(base)
        let idle = monitor(streams: quiet, clock: clock, working: false, activity: -4 * 24 * 3600)
        await idle.pollOnce()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(quiet.openPaths.isEmpty, "days without activity")
        await idle.shutdown()

        final class Session: @unchecked Sendable { var value: ClaudeWebSession? = ClaudeCloudReplyStreamTests.cookies() }
        let streams = FakeStreams(), session = Session()
        let monitor = monitor(streams: streams, clock: clock, cookies: { session.value })
        await monitor.pollOnce()
        try await eventually("streams opened") { streams.openPaths.count == 2 }
        session.value = nil
        await monitor.pollOnce()
        try await eventually("signing out closes them") { streams.openPaths.isEmpty }
        await monitor.shutdown()
    }

    func testStreamsAreBoundedAndAFinishedThreadLingersThenCloses() async throws {
        let streams = FakeStreams(), clock = Box(base)
        let hub = ClaudeCloudReplyStreams(lines: streams.lines, requests: { path in
            URLRequest(url: URL(string: "https://claude.ai" + path)!)
        }, now: { clock.date })
        let handler: ClaudeCloudReplyStreams.Handler = { _, _ in }
        await hub.follow(projects: (1...6).map { "chan_project\($0)" }, threads: (1...8).map { (project: "chan_project1", thread: "cmsg_thread\($0)") }, handler: handler)
        let counts = await hub.openCount
        XCTAssertEqual(counts.projects, ClaudeCloudReplyStreams.maximumProjects)
        XCTAssertEqual(counts.threads, ClaudeCloudReplyStreams.maximumThreads)
        try await eventually("all connected") { streams.openPaths.count == 10 }
        XCTAssertTrue(streams.openPaths.contains(ClaudeCloudReplyStreams.projectPath("chan_project1")), "the most recent first")
        XCTAssertFalse(streams.openPaths.contains(ClaudeCloudReplyStreams.projectPath("chan_project5")))

        await hub.follow(projects: ["chan_project1"], threads: [(project: "chan_project1", thread: "cmsg_thread1")], handler: handler)
        try await eventually("the unwanted project closed") { streams.openPaths.count == 7 }
        clock.date = at(30)
        await hub.follow(projects: ["chan_project1"], threads: [(project: "chan_project1", thread: "cmsg_thread1")], handler: handler)
        let lingering = await hub.openCount.threads
        XCTAssertEqual(lingering, ClaudeCloudReplyStreams.maximumThreads, "a thread can run again right after it stops")
        clock.date = at(100)
        await hub.follow(projects: ["chan_project1"], threads: [(project: "chan_project1", thread: "cmsg_thread1")], handler: handler)
        let left = await hub.openCount.threads
        XCTAssertEqual(left, 1, "only the one still running")
        try await eventually("closed") { streams.openPaths.count == 2 }
        await hub.stop()
        try await eventually("all closed") { streams.openPaths.isEmpty }
    }
}
