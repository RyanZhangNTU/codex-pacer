import XCTest
@testable import PacerCore

final class CodexLogAttentionTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-0000000000e1"
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ payload: [String: Any], outer: String = "response_item", second: Double) -> [String: Any] {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["type": outer, "timestamp": formatter.string(from: epoch.addingTimeInterval(second)), "payload": payload]
    }
    private func question(_ id: String = "synthetic-call", second: Double = 1) -> [String: Any] {
        let arguments = #"{"questions":[{"title":"PRIVATE question","options":["PRIVATE option"]}]}"#
        return record(["type": "function_call", "name": "request_user_input_async", "call_id": id, "arguments": arguments], second: second)
    }
    private func output(_ id: String = "synthetic-call", accepted: Bool = true, second: Double = 2) -> [String: Any] {
        record(["type": "function_call_output", "call_id": id, "output": accepted ? #"{"accepted":true}"# : #"{"accepted":false}"#], second: second)
    }
    private func start(_ turn: String = "turn-a", second: Double = 0) -> [String: Any] {
        record(["type": "task_started", "turn_id": turn], outer: "event_msg", second: second)
    }
    private func data(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { result, row in result.append(try JSONSerialization.data(withJSONObject: row)); result.append(10) }
    }

    func testAcceptedAsyncQuestionDoesNotPauseTheTurnAndClearsOnUserReply() throws {
        var activity = SessionActivity(id: thread), state = CodexLogAttention()
        func feed(_ value: [String: Any]) {
            activity.consume(value); state.consume(value, activity: activity, now: epoch.addingTimeInterval(100))
        }
        feed(start()); feed(question())
        XCTAssertTrue(state.requests(for: activity).isEmpty, "A tool call alone does not prove a question was accepted")
        feed(output())
        let pending = try XCTUnwrap(state.requests(for: activity).first)
        XCTAssertEqual(pending.kind, .input); XCTAssertEqual(pending.threadID, thread)
        XCTAssertEqual(pending.questionKey, CodexLogAttention.key(thread: thread, turn: "turn-a", call: "synthetic-call"))
        XCTAssertEqual(activity.phase, .running)
        feed(output())
        XCTAssertEqual(state.requests(for: activity).map(\.id), [pending.id], "Repeated output cannot replay a notice")
        XCTAssertFalse(String(reflecting: state).contains("PRIVATE"))
        XCTAssertFalse(String(reflecting: state).contains("synthetic-call"), "Only the hashed call identifier survives")
        feed(record(["type": "message", "role": "assistant", "content": "PRIVATE answer"], second: 3))
        XCTAssertEqual(state.requests(for: activity).count, 1)
        feed(record(["type": "message", "role": "user", "content": "PRIVATE reply"], second: 4))
        XCTAssertTrue(state.requests(for: activity).isEmpty)
        feed(output(second: 5))
        XCTAssertTrue(state.requests(for: activity).isEmpty, "Late acceptance cannot restore an answered question")
    }

    func testTurnChangesEndingsAndRejectedCallsDoNotLeakRequests() {
        var activity = SessionActivity(id: thread), state = CodexLogAttention()
        func feed(_ value: [String: Any]) {
            activity.consume(value); state.consume(value, activity: activity, now: epoch.addingTimeInterval(100))
        }
        feed(start()); feed(question()); feed(output(accepted: false))
        XCTAssertTrue(state.requests(for: activity).isEmpty)
        feed(output())
        XCTAssertTrue(state.requests(for: activity).isEmpty)
        feed(question("second", second: 3)); feed(output("second", second: 4))
        XCTAssertEqual(state.requests(for: activity).count, 1)
        feed(record(["type": "message", "role": "user"], second: 1))
        XCTAssertEqual(state.requests(for: activity).count, 1, "An older message cannot clear a newer question")
        feed(start("turn-b", second: 5)); feed(output("second", second: 6))
        XCTAssertTrue(state.requests(for: activity).isEmpty)
        feed(question("third", second: 7)); feed(output("third", second: 8))
        XCTAssertEqual(state.requests(for: activity).count, 1)
        feed(record(["type": "task_complete", "turn_id": "turn-a"], outer: "event_msg", second: 9))
        XCTAssertEqual(state.requests(for: activity).count, 1, "An old turn's ending cannot clear this turn's question")
        feed(record(["type": "task_complete", "turn_id": "turn-b"], outer: "event_msg", second: 10))
        XCTAssertTrue(state.requests(for: activity).isEmpty)
        feed(output("third", second: 11))
        XCTAssertTrue(state.requests(for: activity).isEmpty)
    }

    func testMalformedUnknownAndOverLimitCallsStayBoundedAndUnconfirmed() {
        var activity = SessionActivity(id: thread), state = CodexLogAttention()
        func feed(_ value: [String: Any]) {
            activity.consume(value); state.consume(value, activity: activity, now: epoch.addingTimeInterval(100))
        }
        feed(start())
        for arguments in ["{broken", #"{"questions":[]}"#, #"{"questions":true}"#, String(repeating: " ", count: 65537)] {
            feed(record(["type": "function_call", "name": "request_user_input_async", "call_id": "invalid", "arguments": arguments], second: 1))
            feed(output("invalid"))
        }
        feed(record(["type": "function_call", "name": "other_tool", "call_id": "other", "arguments": #"{"questions":[{}]}"#], second: 1))
        feed(output("other"))
        XCTAssertTrue(state.requests(for: activity).isEmpty)
        for index in 0..<70 { feed(question("bounded-\(index)", second: 3 + Double(index))); feed(output("bounded-\(index)", second: 3.5 + Double(index))) }
        XCTAssertEqual(state.requests(for: activity).count, 64)
        state.reset(); XCTAssertTrue(state.requests(for: activity).isEmpty)
    }

    func testActualReaderFindsCoveredQuestionsAndDropsThemOnReplyReplacementAndRemoval() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-log-attention-" + UUID().uuidString)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + formatter.string(from: epoch))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = directory.appendingPathComponent("rollout-" + thread + ".jsonl")
        let now = epoch.addingTimeInterval(100), reader = LocalActivityReader()
        try data([start()]).write(to: file)
        _ = await reader.read(home: home, now: now, excludingThreads: [thread], includeCoveredMetrics: true)
        func append(_ rows: [[String: Any]]) throws {
            let stream = try FileHandle(forWritingTo: file)
            try stream.seekToEnd(); try stream.write(contentsOf: data(rows)); try stream.close()
        }
        try append([question(), output()])
        let pending = await reader.read(home: home, now: now, excludingThreads: [thread], includeCoveredMetrics: true, metricsOnly: true)
        XCTAssertEqual(pending.requests.count, 1)
        XCTAssertEqual(pending.activities.first?.phase, .running)
        let unchanged = await reader.read(home: home, now: now, excludingThreads: [thread], includeCoveredMetrics: true, metricsOnly: true)
        XCTAssertEqual(unchanged.requests.map(\.id), pending.requests.map(\.id))
        try append([record(["type": "message", "role": "user", "content": "PRIVATE reply"], second: 3)])
        let replied = await reader.read(home: home, now: now, metricsOnly: true)
        XCTAssertTrue(replied.requests.isEmpty)
        try append([question("new", second: 4), output("new", second: 5)])
        let next = await reader.read(home: home, now: now, metricsOnly: true)
        XCTAssertEqual(next.requests.count, 1)
        let replacement = directory.appendingPathComponent("replacement")
        try data([start("replacement", second: 6), output("new", second: 7)]).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        let replaced = await reader.read(home: home, now: now, metricsOnly: true)
        XCTAssertTrue(replaced.requests.isEmpty)
        try FileManager.default.removeItem(at: file)
        let removed = await reader.read(home: home, now: now)
        XCTAssertTrue(removed.requests.isEmpty)
    }

    func testOtherToolTrafficIsSkippedBeforeAnyCallIsHashed() {
        var activity = SessionActivity(id: thread), state = CodexLogAttention()
        func feed(_ value: [String: Any]) {
            activity.consume(value); state.consume(value, activity: activity, now: epoch.addingTimeInterval(100))
        }
        feed(start())
        for index in 0..<500 {
            feed(record(["type": "function_call", "name": "shell", "call_id": "tool-\(index)", "arguments": "{}"], second: 1))
            feed(output("tool-\(index)", second: 1))
            feed(record(["type": "message", "role": "user", "content": "PRIVATE context"], second: 1))
        }
        XCTAssertEqual(state.keyedRecords, 0, "Unrelated calls, outputs and messages never reach the hash")
        feed(question(second: 2)); feed(output(second: 3))
        XCTAssertEqual(state.keyedRecords, 2)
        XCTAssertEqual(state.requests(for: activity).count, 1)
    }

    func testQuestionMovingBetweenDesktopAndTheLogKeepsOneReminder() {
        func request(_ id: String, call: String? = nil, kind: PendingAttentionRequest.Kind = .input, thread: String? = nil) -> PendingAttentionRequest {
            let thread = thread ?? self.thread
            return PendingAttentionRequest(id: id, threadID: thread, sourceHostID: nil, sourceName: nil, kind: kind, detectedAt: epoch,
                questionKey: call.flatMap { CodexLogAttention.key(thread: thread, turn: "turn-a", call: $0) })
        }
        var policy = AttentionPolicy()
        let logged = request(CodexLogAttention.requestPrefix + "question", call: "question")
        XCTAssertEqual(policy.requestNotices([logged]).count, 1)
        XCTAssertTrue(policy.requestNotices([request("desktop-question", call: "question")]).isEmpty, "Desktop's stream takes over the logged question")
        XCTAssertTrue(policy.requestNotices([logged]).isEmpty, "The fallback takes it back without a second reminder")
        XCTAssertEqual(policy.requestNotices([request("desktop-approval", kind: .approval), logged]).count, 1, "Approvals stay independent")
        XCTAssertEqual(policy.requestNotices([request(CodexLogAttention.requestPrefix + "next")]).count, 1,
            "A different question from the same source still notifies")
        XCTAssertTrue(policy.requestNotices([]).isEmpty)
        XCTAssertEqual(policy.requestNotices([request("desktop-question")]).count, 1)
        XCTAssertEqual(policy.requestNotices([request("desktop-next")]).count, 1)
        XCTAssertEqual(policy.requestNotices([request("desktop-next"), request("desktop-other", thread: "other-thread")]).count, 1)
    }

    func testDifferentCallsAndTurnsNotifyAcrossSourceChangesWithoutAnEmptyUpdate() throws {
        for loggedFirst in [false, true] {
            for (turn, call) in [("turn-a", "next-call"), ("turn-b", "original-call")] {
                func request(logged: Bool, turn: String, call: String) throws -> PendingAttentionRequest {
                    let key = try XCTUnwrap(CodexLogAttention.key(thread: thread, turn: turn, call: call))
                    return PendingAttentionRequest(id: (logged ? CodexLogAttention.requestPrefix : "desktop:") + key,
                        threadID: thread, sourceHostID: nil, sourceName: nil, kind: .input, detectedAt: epoch, questionKey: key)
                }
                var policy = AttentionPolicy()
                let original = try request(logged: loggedFirst, turn: "turn-a", call: "original-call")
                let next = try request(logged: !loggedFirst, turn: turn, call: call)
                XCTAssertEqual(policy.requestNotices([original]).count, 1)
                XCTAssertEqual(policy.requestNotices([next]).count, 1, "A different call or turn must notify even when its source changes")
                XCTAssertTrue(policy.requestNotices([next]).isEmpty, "The new question still notifies only once")
                let same = try request(logged: loggedFirst, turn: turn, call: call)
                XCTAssertTrue(policy.requestNotices([same]).isEmpty, "Only the matching question shares the reminder")
            }
        }
    }

    func testSourceChangesWithoutProvenQuestionIdentityDoNotSuppressNewRequests() {
        var policy = AttentionPolicy()
        func request(_ id: String) -> PendingAttentionRequest {
            PendingAttentionRequest(id: id, threadID: thread, sourceHostID: nil, sourceName: nil, kind: .input, detectedAt: epoch)
        }
        XCTAssertEqual(policy.requestNotices([request(CodexLogAttention.requestPrefix + "old")]).count, 1)
        XCTAssertEqual(policy.requestNotices([request("desktop-new")]).count, 1)
        XCTAssertTrue(policy.requestNotices([request("desktop-new")]).isEmpty)
    }
}
