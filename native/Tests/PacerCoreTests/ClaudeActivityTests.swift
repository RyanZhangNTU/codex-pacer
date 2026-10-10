import XCTest
import Darwin
@testable import PacerCore

final class ClaudeActivityTests: XCTestCase {
    private let session = "a5a9fbea-c065-46d8-885c-d87413816c90"
    private let turn = "dc0520e2-1720-42a8-a1d1-d2031bf2b145"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func consume(_ kind: String, state: inout ClaudeActivityState, offset: Double, extra: [String: Any] = [:], attaching: Bool = false) {
        let record: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": session, "promptId": turn, "at": now.timeIntervalSince1970 + offset]
        state.consume(ClaudeActivityRecord.encode(record.merging(extra) { _, newer in newer })!, now: now.addingTimeInterval(100), attaching: attaching)
    }
    func testTranscriptProjectionNeverRetainsTextToolArgumentsOrInfersTTFT() throws {
        let raw: [String: Any] = ["type": "assistant", "sessionId": session, "timestamp": "2027-01-15T08:00:02Z", "uuid": "answer-1",
            "message": ["role": "assistant", "model": "claude-sonnet-4", "stop_reason": "end_turn", "content": [
                ["type": "text", "text": "SECRET_PRIVATE_RESPONSE"], ["type": "thinking", "thinking": "SECRET_REASONING"],
                ["type": "tool_use", "id": "tool-1", "name": "Bash", "input": ["command": "SECRET_COMMAND"]]], "usage": ["output_tokens": 100]]]
        let rows = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(raw)!, sessionID: session)
        let joined = rows.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(joined.contains("SECRET")); XCTAssertFalse(joined.contains("Bash")); XCTAssertFalse(joined.contains("hasText")); XCTAssertFalse(joined.contains("ttft"))
        XCTAssertTrue(joined.contains("toolStart")); XCTAssertTrue(joined.contains("thinking"))
    }
    func testInheritedForeignSessionIsExcludedFromTranscriptOwner() {
        let raw = ClaudeActivityRecord.encode(["type": "user", "sessionId": "other-session", "timestamp": "2027-01-15T08:00:00Z", "uuid": "prompt-1", "message": ["content": "SECRET_PROMPT"]])!
        XCTAssertTrue(ClaudeActivityRecord.transcript(raw, sessionID: session).isEmpty)
        XCTAssertTrue(ClaudeActivityRecord.transcript(raw, sessionID: "agent-1", parentID: session).isEmpty)
    }
    func testCustomTitleWithoutTimestampIsMetadataOnly() throws {
        let raw = ClaudeActivityRecord.encode(["type": "custom-title", "sessionId": session, "customTitle": "Safe synthetic task title"] )!
        let rows = ClaudeActivityRecord.transcript(raw, sessionID: session)
        XCTAssertEqual(rows.count, 1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: rows[0]) as? [String: Any])
        XCTAssertEqual(value["kind"] as? String, "metadata"); XCTAssertNil(value["promptId"])
    }
    func testBlockingQuestionAndUnrelatedBackgroundToolCannotClearAttention() throws {
        var state = ClaudeActivityState()
        consume("prompt", state: &state, offset: 0)
        consume("toolStart", state: &state, offset: 1, extra: ["itemId": "background"])
        consume("toolStart", state: &state, offset: 2, extra: ["itemId": "question", "attention": "input"])
        XCTAssertEqual(state.activities.first?.phase, .waitingForInput)
        consume("toolEnd", state: &state, offset: 3, extra: ["itemId": "background"])
        XCTAssertEqual(state.attention.count, 1); XCTAssertEqual(state.activities.first?.phase, .waitingForInput)
        consume("toolEnd", state: &state, offset: 4, extra: ["itemId": "question"])
        XCTAssertTrue(state.attention.isEmpty); XCTAssertEqual(state.activities.first?.phase, .running)
    }
    func testVerifiedMirrorExclusionRemovesOnlyLocalStateAndDescendantsNotRealSSHIdentities() throws {
        var local = ClaudeActivityState(), remote = ClaudeActivityState(sourceID: "remote-ssh-discovered:fixture", sourceName: "Fixture SSH")
        let other = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        consume("prompt", state: &local, offset: 0); consume("prompt", state: &remote, offset: 0)
        consume("approval", state: &local, offset: 1, extra: ["itemId": "permission"])
        let child = ClaudeActivityRecord.encode(["kind": "subagentStart", "origin": "hook", "sessionId": "child-1", "parentId": session,
            "promptId": turn, "at": now.timeIntervalSince1970 + 1])!
        local.consume(child, now: now.addingTimeInterval(10))
        local.consume(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": other, "promptId": "other-turn",
            "at": now.timeIntervalSince1970 + 1])!, now: now.addingTimeInterval(10))
        local.setExcludedSessionIDs([session]); remote.setExcludedSessionIDs([session])
        XCTAssertEqual(local.activities.compactMap(\.threadID), [other]); XCTAssertTrue(local.attention.isEmpty)
        XCTAssertTrue(local.excludedActivityIDs.contains(AgentProvider.claude.activityID(sessionID: session, sourceHostID: nil)))
        XCTAssertTrue(local.excludedActivityIDs.contains(AgentProvider.claude.activityID(sessionID: "child-1", sourceHostID: nil)))
        XCTAssertTrue(local.knownStartedSessionIDs.contains(session), "Excluded mirror prompts must not force metadata scans on every turn")
        XCTAssertEqual(remote.activities.first?.threadID, session); XCTAssertTrue(remote.excludedActivityIDs.isEmpty)
        consume("stopVerified", state: &local, offset: 2); consume("stopVerified", state: &remote, offset: 2)
        let span = ClaudeActivityRecord.encode(["kind": "request", "sessionId": session, "promptId": turn, "requestId": "req-1",
            "startedAt": now.timeIntervalSince1970 + 1, "at": now.timeIntervalSince1970 + 3, "outputTokens": 100, "durationMs": 2000.0])!
        local.consume(span, now: now.addingTimeInterval(10)); remote.consume(span, now: now.addingTimeInterval(10))
        XCTAssertEqual(local.activities.compactMap(\.threadID), [other]); XCTAssertTrue(local.performanceUpdates.isEmpty)
        XCTAssertEqual(remote.activities.first?.phase, .completed); XCTAssertEqual(remote.activities.first?.responsePerformance?.tokensPerSecond, 50)
    }
    func testStopHookCandidateDoesNotEndContinuedPrompt() {
        var state = ClaudeActivityState()
        consume("prompt", state: &state, offset: 0)
        consume("stopRequested", state: &state, offset: 1)
        XCTAssertEqual(state.activities.first?.phase, .running)
        consume("toolStart", state: &state, offset: 2, extra: ["itemId": "continued-tool"])
        XCTAssertEqual(state.activities.first?.stage, .tool)
        let verified = ClaudeActivityRecord.encode(["origin": "transcript", "kind": "stopVerified", "sessionId": session, "at": now.timeIntervalSince1970 + 3])!
        state.consume(verified, now: now.addingTimeInterval(10))
        XCTAssertEqual(state.activities.first?.phase, .completed)
    }
    func testStopSummaryOnlyEndsWhenContinuationWasNotPrevented() {
        let common: [String: Any] = ["type": "system", "sessionId": session, "timestamp": "2027-01-15T08:00:02Z", "subtype": "stop_hook_summary", "hookErrors": [String](), "hookAdditionalContext": [String]()]
        let blocked = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(common.merging(["preventedContinuation": true]) { _, v in v })!, sessionID: session)
        XCTAssertFalse(blocked.contains { String(data: $0, encoding: .utf8)!.contains("stopVerified") })
        let ended = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(common.merging(["preventedContinuation": false]) { _, v in v })!, sessionID: session)
        XCTAssertTrue(ended.contains { String(data: $0, encoding: .utf8)!.contains("stopVerified") })
        let block = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(common.merging(["preventedContinuation": false, "hookErrors": ["Synthetic blocking hook"]]) { _, v in v })!, sessionID: session)
        XCTAssertFalse(block.contains { String(data: $0, encoding: .utf8)!.contains("stopVerified") })
        let continued = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(common.merging(["preventedContinuation": false, "hookAdditionalContext": ["Synthetic continuation"]]) { _, v in v })!, sessionID: session)
        XCTAssertFalse(continued.contains { String(data: $0, encoding: .utf8)!.contains("stopVerified") })
    }
    func testThinkingAndTextBlocksSharingEndTurnDoNotPrematurelyCompleteTask() {
        var state = ClaudeActivityState()
        let prompt = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "timestamp": "2027-01-15T08:00:00Z", "promptId": turn, "uuid": "user-1", "message": ["role": "user", "content": "synthetic"]])!
        for row in ClaudeActivityRecord.transcript(prompt, sessionID: session) { state.consume(row, now: now.addingTimeInterval(10)) }
        for (index, type) in ["thinking", "text"].enumerated() {
            let raw = ClaudeActivityRecord.encode(["type": "assistant", "sessionId": session, "timestamp": index == 0 ? "2027-01-15T08:00:01Z" : "2027-01-15T08:00:04Z", "uuid": "block-\(index)", "apiBlockIndex": index, "requestId": "req-shared", "message": ["id": "msg-shared", "role": "assistant", "stop_reason": "end_turn", "usage": ["output_tokens": 256], "content": [["type": type, "text": "synthetic"]]]])!
            for row in ClaudeActivityRecord.transcript(raw, sessionID: session, promptID: turn) { state.consume(row, now: now.addingTimeInterval(10)) }
            XCTAssertEqual(state.activities.first?.phase, .running)
            XCTAssertNil(state.activities.first?.firstTokenLatency); XCTAssertNil(state.activities.first?.responsePerformance)
        }
        let summary = ClaudeActivityRecord.encode(["type": "system", "subtype": "stop_hook_summary", "sessionId": session, "timestamp": "2027-01-15T08:00:05Z", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()])!
        for row in ClaudeActivityRecord.transcript(summary, sessionID: session, promptID: turn) { state.consume(row, now: now.addingTimeInterval(10)) }
        XCTAssertEqual(state.activities.first?.phase, .completed)
    }
    func testSpanAccountingCannotCreateActivityAndEnrichesEndedMatchingTurn() throws {
        var state = ClaudeActivityState()
        let request: [String: Any] = ["kind": "request", "sessionId": session, "promptId": turn, "requestId": "req-1", "startedAt": now.timeIntervalSince1970 + 1, "at": now.timeIntervalSince1970 + 5, "outputTokens": 120, "durationMs": 3000.0, "ttftMs": 200.0]
        let bytes = ClaudeActivityRecord.encode(request)!
        state.consume(bytes, now: now.addingTimeInterval(10)); XCTAssertTrue(state.activities.isEmpty)
        consume("prompt", state: &state, offset: 0); consume("stopVerified", state: &state, offset: 5)
        let ended = try XCTUnwrap(state.activities.first?.phaseChangedAt)
        state.consume(bytes, now: now.addingTimeInterval(10))
        let activity = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(activity.phase, .completed); XCTAssertEqual(activity.phaseChangedAt, ended)
        XCTAssertEqual(activity.displayedOutputEstimate(at: now.addingTimeInterval(10))?.value, 40)
        XCTAssertEqual(activity.firstTokenLatency, 0.2)
        XCTAssertEqual(activity.firstTokenReportedAt, now.addingTimeInterval(1.2))
    }
    func testChildSpanNeverOverwritesRootMetric() throws {
        var state = ClaudeActivityState()
        consume("prompt", state: &state, offset: 0)
        let span = ClaudeActivityRecord.encode(["kind": "request", "sessionId": session, "agentId": "child-1", "promptId": turn, "requestId": "req-child", "at": now.timeIntervalSince1970 + 5, "startedAt": now.timeIntervalSince1970 + 1, "durationMs": 4000.0, "outputTokens": 100])!
        state.consume(span, now: now.addingTimeInterval(10))
        XCTAssertNil(state.activities.first?.responsePerformance); XCTAssertEqual(state.activities.count, 1)
        let child = ClaudeActivityRecord.encode(["kind": "subagentStart", "origin": "hook", "sessionId": "child-1", "parentId": session, "promptId": turn, "at": now.timeIntervalSince1970 + 1])!
        state.consume(child, now: now.addingTimeInterval(10)); state.consume(span, now: now.addingTimeInterval(10))
        XCTAssertNil(state.activities.first(where: { $0.threadID == session })?.responsePerformance)
        XCTAssertEqual(state.activities.first(where: { $0.threadID == "child-1" })?.responsePerformance?.tokensPerSecond, 25)
    }
    func testStartupBatchStaysQuietAndDoesNotInventInterruptionFromSilence() {
        var state = ClaudeActivityState(), policy = AttentionPolicy()
        let rows: [[String: Any]] = [
            ["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": now.timeIntervalSince1970],
            ["kind": "stopVerified", "origin": "transcript", "sessionId": session, "at": now.timeIntervalSince1970 + 1]]
        state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "records": rows])!, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.activities.first?.phase, .completed)
        XCTAssertFalse(state.activities.first?.liveTurnStarted ?? true)
        XCTAssertTrue(policy.activityNotices(state.activities, at: now.addingTimeInterval(2)).isEmpty)
        var running = ClaudeActivityState(); consume("prompt", state: &running, offset: 0)
        XCTAssertEqual(running.activities.first?.observedPhase(at: now.addingTimeInterval(10_000)), .running)
    }
    func testHistoricalEndingAcrossTwoPublicationsNeverCreatesUnreadOrNotice() {
        var state = ClaudeActivityState(sourceID: "remote-ssh-discovered:synthetic", sourceName: "Synthetic host")
        var inbox = CompletionInbox(), policy = AttentionPolicy()
        let prompt = ["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": now.timeIntervalSince1970] as [String: Any]
        state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "records": [prompt]])!, now: now)
        inbox.observe(state.activities, at: now, retention: 60); XCTAssertTrue(policy.activityNotices(state.activities, at: now).isEmpty)
        let stop = ["kind": "stopVerified", "origin": "transcript", "sessionId": session, "at": now.timeIntervalSince1970 + 1] as [String: Any]
        state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "records": [stop]])!, now: now.addingTimeInterval(2))
        inbox.observe(state.activities, at: now.addingTimeInterval(2), retention: 60)
        XCTAssertTrue(inbox.unreadActivities.isEmpty); XCTAssertTrue(policy.activityNotices(state.activities, at: now.addingTimeInterval(2)).isEmpty)
        let liveTurn = "live-new-prompt"
        consume("prompt", state: &state, offset: 3, extra: ["promptId": liveTurn])
        inbox.observe(state.activities, at: now.addingTimeInterval(3), retention: 60); _ = policy.activityNotices(state.activities, at: now.addingTimeInterval(3))
        consume("stopVerified", state: &state, offset: 4, extra: ["promptId": liveTurn])
        inbox.observe(state.activities, at: now.addingTimeInterval(4), retention: 60)
        XCTAssertEqual(inbox.unreadActivities.count, 1); XCTAssertEqual(policy.activityNotices(state.activities, at: now.addingTimeInterval(4)).count, 1)
    }
    func testOldHistoricalCompleteTailSurvivesUntilFinalBaselineAndOldRunningRemainsUnconfirmed() {
        var completed = ClaudeActivityState(), running = ClaudeActivityState()
        let start: [String: Any] = ["kind": "prompt", "origin": "hook", "sessionId": session, "promptId": turn, "at": now.timeIntervalSince1970 - 1800]
        let stop: [String: Any] = ["kind": "stopVerified", "origin": "transcript", "sessionId": session, "at": now.timeIntervalSince1970 - 1798]
        completed.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "baselineFinal": true, "records": [start, stop]])!, now: now)
        XCTAssertEqual(completed.activities.first?.phase, .completed)
        XCTAssertTrue(completed.activities.first?.isHistoricalCompletion ?? false)
        running.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "attaching": true, "baselineFinal": true, "records": [start]])!, now: now)
        XCTAssertEqual(running.activities.first?.phase, .unknown)
    }
    func testEngineInterruptMarkerRejectsHumanSpoofTypedMarkerAndOtherPrompt() {
        for scenario in ["engine", "human", "typed", "otherPrompt"] {
            var state = ClaudeActivityState()
            consume("prompt", state: &state, offset: 0, extra: ["typedInterruptMarker": scenario == "typed"])
            var raw: [String: Any] = ["type": "user", "sessionId": session,
                "promptId": scenario == "otherPrompt" ? "previous-prompt" : turn,
                "timestamp": "2027-01-15T08:00:01Z", "uuid": "interrupt-1",
                "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]]
            if scenario == "human" { raw["origin"] = ["kind": "human"]; raw["promptSource"] = "sdk"; raw["turnOrigin"] = "human" }
            let rows = ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(raw)!, sessionID: session)
            for row in rows { state.consume(row, now: now.addingTimeInterval(2)) }
            XCTAssertEqual(state.activities.first?.phase, scenario == "engine" ? .interrupted : .running, scenario)
            XCTAssertFalse(state.activities.first?.turnFailed ?? true); XCTAssertNil(state.activities.first?.firstTokenLatency)
            XCTAssertFalse(rows.contains { String(data: $0, encoding: .utf8)!.contains("Request interrupted") })
        }
    }
    func testNativeReaderKeepsInitialHistoricalProvenanceAcrossTailChunks() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-reader-" + UUID().uuidString)
        let dir = home.appendingPathComponent("projects/synthetic"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = dir.appendingPathComponent(session + ".jsonl")
        let row = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": turn, "uuid": "u1", "timestamp": "2027-01-15T08:00:00Z", "message": ["content": "synthetic"]])! + Data([10])
        var bytes = Data(); for _ in 0..<600 { bytes.append(row) }; try bytes.write(to: file)
        var reader = ClaudeActivityReader(); let first = reader.read(home: home, discover: true, now: now)
        XCTAssertFalse(first.caughtUp)
        let second = reader.read(home: home, discover: false, now: now)
        XCTAssertTrue(second.caughtUp)
        for record in first.records + second.records {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any]); XCTAssertEqual(value["attaching"] as? Bool, true)
        }
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: row); try handle.close()
        let live = reader.read(home: home, discover: false, now: now)
        XCTAssertTrue(live.records.contains { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["kind"] as? String == "prompt" })
    }
    func testVerifiedMirrorsSpendNoTranscriptReadCursorOrWatchBudgetAndCannotStarveLocalFile() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-mirror-budget-" + UUID().uuidString)
        let dir = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let genuine = dir.appendingPathComponent(session + ".jsonl")
        let row = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": turn, "uuid": "local-user",
            "timestamp": "2027-01-15T08:00:00Z", "message": ["content": "synthetic"]])! + Data([10])
        try row.write(to: genuine)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: genuine.path)
        var exclusions: Set<String> = [], mirrorURLs: Set<URL> = []
        for index in 0..<32 {
            let id = "aabbccdd-0000-0000-0000-" + String(format: "%012d", index)
            exclusions.insert(id)
            let mirror = dir.appendingPathComponent((index == 0 ? id.uppercased() : id) + ".jsonl")
            // These files need not contain parseable data: an excluded source
            // must never be opened, even when it is newer than genuine data.
            try Data("PRIVATE synthetic mirror\n".utf8).write(to: mirror)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index))], ofItemAtPath: mirror.path)
            mirrorURLs.insert(mirror)
            let subagents = dir.appendingPathComponent(id + "/subagents")
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            let child = subagents.appendingPathComponent("agent-child-\(index).jsonl")
            try Data("PRIVATE synthetic child\n".utf8).write(to: child); mirrorURLs.insert(child)
        }
        var reader = ClaudeActivityReader()
        let result = reader.read(home: home, discover: true, excludingSessionIDs: exclusions, now: now)
        XCTAssertEqual(reader.fileReads, 1); XCTAssertEqual(reader.attachedTranscriptCount, 1)
        XCTAssertTrue(result.watchURLs.contains(genuine)); XCTAssertTrue(mirrorURLs.isDisjoint(with: Set(result.watchURLs)))
        XCTAssertTrue(result.records.contains { String(data: $0, encoding: .utf8)?.contains(session) == true })
        XCTAssertFalse(result.records.contains { String(data: $0, encoding: .utf8)?.contains("PRIVATE") == true })
        _ = reader.read(home: home, discover: false, excludingSessionIDs: exclusions, now: now)
        XCTAssertEqual(reader.fileReads, 1); XCTAssertEqual(reader.scans, 1, "An unchanged exclusion cache does not require discovery")
    }
    func testExclusionPurgesAttachedCursorAndReplacementReattachesAsQuietHistoryBeforeNextLiveTurn() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-mirror-reattach-" + UUID().uuidString)
        let dir = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = dir.appendingPathComponent(session + ".jsonl")
        func transcript(_ prompt: String, offset: Int) -> Data {
            let start = "2027-01-15T08:00:" + String(format: "%02d", offset) + "Z"
            let end = "2027-01-15T08:00:" + String(format: "%02d", offset + 1) + "Z"
            return ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": prompt, "uuid": "user-" + prompt,
                "timestamp": start, "message": ["content": "synthetic"]])! + Data([10]) +
                ClaudeActivityRecord.encode(["type": "system", "subtype": "stop_hook_summary", "sessionId": session,
                    "promptId": prompt, "timestamp": end, "preventedContinuation": false,
                    "hookErrors": [String](), "hookAdditionalContext": [String]()])! + Data([10])
        }
        try transcript(turn, offset: 0).write(to: file)
        var reader = ClaudeActivityReader()
        _ = reader.read(home: home, discover: true, now: now.addingTimeInterval(20))
        XCTAssertEqual(reader.fileReads, 1)
        XCTAssertEqual(reader.excludeSessionIDs([session]), [file]); XCTAssertEqual(reader.attachedTranscriptCount, 0)
        let excluded = reader.read(home: home, discover: false, excludingSessionIDs: [session], now: now.addingTimeInterval(20))
        XCTAssertTrue(excluded.records.isEmpty); XCTAssertFalse(excluded.watchURLs.contains(file)); XCTAssertEqual(reader.fileReads, 1)
        // The excluded file is replaced while no cursor watches it. Removing
        // the exclusion must baseline the replacement, not replay its ending.
        try transcript("replacement-prompt", offset: 2).write(to: file, options: .atomic)
        let attached = reader.read(home: home, discover: true, now: now.addingTimeInterval(20))
        XCTAssertEqual(reader.fileReads, 2); XCTAssertEqual(reader.attachedTranscriptCount, 1)
        var state = ClaudeActivityState(), inbox = CompletionInbox(), policy = AttentionPolicy()
        for row in attached.records { state.consume(row, now: now.addingTimeInterval(20)) }
        state.finalizeHistoricalBaseline(now: now.addingTimeInterval(20))
        let historical = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(historical.phase, .completed); XCTAssertTrue(historical.isHistoricalCompletion)
        inbox.observe(state.activities, at: now.addingTimeInterval(20), retention: 60)
        XCTAssertTrue(inbox.unreadActivities.isEmpty); XCTAssertTrue(policy.activityNotices(state.activities, at: now.addingTimeInterval(20)).isEmpty)
        let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
        try writer.write(contentsOf: transcript("next-live-prompt", offset: 21)); try writer.close()
        let live = reader.read(home: home, discover: false, now: now.addingTimeInterval(23))
        for row in live.records { state.consume(row, now: now.addingTimeInterval(23)) }
        XCTAssertEqual(state.activities.first?.phase, .completed); XCTAssertFalse(state.activities.first?.isHistoricalCompletion ?? true)
        inbox.observe(state.activities, at: now.addingTimeInterval(23), retention: 60)
        XCTAssertEqual(inbox.unreadActivities.count, 1); XCTAssertEqual(policy.activityNotices(state.activities, at: now.addingTimeInterval(23)).count, 1)
    }
    func testIdleCursorSkipsFileReadsButFirstAppendAndAtomicReplacementStayObservable() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-idle-reader-" + UUID().uuidString)
        let dir = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = dir.appendingPathComponent(session + ".jsonl")
        func row(_ id: String) -> Data {
            ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": id, "uuid": id,
                "timestamp": "2027-01-15T08:00:00Z", "origin": ["kind": "human"], "message": ["content": "synthetic"]])! + Data([10])
        }
        try row("initial").write(to: file)
        var reader = ClaudeActivityReader()
        _ = reader.read(home: home, discover: true, now: now)
        let baseline = reader.fileReads
        XCTAssertEqual(baseline, 1)
        for _ in 0..<10 {
            let idle = reader.read(home: home, discover: false, now: now)
            XCTAssertTrue(idle.caughtUp); XCTAssertTrue(idle.records.isEmpty)
        }
        XCTAssertEqual(reader.fileReads, baseline, "Unchanged EOF cursors must not reopen files")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: row("live")); try handle.close()
        let appended = reader.read(home: home, discover: false, now: now)
        XCTAssertEqual(reader.fileReads, baseline + 1)
        XCTAssertTrue(appended.records.contains { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["promptId"] as? String == "live" })
        try row("replaced").write(to: file, options: .atomic)
        let replaced = reader.read(home: home, discover: false, now: now)
        XCTAssertEqual(reader.fileReads, baseline + 2)
        XCTAssertTrue(replaced.records.contains { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["attaching"] as? Bool == true })
        try FileManager.default.removeItem(at: file)
        let removed = reader.read(home: home, discover: false, now: now)
        XCTAssertTrue(removed.records.contains { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["kind"] as? String == "unavailable" })
    }
    func testInitialPartialRecordAndNewAppendKeepSeparateHistoricalProvenance() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-mixed-tail-" + UUID().uuidString)
        let dir = home.appendingPathComponent("projects/synthetic"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = dir.appendingPathComponent(session + ".jsonl")
        let historical = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": turn, "uuid": "old-user", "timestamp": "2027-01-15T08:00:00Z", "message": ["content": "synthetic"]])! + Data([10])
        let live = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "promptId": "new-prompt", "uuid": "new-user", "timestamp": "2027-01-15T08:00:01Z", "message": ["content": "synthetic"]])! + Data([10])
        let boundary = historical.count / 2; try historical.prefix(boundary).write(to: file)
        var reader = ClaudeActivityReader(); _ = reader.read(home: home, discover: true, now: now)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: historical.dropFirst(boundary) + live); try handle.close()
        let mixed = reader.read(home: home, discover: false, now: now)
        let values = try mixed.records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertTrue(values.contains { $0["attaching"] as? Bool == true && ($0["records"] as? [[String: Any]])?.contains { $0["promptId"] as? String == turn } == true })
        XCTAssertTrue(values.contains { $0["kind"] as? String == "prompt" && $0["promptId"] as? String == "new-prompt" && $0["attaching"] == nil })
    }
    func testNativeAndSshDrainLargeAttachmentAppendsWithoutLosingPromptOwnership() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-burst-" + UUID().uuidString)
        let dir = home.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = dir.appendingPathComponent(session + ".jsonl")
        let prompt = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "uuid": "user-1", "promptId": turn,
            "timestamp": "2027-01-15T08:00:00Z", "origin": ["kind": "human"], "message": ["content": "PRIVATE synthetic prompt"]])! + Data([10])
        try prompt.write(to: file)
        var reader = ClaudeActivityReader(), native = ClaudeActivityState()
        consume("prompt", state: &native, offset: 0)
        for row in reader.read(home: home, discover: true, now: now).records { native.consume(row, now: now) }
        let attachments: [[String: Any]] = [
            ["type": "attachment", "sessionId": session, "uuid": "attachment-1", "parentUuid": "user-1", "timestamp": "2027-01-15T08:00:01Z", "attachment": ["content": String(repeating: "PRIVATE", count: 24_000)]],
            ["type": "attachment", "sessionId": session, "uuid": "attachment-2", "parentUuid": "attachment-1", "timestamp": "2027-01-15T08:00:02Z", "attachment": ["content": String(repeating: "PRIVATE", count: 24_000)]],
            ["type": "assistant", "sessionId": session, "uuid": "answer-1", "parentUuid": "attachment-2", "timestamp": "2027-01-15T08:00:04Z", "requestId": "req-1", "message": ["id": "msg-1", "model": "claude-sonnet-4", "usage": ["output_tokens": 100], "stop_reason": "end_turn", "content": [["type": "text", "text": "PRIVATE response"]]]],
            ["type": "system", "subtype": "stop_hook_summary", "sessionId": session, "uuid": "stop-1", "parentUuid": "answer-1", "timestamp": "2027-01-15T08:00:05Z", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]]
        let burst = attachments.reduce(into: Data()) { bytes, row in bytes.append(ClaudeActivityRecord.encode(row)!); bytes.append(10) }
        XCTAssertGreaterThan(burst.count, 256 * 1024)
        let burstFile = home.appendingPathComponent("burst.jsonl"); try burst.write(to: burstFile)
        // The Python helper sees the same first prompt before the large append,
        // then drains it using the real Tailer rather than a parser-only fixture.
        let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let script = "__name__='fixture'\nimport base64,json,sys,pathlib\nexec(base64.b64decode('" + program + "').decode(),globals())\ntailer=Tailer(pathlib.Path(sys.argv[1]));tailer.discover();initial=tailer.read()\nwith open(sys.argv[2],'ab') as stream:stream.write(pathlib.Path(sys.argv[3]).read_bytes())\nchunks=[]\nfor _ in range(10):\n tailer.poll();chunks.append(tailer.read())\n if not tailer.dirty:break\ntailer.close();print(json.dumps({'initial':initial,'chunks':chunks},separators=(',',':')))\n"
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); child.arguments = ["-c", script, home.path, file.path, burstFile.path]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let chunks = try XCTUnwrap(projected["chunks"] as? [[[String: Any]]]); XCTAssertGreaterThan(chunks.count, 1)
        var remote = ClaudeActivityState(sourceID: "synthetic", sourceName: "Synthetic SSH")
        consume("prompt", state: &remote, offset: 0)
        for rows in [projected["initial"] as? [[String: Any]] ?? []] + chunks {
            remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": rows])!, now: now.addingTimeInterval(10))
        }
        var reads = 0, caughtUp = false, nativeRows: [Data] = []
        while !caughtUp && reads < 10 {
            let result = reader.read(home: home, discover: false, now: now.addingTimeInterval(10))
            nativeRows += result.records; for row in result.records { native.consume(row, now: now.addingTimeInterval(10)) }
            reads += 1; caughtUp = result.caughtUp
        }
        XCTAssertTrue(caughtUp); XCTAssertGreaterThan(reads, 1)
        XCTAssertFalse((nativeRows.compactMap { String(data: $0, encoding: .utf8) }.joined() + String(decoding: bytes, as: UTF8.self)).contains("PRIVATE"))
        for value in [try XCTUnwrap(native.activities.first), try XCTUnwrap(remote.activities.first)] {
            XCTAssertEqual(value.phase, .completed); XCTAssertEqual(value.turnID, turn)
            XCTAssertEqual(value.modelName, "claude-sonnet-4")
            XCTAssertEqual(value.responsePerformance?.tokensPerSecond, 25); XCTAssertNil(value.firstTokenLatency)
        }
    }
    func testRemoteHelperEOFAndClosedOutputTerminatePromptly() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-helper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); child.arguments = ["-u", "-c", ClaudeActivityProbe.script, Data(home.path.utf8).base64EncodedString(), "5"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice; try child.run()
        var readiness = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = Darwin.poll(&readiness, 1, 2000)
        guard ready > 0 else {
            child.terminate(); child.waitUntilExit(); XCTFail("Helper must emit its startup status promptly"); return
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress!, 1024) }
        XCTAssertGreaterThan(count, 0)
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2); while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(child.isRunning, "Owned stdin EOF must stop the actual helper within two seconds")
        if child.isRunning { child.terminate() }; child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0)
    }
    func testDroppedOversizeRecordsInvalidateObservedWindowsForBothCollectors() throws {
        // One size finishes just above the record limit; the other crosses the
        // fragment limit before its newline arrives. Both lose real bytes.
        for length in [1_050_000, 1_400_000] {
            let home = URL(fileURLWithPath: "/private/tmp/pacer-claude-oversize-" + UUID().uuidString)
            let dir = home.appendingPathComponent("projects/synthetic")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let file = dir.appendingPathComponent(session + ".jsonl")
            let prompt = ClaudeActivityRecord.encode(["type": "user", "sessionId": session, "uuid": "user-1", "promptId": turn,
                "timestamp": "2027-01-15T08:00:00Z", "origin": ["kind": "human"], "message": ["content": "synthetic"]])! + Data([10])
            try prompt.write(to: file)
            var reader = ClaudeActivityReader(), native = ClaudeActivityState()
            consume("prompt", state: &native, offset: 0)
            for row in reader.read(home: home, discover: true, now: now).records { native.consume(row, now: now) }
            let additions: [[String: Any]] = [
                ["type": "attachment", "sessionId": session, "uuid": "oversize", "parentUuid": "user-1", "timestamp": "2027-01-15T08:00:01Z", "attachment": ["content": "PRIVATE" + String(repeating: "X", count: length)]],
                ["type": "assistant", "sessionId": session, "uuid": "answer-1", "parentUuid": "oversize", "promptId": turn, "timestamp": "2027-01-15T08:00:04Z", "requestId": "req-1", "message": ["id": "msg-1", "usage": ["output_tokens": 100], "content": [["type": "text", "text": "PRIVATE response"]]]],
                ["type": "system", "subtype": "stop_hook_summary", "sessionId": session, "parentUuid": "answer-1", "promptId": turn, "timestamp": "2027-01-15T08:00:05Z", "preventedContinuation": false, "hookErrors": [String](), "hookAdditionalContext": [String]()]]
            let burst = additions.reduce(into: Data()) { bytes, row in bytes.append(ClaudeActivityRecord.encode(row)!); bytes.append(10) }
            let burstFile = home.appendingPathComponent("burst.jsonl"); try burst.write(to: burstFile)
            let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
            let script = "__name__='fixture'\nimport base64,json,sys,pathlib\nexec(base64.b64decode('" + program + "').decode(),globals())\ntailer=Tailer(pathlib.Path(sys.argv[1]));tailer.discover();tailer.read()\nwith open(sys.argv[2],'ab') as stream:stream.write(pathlib.Path(sys.argv[3]).read_bytes())\nrows=[]\nfor _ in range(24):\n tailer.poll();rows.extend(tailer.read())\n if not tailer.dirty:break\ntailer.close();print(json.dumps(rows,separators=(',',':')))\n"
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); child.arguments = ["-c", script, home.path, file.path, burstFile.path]
            child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
            try child.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
            XCTAssertTrue(rows.contains { $0["kind"] as? String == "discontinuity" })
            var remote = ClaudeActivityState(sourceID: "synthetic", sourceName: "Synthetic SSH")
            consume("prompt", state: &remote, offset: 0)
            remote.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": rows])!, now: now.addingTimeInterval(10))
            var caughtUp = false, seenGap = false
            for _ in 0..<24 where !caughtUp {
                let result = reader.read(home: home, discover: false, now: now.addingTimeInterval(10))
                for row in result.records {
                    let kind = (try? JSONSerialization.jsonObject(with: row) as? [String: Any])?["kind"] as? String
                    seenGap = seenGap || kind == "discontinuity"
                    native.consume(row, now: now.addingTimeInterval(10))
                }
                caughtUp = result.caughtUp
            }
            XCTAssertTrue(caughtUp); XCTAssertTrue(seenGap)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
            for value in [try XCTUnwrap(native.activities.first), try XCTUnwrap(remote.activities.first)] {
                XCTAssertEqual(value.phase, .completed); XCTAssertEqual(value.turnID, turn)
                XCTAssertNil(value.responsePerformance); XCTAssertNil(value.firstTokenLatency)
            }
        }
    }
    func testNativeAndSshProjectionAgreeForListContentWithoutPrivateText() throws {
        let fixtures: [[String: Any]] = [
            ["type": "user", "sessionId": session, "promptId": turn, "uuid": "user-1", "timestamp": "2027-01-15T08:00:00Z", "origin": ["kind": "human"], "message": ["role": "user", "content": [["type": "text", "text": "PRIVATE prompt"]]]],
            ["type": "assistant", "sessionId": session, "uuid": "answer-1", "timestamp": "2027-01-15T08:00:01Z", "requestId": "req-1", "message": ["id": "msg-1", "role": "assistant", "model": "claude-sonnet-4", "stop_reason": "end_turn", "usage": ["output_tokens": 100], "content": [["type": "thinking", "thinking": "PRIVATE reasoning"], ["type": "text", "text": "PRIVATE response"], ["type": "tool_use", "id": "tool-1", "name": "AskUserQuestion", "input": ["question": "PRIVATE question"]]]]],
            ["type": "user", "sessionId": session, "promptId": turn, "uuid": "result-1", "timestamp": "2027-01-15T08:00:02Z", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool-1", "content": "PRIVATE output"]]]]
        ]
        let native = fixtures.flatMap { fixture in ClaudeActivityRecord.transcript(ClaudeActivityRecord.encode(fixture)!, sessionID: session, promptID: turn) }
        let expected = try native.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let fixtureData = try JSONSerialization.data(withJSONObject: fixtures)
        let program = Data(ClaudeActivityProbe.script.utf8).base64EncodedString()
        let script = "import base64,json,sys\nexec(base64.b64decode('" + program + "').decode(),globals())\nrows=[]\nfor value in json.loads(base64.b64decode(sys.argv[1])):\n rows.extend(transcript(json.dumps(value).encode(),sys.argv[2],None,sys.argv[3]))\nprint(json.dumps(rows,separators=(',',':')))\n"
        // Set a library name before evaluating so no helper listener starts.
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "__name__='fixture'\n" + script, fixtureData.base64EncodedString(), session, turn]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        XCTAssertTrue(NSArray(array: actual).isEqual(to: expected))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        XCTAssertTrue(actual.contains { $0["kind"] as? String == "modelBlock" })
        XCTAssertTrue(actual.contains { $0["kind"] as? String == "toolEnd" })
    }
}
