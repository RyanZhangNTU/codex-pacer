import XCTest
@testable import PacerCore

final class DeepSeekActivityTests: XCTestCase {
    private let session = "11111111-2222-4333-8444-555555555555"
    /// Tuesday 2026-10-27 10:00 in Beijing, inside the morning peak.
    private let peak = Date(timeIntervalSince1970: 1_793_066_400)
    private var key: String { AgentProvider.deepseek.activityID(sessionID: session) }
    /// Frames as Harness appends them: a header and an open step, then a response and its end.
    private let opening = Data(base64Encoded: "KLUv/WRCAN0FACILJCBAa6sDOMsVMmq/zdtikXbdhXVLIbH4kVZqUH1nFD3MgYemSepUyfvGJqkbarasOVH6wm3CI2QbjwUy9tAg9cG+EyyMW2ZwxZvzUcES6vb2F0Tn9CpHYOA7h4xlcInjLfZYUJxoJQlCBACSegfalx0qTiPOWivgIAiyjlJKnXSacy6FV3B6YVyMj1b/NawbARAAXgkCvAMJA5mREElVweNxJGZueLWHZVZQCkGC0AKzcBn73KJtaQL7UWPk")!
    private let closing = Data(base64Encoded: "KLUv/WQ7AmUNABbZSiMwa6wDQduvkGtvgCw8ZAn3XbDix4kFSVwYlHgfgDpYGKQ4BD4AQQBCAAZfDNwI6/24H2RPj6D8Y0Xu+ZSsP0n7j/XtbU9KKUUdGEYJNOxw/YRI1hV4Pp0Tdk52BPTbnm7O/TrHhv4jCMOaRRiMoTzMNu6pVqdOiMGI0dsGDRtFlk9vzI2eRyFji0DMMzK3r0tubgHK+PSIG3R8vT0HMUnhfHLqFwkFQSLtObk9kbWoQ482mGNZ9nyqSi1LtA37SXE7eXBoywpusGVLU5isz8cQXDSNz/2x6FN9Y9TDODyIAYSyIAilaRAm2UMAtdY3bo6iA7IH57JMBgKepA1Q3x7HuF+PBcz2kdSp9Y3pnnuaJnG+SDxdQfD0hMGTo5SSlEqaUhalJpJqXTBwNCBQomEIyQeAYlSTA5Sn5e21tG1lELVQkyFWATFRbLAFIJLcQDie04XMrSRr0hLKBTB6Lm+3XnBprbdL94uYQznQCQfY9eeCN/9zwjdS/UXbbfz9fN0zjizKis2uzLJ2o1lgEeEyljohR8H4mdirtVyAtB96qjgC4txTLV4G3P8VVg==")!

    /// Harness writes keys in a fixed order, which the baseline parser relies on.
    private func json(_ value: Any) -> String {
        switch value {
        case let pairs as KeyValuePairs<String, Any>: "{" + pairs.map { "\"\($0.key)\":" + json($0.value) }.joined(separator: ",") + "}"
        case let list as [Any]: "[" + list.map(json).joined(separator: ",") + "]"
        default: String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
    }
    private func line(_ type: String, seq: Int, at offset: Double, _ data: KeyValuePairs<String, Any>) -> Data {
        Data(json(["type": type, "seq": seq, "time": (peak.timeIntervalSince1970 + offset) * 1000, "data": data] as KeyValuePairs<String, Any>).utf8)
    }
    private func response(step: Int, at offset: Double, output: Int, tool: Bool = false, model: String = "deepseek-flash") -> Data {
        let start = Int((peak.timeIntervalSince1970 + offset - 1.5) * 1000), at = Int((peak.timeIntervalSince1970 + offset) * 1000)
        let blocks = tool ? #"[{"type":"reasoning","signature":"x"},{"type":"tool-call"}]"# : #"[{"type":"text"}]"#
        return Data(("""
        {"type":"assistant/message","seq":\(10 + step),"time":\(at),"data":{"turn":1,"step":\(step),"message":{"role":"assistant",\
        "content":[{"type":"text","text":"PRIVATE_ANSWER"}],"source":{"kind":"model","provider":"deepseek-account","model":"\(model)",\
        "replayState":{"blocks":\(blocks)}},"id":"9a6f2bcb-a9c6-4a16-9927-52787f4bf06d"},\
        "usage":{"inputTokens":1000,"outputTokens":\(output),"cacheReadTokens":4000,"cacheWriteTokens":0,"totalTokens":5000},\
        "stream":[{"type":"chunk","time":\(start),"chunk":{"type":"block-start"}},\
        {"type":"text-chunks","time0":\(start + 250),"dt":[100,150],"texts":["PRIVATE","_","TEXT"]},\
        {"type":"chunk","time":\(start + 1400),"chunk":{"type":"finish"}}]},"surfaceOp":"append"}
        """).utf8)
    }
    private func feed(_ state: inout DeepSeekActivityState, _ lines: [Data], attaching: Bool = false, now: Date? = nil) {
        for raw in lines {
            guard let record = DeepSeekSessionLog.parse(raw, light: attaching) else { continue }
            state.consume(record, session: session, attaching: attaching, now: now ?? peak.addingTimeInterval(120))
        }
    }
    private var header: Data {
        Data(json(["type": "session", "version": 4, "id": "session-" + session, "createdAt": Int(peak.timeIntervalSince1970 * 1000),
            "cwd": "/Users/fixture/Projects/demo-app", "delegationDepth": 0] as KeyValuePairs<String, Any>).utf8)
    }

    func testParserKeepsLifecycleAndNumbersButNeverText() throws {
        let full = try XCTUnwrap(DeepSeekSessionLog.parse(response(step: 1, at: 3, output: 300)))
        guard case .response(let value) = full.event else { return XCTFail("not a response") }
        XCTAssertEqual(value.usage, DeepSeekUsage(input: 1000, cacheRead: 4000, output: 300))
        XCTAssertEqual(value.model, "deepseek-flash")
        XCTAssertEqual(value.firstChunkAt?.timeIntervalSince1970 ?? 0, peak.timeIntervalSince1970 + 1.75, accuracy: 0.001)
        XCTAssertEqual(value.lastChunkAt?.timeIntervalSince1970 ?? 0, peak.timeIntervalSince1970 + 2.9, accuracy: 0.001)
        XCTAssertTrue(value.hasText)
        XCTAssertFalse(String(describing: full).contains("PRIVATE"))
        // A baseline read skips the stream but keeps usage and model.
        let light = try XCTUnwrap(DeepSeekSessionLog.parse(response(step: 1, at: 3, output: 300), light: true))
        guard case .response(let quick) = light.event else { return XCTFail("not a response") }
        XCTAssertEqual(quick.usage, value.usage); XCTAssertEqual(quick.model, "deepseek-flash"); XCTAssertNil(quick.firstChunkAt)
        let call = try XCTUnwrap(DeepSeekSessionLog.parse(line("tool/call", seq: 8, at: 4, ["turn": 1, "step": 1, "callId": "call_1",
            "name": "bash", "arguments": "{\"command\":\"PRIVATE_COMMAND\"}"])))
        XCTAssertEqual(call.event, .toolCall(turn: 1, call: "call_1", kind: .other))
        let result = try XCTUnwrap(DeepSeekSessionLog.parse(line("tool/result", seq: 9, at: 5, ["turn": 1, "step": 1,
            "message": ["role": "tool", "toolCallId": "call_1", "content": "PRIVATE_OUTPUT", "isError": false] as KeyValuePairs<String, Any>])))
        XCTAssertEqual(result.event, .toolResult(call: "call_1"))
        let header = try XCTUnwrap(DeepSeekSessionLog.parse(header))
        XCTAssertEqual(header.event, .header(.init(session: session, createdAt: peak, project: "demo-app", parent: nil)))
        // Only version 4 logs are read.
        XCTAssertNil(DeepSeekSessionLog.parse(Data(#"{"type":"session","version":5,"id":"session-11111111-2222-4333-8444-555555555555","createdAt":1793066400000}"#.utf8)))
    }

    func testTurnRunsThroughToolsAndSettlesSpeedLatencyAndCost() throws {
        var state = DeepSeekActivityState()
        feed(&state, [header, line("model/selection", seq: 1, at: 0, ["provider": "deepseek-account", "model": "deepseek-flash", "reasoningEffort": "low"]),
                      line("turn/start", seq: 2, at: 0.1, ["turn": 1]), line("step/start", seq: 3, at: 0.2, ["turn": 1, "step": 1])])
        var value = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(value.phase, .running); XCTAssertEqual(value.stage, .thinking)
        XCTAssertEqual(value.project, "demo-app"); XCTAssertEqual(value.modelName, "deepseek-flash"); XCTAssertEqual(value.reasoningEffort, "low")
        feed(&state, [response(step: 1, at: 2, output: 200, tool: true),
                      line("tool/call", seq: 5, at: 2.1, ["turn": 1, "step": 1, "callId": "call_1", "name": "bash", "arguments": "{}"])])
        value = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(value.stage, .tool)
        let first = try XCTUnwrap(state.performanceUpdates.first)
        XCTAssertEqual(first.response?.outputTokens, 200)
        XCTAssertEqual(first.firstTokenLatency ?? 0, 0.55, accuracy: 0.001) // First chunk at 0.75 s, request at 0.2 s.
        XCTAssertEqual(first.response?.duration ?? 0, 1.7, accuracy: 0.001) // Request at 0.2 s to the last chunk at 1.9 s.
        feed(&state, [line("tool/result", seq: 6, at: 3, ["turn": 1, "step": 1, "message": ["toolCallId": "call_1"] as KeyValuePairs<String, Any>]),
                      line("step/start", seq: 7, at: 3.1, ["turn": 1, "step": 2]),
                      response(step: 2, at: 5, output: 100),
                      line("turn/end", seq: 9, at: 5.1, ["turn": 1, "reason": ["kind": "completed"] as KeyValuePairs<String, Any>])])
        value = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(value.phase, .completed)
        XCTAssertFalse(value.isHistoricalCompletion)
        // 1000 uncached + 4000 cached input and 300 output, at twice the off-peak price.
        let expected = (2000 * 1.0 + 8000 * 0.02 + 300 * 4.0) * 2 / 1_000_000
        XCTAssertEqual(value.turnCost ?? 0, expected, accuracy: 1e-9)
        XCTAssertEqual(state.ledger.total(in: DateInterval(start: peak, duration: 3600)).peak, expected, accuracy: 1e-9)
        XCTAssertEqual(state.latestProvider?.name, "deepseek-account")
        XCTAssertNil(state.performanceUpdates.first?.firstTokenLatency, "Only a turn's first response reports latency")
    }

    func testApprovalAndQuestionWaitUntilAnswered() throws {
        var state = DeepSeekActivityState()
        feed(&state, [header, line("turn/start", seq: 1, at: 0, ["turn": 1]),
                      line("tool/call", seq: 2, at: 1, ["turn": 1, "step": 1, "callId": "call_a", "name": "bash"]),
                      line("approval/asked", seq: 3, at: 1.1, ["id": "approval-1", "toolName": "bash", "callId": "call_a", "reason": "PRIVATE_REASON"])])
        XCTAssertEqual(state.activities.first?.phase, .waitingForInput)
        XCTAssertEqual(state.attention.map(\.kind), [.approval])
        XCTAssertTrue(state.activities.first?.waitingForApproval == true)
        feed(&state, [line("approval/decided", seq: 4, at: 2, ["id": "approval-1", "outcome": "approved"])])
        XCTAssertEqual(state.activities.first?.phase, .running); XCTAssertTrue(state.attention.isEmpty)
        feed(&state, [line("tool/call", seq: 5, at: 3, ["turn": 1, "step": 2, "callId": "call_q", "name": "ask_user_question"])])
        XCTAssertEqual(state.attention.map(\.kind), [.input]); XCTAssertEqual(state.activities.first?.phase, .waitingForInput)
        feed(&state, [line("tool/result", seq: 6, at: 9, ["turn": 1, "step": 2, "message": ["toolCallId": "call_q"] as KeyValuePairs<String, Any>])])
        XCTAssertTrue(state.attention.isEmpty); XCTAssertEqual(state.activities.first?.phase, .running)
        feed(&state, [line("turn/end", seq: 7, at: 10, ["turn": 1, "reason": ["kind": "error"] as KeyValuePairs<String, Any>])])
        XCTAssertEqual(state.activities.first?.phase, .interrupted); XCTAssertTrue(state.activities.first?.turnFailed == true)
    }

    func testBaselineOpenTurnStaysOnlyWhileHarnessHoldsTheLock() throws {
        let open = [header, line("turn/start", seq: 1, at: 0, ["turn": 1]), line("step/start", seq: 2, at: 1, ["turn": 1, "step": 1])]
        var held = DeepSeekActivityState(), released = DeepSeekActivityState()
        feed(&held, open, attaching: true); feed(&released, open, attaching: true)
        held.finalizeHistoricalBaseline(live: [session]); released.finalizeHistoricalBaseline(live: [])
        XCTAssertEqual(held.activities.first?.phase, .running)
        XCTAssertEqual(released.activities.first?.phase, .unknown)
        // A live turn quiet for a minute ends the same way once its lock is gone.
        held.expire(candidates: held.openSessions(quietFor: 60, now: peak.addingTimeInterval(120)), live: [])
        XCTAssertEqual(held.activities.first?.phase, .unknown)
        var done = DeepSeekActivityState()
        feed(&done, open + [line("turn/end", seq: 3, at: 2, ["turn": 1, "reason": ["kind": "completed"] as KeyValuePairs<String, Any>])], attaching: true)
        XCTAssertTrue(done.activities.first?.isHistoricalCompletion == true)
    }

    func testPeakScheduleAndPrices() throws {
        XCTAssertTrue(DeepSeekPricing.isPeak(at: peak))
        XCTAssertFalse(DeepSeekPricing.isPeak(at: peak.addingTimeInterval(2.5 * 3600))) // 12:30
        XCTAssertTrue(DeepSeekPricing.isPeak(at: peak.addingTimeInterval(4 * 3600)))    // 14:00
        XCTAssertFalse(DeepSeekPricing.isPeak(at: peak.addingTimeInterval(-3 * 86_400))) // Saturday
        XCTAssertEqual(DeepSeekPricing.nextChange(after: peak), peak.addingTimeInterval(2 * 3600))
        let usage = try XCTUnwrap(DeepSeekUsage(input: 1_000_000, cacheRead: 0, output: 0))
        XCTAssertEqual(DeepSeekPricing.cost(model: "deepseek-v4-pro", usage: usage, at: peak.addingTimeInterval(-3 * 86_400)) ?? 0, 4.5, accuracy: 1e-9)
        XCTAssertEqual(DeepSeekPricing.cost(model: "deepseek-v4-pro", usage: usage, at: peak) ?? 0, 9, accuracy: 1e-9)
        XCTAssertNil(DeepSeekPricing.cost(model: "unknown-model", usage: usage, at: peak))
        let day = try XCTUnwrap(Calendar.current.dateInterval(of: .day, for: peak))
        XCTAssertEqual(DeepSeekPricing.peakIntervals(overlapping: day).reduce(0) { $0 + $1.duration }, 7 * 3600)
        XCTAssertFalse(DeepSeekPricing.isPeak(at: peak.addingTimeInterval(-26 * 86_400)), "National Day (Thursday 1 October) is off-peak")
        XCTAssertTrue(DeepSeekPricing.isPeak(at: peak.addingTimeInterval(-18 * 86_400)), "The Friday after the holiday is a working day")
        XCTAssertFalse(DeepSeekPricing.isPeak(at: peak.addingTimeInterval(-17 * 86_400)), "A make-up Saturday is treated as a weekend")
        let searchStart = Date(timeIntervalSince1970: 1_793_462_400) // 2026-11-01 00:00 in Beijing.
        XCTAssertNil(DeepSeekPricing.toolCost("web_search", at: searchStart.addingTimeInterval(-1)), "Search is free until November")
        XCTAssertEqual(DeepSeekPricing.toolCost("web_search", at: searchStart) ?? 0, 0.005, accuracy: 1e-9)
        XCTAssertNil(DeepSeekPricing.toolCost("bash", at: searchStart))
        XCTAssertTrue(DeepSeekPricing.isOfficial(provider: "deepseek-account"))
        XCTAssertTrue(DeepSeekPricing.isOfficial(provider: nil), "A log without a provider is Harness's own default")
        XCTAssertFalse(DeepSeekPricing.isOfficial(provider: "openrouter"))
    }

    func testSubagentSpendCountsTowardItsRootTaskAndThirdPartyChannelsAreNotPriced() throws {
        var state = DeepSeekActivityState()
        feed(&state, [header, line("model/selection", seq: 1, at: 0, ["provider": "deepseek-account", "model": "deepseek-flash"]),
                      line("turn/start", seq: 2, at: 0.1, ["turn": 1]), line("step/start", seq: 3, at: 0.2, ["turn": 1, "step": 1])])
        func consume(_ session: String, _ lines: [Data]) {
            for raw in lines {
                guard let record = DeepSeekSessionLog.parse(raw) else { continue }
                state.consume(record, session: session, attaching: false, now: peak.addingTimeInterval(120))
            }
        }
        func childHeader(_ id: String, parent: String) -> Data {
            Data(json(["type": "session", "version": 4, "id": id, "createdAt": Int(peak.timeIntervalSince1970 * 1000),
                "cwd": "/Users/fixture/Projects/demo-app", "parentSession": parent] as KeyValuePairs<String, Any>).utf8)
        }
        let child = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", grandchild = "aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff"
        consume(child, [childHeader(child, parent: "session-" + session),
            line("model/selection", seq: 1, at: 0.5, ["provider": "deepseek-account", "model": "deepseek-flash"]),
            line("turn/start", seq: 2, at: 1, ["turn": 1]), line("step/start", seq: 3, at: 1.2, ["turn": 1, "step": 1]),
            response(step: 1, at: 3, output: 100)])
        consume(grandchild, [childHeader(grandchild, parent: child),
            line("model/selection", seq: 1, at: 0.5, ["provider": "deepseek-account", "model": "deepseek-flash"]),
            line("turn/start", seq: 2, at: 1, ["turn": 1]), line("step/start", seq: 3, at: 1.2, ["turn": 1, "step": 1]),
            response(step: 1, at: 3, output: 100)])
        let each = (1000 * 1.0 + 4000 * 0.02 + 100 * 4.0) * 2 / 1_000_000
        let root = try XCTUnwrap(state.activities.first { $0.id == key })
        XCTAssertEqual(root.turnCost ?? 0, 2 * each, accuracy: 1e-9, "Delegated spend adds to the parent's open turn")
        XCTAssertEqual(root.turnPeakCost ?? 0, 2 * each, accuracy: 1e-9)
        let day = DateInterval(start: peak.addingTimeInterval(-3600), duration: 7200)
        XCTAssertEqual(state.ledger.tasks(in: day).map(\.task), [session], "Both levels count toward the root task")
        XCTAssertEqual(state.ledger.tasks(in: day).first?.total ?? 0, 2 * each, accuracy: 1e-9)
        let usage = DeepSeekLocalUsage(ledger: state.ledger, parents: state.parents)
        XCTAssertEqual(usage.task(of: grandchild), session)
        XCTAssertEqual(usage.subagents(of: session), 2)
        feed(&state, [line("session/title", seq: 4, at: 0.3, ["title": "Fixture task"])])
        state.pruneLedger(now: peak.addingTimeInterval(120))
        XCTAssertEqual(state.titles[session], "Fixture task", "A task with spend keeps its title for where the money went")

        let other = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        consume(other, [childHeader("session-" + other, parent: "none"),
            line("model/selection", seq: 1, at: 0.5, ["provider": "openrouter", "model": "deepseek-flash"]),
            line("turn/start", seq: 2, at: 1, ["turn": 1]), line("step/start", seq: 3, at: 1.2, ["turn": 1, "step": 1]),
            response(step: 1, at: 3, output: 100)])
        XCTAssertNil(state.activities.first { $0.threadID == other }?.turnCost, "A third-party channel bills differently")
        XCTAssertEqual(state.ledger.total(in: day).total, 2 * each, accuracy: 1e-9)
        state.pruneLedger(now: peak.addingTimeInterval(9 * 86_400))
        XCTAssertEqual(state.titles[session], "Fixture task", "A session still known keeps its title after its spend ages out")
    }

    func testReaderAttachesExistingLogAndReadsLaterFramesLive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dsh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions/--tmp-fixture--/session-" + session, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent(DeepSeekSessionReader.logName)
        try opening.write(to: log)
        var reader = DeepSeekSessionReader()
        let now = peak.addingTimeInterval(60)
        let first = reader.read(home: home, discover: true, now: now)
        XCTAssertTrue(first.available); XCTAssertTrue(first.caughtUp)
        XCTAssertEqual(first.lines.count, 3); XCTAssertTrue(first.lines.allSatisfy(\.attaching))
        XCTAssertTrue(first.watchURLs.map { $0.resolvingSymlinksInPath() }.contains(log.resolvingSymlinksInPath()))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: closing.prefix(40)); try handle.close()
        XCTAssertTrue(reader.read(home: home, discover: false, now: now).lines.isEmpty, "A torn frame waits for its writer")
        let rest = try FileHandle(forWritingTo: log)
        try rest.seekToEnd(); try rest.write(contentsOf: closing.dropFirst(40)); try rest.close()
        let second = reader.read(home: home, discover: false, now: now)
        XCTAssertEqual(second.lines.count, 2); XCTAssertFalse(second.lines.contains(where: \.attaching))
        var state = DeepSeekActivityState()
        for line in first.lines + second.lines { state.consume(line.record, session: line.session, attaching: line.attaching, now: now) }
        XCTAssertEqual(state.activities.first?.phase, .completed)
        XCTAssertEqual(state.activities.first?.project, "fixture-project")
        XCTAssertNotNil(state.performanceUpdates.first?.response)
        let lock = try XCTUnwrap(reader.lockURLs(sessions: [session])[session])
        XCTAssertEqual(lock.lastPathComponent, "session.lock")
        XCTAssertEqual(lock.deletingLastPathComponent().resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
    }

    func testStartupCatchupKeepsTurnsAppendedAfterItsBaselineLive() throws {
        let headers = [
            "KLUv/SCKVQMAEsYVG2Br28NiP9tnLp7uPwAAwWswFrv7O3iAQUjiHIDHmSmaoQxnHfpwK41i6yyWH9okQUoQIOldYLgVZsvvAdzdAarqYmYmIsio3ybGze+IhGqN29N5NfqOBgBSCBKEFpiFy9jnFm1LEw==",
            "KLUv/SCKXQMAIgYWG2Br28NiP9tnLp7uPwAAwWswFrv7O3iAQUjiHIDHmSmaoQxnHfpwK41i6yyWH9okQUoQIOldYLgVZsvvAdzdAarqYmYmIomM+m1i3PyOSKjWuD2dV6PvCAYAUggShBaYhRvD5xZtSxM="
        ].map { Data(base64Encoded: $0)! }
        let live = Data(base64Encoded: "KLUv/SD0zQMAksYVGYC5OX3qZRe3t0+p/AMzAoDsPlkqmDmosejF7jpdb1iJQnA6KaSglIbOfOck9TOMdW3FrkkvaaQo+RDRYOA48AwEJv0EUZ9JH958Voa0ARRDqNNfCfUSDAAnEzCgGUxBsTcWEyAKDV61B2gGZgGSIEGL1lZBAQ==")!
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dsh-catchup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = ["a", "b"].map { home.appendingPathComponent("sessions/workspace/\($0)/\(DeepSeekSessionReader.logName)") }
        let now = peak.addingTimeInterval(10)
        for (index, log) in logs.enumerated() {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try headers[index].write(to: log)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(2 - index))], ofItemAtPath: log.path)
        }
        var reader = DeepSeekSessionReader()
        reader.perPassBytes = 1 // Exhaust a pass before the second captured baseline can be read.
        let first = reader.read(home: home, discover: true, now: now)
        XCTAssertFalse(first.caughtUp)
        XCTAssertEqual(first.lines.count, 1)
        let writer = try FileHandle(forWritingTo: logs[1])
        try writer.seekToEnd(); try writer.write(contentsOf: live); try writer.close()
        var lines = first.lines, caughtUp = false
        for _ in 0..<5 {
            let next = reader.read(home: home, discover: false, now: now)
            lines += next.lines
            if next.caughtUp { caughtUp = true; break }
        }
        XCTAssertTrue(caughtUp)
        let starts = lines.filter { if case .turnStart = $0.record.event { return true }; return false }
        XCTAssertEqual(starts.count, 1)
        XCTAssertFalse(try XCTUnwrap(starts.first).attaching)
        var state = DeepSeekActivityState()
        for line in lines { state.consume(line.record, session: line.session, attaching: line.attaching, now: now) }
        let completion = try XCTUnwrap(state.activities.first { $0.phase == .completed })
        XCTAssertFalse(completion.isHistoricalCompletion, "A post-startup ending must retain its unread reminder")
    }

    func testStartupTornFrameKeepsItsBaselineButLaterWholeFramesAreLive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dsh-torn-baseline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("sessions/workspace/session/\(DeepSeekSessionReader.logName)")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try opening.prefix(40).write(to: log)
        var reader = DeepSeekSessionReader()
        XCTAssertTrue(reader.read(home: home, discover: true).lines.isEmpty)
        let writer = try FileHandle(forWritingTo: log)
        try writer.seekToEnd(); try writer.write(contentsOf: opening.dropFirst(40) + closing); try writer.close()
        let next = reader.read(home: home, discover: false)
        XCTAssertTrue(next.caughtUp)
        XCTAssertEqual(next.lines.count, 5)
        XCTAssertTrue(next.lines.prefix(3).allSatisfy(\.attaching))
        XCTAssertFalse(next.lines.suffix(2).contains(where: \.attaching))
        let response = next.lines.first { if case .response = $0.record.event { return true }; return false }
        guard case .response(let sample) = try XCTUnwrap(response).record.event else { return XCTFail("Missing response") }
        XCTAssertNotNil(sample.lastChunkAt, "A live response must keep its performance timing")
    }
}
