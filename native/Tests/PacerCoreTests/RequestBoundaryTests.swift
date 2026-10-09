import XCTest
@testable import PacerCore

final class RequestBoundaryTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ a: inout SessionActivity, _ method: String, _ seconds: Double, _ fields: [String: Any] = [:]) {
        var value: [String: Any] = ["method": method, "threadId": thread, "turnId": "turn", "at": start.addingTimeInterval(seconds).timeIntervalSince1970]
        value.merge(fields) { _, new in new }; a.consumeLive(value)
    }
    private func loggedRequest(source: String?) throws -> SessionActivity {
        var a = SessionActivity(id: thread, sourceHostID: source, phaseAwareRate: true)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func log(_ kind: String, _ seconds: Double, _ payload: [String: Any]) throws {
            a.consume(try JSONSerialization.data(withJSONObject: ["type": kind,
                "timestamp": formatter.string(from: start.addingTimeInterval(seconds)), "payload": payload]))
        }
        try log("event_msg", 0, ["type": "task_started", "turn_id": "turn"])
        try log("response_item", 10, ["type": "custom_tool_call", "call_id": "first", "name": "exec"])
        try log("token_usage_record", 10.05, ["thread_id": thread, "turn_id": "turn", "response_id": "first", "usage": ["output_tokens": 648]])
        try log("response_item", 11, ["type": "custom_tool_call_output", "call_id": "first"])
        try log("response_item", 90, ["type": "reasoning"])
        try log("response_item", 101.506, ["type": "custom_tool_call", "call_id": "second", "name": "exec"])
        try log("token_usage_record", 101.558, ["thread_id": thread, "turn_id": "turn", "response_id": "second", "usage": ["output_tokens": 4238, "reasoning_output_tokens": 1034]])
        return a
    }
    func testNestedToolGapsNeverBecomeRequestDurationBeforeOrAfterToolCompletion() throws {
        for source in [nil, "remote-ssh-discovered:fixture"] as [String?] {
            for delayed in [false, true] {
                var a = SessionActivity(id: thread, sourceHostID: source, phaseAwareRate: true)
                event(&a, "turn/started", 0)
                event(&a, "item/agentMessage/delta", 6.02, ["hasText": true])
                event(&a, "item/started", 10, ["itemId": "first", "itemType": "commandExecution"])
                event(&a, "thread/tokenUsage/updated", 10.05, ["outputTokens": 648, "lastOutputTokens": 648])
                event(&a, "item/completed", 11, ["itemId": "first", "itemType": "commandExecution"])
                event(&a, "item/reasoning/textDelta", 90, ["hasText": true])
                // Relative times from the real 159 ms file-change/command gap.
                event(&a, "item/started", 101.528, ["itemId": "patch", "itemType": "fileChange"])
                event(&a, "item/completed", 101.553, ["itemId": "patch", "itemType": "fileChange"])
                event(&a, "item/started", 101.712, ["itemId": "command", "itemType": "commandExecution"])
                if delayed { event(&a, "item/completed", 103.141, ["itemId": "command", "itemType": "commandExecution"]) }
                event(&a, "thread/tokenUsage/updated", delayed ? 103.142 : 102.714,
                    ["outputTokens": 4886, "lastOutputTokens": 4238, "lastReasoningTokens": 1034])
                let runtime = try XCTUnwrap(a.responsePerformance)
                XCTAssertEqual(runtime.outputTokens, 4238)
                XCTAssertEqual(runtime.duration, 90.528, accuracy: 0.00001)
                XCTAssertEqual(runtime.tokensPerSecond, 4238 / 90.528, accuracy: 0.001)
                if !delayed { event(&a, "item/completed", 103.141, ["itemId": "command", "itemType": "commandExecution"]) }
                a.mergePerformance(from: try loggedRequest(source: source))
                XCTAssertEqual(try XCTUnwrap(a.displayedOutputEstimate(at: start.addingTimeInterval(104))).value, 4238 / 90.506, accuracy: 0.001)
                XCTAssertEqual(a.responsePerformance?.source, .requestUsage)
                XCTAssertEqual(try XCTUnwrap(a.firstTokenLatency), 6.02, accuracy: 0.00001)
                // Next genuine model response starts after the final required tool,
                // not at the earlier file-change result or usage-report time.
                event(&a, "item/reasoning/textDelta", 113.141, ["hasText": true])
                event(&a, "thread/tokenUsage/updated", 113.142, ["outputTokens": 5486, "lastOutputTokens": 600])
                XCTAssertEqual(try XCTUnwrap(a.responsePerformance).duration, 10, accuracy: 0.00001)
            }
        }
    }
    func testAuthoritativeCorrectionReplacesAndCannotReintroduceAnOlderBadCache() throws {
        for source in [nil, "remote-ssh-discovered:fixture"] as [String?] {
            var old = SessionActivity(id: thread, sourceHostID: source, phaseAwareRate: true)
            event(&old, "turn/started", 0); event(&old, "item/agentMessage/delta", 6.02, ["hasText": true])
            event(&old, "item/started", 10, ["itemId": "tool", "itemType": "commandExecution"])
            event(&old, "thread/tokenUsage/updated", 10.05, ["outputTokens": 648, "lastOutputTokens": 648])
            event(&old, "item/completed", 101.553, ["itemId": "tool", "itemType": "commandExecution"])
            // Seed a genuine short window to represent a cached pre-fix estimate.
            event(&old, "item/agentMessage/delta", 101.712, ["hasText": true])
            event(&old, "thread/tokenUsage/updated", 102.714, ["outputTokens": 4886, "lastOutputTokens": 4238])
            XCTAssertEqual(try XCTUnwrap(old.displayedOutputEstimate(at: start.addingTimeInterval(104))).value, 26654.1, accuracy: 0.1)
            var repaired = old
            repaired.mergePerformance(from: try loggedRequest(source: source))
            repaired.mergeDisplayMetadata(from: old)
            repaired.mergePerformance(from: old)
            XCTAssertEqual(try XCTUnwrap(repaired.displayedOutputEstimate(at: start.addingTimeInterval(104))).value, 4238 / 90.506, accuracy: 0.001)
            XCTAssertEqual(repaired.responsePerformance?.source, .requestUsage)
            XCTAssertEqual(repaired.rateExpiresAt, start.addingTimeInterval(116.506))
            XCTAssertFalse(repaired.displayedOutputEstimate(at: start.addingTimeInterval(117))!.isFresh, "Correction cannot refresh the original measurement age")
            var replacement = try loggedRequest(source: source)
            replacement.mergeDisplayMetadata(from: old)
            XCTAssertEqual(try XCTUnwrap(replacement.displayedOutputEstimate(at: start.addingTimeInterval(104))).value, 4238 / 90.506, accuracy: 0.001)
        }
    }
    func testToolOnlyAttachmentAndAmbiguousRequestsDoNotInventSettledRates() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        event(&a, "turn/attached", 0)
        event(&a, "item/started", 1, ["itemId": "a", "itemType": "fileChange"])
        event(&a, "item/completed", 1.02, ["itemId": "a", "itemType": "fileChange"])
        event(&a, "item/started", 1.179, ["itemId": "b", "itemType": "commandExecution"])
        event(&a, "thread/tokenUsage/updated", 2, ["outputTokens": 4238, "lastOutputTokens": 4238])
        XCTAssertNil(a.responsePerformance)
        var meter = ResponsePerformanceMeter(); meter.start(turnID: "turn", at: start, observed: true)
        meter.modelOutput(at: start.addingTimeInterval(1), textDelta: true)
        meter.setWaiting(true, at: start.addingTimeInterval(2)); meter.inputBoundary(at: start.addingTimeInterval(3))
        meter.modelOutput(at: start.addingTimeInterval(4), textDelta: true)
        meter.setWaiting(true, at: start.addingTimeInterval(5))
        meter.observeRuntime(total: 1200, last: 600, reasoning: nil, at: start.addingTimeInterval(6))
        XCTAssertNil(meter.latest, "Unpaired windows cannot be assigned the most recent request's entire usage")
        meter.modelOutput(at: start.addingTimeInterval(6.159), textDelta: true)
        meter.observeRuntime(total: 1800, last: 600, reasoning: nil, at: start.addingTimeInterval(6.16))
        XCTAssertNil(meter.latest, "A dropped window must not seed the next partial request")
        meter.inputBoundary(at: start.addingTimeInterval(7))
        meter.modelOutput(at: start.addingTimeInterval(17), textDelta: true)
        meter.observeRuntime(total: 2400, last: 600, reasoning: nil, at: start.addingTimeInterval(17))
        XCTAssertEqual(meter.latest?.tokensPerSecond, 60, "A newly confirmed request boundary recovers sampling")
    }
}
