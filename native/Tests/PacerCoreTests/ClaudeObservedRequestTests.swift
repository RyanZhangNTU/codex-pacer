import XCTest
@testable import PacerCore

final class ClaudeObservedRequestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    func testRepeatedUsageOnThinkingAndTextSettlesOnceAtLastBlockWithoutFirstOutput() throws {
        var meter = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: start)
        meter.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 256, toolIDs: [], at: at(1))
        meter.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 256, toolIDs: [], at: at(4))
        meter.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 256, toolIDs: [], at: at(4))
        XCTAssertTrue(meter.settled(at: at(3)).isEmpty)
        let sample = try XCTUnwrap(meter.settled(at: at(5)).first)
        XCTAssertEqual(meter.settled(at: at(5)).count, 1)
        XCTAssertEqual(sample.outputTokens, 256); XCTAssertEqual(sample.tokensPerSecond, 64)
        XCTAssertEqual(sample.completedAt, at(4)); XCTAssertEqual(sample.source, .observedRequest)
    }
    func testUnknownStartGapOrConflictingMessageCannotManufactureRate() {
        var attached = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: nil)
        attached.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 100, toolIDs: [], at: at(2))
        XCTAssertTrue(attached.settled(at: at(5)).isEmpty)
        var gap = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: start)
        gap.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 100, toolIDs: [], at: at(2)); gap.markGap()
        XCTAssertTrue(gap.settled(at: at(5)).isEmpty)
        var conflict = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: start)
        conflict.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 100, toolIDs: [], at: at(2))
        conflict.modelBlock(id: "req-1", messageID: "msg-2", outputTokens: 100, toolIDs: [], at: at(3))
        XCTAssertTrue(conflict.settled(at: at(5)).isEmpty)
    }
    func testParallelRequiredToolsUseLastMatchingResultAndIgnoreDuplicateLateBackgroundResult() throws {
        var meter = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: start)
        meter.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 100, toolIDs: ["tool-a", "tool-b"], at: at(2))
        meter.toolStarted("tool-a", at: at(3)); meter.toolStarted("tool-b", at: at(3))
        meter.toolEnded("tool-a", at: at(8)); meter.toolEnded("tool-b", at: at(10))
        meter.toolEnded("tool-a", at: at(14))
        meter.modelBlock(id: "req-2", messageID: "msg-2", outputTokens: 30, toolIDs: [], at: at(12))
        meter.modelBlock(id: "req-2", messageID: "msg-2", outputTokens: 30, toolIDs: [], at: at(15))
        let samples = meter.settled(at: at(16)); XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].tokensPerSecond, 50)
        XCTAssertEqual(samples[1].startedAt, at(10)); XCTAssertEqual(samples[1].tokensPerSecond, 6)
    }
    func testUnpairedOrOverlappingToolsKeepOnlyPreviousSafeResponse() {
        for ending in [Double?.none, 12] {
            var meter = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: start)
            meter.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 100, toolIDs: ["tool"], at: at(2))
            meter.toolStarted("tool", at: at(3)); if let ending { meter.toolEnded("tool", at: at(ending)) }
            meter.modelBlock(id: "req-2", messageID: "msg-2", outputTokens: 80, toolIDs: [], at: at(8))
            let samples = meter.settled(at: at(15))
            XCTAssertEqual(samples.map(\.responseID), ["req-1"]); XCTAssertEqual(samples.first?.tokensPerSecond, 50)
        }
    }
    func testAuthoritativeRequestSkipsOnlyItsOwnFallbackWhileFollowingAccountingCanSettle() {
        var meter = ClaudeObservedRequestMeter(turnID: "prompt-1", observedStart: start)
        meter.modelBlock(id: "req-1", messageID: "msg-1", outputTokens: 100, toolIDs: [], at: at(2))
        meter.modelBlock(id: "req-2", messageID: "msg-2", outputTokens: 60, toolIDs: [], at: at(5))
        meter.authoritative("req-1")
        let samples = meter.settled(at: at(6))
        XCTAssertEqual(samples.map(\.responseID), ["req-2"]); XCTAssertEqual(samples.first?.startedAt, at(2)); XCTAssertEqual(samples.first?.tokensPerSecond, 20)
    }
    func testObservedHookStartAllowsNewTranscriptAttachmentToSettleAndNotifyWithoutTTFT() throws {
        var state = ClaudeActivityState(), inbox = CompletionInbox(), attention = AttentionPolicy()
        let session = "synthetic-session", turn = "prompt-1"
        state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": start.timeIntervalSince1970])!, now: start)
        inbox.observe(state.activities, at: start, retention: 60); _ = attention.activityNotices(state.activities, at: start)
        let block: [String: Any] = ["kind": "modelBlock", "origin": "transcript", "sessionId": session, "requestId": "req-1", "messageId": "msg-1", "outputTokens": 100, "toolIds": [String](), "at": at(2).timeIntervalSince1970]
        let stop: [String: Any] = ["kind": "stopVerified", "origin": "transcript", "sessionId": session, "at": at(3).timeIntervalSince1970]
        state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "baselineFinal": true, "records": [block, stop]])!, now: at(4))
        let value = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(value.phase, .completed); XCTAssertFalse(value.isHistoricalCompletion)
        XCTAssertEqual(value.displayedOutputEstimate(at: at(4))?.value, 50); XCTAssertTrue(value.displayedRateIsEstimated(at: at(4)))
        XCTAssertNil(value.firstTokenLatency); XCTAssertEqual(value.responsePerformance?.completedAt, at(2))
        inbox.observe(state.activities, at: at(4), retention: 60)
        XCTAssertEqual(inbox.unreadActivities.count, 1); XCTAssertEqual(attention.activityNotices(state.activities, at: at(4)).count, 1)
    }
    func testMessageDisplayPartialOnlyProvesObservedOutputWhenPromptWasSeen() {
        for (partial, observed) in [(true, true), (false, true), (true, false)] {
            var state = ClaudeActivityState()
            let common: [String: Any] = ["origin": "hook", "sessionId": "session-1", "promptId": "prompt-1"]
            let prompt = common.merging(["kind": "prompt", "at": start.timeIntervalSince1970]) { _, new in new }
            state.consume(ClaudeActivityRecord.encode(prompt)!, now: start, attaching: !observed)
            let output = common.merging(["kind": "responseDelta", "itemId": "message-1", "displayTurnId": "display-turn-1", "partial": partial, "index": 0, "hasText": true, "at": at(1).timeIntervalSince1970]) { _, new in new }
            state.consume(ClaudeActivityRecord.encode(output)!, now: at(2), attaching: !observed)
            XCTAssertEqual(state.activities.first?.firstTokenLatency, partial && observed ? 1 : nil)
        }
    }
    func testFirstDisplayReplayAndOtherPromptCannotMoveLatencyOrReopenCompletedTurn() throws {
        var state = ClaudeActivityState()
        let common: [String: Any] = ["origin": "hook", "sessionId": "session-1", "promptId": "prompt-1"]
        state.consume(ClaudeActivityRecord.encode(common.merging(["kind": "prompt", "at": start.timeIntervalSince1970]) { _, new in new })!, now: start)
        let display = common.merging(["kind": "responseDelta", "itemId": "message-1", "displayTurnId": "display-turn-1", "partial": true, "index": 0, "hasText": true]) { _, new in new }
        for (seconds, turn) in [(1.0, "prompt-1"), (2.0, "prompt-1"), (3.0, "old-prompt")] {
            state.consume(ClaudeActivityRecord.encode(display.merging(["at": at(seconds).timeIntervalSince1970, "promptId": turn]) { _, new in new })!, now: at(6))
        }
        let first = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(first.firstTokenLatency, 1); XCTAssertEqual(first.firstTokenReportedAt, at(1)); XCTAssertEqual(first.turnID, "prompt-1")
        state.consume(ClaudeActivityRecord.encode(common.merging(["kind": "stopVerified", "at": at(4).timeIntervalSince1970]) { _, new in new })!, now: at(6))
        state.consume(ClaudeActivityRecord.encode(display.merging(["at": at(5).timeIntervalSince1970]) { _, new in new })!, now: at(6))
        let ended = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(ended.phase, .completed); XCTAssertEqual(ended.firstTokenLatency, 1); XCTAssertEqual(ended.firstTokenReportedAt, at(1))
    }
    func testParentChainKeepsLatePriorResponseOutOfNewPromptAccounting() throws {
        var context = ClaudeTranscriptContext(), state = ClaudeActivityState()
        let session = "session-1"
        let lines: [[String: Any]] = [
            ["type": "user", "sessionId": session, "uuid": "user-old", "promptId": "prompt-old", "origin": ["kind": "human"]],
            ["type": "attachment", "sessionId": session, "uuid": "attachment-old", "parentUuid": "user-old"],
            ["type": "user", "sessionId": session, "uuid": "user-new", "promptId": "prompt-new", "origin": ["kind": "human"]],
            ["type": "assistant", "sessionId": session, "uuid": "answer-old", "parentUuid": "attachment-old"]]
        let expected = ["prompt-old", "prompt-old", "prompt-new", "prompt-old"]
        for (line, prompt) in zip(lines, expected) {
            XCTAssertEqual(context.promptID(for: ClaudeActivityRecord.encode(line)!, sessionID: session, parentID: nil), prompt)
        }
        state.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": "prompt-new", "at": start.timeIntervalSince1970])!, now: start)
        let block: [String: Any] = ["kind": "modelBlock", "origin": "transcript", "sessionId": session, "promptId": "prompt-old", "requestId": "req-old", "messageId": "msg-old", "outputTokens": 100, "toolIds": [String](), "at": at(2).timeIntervalSince1970]
        state.consume(ClaudeActivityRecord.encode(block)!, now: at(3))
        state.consume(ClaudeActivityRecord.encode(["kind": "stopVerified", "origin": "transcript", "sessionId": session, "promptId": "prompt-new", "at": at(4).timeIntervalSince1970])!, now: at(5))
        XCTAssertNil(state.activities.first?.responsePerformance)
        let foreign = ClaudeActivityRecord.encode(["type": "user", "sessionId": "other-session", "uuid": "foreign", "promptId": "foreign-prompt"] )!
        XCTAssertNil(context.promptID(for: foreign, sessionID: session, parentID: nil))
    }
}
