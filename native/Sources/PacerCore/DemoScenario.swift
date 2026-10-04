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
    public static func quota(at now: Date) -> [QuotaSnapshot] {
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
            let wire: [String: Any] = [
                "rateLimitResetCredits": ["availableCount": 2, "credits": [
                    ["id": "demo-reset-1", "status": "available", "grantedAt": now.addingTimeInterval(-86400).timeIntervalSince1970,
                     "expiresAt": now.addingTimeInterval(12 * 3600).timeIntervalSince1970],
                    ["id": "demo-reset-2", "status": "available", "grantedAt": now.addingTimeInterval(-43200).timeIntervalSince1970,
                     "expiresAt": now.addingTimeInterval(36 * 3600).timeIntervalSince1970]]],
                "rateLimits": ["limitId": "codex", "planType": "pro", "credits": ["hasCredits": true, "unlimited": false, "balance": "12500"],
                    "secondary": ["usedPercent": 100 - remaining, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970]]]
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

    private static func task(id: String, name: String, stage: DemoTaskStage, at now: Date,
                             sourceID: String? = nil, sourceName: String? = nil) -> SessionActivity {
        var stream = RuntimeEventState(sourceID: sourceID, sourceName: sourceName)
        stream.consume(["kind": "status", "connected": true, "attached": 1])
        func event(_ method: String, _ ago: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["method": method, "threadId": id, "turnId": "demo-turn", "at": now.addingTimeInterval(ago).timeIntervalSince1970]
            value.merge(fields) { _, new in new }; return value
        }
        var events = [event("metadata", -30, ["name": name, "model": "Codex"]), event("turn/started", -30),
                      event("item/started", -28, ["itemId": "reasoning", "itemType": "reasoning"]),
                      event("thread/tokenUsage/updated", -25, ["outputTokens": 300]),
                      event("thread/tokenUsage/updated", -14, ["outputTokens": 965])]
        if stage == .tool {
            events += [event("item/started", -10, ["itemId": "tool", "itemType": "commandExecution"])]
        } else {
            if stage == .responding {
                events += [event("item/started", -9, ["itemId": "answer", "itemType": "agentMessage"]),
                           event("item/agentMessage/delta", -1)]
            }
            events += [event("thread/tokenUsage/updated", 0, ["outputTokens": 1815])]
            if stage == .completed { events += [event("turn/completed", 0, ["status": "completed"])] }
        }
        stream.consume(["kind": "runtimeBatch", "events": events])
        return stream.activities[0]
    }
}
