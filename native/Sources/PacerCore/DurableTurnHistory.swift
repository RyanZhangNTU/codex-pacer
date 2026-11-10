import Foundation

/// Metadata from the Durable app server's read-only turn and item pages.
/// The parser retains no transcript or tool output.
package struct DurableTurnHistory: Sendable {
    package enum Status: String, Sendable {
        case inProgress, completed, failed, interrupted
    }

    package struct Report: Sendable {
        let id: String
        let percent: Int
        let at: Date?
    }

    let threadID: String
    let name: String?
    package let turnID: String
    let rootTurnID: String?
    package let status: Status
    package let startedAt: Date?
    package let completedAt: Date?
    package var report: Report?

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
