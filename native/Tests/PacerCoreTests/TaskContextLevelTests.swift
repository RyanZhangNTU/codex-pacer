import XCTest
@testable import PacerCore

final class TaskContextLevelTests: XCTestCase {
    private let session = "00000000-0000-4000-8000-000000000015"
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func testWindowValidationAndCodexComplementOfRoundedRemaining() {
        func fraction(_ used: Int, _ capacity: Int) -> Double? {
            TaskContextLevel(used: used, capacity: capacity, at: epoch, codex: true)?.fraction
        }
        XCTAssertNil(fraction(-1, 12_001))
        XCTAssertNil(fraction(1, 0))
        XCTAssertEqual(fraction(0, 12_000), 1)
        XCTAssertEqual(fraction(11_999, 12_200), 0)
        XCTAssertEqual(fraction(12_101, 12_200), 0.50)
        XCTAssertEqual(fraction(13_000, 12_200), 1)
        XCTAssertEqual(TaskContextLevel(used: 105, capacity: 100, at: epoch)?.fraction, 1)
        for invalid: Any in [true, 0.3, 2.0, "100", -1] { XCTAssertNil(TaskContextLevel.count(invalid)) }
    }

    func testClaudeCapacityByFamilyAndSessionSetting() {
        for model in ["claude-fable-5", "claude-opus-4-7", "claude-opus-5-1", "claude-sonnet-5",
                      "claude-haiku-5-5", "claude-haiku-6", "sonnet[1m]"] {
            XCTAssertEqual(TaskContextLevel.claudeCapacity(model: model, extended: false), 1_000_000, model)
        }
        for model in ["claude-sonnet-4-6", "claude-opus-4-6-20260101", "claude-haiku-5-4", "unknown"] {
            XCTAssertEqual(TaskContextLevel.claudeCapacity(model: model, extended: false), 200_000, model)
        }
    }

    func testClaudeMergesTranscriptAndHooksWithoutChangingLifecycle() throws {
        var state = ClaudeActivityState()
        func hook(_ kind: String, _ seconds: Int, turn: String = "turn", model: String? = nil) {
            var row: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": session,
                "promptId": turn, "at": epoch.addingTimeInterval(Double(seconds)).timeIntervalSince1970]
            row["model"] = model
            state.consume(ClaudeActivityRecord.encode(row)!, now: epoch.addingTimeInterval(100))
        }
        func transcript(_ raw: [String: Any], _ seconds: Int) {
            var row = raw
            row["timestamp"] = ISO8601DateFormatter().string(from: epoch.addingTimeInterval(Double(seconds)))
            row["sessionId"] = session
            for data in ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(row)!, sessionID: session) {
                state.consume(data, now: epoch.addingTimeInterval(100))
            }
        }
        func usage(_ model: String, _ input: Int, side: Bool = false, at: Int) {
            transcript(["type": "assistant", "isSidechain": side, "message": ["role": "assistant", "model": model,
                "usage": ["input_tokens": input, "cache_creation_input_tokens": 20,
                          "cache_read_input_tokens": 40, "output_tokens": 4]]], at)
        }
        hook("metadata", 0, model: "sonnet[1m]")
        hook("prompt", 1)
        usage("claude-sonnet-4-6", 100, at: 2)
        let first = try XCTUnwrap(state.activities.first?.contextLevel)
        XCTAssertEqual(first.usedTokens, 164)
        XCTAssertEqual(first.capacityTokens, 1_000_000)
        usage("<synthetic>", 500, at: 3)
        usage("claude-sonnet-5", 900, side: true, at: 4)
        XCTAssertEqual(state.activities.first?.contextLevel, first)
        hook("preCompact", 5)
        let pre = try XCTUnwrap(state.activities.first)
        let since = epoch.addingTimeInterval(5)
        XCTAssertEqual(pre.compactingSince(at: since.addingTimeInterval(599)), since)
        XCTAssertNil(pre.compactingSince(at: since.addingTimeInterval(600)))
        let row = ActivityTaskRowPresentation(activity: pre, unread: false, at: since)
        XCTAssertTrue(row.isCompacting)
        XCTAssertEqual(row.status, L10n.text("activity.compacting_context"))
        XCTAssertEqual(row.contextAccessibilityValue, row.status)
        var off = TaskPresentationOptions()
        off.showContextLevel = false
        let hidden = ActivityTaskRowPresentation(activity: pre, unread: false, options: off, at: since)
        XCTAssertNil(hidden.contextLevel)
        XCTAssertEqual(hidden.status, row.status)
        hook("postCompact", 9)
        XCTAssertNil(state.activities.first?.contextLevel)
        XCTAssertNil(state.activities.first?.compactingSince(at: epoch.addingTimeInterval(10)))
        transcript(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["postTokens": 100, "preTokens": 164]], 8)
        usage("claude-sonnet-4-6", 500, at: 7)
        XCTAssertEqual(state.activities.first?.contextLevel?.usedTokens, 100, "Spool replay precedes transcript replay")
        hook("preCompact", 12)
        XCTAssertEqual(state.activities.first?.contextLevel?.usedTokens, 100)
        transcript(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["postTokens": 77]], 14)
        XCTAssertNil(state.activities.first?.compactingSince(at: epoch.addingTimeInterval(15)))
        hook("preCompact", 16)
        hook("prompt", 20, turn: "next")
        XCTAssertNil(state.activities.first?.compactingSince(at: epoch.addingTimeInterval(20)))
        hook("metadata", 21, model: "sonnet")
        usage("claude-sonnet-4-6", 200_001, at: 22)
        usage("claude-sonnet-4-6", 42, at: 23)
        XCTAssertEqual(state.activities.first?.contextLevel?.capacityTokens, 1_000_000)
    }

    func testRowRetainsEndedLevelAndHidesItForAttentionAndChildren() throws {
        var root = SessionActivity(id: session, sessionID: session)
        root.consume(["type": "event_msg", "timestamp": "2027-01-15T08:00:00Z",
                      "payload": ["type": "task_started", "turn_id": "turn"]])
        root.context.measure(TaskContextLevel(used: 64, capacity: 100, at: epoch))
        let value = try XCTUnwrap(root.contextLevel)
        XCTAssertEqual(value.accessibilityValue, L10n.text("activity.context_used", 64))
        let waiting = ActivityTaskRowPresentation(activity: root, attention: .approval, unread: false, at: epoch)
        XCTAssertNil(waiting.contextLevel)
        root.consume(["type": "event_msg", "timestamp": "2027-01-15T08:00:02Z",
                      "payload": ["type": "task_complete", "turn_id": "turn"]])
        let group = try XCTUnwrap(ActivityTaskGroup.make([root]).first)
        XCTAssertEqual(group.contextLevel, value)
        let row = ActivityTaskRowPresentation(activity: root, group: group, unread: true, at: epoch.addingTimeInterval(2))
        XCTAssertEqual(row.phase, .completed)
        XCTAssertEqual(row.contextLevel, value)
        root.updateParent("00000000-0000-4000-8000-000000000099")
        XCTAssertNil(root.contextLevel)
        var options = ExpandedPanelOptions.decode("{}")
        XCTAssertTrue(options.showContextLevel)
        options.showContextLevel = false
        XCTAssertFalse(ExpandedPanelOptions.decode(options.json).showContextLevel)
    }
}
