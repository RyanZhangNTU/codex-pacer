import Foundation

/// Synthetic event/usage fixtures. Never connects to Codex or reads user data.
public enum DemoTaskStage: Int, CaseIterable {
    case thinking, tool, responding, completed
    public var label: String {
        switch self {
        case .thinking: return L10n.text("demo.thinking")
        case .tool: return L10n.text("demo.tool")
        case .responding: return L10n.text("activity.responding")
        case .completed: return L10n.text("activity.turn_finished")
        }
    }
}

public enum DemoScenario {
    /// Codex is a weekly-only Pro sample with banked resets; Claude reports
    /// both its 5-hour and 7-day windows.
    public static func quota(_ provider: AgentProvider = .codex, at now: Date) -> [QuotaSnapshot] {
        let reset = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0,
            of: now.addingTimeInterval(2 * 86400))!
        let start = reset.addingTimeInterval(-7 * 86400)
        // Uneven work bursts and idle plateaus, sampled across the elapsed cycle.
        let trace: [(Double, Double)] = [
            (0,100),(0.01,100),(0.06,100),(0.10,99),(0.13,97),(0.145,90),
            (0.165,87),(0.21,86),(0.27,86),(0.30,85),(0.32,82),(0.35,76),
            (0.39,73),(0.42,73),(0.47,73),(0.51,72),(0.57,72),(0.60,71),
            (0.625,66),(0.645,64),(0.66,64),(0.70,64),(0.735,64),(0.75,58),
            (0.77,51),(0.80,47),(0.83,46),(0.88,46),(0.93,46),(0.97,43),(1,43)
        ]
        return trace.map { fraction, remaining in
            let capture = start.addingTimeInterval(now.timeIntervalSince(start) * fraction)
            let weekly = provider == .codex ? remaining : min(100, remaining + 21)
            var limits: [String: Any] = ["limitId": provider.rawValue, "planType": provider == .codex ? "pro" : "max",
                "secondary": ["usedPercent": 100 - weekly, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970]]
            var wire: [String: Any] = [:]
            if provider == .codex {
                limits["credits"] = ["hasCredits": true, "unlimited": false, "balance": "12500"]
                wire["rateLimitResetCredits"] = ["availableCount": 2, "credits": [
                    ["id": "demo-reset-1", "status": "available", "grantedAt": now.addingTimeInterval(-86400).timeIntervalSince1970,
                     "expiresAt": now.addingTimeInterval(12 * 3600).timeIntervalSince1970],
                    ["id": "demo-reset-2", "status": "available", "grantedAt": now.addingTimeInterval(-43200).timeIntervalSince1970,
                     "expiresAt": now.addingTimeInterval(36 * 3600).timeIntervalSince1970]]]
            } else {
                limits["primary"] = ["usedPercent": 19, "windowDurationMins": 300,
                                     "resetsAt": now.addingTimeInterval(2 * 3600 + 40 * 60).timeIntervalSince1970]
            }
            wire["rateLimits"] = limits
            var value = try! QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: wire), capturedAt: capture)
            value.accountScope = "demo"
            return value
        }
    }

    public static func tasks(stage: DemoTaskStage, at now: Date) -> [SessionActivity] {
        [task(id: "00000000-0000-4000-8000-000000000001", name: L10n.text("demo.optimize"), stage: stage, at: now),
         task(id: "00000000-0000-4000-8000-000000000002", name: L10n.text("demo.verify_remote"), stage: .tool, at: now,
              sourceID: "remote-ssh-discovered:demo", sourceName: "SSH")]
    }

    /// A Claude task beside the Codex samples that follows the same stage, so
    /// the completion stage leaves Codex running alone and the others bring
    /// both providers back together.
    public static func claudeTask(stage: DemoTaskStage, at now: Date) -> SessionActivity {
        var state = ClaudeActivityState()
        func record(_ kind: String, _ ago: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["kind": kind, "origin": "hook", "sessionId": "00000000-0000-4000-8000-000000000003",
                                        "promptId": "demo-prompt", "at": now.addingTimeInterval(ago).timeIntervalSince1970]
            value.merge(fields) { _, new in new }; return value
        }
        var records = [record("metadata", -40, ["title": L10n.text("demo.review_notes"), "model": "claude-opus-5-5", "effort": "xhigh"]),
                       record("prompt", -40), record("thinking", -36, ["itemId": "thinking"])]
        if stage == .completed { records.append(record("stopVerified", 0)) }
        state.consume(ClaudeActivityRecord.encode(["kind": "claudeBatch", "records": records])!, now: now)
        return state.activities[0]
    }

    /// A DeepSeek Harness task beside the others, with a settled response so
    /// its speed, first-output time and estimated cost appear.
    static let demoDeepSeekSession = "00000000-0000-4000-8000-000000000004"
    static let demoDeepSeekSecondSession = "00000000-0000-4000-8000-000000000005"
    public static func deepseekTask(stage: DemoTaskStage, at now: Date) -> SessionActivity {
        var state = DeepSeekActivityState()
        let session = demoDeepSeekSession
        func record(_ ago: Double, _ event: DeepSeekLogEvent, seq: Int) -> DeepSeekLogRecord {
            DeepSeekLogRecord(seq: seq, at: now.addingTimeInterval(ago), event: event)
        }
        var records = [record(-50, .header(.init(session: session, createdAt: now.addingTimeInterval(-50), project: L10n.text("demo.deepseek_project"), parent: nil)), seq: 0),
            record(-50, .title(L10n.text("demo.deepseek_task")), seq: 1),
            record(-50, .model("deepseek-v4-pro", effort: "high", reported: true, provider: "deepseek-account"), seq: 2),
            record(-48, .turnStart(1), seq: 3), record(-47, .stepStart(turn: 1, step: 1), seq: 4),
            record(-20, .response(.init(turn: 1, step: 1, model: "deepseek-v4-pro", usage: DeepSeekUsage(input: 18_000, cacheRead: 96_000, output: 2_400),
                firstChunkAt: now.addingTimeInterval(-45.6), lastChunkAt: now.addingTimeInterval(-20), hasText: false, hasReasoning: true, toolCalls: 1)), seq: 5),
            record(-20, .toolCall(turn: 1, call: "demo-call", kind: .other), seq: 6)]
        if stage != .tool { records += [record(-12, .toolResult(call: "demo-call"), seq: 7), record(-12, .stepStart(turn: 1, step: 2), seq: 8)] }
        if stage == .completed {
            records += [record(-1, .response(.init(turn: 1, step: 2, model: "deepseek-v4-pro", usage: DeepSeekUsage(input: 1_200, cacheRead: 116_000, output: 900),
                firstChunkAt: now.addingTimeInterval(-10.8), lastChunkAt: now.addingTimeInterval(-1), hasText: true, hasReasoning: true, toolCalls: 0)), seq: 9),
                record(0, .turnEnd(turn: 1, outcome: .completed), seq: 10)]
        }
        for value in records { state.consume(value, session: session, attaching: false, now: now) }
        return state.activities[0]
    }

    /// A week of uneven spending with peak-hour work on weekdays.
    public static func deepseekUsage(at now: Date, calendar: Calendar = .current) -> DeepSeekLocalUsage {
        var ledger = DeepSeekSpendLedger()
        let hours: [(Int, Double)] = [(9, 0.9), (10, 2.4), (11, 1.6), (14, 1.1), (15, 2.8), (16, 1.9), (17, 0.7), (20, 1.4), (21, 2.2), (22, 0.8)]
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { continue }
            let scale = [1.0, 0.7, 1.3, 0.5, 0.9, 1.1, 0.4, 0.8][offset]
            for (hour, cost) in hours {
                guard let at = calendar.date(bySettingHour: hour, minute: 20, second: 0, of: day), at < now else { continue }
                // Today's morning belongs to the demo task, the afternoon to a second one.
                let task = offset > 0 ? nil : hour < 12 ? demoDeepSeekSession : hour < 17 ? demoDeepSeekSecondSession : nil
                ledger.record(id: "demo:\(offset):\(hour)", at: at, cost: cost * scale, task: task)
            }
        }
        for span in 0..<12 {
            let at = now.addingTimeInterval(-Double(span * 600 + 180))
            guard calendar.isDate(at, inSameDayAs: now) else { continue }
            ledger.record(id: "demo:recent:\(span)", at: at, cost: [0.32, 0.18, 0.4, 0.22][span % 4], task: demoDeepSeekSession)
        }
        return DeepSeekLocalUsage(ledger: ledger, provider: "deepseek-account",
            parents: ["00000000-0000-4000-8000-0000000000a1": demoDeepSeekSession, "00000000-0000-4000-8000-0000000000a2": demoDeepSeekSession],
            titles: [demoDeepSeekSession: L10n.text("demo.deepseek_task"), demoDeepSeekSecondSession: L10n.text("demo.deepseek_task_second")])
    }

    /// Bounded synthetic graph for native grouping/retained-rate UI acceptance.
    public static func subagentTasks(stage: DemoTaskStage, at now: Date) -> [SessionActivity] {
        let parent = "019a0000-0000-7000-8000-000000000101"
        var result = [task(id: parent, name: L10n.text("demo.optimize"), stage: stage, at: now)]
        for index in 1...3 {
            var child = task(id: String(format: "019a0000-0000-7000-8000-%012d", 101 + index),
                name: "Demo subagent", stage: stage, at: now)
            child.updateParent(parent); result.append(child)
        }
        return result
    }

    private static func task(id: String, name: String, stage: DemoTaskStage, at now: Date,
                             sourceID: String? = nil, sourceName: String? = nil) -> SessionActivity {
        var stream = RuntimeEventState(sourceID: sourceID, sourceName: sourceName)
        stream.consume(["kind": "status", "connected": true, "attached": 1])
        func event(_ method: String, _ ago: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["method": method, "threadId": id, "turnId": "demo-turn", "at": now.addingTimeInterval(ago).timeIntervalSince1970]
            value.merge(fields) { _, new in new }; return value
        }
        var events = [event("metadata", -30, ["name": name, "model": "gpt-6.1-sol", "reasoningEffort": "high"]), event("turn/started", -30),
                      event("item/started", -28, ["itemId": "reasoning", "itemType": "reasoning", "hasText": true]),
                      event("thread/tokenUsage/updated", -25, ["outputTokens": 300]),
                      event("item/completed", -14, ["itemId": "reasoning", "itemType": "reasoning"]),
                      event("thread/tokenUsage/updated", -14, ["outputTokens": 965, "lastOutputTokens": 665, "lastReasoningTokens": 265])]
        if stage == .tool {
            events += [event("item/started", -10, ["itemId": "tool", "itemType": "commandExecution"])]
        } else {
            if stage == .responding {
                events += [event("item/started", -9, ["itemId": "answer", "itemType": "agentMessage"]),
                           event("item/agentMessage/delta", -1, ["hasText": true])]
            }
            events += [event("item/completed", 0, ["itemId": "answer", "itemType": "agentMessage"]),
                       event("thread/tokenUsage/updated", 0, ["outputTokens": 1815, "lastOutputTokens": 850, "lastReasoningTokens": 100])]
            if stage == .completed { events += [event("turn/completed", 0, ["status": "completed"])] }
        }
        stream.consume(["kind": "runtimeBatch", "events": events])
        return stream.activities[0]
    }
}
