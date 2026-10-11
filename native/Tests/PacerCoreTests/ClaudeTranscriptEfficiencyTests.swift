import XCTest
@testable import PacerCore

final class ClaudeTranscriptEfficiencyTests: XCTestCase {
    private let session = "aaaaaaaa-1111-4111-8111-111111111111"
    private let turn = "fixture-turn"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func data(_ values: [String: Any]) -> Data { ClaudeActivityRecord.encode(values)! }
    private func fixture(_ kind: String, uuid: String, parent: String? = nil, extra: [String: Any] = [:]) -> Data {
        var value: [String: Any] = ["type": kind, "sessionId": session, "uuid": uuid, "timestamp": "2027-01-15T08:00:00Z"]
        if let parent { value["parentUuid"] = parent }
        return data(value.merging(extra) { _, new in new })
    }
    private func rows(_ values: [Data]) throws -> [[String: Any]] {
        try values.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    func testSharedFieldsPreserveRawWrapperProjectionAndParentOwnershipAcrossLifecycleKinds() throws {
        let prompt = fixture("user", uuid: "user", extra: ["promptId": turn, "origin": ["kind": "human"], "message": ["content": "PRIVATE prompt"]])
        let attachment = fixture("attachment", uuid: "attachment", parent: "user", extra: ["attachment": ["content": String(repeating: "PRIVATE", count: 15_000)]])
        let assistant = fixture("assistant", uuid: "answer", parent: "attachment", extra: ["requestId": "req-1", "message": ["id": "msg-1", "model": "claude-fixture", "stop_reason": "end_turn", "usage": ["output_tokens": 100], "content": [["type": "thinking", "thinking": "PRIVATE reasoning"], ["type": "text", "text": "PRIVATE response"], ["type": "tool_use", "id": "tool", "name": "AskUserQuestion", "input": ["question": "PRIVATE question"]]]]])
        let result = fixture("user", uuid: "result", parent: "answer", extra: ["message": ["content": [["type": "tool_result", "tool_use_id": "tool", "content": "PRIVATE result"]]]])
        let stop = fixture("system", uuid: "stop", parent: "result", extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])
        let interrupt = fixture("user", uuid: "cancel", extra: ["promptId": turn, "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]])
        let spoof = fixture("user", uuid: "human", extra: ["promptId": "next-turn", "origin": ["kind": "human"], "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]])
        let fallback = fixture("user", uuid: "fallback-user", extra: ["origin": ["kind": "human"], "message": ["content": "PRIVATE legacy prompt"]])
        var rawContext = ClaudeTranscriptContext(), sharedContext = ClaudeTranscriptContext()
        let fixtures = [prompt, attachment, assistant, result, stop, interrupt, spoof, fallback]
        let expectedPrompts = [turn, turn, turn, turn, turn, turn, "next-turn", "fallback-user"]
        for (index, bytes) in fixtures.enumerated() {
            let rawPrompt = rawContext.promptID(for: bytes, sessionID: session, parentID: nil)
            let parsed = try XCTUnwrap(ClaudeTranscriptFields(bytes))
            let sharedPrompt = sharedContext.promptID(for: parsed, sessionID: session, parentID: nil)
            XCTAssertEqual(sharedPrompt, expectedPrompts[index]); XCTAssertEqual(rawPrompt, sharedPrompt)
            let raw = ClaudeActivityRecord.transcript(bytes, sessionID: session, promptID: rawPrompt)
            let shared = ClaudeActivityRecord.transcript(parsed, sessionID: session, promptID: sharedPrompt)
            XCTAssertEqual(raw, shared)
            let output = String(decoding: shared.reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
            XCTAssertFalse(output.contains("PRIVATE")); XCTAssertFalse(output.contains("ttft")); XCTAssertFalse(output.contains("firstToken"))
            let kinds = Set(try rows(shared).compactMap { $0["kind"] as? String })
            if index == 2 {
                let block = try XCTUnwrap(try rows(shared).first { $0["kind"] as? String == "modelBlock" })
                XCTAssertEqual(block["outputTokens"] as? Int, 100); XCTAssertEqual(block["requestId"] as? String, "req-1")
                XCTAssertFalse(kinds.contains("stopVerified"))
            }
            if index == 4 { XCTAssertTrue(kinds.contains("stopVerified")) }
            if index == 5 { XCTAssertTrue(kinds.contains("interrupt")) }
            if index == 6 { XCTAssertFalse(kinds.contains("interrupt")) }
        }
    }

    func testSharedParseBoundsAndTypedStopEvidenceRemainFailClosed() throws {
        let malformed = [Data(), Data("[]".utf8), Data("{\"type\":\"user\"}".utf8) + Data(" trailing".utf8),
            Data(repeating: 32, count: ClaudeActivityRecord.maximumBytes + 1),
            Data((String(repeating: "[", count: 70) + "0" + String(repeating: "]", count: 70)).utf8)]
        for bytes in malformed {
            XCTAssertNil(ClaudeTranscriptFields(bytes)); XCTAssertTrue(ClaudeActivityRecord.transcript(bytes, sessionID: session).isEmpty)
            var context = ClaudeTranscriptContext(); XCTAssertNil(context.promptID(for: bytes, sessionID: session, parentID: nil))
        }
        let ownerMismatch = data(["type": "user", "sessionId": "other-session", "uuid": "foreign", "promptId": turn, "timestamp": "2027-01-15T08:00:00Z"])
        let foreign = try XCTUnwrap(ClaudeTranscriptFields(ownerMismatch)); var context = ClaudeTranscriptContext()
        XCTAssertNil(context.promptID(for: foreign, sessionID: session, parentID: nil))
        XCTAssertTrue(ClaudeActivityRecord.transcript(foreign, sessionID: session).isEmpty)
        for extra: [String: Any] in [["hookErrors": "not-array", "hookAdditionalContext": [String]()],
                                    ["hookErrors": ["PRIVATE blocked"], "hookAdditionalContext": [String]()],
                                    ["hookErrors": [String](), "hookAdditionalContext": ["PRIVATE continuation"]],
                                    ["hookErrors": [String](), "hookAdditionalContext": [String](), "preventedContinuation": true]] {
            let common: [String: Any] = ["subtype": "stop_hook_summary", "preventedContinuation": false, "promptId": turn]
            let bytes = fixture("system", uuid: "stop", extra: common.merging(extra) { _, new in new })
            let parsed = try XCTUnwrap(ClaudeTranscriptFields(bytes))
            XCTAssertEqual(ClaudeActivityRecord.transcript(bytes, sessionID: session), ClaudeActivityRecord.transcript(parsed, sessionID: session))
            XCTAssertFalse(try rows(ClaudeActivityRecord.transcript(parsed, sessionID: session)).contains { $0["kind"] as? String == "stopVerified" })
        }
        let child = fixture("user", uuid: "child-user", extra: ["promptId": turn])
        let parsedChild = try XCTUnwrap(ClaudeTranscriptFields(child))
        XCTAssertEqual(context.promptID(for: parsedChild, sessionID: "child", parentID: session), turn)
        XCTAssertTrue(try rows(ClaudeActivityRecord.transcript(parsedChild, sessionID: "child", parentID: session)).allSatisfy { $0["sessionId"] as? String == "child" && $0["parentId"] as? String == session })
    }

    func testActualReaderSharesOneDocumentPerLineAndPreservesParentBindingThroughLargeAttachment() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-transcript-efficiency-" + UUID().uuidString)
        let project = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = project.appendingPathComponent(session + ".jsonl")
        let lines = [fixture("user", uuid: "user", extra: ["promptId": turn]),
                     fixture("attachment", uuid: "attachment", parent: "user", extra: ["attachment": ["content": String(repeating: "PRIVATE", count: 15_000)]]),
                     fixture("assistant", uuid: "answer", parent: "attachment", extra: ["requestId": "req-1", "message": ["id": "msg-1", "usage": ["output_tokens": 100], "content": [["type": "text", "text": "PRIVATE response"]]]]),
                     fixture("system", uuid: "stop", parent: "answer", extra: ["subtype": "stop_hook_summary", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])]
        try lines.reduce(into: Data()) { $0.append($1); $0.append(10) }.write(to: file)
        var reader = ClaudeActivityReader()
        let result = reader.read(home: home, discover: true, now: now)
        XCTAssertTrue(result.caughtUp); XCTAssertEqual(reader.fileReads, 1); XCTAssertEqual(reader.transcriptDocumentParses, lines.count)
        let frames = try rows(result.records), normalized = frames.flatMap { $0["records"] as? [[String: Any]] ?? [$0] }
        XCTAssertTrue(normalized.contains { $0["kind"] as? String == "modelBlock" && $0["promptId"] as? String == turn })
        XCTAssertTrue(normalized.contains { $0["kind"] as? String == "stopVerified" && $0["promptId"] as? String == turn })
        XCTAssertFalse(String(decoding: result.records.reduce(into: Data()) { $0.append($1) }, as: UTF8.self).contains("PRIVATE"))
        _ = reader.read(home: home, discover: false, now: now)
        XCTAssertEqual(reader.fileReads, 1); XCTAssertEqual(reader.transcriptDocumentParses, lines.count)
        reader.reset(); XCTAssertEqual(reader.transcriptDocumentParses, 0)
    }
}
