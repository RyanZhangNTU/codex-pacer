import Foundation

/// IDs only. Parent links keep a late previous response attached to its own
/// prompt instead of charging it to whichever turn is currently visible.
struct ClaudeTranscriptContext: Sendable {
    private struct Node: Sendable {
        let prompt: String?
        let parent: String?
    }
    private var nodes: [String: Node] = [:]
    private var order: [String] = []
    private func resolvedPrompt(for id: String?) -> String? {
        var current = id, visited = Set<String>()
        while let id = current, visited.insert(id).inserted, let node = nodes[id] {
            if let prompt = node.prompt { return prompt }
            current = node.parent
        }
        return nil
    }
    mutating func promptID(for bytes: Data, sessionID: String, parentID: String?) -> String? {
        guard let parsed = ClaudeTranscriptFields(bytes) else { return nil }
        return promptID(for: parsed, sessionID: sessionID, parentID: parentID)
    }
    mutating func promptID(for parsed: ClaudeTranscriptFields, sessionID: String, parentID: String?) -> String? {
        let fields = parsed.values
        guard ClaudeActivityRecord.identifier(fields["sessionId"]?.string() ?? sessionID) == (parentID ?? sessionID) else { return nil }
        let parent = ClaudeActivityRecord.identifier(fields["parentUuid"]?.string())
        var prompt = ClaudeActivityRecord.identifier(fields["promptId"]?.string())
        if prompt == nil { prompt = resolvedPrompt(for: parent) }
        if prompt == nil, fields["type"]?.string(limit: 24) == "user",
           let origin = fields["origin"].flatMap({ try? $0.fields(["kind"]) }), origin["kind"]?.string(limit: 24) == "human" {
            prompt = ClaudeActivityRecord.identifier(fields["uuid"]?.string())
        }
        if let id = ClaudeActivityRecord.identifier(fields["uuid"]?.string()) {
            // Desktop can persist an attachment before its parent tool result.
            // Retain that unresolved edge so a later descendant can resolve it
            // once the parent arrives. Cache proven ownership for long chains.
            if nodes[id] == nil { order.append(id) }
            nodes[id] = Node(prompt: prompt, parent: parent)
            if order.count > 512 { nodes.removeValue(forKey: order.removeFirst()) }
        }
        return prompt
    }
}
