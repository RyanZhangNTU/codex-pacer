import Foundation

/// Identity comes from Codex's MCP envelope. The model supplies only percent.
package struct DurableProgressReceipt: Codable, Sendable {
    package let threadID: String
    package let turnID: String
    package let callID: String
    package let percent: Int
    package let at: Date

    init?(parameters: [String: Any], percent: Int) {
        guard let metadata = parameters["_meta"] as? [String: Any],
              let context = metadata["x-codex-turn-metadata"] as? [String: Any],
              let thread = (metadata["threadId"] as? String).flatMap(UUID.init(uuidString:)),
              (context["thread_id"] as? String).flatMap(UUID.init(uuidString:)) == thread,
              let turn = (context["turn_id"] as? String).flatMap(UUID.init(uuidString:)),
              let call = CodexProgressEvidence.identifier(metadata["callId"]),
              (0...100).contains(percent) else { return nil }
        threadID = thread.uuidString.lowercased()
        turnID = turn.uuidString.lowercased()
        callID = call; self.percent = percent; at = Date()
    }

    package func isRecent(at now: Date) -> Bool {
        UUID(uuidString: threadID)?.uuidString.lowercased() == threadID &&
            UUID(uuidString: turnID)?.uuidString.lowercased() == turnID &&
            CodexProgressEvidence.identifier(callID) != nil && (0...100).contains(percent) &&
            (-5...900).contains(now.timeIntervalSince(at))
    }
}

/// Upgrade evidence for the opt-in Dot switch: the local Durable reporter has
/// recorded at least one receipt in this Codex home. Recency is ignored, so a
/// profile that used Dot keeps it after an upgrade; other profiles start off.
public enum DurableUsageEvidence {
    public static let receiptsPath = "pacer/codex-progress/durable-marketplace/receipts/latest.json"

    public static func hasReceipts(home: URL, files: any PlatformFileSystem) -> Bool {
        let url = home.appendingPathComponent(receiptsPath)
        guard files.metadata(url)?.isRegularFile == true,
              let data = try? files.read(url, offset: 0, maximumBytes: 64 * 1024 + 1), data.count <= 64 * 1024,
              let values = try? JSONDecoder().decode([String: DurableProgressReceipt].self, from: data) else { return false }
        return !values.isEmpty
    }
}

/// Metadata from the Durable app server's read-only turn and item pages.
/// The parser retains no transcript or tool output.
package struct DurableTurnHistory: Sendable {
    package enum Status: String, Sendable {
        case inProgress, completed, failed, interrupted
    }

    package struct Report: Sendable {
        let id: String
        let percent: Int
        package let at: Date?
    }

    let threadID: String
    let name: String?
    package let turnID: String
    let rootTurnID: String?
    package let status: Status
    package let startedAt: Date?
    package let completedAt: Date?
    package var report: Report?

    @discardableResult
    package mutating func useLocalReceipt(_ receipt: DurableProgressReceipt) -> Bool {
        guard receipt.threadID == threadID, receipt.turnID == turnID.lowercased(),
              receipt.at >= (startedAt ?? .distantPast),
              receipt.at < (completedAt?.addingTimeInterval(1) ?? .distantFuture) else { return false }
        report = Report(id: receipt.callID, percent: receipt.percent, at: receipt.at)
        return true
    }

    package static func latest(_ result: JSONFieldView, thread: DurableActivityCatalog.Entry,
                               now: Date = Date()) throws -> Self? {
        let fields = try result.fields(["data"])
        guard let data = fields["data"], data.isArray else { throw CodexClientError.invalidResponse }
        guard let entry = try data.elements(maximumCount: 1).first else { return nil }
        let turn = try entry.fields(["id", "rootTurnId", "status", "startedAt", "completedAt"])
        guard let id = CodexProgressEvidence.identifier(turn["id"]?.string(limit: 256)),
              let status = turn["status"]?.string(limit: 20).flatMap(Status.init(rawValue:)) else { return nil }
        let started = date(turn["startedAt"], now: now)
        let completed = date(turn["completedAt"], now: now)
        if let started, let completed, started > completed { return nil }
        return Self(threadID: thread.id, name: thread.name, turnID: id,
                    rootTurnID: CodexProgressEvidence.identifier(turn["rootTurnId"]?.string(limit: 256)),
                    status: status, startedAt: started, completedAt: completed, report: nil)
    }

    package func receiptPage(_ result: JSONFieldView, now: Date = Date()) throws -> (report: Report?, next: String?) {
        let fields = try result.fields(["data", "nextCursor"])
        guard let rows = fields["data"], rows.isArray else { throw CodexClientError.invalidResponse }
        // The server returns the newest entries first. An unsuccessful newer
        // call must not hide the most recent successful one.
        for row in try rows.elements(maximumCount: 32) {
            let entry = try row.fields(["turnId", "completedAtMs", "item"])
            guard entry["turnId"]?.string(limit: 256) == turnID, let item = entry["item"] else { continue }
            let fields = try item.fields(["id", "type", "server", "tool", "status", "arguments", "result"])
            guard fields["type"]?.string(limit: 16) == "mcpToolCall",
                  fields["server"]?.string(limit: 32) == CodexProgressEvidence.server,
                  fields["tool"]?.string(limit: 32) == CodexProgressEvidence.tool,
                  fields["status"]?.string(limit: 16) == "completed",
                  let id = CodexProgressEvidence.identifier(fields["id"]?.string(limit: 256)),
                  let percent = CodexProgressEvidence.percent(fields["arguments"]),
                  CodexProgressEvidence.resultAccepted(fields["result"]) else { continue }
            let at = Self.date(entry["completedAtMs"], divisor: 1000, now: now)
            if let at, let startedAt, at < startedAt { continue }
            return (Report(id: id, percent: percent, at: at), nil)
        }
        return (nil, fields["nextCursor"]?.string(limit: 1024))
    }

    private static func date(_ field: JSONFieldView?, divisor: Double = 1, now: Date) -> Date? {
        guard let value = field?.number().map({ $0 / divisor }), value > 0,
              value <= now.timeIntervalSince1970 + 5 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}
