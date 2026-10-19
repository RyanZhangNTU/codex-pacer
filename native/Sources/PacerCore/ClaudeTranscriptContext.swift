import Foundation

/// IDs only. Parent links keep a late previous response attached to its own
/// prompt instead of charging it to whichever turn is currently visible.
struct ClaudeTranscriptContext: Sendable {
    /// Stands in for the owner of a record whose parent has not been read yet.
    /// Deferred rows carry it until release; it never leaves the reader.
    static let pendingOwner = "pacer-pending-owner"
    // Encoded rows have sorted, unspaced keys and escaped string values, so
    // these byte patterns match only the fields themselves.
    private static let pendingField = Data(#""promptId":"pacer-pending-owner""#.utf8)
    private static let unownedField = Data(#""unownedTurn":true"#.utf8)
    private static let metadataKind = Data(#""kind":"metadata""#.utf8)
    private static let replyEnding = Data(#""awaitsReply":true"#.utf8)
    struct Release: Sendable {
        let rows: [Data]
        let historical: Bool
    }
    private struct Node: Sendable {
        var prompt: String?
        var parent: String?
    }
    private var nodes: [String: Node] = [:]
    private var order: [String] = []
    /// Deferred records by the unread ID they wait for, in file order. Out of
    /// order writes involve a few nearby records, so both bounds stay small.
    private var waiting: [String: [Release]] = [:]
    private var awaitedOrder: [String] = []
    private var released: [Release] = []
    /// The unread ancestor that the last record's ownership waits for.
    private(set) var awaitedParent: String?
    private(set) var parentLookups = 0
    var deferredRows: Int { waiting.values.joined().reduce(0) { $0 + $1.rows.count } }

    /// Follows parent links to a proven prompt, the first unread ID or a root
    /// without an owner. Walked links are compressed onto that answer, so a
    /// long unresolved chain is not walked again for every later record.
    private mutating func resolve(_ start: String?) -> (prompt: String?, missing: String?) {
        var current = start, path: [String] = []
        for _ in 0...nodes.count {
            guard let id = current else {
                if let root = path.last { for walked in path.dropLast() { nodes[walked]?.parent = root } }
                return (nil, nil)
            }
            parentLookups += 1
            guard let node = nodes[id] else {
                for walked in path { nodes[walked]?.parent = id }
                return (nil, id)
            }
            if let prompt = node.prompt {
                for walked in path { nodes[walked]?.prompt = prompt }
                return (prompt, nil)
            }
            path.append(id); current = node.parent
        }
        return (nil, nil) // A cycle never proves ownership.
    }
    mutating func promptID(for bytes: Data, sessionID: String, parentID: String?) -> String? {
        guard let parsed = ClaudeTranscriptFields(bytes) else { return nil }
        return promptID(for: parsed, sessionID: sessionID, parentID: parentID)
    }
    mutating func promptID(for parsed: ClaudeTranscriptFields, sessionID: String, parentID: String?) -> String? {
        awaitedParent = nil
        let fields = parsed.values
        guard ClaudeActivityRecord.identifier(fields["sessionId"]?.string() ?? sessionID) == (parentID ?? sessionID) else { return nil }
        let parent = ClaudeActivityRecord.identifier(fields["parentUuid"]?.string())
        var prompt = ClaudeActivityRecord.identifier(fields["promptId"]?.string()), missing: String?
        if prompt == nil { (prompt, missing) = resolve(parent) }
        if prompt == nil, fields["type"]?.string(limit: 24) == "user",
           let origin = fields["origin"].flatMap({ try? $0.fields(["kind"]) }), origin["kind"]?.string(limit: 24) == "human" {
            prompt = ClaudeActivityRecord.identifier(fields["uuid"]?.string())
        }
        if let id = ClaudeActivityRecord.identifier(fields["uuid"]?.string()) {
            // Desktop can persist an attachment before its parent tool result.
            // Retain that unresolved edge so a later descendant can resolve it
            // once the parent arrives. A repeated record keeps proven ownership.
            if missing == id { missing = nil }
            if nodes[id] == nil { order.append(id) } else if prompt == nil { prompt = nodes[id]?.prompt }
            nodes[id] = Node(prompt: prompt, parent: parent)
            if order.count > 512 { nodes.removeValue(forKey: order.removeFirst()) }
            settle(id, prompt: prompt, missing: missing)
        }
        if prompt == nil { awaitedParent = missing }
        return prompt
    }

    /// The rows a record emits before its owner is known. `transcript`
    /// differs without an owner only in this field and the reply-box ending,
    /// which it emits for owned turns alone.
    static func unowned(_ owned: [Data]) -> [Data] {
        owned.compactMap { row in
            guard let field = row.range(of: pendingField) else { return row }
            guard row.range(of: replyEnding) == nil else { return nil }
            var row = row; row.replaceSubrange(field, with: unownedField)
            return row
        }
    }

    /// Keeps the owned form of the record just read, built with
    /// `pendingOwner`, until its awaited parent arrives. Metadata already
    /// applies without an owner, so only the other rows wait.
    mutating func deferLast(_ rows: [Data], historical: Bool) {
        guard let awaiting = awaitedParent else { return }
        let rows = rows.filter { $0.range(of: Self.metadataKind) == nil }
        guard !rows.isEmpty else { return }
        enqueue([Release(rows: rows, historical: historical)], awaiting: awaiting)
    }

    /// Deferred records whose owner the last record proved, in file order.
    mutating func takeReleased() -> [Release] {
        defer { released.removeAll() }
        return released
    }

    /// Keeps at most 16 awaited IDs and the newest 64 rows for each.
    private mutating func enqueue(_ entries: [Release], awaiting: String) {
        if waiting[awaiting] == nil {
            awaitedOrder.append(awaiting)
            if awaitedOrder.count > 16 { waiting.removeValue(forKey: awaitedOrder.removeFirst()) }
        }
        var list = (waiting[awaiting] ?? []) + entries, count = list.reduce(0) { $0 + $1.rows.count }
        while count > 64, list.count > 1 { count -= list.removeFirst().rows.count }
        waiting[awaiting] = list
    }

    private mutating func settle(_ id: String, prompt: String?, missing: String?) {
        guard let entries = waiting.removeValue(forKey: id) else { return }
        awaitedOrder.removeAll { $0 == id }
        if let prompt {
            // Identifiers need no JSON escaping.
            let owner = Data(("\"promptId\":\"" + prompt + "\"").utf8)
            released += entries.map { entry in
                Release(rows: entry.rows.map { row in
                    guard let field = row.range(of: Self.pendingField) else { return row }
                    var row = row; row.replaceSubrange(field, with: owner)
                    return row
                }, historical: entry.historical)
            }
        } else if let missing {
            enqueue(entries, awaiting: missing)
        } // A cycle or a root without an owner cannot release them.
    }
}
