import Foundation

/// Only the reserved, ordered engine header is interpreted. The escaped
/// summary/report remains ephemeral and never enters activity or transport.
struct ClaudeAgentNotification {
    let agentID: String
    let itemID: String
    let status: String
    init?(_ text: String) {
        guard text.utf8.count <= 65_536, text.hasPrefix("<task-notification>\n"), text.hasSuffix("\n</task-notification>"),
              !text.contains("<!"), !text.contains("<?") else { return nil }
        var remaining = text.dropFirst("<task-notification>\n".count)
        func field(_ name: String) -> String? {
            let open = "<" + name + ">", close = "</" + name + ">"
            guard remaining.hasPrefix(open), let end = remaining.range(of: close) else { return nil }
            let value = String(remaining.dropFirst(open.count).prefix(upTo: end.lowerBound))
            guard !value.contains("<"), !value.contains(">"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            remaining = remaining[end.upperBound...]
            guard remaining.first == "\n" else { return nil }; remaining = remaining.dropFirst()
            return value
        }
        guard let agent = field("task-id").flatMap({ ClaudeActivityRecord.identifier($0) }),
              let item = field("tool-use-id").flatMap({ ClaudeActivityRecord.identifier($0) }) else { return nil }
        if remaining.hasPrefix("<task-type>") { guard field("task-type") == "local_agent" else { return nil } }
        if remaining.hasPrefix("<output-file>") { guard field("output-file") != nil else { return nil } }
        guard let status = field("status"), ["completed", "failed", "killed"].contains(status),
              remaining.hasPrefix("<summary>"), let summaryEnd = remaining.range(of: "</summary>") else { return nil }
        let summary = remaining.dropFirst("<summary>".count).prefix(upTo: summaryEnd.lowerBound)
        guard !summary.contains("<"), !summary.contains(">") else { return nil }
        remaining = remaining[summaryEnd.upperBound...]
        // Usage/report markup follows the header. It cannot supply IDs or
        // status and is never interpreted or retained by this observer.
        guard remaining.hasSuffix("\n</task-notification>"), !remaining.dropLast("\n</task-notification>".count).contains("</task-notification>") else { return nil }
        agentID = agent; itemID = item; self.status = status
    }
}
