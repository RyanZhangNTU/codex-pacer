import Foundation
import XCTest
@testable import PacerCore

/// WorkBuddy's agent logs say what a task does as it happens, and its
/// transcript can grow by hundreds of kilobytes a second while a model writes
/// files; neither may leave a running task without its turn or live state.
final class WorkBuddyRunLogTests: XCTestCase {
    private let session = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-workbuddy-" + UUID().uuidString, isDirectory: true)

    override func setUpWithError() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// The log's own time format: local time, twelve-hour, in Chinese.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = WorkBuddyRunLog.localZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let hour = c.hour ?? 0, twelve = hour % 12 == 0 ? 12 : hour % 12
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "[\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 \(hour < 12 ? "上午" : "下午")\(twelve):\(two(c.minute)):\(two(c.second)).\(String(format: "%03d", (c.nanosecond ?? 0) / 1_000_000))]"
    }

    static func transition(_ session: String, _ event: String, to: String, at date: Date, extra: String = "") -> String {
        stamp(date) + " [info] [pid=62836] [Agent]  [SessionRunStateMachine] transition | sessionId=\(session) | event=\(event)" +
            " | from=previous | to=\(to) | lifecycle=running | busy=true | queueBusy=true | elapsedSinceLastTransitionMs=1830" + extra + "\r\n"
    }

    func testReadsOnlyTheSessionStageAndTimeOfATransition() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000.12)
        let entry = try XCTUnwrap(WorkBuddyRunLog.parse(Data(Self.transition(session, "MODEL_STREAM_STARTED", to: "model_streaming", at: at).utf8), near: at))
        XCTAssertEqual(entry.session, session.lowercased())
        XCTAssertEqual(entry.stage, .model, "A stream without a tool is the model thinking or writing")
        XCTAssertEqual(entry.at?.timeIntervalSince1970 ?? 0, at.timeIntervalSince1970, accuracy: 0.002)
        let writing = Self.transition(session, "MODEL_STREAM_STARTED", to: "model_streaming", at: at, extra: " | streamingToolName=Write")
        XCTAssertEqual(WorkBuddyRunLog.parse(Data(writing.utf8), near: at)?.stage, .tool, "Writing a tool call counts as the tool")
        let stages: [(String, String, WorkBuddyRunLog.Stage?)] = [
            ("RUN_PREPARING", "preparing", .starting), ("RUN_ACCEPTED", "pending", .starting), ("AGENT_STARTED", "agent_running", .starting),
            ("MODEL_REQUEST_STARTED", "model_requesting", .model), ("MODEL_RESPONSE_DONE", "model_done", .model),
            ("TOOL_STARTED", "tool_executing", .tool), ("TOOL_ENDED", "agent_running", .model),
            ("WAITING_FOR_PERMISSION", "waiting_for_permission", .permission), ("AGENT_ENDED", "idle", .ended),
            ("SOMETHING_NEW", "tool_streaming", .tool), ("SOMETHING_NEW", "model_retrying", .model), ("SOMETHING_NEW", "unknown", nil),
        ]
        for (event, to, stage) in stages { XCTAssertEqual(WorkBuddyRunLog.stage(event: event, to: to, writingTool: false), stage, event + " " + to) }
        for line in ["[2026年11月15日 下午10:05:24.120] [info] [Agent] transition | sessionId=\(session) | event=AGENT_STARTED",
                     Self.transition("not-a-session", "AGENT_STARTED", to: "agent_running", at: at)] {
            XCTAssertNil(WorkBuddyRunLog.parse(Data(line.utf8), near: at), "Only a run-state transition of a real session counts")
        }
        // Each region's own format, as WorkBuddy writes it with toLocaleString.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = WorkBuddyRunLog.localZone
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, _ fraction: Double = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second)))
                .addingTimeInterval(fraction)
        }
        let near = try local(11, 15, 12, 0, 0)
        let readings: [(String, Date)] = [
            ("[2026年11月15日 上午12:00:01.000] x", try local(11, 15, 0, 0, 1)),
            ("[2026年11月15日 下午12:00:01.000] x", try local(11, 15, 12, 0, 1)),
            ("[2026年11月15日 下午10:05:20.514] x", try local(11, 15, 22, 5, 20, 0.514)),
            ("[11/15/2026, 1:54:39 PM.902] [Info] x", try local(11, 15, 13, 54, 39, 0.902)),
            ("[11/15/2026, 12:04:39 AM] x", try local(11, 15, 0, 4, 39)),
            ("[15/11/2026, 13:54:39] x", try local(11, 15, 13, 54, 39)),
            ("[15.11.2026, 13:54:39.250] x", try local(11, 15, 13, 54, 39, 0.25)),
            ("[2026/11/15 13:54:39] x", try local(11, 15, 13, 54, 39)),
            ("[2026. 11. 15. 오후 1:54:39] x", try local(11, 15, 13, 54, 39)),
        ]
        for (text, expected) in readings {
            XCTAssertEqual(WorkBuddyRunLog.time(Substring(text), near: near)?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001, text)
        }
        // Day and month that could swap: the reading nearer the file's last write.
        XCTAssertEqual(WorkBuddyRunLog.time("[11/12/2026, 9:00:00 AM] x", near: try local(11, 12, 10, 0, 0)), try local(11, 12, 9, 0, 0))
        XCTAssertEqual(WorkBuddyRunLog.time("[11/12/2026, 9:00:00 AM] x", near: try local(12, 11, 10, 0, 0)), try local(12, 11, 9, 0, 0))
        XCTAssertEqual(WorkBuddyRunLog.time("[2026-11-15T14:05:20.500Z] x", near: near)?.timeIntervalSince1970 ?? 0, 1_794_751_520.5, accuracy: 0.001)
        for text in ["2026年11月15日 下午10:05:24 no brackets", "[Info] [pid=1]", "[11/31/26, 9:00:00] x", "[13/13/2026, 9:00:00] x"] {
            XCTAssertNil(WorkBuddyRunLog.time(Substring(text), near: near), text)
        }
    }

    func testFollowsTheNewestAgentLogsAndReportsOnlyANewStage() throws {
        // A task's process is named after its folder; WorkBuddy's own new-task folders by date and time.
        let hash = "b2eb422995fae081350043745df65c69"
        for name in ["2026-11-15-22-05-19", "my_project", "__workbuddy_cli_host", "", "workbuddyMainThread", "unknown-workspace"] {
            XCTAssertTrue(WorkBuddyRunLog.isAgentLog(name + "__" + hash + ".log"), name)
        }
        for name in ["2026-11-15-22-05-19__\(hash).old.log", "AppStartup.log", "extension-scheduler-diag.log",
                     "2026-11-15-22-05-19_\(hash).log", "2026-11-15-22-05-19__\(hash.dropLast()).log", "2026-11-15-22-05-19__\(hash).txt"] {
            XCTAssertFalse(WorkBuddyRunLog.isAgentLog(name), name)
        }
        let files = TestFileSystem(), now = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = WorkBuddyRunLog.localZone; formatter.dateFormat = "yyyy-MM-dd"
        let day = folder.appendingPathComponent("logs/" + formatter.string(from: now), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let log = day.appendingPathComponent("2026-11-15-22-05-19__" + String(repeating: "b", count: 32) + ".log")
        let other = day.appendingPathComponent("extension-scheduler-diag.log")
        // Startup chatter fills most of a process's log before its first transition.
        let chatterLine = Self.stamp(now.addingTimeInterval(-10)) + " [info] [pid=1] [Startup] loading plugins\r\n"
        let chatter = String(repeating: chatterLine, count: 12_000)
        try Data((chatter + Self.transition(session, "AGENT_STARTED", to: "agent_running", at: now.addingTimeInterval(-3))).utf8).write(to: log)
        try Data(Self.transition(session, "TOOL_STARTED", to: "tool_executing", at: now).utf8).write(to: other)
        var reader = WorkBuddyRunLog()
        XCTAssertTrue(reader.read(home: folder, files: files, now: now, within: 900))
        XCTAssertEqual(reader.sessions[session.lowercased()]?.stage, .starting, "Only agent logs count, read from their end")
        let handle = try FileHandle(forWritingTo: log)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(repeating: chatterLine, count: 50) + Self.transition(session, "AGENT_STARTED", to: "agent_running", at: now.addingTimeInterval(-2))).utf8))
        XCTAssertFalse(reader.read(home: folder, files: files, now: now, within: 900), "Chatter and the same stage ask for no read")
        // A partly written line waits for its end.
        let streaming = Self.transition(session, "MODEL_STREAM_STARTED", to: "model_streaming", at: now.addingTimeInterval(-1))
        try handle.write(contentsOf: Data(streaming.prefix(60).utf8))
        XCTAssertFalse(reader.read(home: folder, files: files, now: now, within: 900))
        try handle.write(contentsOf: Data(streaming.dropFirst(60).utf8))
        XCTAssertTrue(reader.read(home: folder, files: files, now: now, within: 900))
        XCTAssertEqual(reader.sessions[session.lowercased()]?.stage, .model)
        // A burst larger than the tail still ends on its latest transition.
        try handle.write(contentsOf: Data((chatter + Self.transition(session, "TOOL_STARTED", to: "tool_executing", at: now, extra: " | toolName=Bash")).utf8))
        try handle.close()
        XCTAssertTrue(reader.read(home: folder, files: files, now: now, within: 900))
        XCTAssertEqual(reader.sessions[session.lowercased()]?.stage, .tool)
        // An older line never replaces a newer state.
        let earlier = Self.transition(session, "AGENT_ENDED", to: "idle", at: now.addingTimeInterval(-30))
        let append = try FileHandle(forWritingTo: log)
        _ = try append.seekToEnd(); try append.write(contentsOf: Data(earlier.utf8)); try append.close()
        XCTAssertFalse(reader.read(home: folder, files: files, now: now, within: 900))
        XCTAssertEqual(reader.sessions[session.lowercased()]?.stage, .tool)
        XCTAssertEqual(WorkBuddyRunLog.recentLogs(home: folder, files: files, now: now.addingTimeInterval(3600), within: 900), [],
                       "Logs untouched for longer than a task lives are not followed")
    }

    func testATranscriptKeepsItsTurnThroughABurstAndAFirstReadFindsItFarBack() throws {
        let file = folder.appendingPathComponent(session + ".jsonl"), files = TestFileSystem(), now = Date()
        var stamp = Int64(now.timeIntervalSince1970 * 1000) - 60_000
        func line(_ fields: [String: Any], request: String) throws -> Data {
            var row = fields
            row["sessionId"] = session; row["timestamp"] = stamp; stamp += 10
            var metadata: [String: Any] = ["conversationRequestId": request]
            if fields["role"] as? String == "user" { metadata["startsNewUserRequest"] = true }
            row["providerData"] = metadata
            return try JSONSerialization.data(withJSONObject: row) + Data([10])
        }
        // A tool call that writes a web page holds the whole page.
        let page = String(repeating: "<div class=\"PRIVATE\">x</div>", count: 5_000)
        var tail = "u2"
        func write(_ call: String, request: String = "r2") throws -> Data {
            let data = try line(["type": "function_call", "name": "Write", "id": call, "parentId": tail, "callId": call + "-call",
                                 "arguments": ["content": page]], request: request) +
                line(["type": "function_call_result", "status": "completed", "id": call + "-result", "parentId": call, "callId": call + "-call"], request: request)
            tail = call + "-result"
            return data
        }
        let old = try line(["type": "message", "role": "user", "id": "u1"], request: "r1")
        let opening = try line(["type": "message", "role": "user", "id": "u2"], request: "r2")
        try (old + opening).write(to: file)
        var transcript = WorkBuddyTranscript()
        try transcript.read(file, session: session, files: files, now: now)
        XCTAssertEqual(transcript.turn?.id, "r2")
        // More than 256 KB between two reads, as WorkBuddy wrote on 11/15.
        let burst = try write("w1") + write("w2") + write("w3")
        XCTAssertGreaterThan(burst.count, 400 * 1024)
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd(); try handle.write(contentsOf: burst)
        try transcript.read(file, session: session, files: files, now: now)
        XCTAssertEqual(transcript.turn?.id, "r2", "A burst never loses the request that opened the turn")
        XCTAssertEqual(transcript.turn?.calls, [])
        let open = try line(["type": "function_call", "name": "Bash", "id": "b1", "parentId": tail, "callId": "b1-call"], request: "r2")
        try handle.write(contentsOf: open); try handle.close()
        try transcript.read(file, session: session, files: files, now: now)
        XCTAssertEqual(transcript.turn?.calls, ["b1-call"], "The chain continues after the burst")
        // Pacer starting while the turn runs reads back to its request.
        var fresh = WorkBuddyTranscript()
        try fresh.read(file, session: session, files: files, now: now)
        XCTAssertEqual(fresh.turn?.id, "r2")
        XCTAssertEqual(fresh.turn?.calls, ["b1-call"])
        XCTAssertFalse(String(describing: fresh.turn).contains("PRIVATE"))
        // Without a request in reach, the reader still waits for the next one.
        let orphan = folder.appendingPathComponent("orphan.jsonl")
        tail = "none"
        try (write("o1") + write("o2")).write(to: orphan)
        var lost = WorkBuddyTranscript()
        try lost.read(orphan, session: session, files: files, now: now)
        XCTAssertNil(lost.turn)
        XCTAssertNil(try WorkBuddyTranscript.latestRequest(in: orphan, size: UInt64(try Data(contentsOf: orphan).count), files: files))
    }
}
