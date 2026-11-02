import XCTest
@testable import PacerCore

final class ClaudeTelemetryProjectionTests: XCTestCase {
    private func attributes(_ values: [String: Any]) -> [[String: Any]] {
        values.map { key, value in
            let field: String
            if value is Bool { field = "boolValue" }
            else if value is Int { field = "intValue" }
            else if value is Double { field = "doubleValue" }
            else { field = "stringValue" }
            return ["key": key, "value": [field: value is Int ? String(value as! Int) : value]]
        }
    }

    private func span(_ values: [String: Any] = [:], name: String = "claude_code.llm_request") -> [String: Any] {
        let defaults: [String: Any] = ["session.id": "session-1", "prompt.id": "prompt-1", "request_id": "req_1",
                                      "output_tokens": 160, "duration_ms": 2000.0, "ttft_ms": 240.0,
                                      "first_content_ms": 300.0, "model": "claude-sonnet-4-6", "success": true]
        return ["name": name, "startTimeUnixNano": "1790000000000000000", "endTimeUnixNano": "1790000002000000000",
                "attributes": attributes(defaults.merging(values) { _, supplied in supplied })]
    }

    private func payload(_ spans: [[String: Any]], resource: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resourceSpans": [["resource": ["attributes": attributes(resource)],
                                                                    "scopeSpans": [["spans": spans]]]]])
    }

    private func records(_ data: Data) throws -> [[String: Any]] {
        let frames = try ClaudeActivityTelemetry.frames(data)
        return try frames.flatMap { frame -> [[String: Any]] in
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            XCTAssertEqual(value["kind"] as? String, "claudeBatch")
            return try XCTUnwrap(value["records"] as? [[String: Any]])
        }
    }

    func testProjectsOnlyAuthoritativeNumericRequestsAndNeverPrivateContent() throws {
        var request = span(["agent_id": "agent-2", "parent_agent_id": "agent-1",
                            "user_prompt": String(repeating: "PRIVATE", count: 10_000),
                            "response.model_output": "PRIVATE response", "input_tokens": 9000,
                            "error": "PRIVATE path", "tool_input": "PRIVATE command"])
        request["events"] = [["name": "tool.output", "attributes": attributes(["output": "PRIVATE output"])]]
        let bytes = try payload([request, span(name: "claude_code.interaction"), span(name: "claude_code.tool")],
                                resource: ["user.account_uuid": "PRIVATE account", "user.email": "PRIVATE email"])
        let frames = try ClaudeActivityTelemetry.frames(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(String(decoding: frames[0], as: UTF8.self).contains("PRIVATE"))
        let result = try records(bytes)
        XCTAssertEqual(result.count, 1)
        let record = try XCTUnwrap(result.first)
        XCTAssertEqual(Set(record.keys), ["kind", "sessionId", "promptId", "requestId", "agentId", "parentAgentId", "at",
                                         "startedAt", "durationMs", "outputTokens", "ttftMs", "firstContentMs", "model", "success"])
        XCTAssertEqual(record["kind"] as? String, "request")
        XCTAssertEqual(record["sessionId"] as? String, "session-1")
        XCTAssertEqual(record["agentId"] as? String, "agent-2")
        XCTAssertEqual(record["parentAgentId"] as? String, "agent-1")
        XCTAssertEqual(record["outputTokens"] as? Int, 160)
        XCTAssertEqual(record["durationMs"] as? Double, 2000)
        XCTAssertEqual(record["ttftMs"] as? Double, 240)
        XCTAssertEqual(record["firstContentMs"] as? Double, 300)
        XCTAssertEqual(try XCTUnwrap(record["startedAt"] as? Double), 1_790_000_000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(record["at"] as? Double), 1_790_000_002, accuracy: 0.000001)
    }

    func testResourceIdentifiersAreFallbacksAndSpanIdentifiersTakePrecedence() throws {
        var request = span()
        request["attributes"] = attributes(["request_id": "req-1", "duration_ms": 1500, "output_tokens": 40,
                                            "session.id": "span-session", "gen_ai.request.model": "claude-opus-4-6"])
        let result = try records(payload([request], resource: ["session.id": "resource-session", "prompt.id": "resource-prompt"]))
        let record = try XCTUnwrap(result.first)
        XCTAssertEqual(record["sessionId"] as? String, "span-session")
        XCTAssertEqual(record["promptId"] as? String, "resource-prompt")
        XCTAssertEqual(record["model"] as? String, "claude-opus-4-6")
        XCTAssertNil(record["success"])
    }

    func testFailedMissingOrUnsafeRequestsCannotManufactureMetricsOrCompletion() throws {
        var failedStatus = span()
        failedStatus["status"] = ["code": 2, "message": "PRIVATE failure"]
        var failedNamedStatus = span()
        failedNamedStatus["status"] = ["code": "STATUS_CODE_ERROR", "message": "PRIVATE failure"]
        var missingPrompt = span()
        missingPrompt["attributes"] = attributes(["session.id": "session-1", "request_id": "req-1", "output_tokens": 10, "duration_ms": 100])
        var reversed = span()
        reversed["endTimeUnixNano"] = "1789999999000000000"
        let rows = [span(["success": false]), span(["success": "false"]), failedStatus, failedNamedStatus, missingPrompt, reversed,
                    span(["session.id": "PRIVATE/session"]), span(["request_id": String(repeating: "a", count: 257)]),
                    span(["output_tokens": -1]), span(["output_tokens": 1.5]), span(["duration_ms": 0]),
                    span(name: "claude_code.interaction")]
        XCTAssertTrue(try ClaudeActivityTelemetry.frames(payload(rows)).isEmpty)
        let optionalRows = try records(payload([span(["ttft_ms": -1, "first_content_ms": 9000,
                                                      "agent_id": "bad agent", "model": "PRIVATE model"])]))
        let record = try XCTUnwrap(optionalRows.first)
        XCTAssertNil(record["ttftMs"])
        XCTAssertNil(record["firstContentMs"])
        XCTAssertNil(record["agentId"])
        XCTAssertNil(record["model"])
    }

    func testMalformedSkippedContentAndBoundedPayloadsAreRejectedAtomically() throws {
        let bytes = try payload([span()])
        var text = String(decoding: bytes, as: UTF8.self)
        text.removeLast(); text += #", "PRIVATE":"\uD800"}"#
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(Data(text.utf8)))
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(Data(repeating: 32, count: ClaudeActivityTelemetry.maximumBodyBytes + 1)))
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(payload(Array(repeating: span(), count: 513))))
        var oversized = span()
        oversized["attributes"] = (0..<257).map { ["key": "private-\($0)", "value": ["stringValue": "PRIVATE"]] }
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(payload([oversized])))
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(Data(#"{"resourceSpans":{}}"#.utf8)))
        XCTAssertTrue(try ClaudeActivityTelemetry.frames(Data(#"{"resourceMetrics":[{"PRIVATE":"private"}]}"#.utf8)).isEmpty)
    }

}
