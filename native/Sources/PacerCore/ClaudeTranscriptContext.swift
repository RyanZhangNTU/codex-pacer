import Foundation

/// IDs only. Parent links keep a late previous response attached to its own
/// prompt instead of charging it to whichever turn is currently visible.
struct ClaudeTranscriptContext: Sendable {
    private var prompts: [String: String] = [:]
    private var order: [String] = []
    mutating func promptID(for bytes: Data, sessionID: String, parentID: String?) -> String? {
        guard let parsed = ClaudeTranscriptFields(bytes) else { return nil }
        return promptID(for: parsed, sessionID: sessionID, parentID: parentID)
    }
    mutating func promptID(for parsed: ClaudeTranscriptFields, sessionID: String, parentID: String?) -> String? {
        let fields = parsed.values
        guard ClaudeActivityRecord.identifier(fields["sessionId"]?.string() ?? sessionID) == (parentID ?? sessionID) else { return nil }
        var prompt = ClaudeActivityRecord.identifier(fields["promptId"]?.string())
        if prompt == nil, let parent = ClaudeActivityRecord.identifier(fields["parentUuid"]?.string()) { prompt = prompts[parent] }
        if prompt == nil, fields["type"]?.string(limit: 24) == "user",
           let origin = fields["origin"].flatMap({ try? $0.fields(["kind"]) }), origin["kind"]?.string(limit: 24) == "human" {
            prompt = ClaudeActivityRecord.identifier(fields["uuid"]?.string())
        }
        if let id = ClaudeActivityRecord.identifier(fields["uuid"]?.string()), let prompt {
            if prompts[id] == nil { order.append(id) }
            prompts[id] = prompt
            if order.count > 512 { prompts.removeValue(forKey: order.removeFirst()) }
        }
        return prompt
    }
}
