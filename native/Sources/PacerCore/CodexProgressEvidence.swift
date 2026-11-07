import Foundation

/// Only the dedicated Pacer tool can report progress. The estimate is accepted
/// after an observed successful result, never from a prompt or assistant text.
enum CodexProgressEvidence {
    static let server = "pacer_progress"
    static let tool = "report_progress"
    static let qualified = "mcp__pacer_progress__report_progress"
    static let acknowledgment = "pacer-progress:accepted"

    static func matches(name: String?, namespace: String?) -> Bool {
        (name == qualified && (namespace == nil || namespace == "")) ||
            (name == tool && [server, "mcp__" + server].contains(namespace ?? ""))
    }

    static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              !["d", "f"].contains(String(cString: number.objCType)),
              let encoded = try? JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed]),
              let view = try? JSONFieldView.document(encoded, maximumBytes: 3),
              let value = view.integer(), (0...100).contains(value) else { return nil }
        return value
    }

    static func percent(_ arguments: Any?) -> Int? {
        if let arguments = arguments as? [String: Any], arguments.count == 1 { return integer(arguments["percent"]) }
        guard let text = arguments as? String, text.utf8.count <= 128,
              let view = try? JSONFieldView.document(Data(text.utf8), maximumBytes: 128) else { return nil }
        return percent(view)
    }

    static func percent(_ view: JSONFieldView?) -> Int? {
        guard let view, view.isObject, let fields = try? view.fields(maximumCount: 1), fields.count == 1,
              let value = fields["percent"]?.integer(), (0...100).contains(value) else { return nil }
        return value
    }

    static func isAcknowledgment(_ output: Any?) -> Bool {
        if let text = output as? String { return text == acknowledgment }
        guard let items = output as? [[String: Any]], (1...2).contains(items.count), let item = items.last else { return false }
        if items.count == 2 {
            guard items[0]["type"] as? String == "input_text", let prefix = items[0]["text"] as? String,
                  prefix.utf8.count <= 128, prefix.hasPrefix("Wall time: "), prefix.hasSuffix("\nOutput:") else { return false }
        }
        return ["input_text", "text"].contains(item["type"] as? String ?? "") && item["text"] as? String == acknowledgment
    }

    static func isReportItem(_ item: [String: Any]) -> Bool {
        ["mcpToolCall", "mcp_tool_call", "McpToolCall"].contains(item["type"] as? String ?? "") &&
            item["server"] as? String == server && item["tool"] as? String == tool
    }

    static func itemPercent(_ item: [String: Any]) -> Int? {
        guard isReportItem(item), ["completed", "Completed"].contains(item["status"] as? String ?? ""),
              let result = item["result"] as? [String: Any], result["isError"] as? Bool != true,
              result["is_error"] as? Bool != true, isAcknowledgment(result["content"]) else { return nil }
        return percent(item["arguments"])
    }

    static func resultAccepted(_ view: JSONFieldView?) -> Bool {
        guard let view, view.isObject, let fields = try? view.fields(["content", "isError", "is_error"]),
              fields["isError"]?.boolean() != true, fields["is_error"]?.boolean() != true,
              let items = try? fields["content"]?.elements(maximumCount: 1), items.count == 1,
              let item = try? items[0].fields(["type", "text"]) else { return false }
        return item["type"]?.string(limit: 16) == "text" && item["text"]?.string(limit: 32) == acknowledgment
    }

    /// Match modern turn IDs and older bounded IDs without guessing ownership.
    static func identifier(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
        return value
    }
}

struct CodexTurnSteps: Equatable, Sendable {
    struct Report: Equatable, Sendable { let percent: Int; let at: Date }
    var reports: [String: Report] = [:]
    var tools: [String: Date] = [:]
    var waits: [String: Date] = [:]
    var foregroundItems: Set<String> = []
    var blockingCalls: Set<String> = []
    var blockingFlags: Set<String> = []

    var isBlocked: Bool { !blockingCalls.isEmpty || !blockingFlags.isEmpty }
    var waitingSince: Date? { tools.isEmpty && foregroundItems.isEmpty ? waits.values.min() : nil }

    mutating func start(_ id: String, at: Date, waiting: Bool) {
        if waiting {
            if waits.count < 128, waits[id] == nil { waits[id] = at }
        } else if tools.count < 128, tools[id] == nil { tools[id] = at }
    }

    mutating func finish(_ id: String) {
        tools.removeValue(forKey: id)
        waits.removeValue(forKey: id)
        foregroundItems.remove(id)
    }
}

struct CodexGoalEvidence: Equatable, Sendable {
    enum Status: String, Sendable {
        case active, paused, blocked, usageLimited, budgetLimited, complete
        var pauseLabel: String? {
            switch self {
            case .paused: L10n.text("activity.goal_paused")
            case .blocked: L10n.text("activity.goal_blocked")
            case .usageLimited: L10n.text("activity.goal_usage_limit")
            case .budgetLimited: L10n.text("activity.goal_budget_limit")
            case .active, .complete: nil
            }
        }
    }
    let status: Status
    let createdAt: Double
    let updatedAt: Double
    let observedAt: Date
}
