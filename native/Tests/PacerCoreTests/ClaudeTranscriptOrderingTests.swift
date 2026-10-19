import Foundation
import XCTest
@testable import PacerCore

final class ClaudeTranscriptOrderingTests: XCTestCase {
    private let session = "00000000-0000-4000-8000-000000000001"
    private let prompt = "00000000-0000-4000-8000-000000000002"
    private let now = Date(timeIntervalSince1970: 1_800_000_100)

    private func row(_ type: String, id: String, parent: String? = nil, prompt: String? = nil,
                     second: Int = 0, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["type": type, "sessionId": session, "uuid": id,
            "timestamp": "2027-01-15T08:00:" + String(format: "%02d", second) + "Z"]
        if let parent { value["parentUuid"] = parent }
        if let prompt { value["promptId"] = prompt }
        return value.merging(extra) { _, new in new }
    }
    private var ending: [[String: Any]] {
        [row("user", id: "start", prompt: prompt, extra: ["origin": ["kind": "human"],
            "message": ["role": "user", "content": "PRIVATE synthetic prompt"]]),
         // The attachment was persisted ahead of its parent tool result.
         row("attachment", id: "bridge", parent: "result", second: 3),
         row("assistant", id: "tool", parent: "start", second: 1,
             extra: ["message": ["role": "assistant", "content": [["type": "tool_use", "id": "tool-one", "name": "Bash"]]]]),
         row("user", id: "result", parent: "tool", prompt: prompt, second: 2,
             extra: ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-one", "content": "PRIVATE result"]]]]),
         row("assistant", id: "answer", parent: "bridge", second: 4,
             extra: ["message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "PRIVATE answer"]]]]),
         row("system", id: "stop", parent: "answer", second: 5,
             extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])]
    }
    private func bytes(_ rows: [[String: Any]]) -> Data {
        rows.reduce(into: Data()) { $0.append(ClaudeActivityRecord.encode($1)!); $0.append(10) }
    }
    private func runningState(remote: Bool = false) -> ClaudeActivityState {
        var state = ClaudeActivityState(sourceID: remote ? "synthetic-ssh" : nil, sourceName: nil)
        state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session,
            "promptId": prompt, "at": 1_800_000_000.0])!, now: now)
        return state
    }
    private func ssh(_ program: String, arguments: [String]) throws -> Data {
        let script = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "__name__='fixture'\nimport base64,json,sys,pathlib\nexec(base64.b64decode('" + script + "').decode(),globals())\n" + program] + arguments
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        return data
    }

    func testNativeAndSshEndTheOwnedTurnWhenAnAttachmentPrecedesItsParentAcrossReads() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-order-" + UUID().uuidString)
        let project = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = project.appendingPathComponent(session + ".jsonl")
        let rows = ending
        try bytes([rows[0]]).write(to: file)
        var reader = ClaudeActivityReader(), native = runningState()
        for record in reader.read(home: home, discover: true, now: now).records { native.consume(record, now: now) }
        var projected: [Data] = []
        for row in rows.dropFirst() {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: bytes([row])); try handle.close()
            let result = reader.read(home: home, discover: false, now: now)
            XCTAssertTrue(result.caughtUp)
            projected += result.records
            for record in result.records { native.consume(record, now: now) }
        }
        XCTAssertEqual(native.activities.first?.phase, .completed)
        XCTAssertEqual(native.activities.first?.turnID, prompt)
        XCTAssertFalse(native.activities.first?.isHistoricalCompletion ?? true)
        XCTAssertEqual(reader.scans, 1, "Ordinary append ownership does not need rediscovery")
        XCTAssertFalse(projected.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })

        // Exercise the real SSH Tailer with the same per-append boundaries.
        try bytes([rows[0]]).write(to: file)
        let fixture = home.appendingPathComponent("rows.json")
        try JSONSerialization.data(withJSONObject: Array(rows.dropFirst())).write(to: fixture)
        let program = "tailer=Tailer(pathlib.Path(sys.argv[1]));tailer.discover();chunks=[tailer.read()]\nfor row in json.loads(pathlib.Path(sys.argv[3]).read_text()):\n with open(sys.argv[2],'ab') as stream:stream.write((json.dumps(row)+'\\n').encode())\n tailer.poll();chunks.append(tailer.read())\ntailer.close();print(json.dumps(chunks))\n"
        let output = try ssh(program, arguments: [home.path, file.path, fixture.path])
        let chunks = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [[[String: Any]]])
        var remote = runningState(remote: true)
        for chunk in chunks { remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": chunk])!, now: now) }
        XCTAssertEqual(remote.activities.first?.phase, .completed)
        XCTAssertEqual(remote.activities.first?.turnID, prompt)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("PRIVATE"))

        var historicalReader = ClaudeActivityReader(), history = ClaudeActivityState()
        for record in historicalReader.read(home: home, discover: true, now: now).records { history.consume(record, now: now) }
        XCTAssertEqual(history.activities.first?.phase, .completed)
        XCTAssertTrue(history.activities.first?.isHistoricalCompletion ?? false)
    }

    func testLateParentStaysBoundToItsOriginalPromptAndCannotEndTheNextPrompt() throws {
        let next = "00000000-0000-4000-8000-000000000003"
        let rows = [row("user", id: "old", prompt: prompt),
            row("attachment", id: "bridge", parent: "late"), row("user", id: "new", prompt: next, second: 1),
            row("user", id: "late", parent: "old", prompt: prompt, second: 2),
            row("system", id: "stop", parent: "bridge", second: 3,
                extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])]
        var context = ClaudeTranscriptContext(), state = runningState()
        var resolved: [String?] = []
        for row in rows {
            let raw = ClaudeActivityRecord.encode(row)!
            let owner = context.promptID(for: raw, sessionID: session, parentID: nil)
            resolved.append(owner)
            // Model the independently observed start of the user's next turn.
            if row["uuid"] as? String == "new" {
                state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session,
                    "promptId": next, "at": 1_800_000_001.0])!, now: now)
            }
            for record in ClaudeActivityRecord.transcript(raw, sessionID: session, promptID: owner) { state.consume(record, now: now) }
        }
        XCTAssertEqual(resolved.last!, prompt)
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertEqual(state.activities.first?.turnID, next)
        let data = try ssh("cursor={'session':sys.argv[1],'parent':None}\nrows=json.loads(sys.argv[2]);tailer=Tailer(pathlib.Path('/synthetic'))\nprint(json.dumps([tailer.prompt_context_record(row,cursor) for row in rows]))\ntailer.close()\n",
            arguments: [session, String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)])
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(remote.last as? String, prompt)
        XCTAssertTrue(remote[1] is NSNull, "An unresolved attachment does not borrow the currently active prompt")
    }

    func testMissingForeignCyclicAndEvictedParentsStayUnknownWhileLongOwnedChainsSurvive() throws {
        var context = ClaudeTranscriptContext()
        var records: [[String: Any]] = [], expected: [String?] = []
        func resolve(_ value: [String: Any]) -> String? {
            let owner = context.promptID(for: ClaudeActivityRecord.encode(value)!, sessionID: session, parentID: nil)
            records.append(value); expected.append(owner)
            return owner
        }
        XCTAssertEqual(resolve(row("user", id: "root", prompt: prompt)), prompt)
        XCTAssertNil(resolve(row("attachment", id: "pending", parent: "future")))
        XCTAssertNil(resolve(row("attachment", id: "cycle-a", parent: "cycle-b")))
        XCTAssertNil(resolve(row("attachment", id: "cycle-b", parent: "cycle-a")))
        XCTAssertNil(resolve(row("system", id: "cycle-end", parent: "cycle-b")))
        var foreign = row("user", id: "future", prompt: prompt); foreign["sessionId"] = "foreign-session"
        XCTAssertNil(resolve(foreign))
        XCTAssertNil(resolve(row("system", id: "missing-end", parent: "pending")))
        var parent = "root"
        for i in 0..<600 {
            let id = "chain-\(i)"
            XCTAssertEqual(resolve(row("attachment", id: id, parent: parent)), prompt)
            parent = id
        }
        XCTAssertNil(resolve(row("system", id: "evicted-root", parent: "root")))
        XCTAssertEqual(resolve(row("user", id: "future", prompt: prompt)), prompt)
        XCTAssertNil(resolve(row("system", id: "evicted-pending", parent: "pending")), "An evicted unresolved edge cannot guess ownership")
        context = ClaudeTranscriptContext()
        records.append(["reset": true])
        XCTAssertNil(resolve(row("system", id: "after-gap", parent: parent)), "Resetting after a gap drops all ownership links")
        let fixture = URL(fileURLWithPath: "/private/tmp/pacer-claude-context-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: records).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let program = "cursor={'session':sys.argv[1],'parent':None};tailer=Tailer(pathlib.Path('/synthetic'));owners=[];largest=0\nfor row in json.loads(pathlib.Path(sys.argv[2]).read_text()):\n if row.get('reset'):\n  cursor={'session':sys.argv[1],'parent':None};continue\n owners.append(tailer.prompt_context_record(row,cursor));largest=max(largest,len(cursor.get('context',{})))\ntailer.close();print(json.dumps({'owners':owners,'largest':largest}))\n"
        let output = try ssh(program, arguments: [session, fixture.path])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let owners = try XCTUnwrap(result["owners"] as? [Any]).map { $0 as? String }
        XCTAssertEqual(owners, expected, "SSH and native ownership decisions agree at every boundary")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result["largest"] as? Int), 512)
    }
}
