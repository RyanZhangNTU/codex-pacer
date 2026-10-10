import Foundation
import CryptoKit

private enum DesktopPath: Equatable {
    case key(String), index(Int)
}

/// Value semantics provide atomic patches with copies of changed containers,
/// not deep copies of every historical item in the conversation.
private indirect enum DesktopValue: Equatable {
    case object([String: DesktopValue]), list([DesktopValue])
    case items(count: Int, values: [Int: DesktopValue], hydrated: Bool)
    case text(String), integer(Int), number(Double), boolean(Bool), null
    subscript(_ key: String) -> Self? { if case .object(let values) = self { return values[key] }; return nil }
    var text: String? { if case .text(let value) = self { return value }; return nil }
    var number: Double? {
        if case .number(let value) = self { return value }
        if case .integer(let value) = self { return Double(value) }
        return nil
    }
    var integer: Int? { if case .integer(let value) = self { return value }; return nil }
    var list: [Self] {
        if case .list(let values) = self { return values }
        if case .items(_, let values, _) = self { return values.keys.sorted().compactMap { values[$0] } }
        return []
    }
    func at(_ path: ArraySlice<DesktopPath>) -> Self? {
        guard let first = path.first else { return self }
        let child: Self?
        switch (self, first) {
        case (.object(let values), .key(let key)): child = values[key]
        case (.list(let values), .index(let index)): child = values.indices.contains(index) ? values[index] : nil
        case (.items(let count, let values, _), .index(let index)): child = (0..<count).contains(index) ? (values[index] ?? .object([:])) : nil
        default: child = nil
        }
        return child?.at(path.dropFirst())
    }
    mutating func patch(_ path: ArraySlice<DesktopPath>, op: String, value: Self) throws {
        guard let first = path.first else { throw JSONFieldView.Failure.malformed }
        let rest = path.dropFirst()
        switch (self, first) {
        case (.object(var values), .key(let key)):
            if rest.isEmpty {
                if op == "remove" { values.removeValue(forKey: key) } else { values[key] = value }
            } else {
                var child = values[key] ?? (rest.first.map { if case .index = $0 { return Self.list([]) }; return Self.object([:]) }!)
                try child.patch(rest, op: op, value: value); values[key] = child
            }
            self = .object(values)
        case (.list(var values), .index(let index)):
            guard index >= 0, index <= values.count else { throw JSONFieldView.Failure.malformed }
            if rest.isEmpty {
                if op == "add" { values.insert(value, at: index) }
                else {
                    guard index < values.count else { throw JSONFieldView.Failure.malformed }
                    if op == "remove" { values.remove(at: index) } else { values[index] = value }
                }
            } else {
                guard index < values.count else { throw JSONFieldView.Failure.malformed }
                try values[index].patch(rest, op: op, value: value)
            }
            self = .list(values)
        case (.items(var count, var values, let hydrated), .index(let index)):
            guard index >= 0, index <= count, count <= 8192 else { throw JSONFieldView.Failure.malformed }
            if rest.isEmpty {
                if op == "add" {
                    guard count < 8192 else { throw JSONFieldView.Failure.limit }
                    values = Dictionary(uniqueKeysWithValues: values.map { ($0.key >= index ? $0.key + 1 : $0.key, $0.value) })
                    values[index] = value; count += 1
                } else {
                    guard index < count else { throw JSONFieldView.Failure.malformed }
                    if op == "remove" {
                        values.removeValue(forKey: index)
                        values = Dictionary(uniqueKeysWithValues: values.map { ($0.key > index ? $0.key - 1 : $0.key, $0.value) }); count -= 1
                    } else { values[index] = value }
                }
            } else {
                guard index < count else { throw JSONFieldView.Failure.malformed }
                var child = values[index] ?? .object([:]); try child.patch(rest, op: op, value: value); values[index] = child
            }
            self = .items(count: count, values: values, hydrated: hydrated)
        default: throw JSONFieldView.Failure.malformed
        }
    }
}

struct DesktopRequestDescriptor: Equatable {
    let id: String
    let kind: PendingAttentionRequest.Kind
}

/// The private v11 adapter keeps bounded turn headers and current-turn items.
/// Historical array positions survive as counts; old items are not retained.
struct DesktopWireProjection {
    private var tree: DesktopValue = .object([:])
    private var canonicalKeys: [String] = []
    private var selection: [DesktopPath]?
    private var selectionResolved = false
    private var owner: String?
    private(set) var revision: Int?
    private var previousTurn: DesktopValue?
    private var previousItems: [String: DesktopValue] = [:]
    private var firstTextSeen = false
    private var previousUsage: Int?
    private(set) var requests: [DesktopRequestDescriptor] = []
    private(set) var isActive = false
    private(set) var isTerminal = false
    let threadID: String
    let attentionOnly: Bool
    private let requiresResumedRuntime: Bool
    private(set) var runtimeAvailable: Bool
    private static let models: Set<String> = ["reasoning", "agentMessage", "plan"]
    private static let terminal: Set<String> = ["completed", "failed", "interrupted"]

    init(threadID: String, attentionOnly: Bool = false, requiresResumedRuntime: Bool = false) {
        self.threadID = threadID; self.attentionOnly = attentionOnly; self.requiresResumedRuntime = requiresResumedRuntime
        runtimeAvailable = !requiresResumedRuntime
    }
    func isOwned(by client: String) -> Bool { owner == client }
    var currentTurnID: String? { previousTurn?["turnId"]?.text }
    var retainedItemCount: Int {
        func count(_ value: DesktopValue) -> Int {
            switch value {
            case .items(_, let values, _): return values.count
            case .list(let values): return values.reduce(0) { $0 + count($1) }
            case .object(let values): return values.values.reduce(0) { $0 + count($1) }
            default: return 0
            }
        }
        return count(tree)
    }
    private func currentPath() -> [DesktopPath]? { selectionResolved ? selection : findCurrentPath() }
    private func findCurrentPath() -> [DesktopPath]? {
        var selected: [DesktopPath]?, selectedTurn: DesktopValue?
        let candidates: [[DesktopPath]]
        if tree["turnHistory"]?["kind"]?.text == "canonical" {
            candidates = canonicalKeys.map { [.key("turnHistory"), .key("history"), .key("entitiesByKey"), .key($0)] }
        } else { candidates = tree["turns"]?.list.indices.map { [.key("turns"), .index($0)] } ?? [] }
        for path in candidates {
            guard let turn = tree.at(path[...]), turn["turnId"]?.text != nil else { continue }
            if Self.prefers(turn, over: selectedTurn, currentID: currentTurnID) { selectedTurn = turn; selected = path }
        }
        return selected
    }
    private static func prefers(_ turn: DesktopValue, over previous: DesktopValue?, currentID: String?) -> Bool {
        guard let previous else { return true }
        let start = turn["turnStartedAtMs"]?.number.flatMap { $0 > 0 ? $0 : nil }
        let oldStart = previous["turnStartedAtMs"]?.number.flatMap { $0 > 0 ? $0 : nil }
        if let start, let oldStart, start != oldStart { return start > oldStart }
        // Activity can arrive before startedAt. A completed historical timestamp
        // must not hide it; known unequal timestamps still preserve chronology.
        let active = turn["status"]?.text == "inProgress"
        let oldActive = previous["status"]?.text == "inProgress"
        if active != oldActive { return active }
        // Once observed, a timestamp-less turn must also keep its terminal
        // event when older history still has a timestamp.
        if let currentID {
            let current = turn["turnId"]?.text == currentID
            let oldCurrent = previous["turnId"]?.text == currentID
            if current != oldCurrent { return current }
        }
        if (start != nil) != (oldStart != nil) { return start != nil }
        return true // Equal/absent timestamps retain the later wire position.
    }
    private static func string(_ view: JSONFieldView?, limit: Int = 256) -> DesktopValue? {
        view?.string(limit: limit).map(DesktopValue.text)
    }
    private static func relationship(_ view: JSONFieldView?, depth: Int = 0) throws -> DesktopValue {
        guard let view, depth < 5 else { return .null }
        if let raw = view.string(), let id = UUID(uuidString: raw) { return .text(id.uuidString.lowercased()) }
        guard view.isObject else { return .null }
        var result: [String: DesktopValue] = [:]
        for (key, value) in try view.fields(["subAgent", "subagent", "thread_spawn", "threadSpawn", "parent_thread_id", "parentThreadId"]) {
            result[key] = try relationship(value, depth: depth + 1)
        }
        return .object(result)
    }
    private static func threadIDs(_ view: JSONFieldView?) throws -> DesktopValue {
        guard let view, !view.isNull else { return .list([]) }
        return .list(try view.elements(maximumCount: 64).compactMap { $0.string().flatMap { UUID(uuidString: $0)?.uuidString.lowercased() } }.map(DesktopValue.text))
    }
    private(set) var collaborationThreadIDs: [String] = []
    private var previousAgentStates: [String: String] = [:]
    private var projectedCollaborationThreadIDs: [String] {
        guard let current = currentPath().flatMap({ tree.at($0[...]) }) else { return [] }
        return Array(Set((current["items"]?.list ?? []).flatMap { ($0["receiverThreadIds"]?.list ?? []).compactMap(\.text) + ($0["agentThreadId"]?.text.map { [$0] } ?? []) })).sorted().prefix(64).map { $0 }
    }
    private var subagentStates: [String: String] {
        guard let current = currentPath().flatMap({ tree.at($0[...]) }) else { return [:] }
        var result: [String: String] = [:]
        for item in current["items"]?.list ?? [] where item["type"]?.text == "subAgentActivity" {
            guard let id = item["agentThreadId"]?.text, result[id] != nil || result.count < 64 else { continue }
            switch item["kind"]?.text {
            case "started", "interacted": result[id] = "running"
            case "completed", "interrupted", "closed": result[id] = "completed"
            default: break
            }
        }
        return result
    }
    private static func item(_ view: JSONFieldView, attentionOnly: Bool = false) throws -> DesktopValue {
        guard view.isObject else { return .object([:]) }
        let fields = try view.fields(["id", "type", "status", "questions", "receiverThreadIds", "agentThreadId", "kind"])
        let questions = try questionMarkers(fields["questions"])
        if attentionOnly, !["userMessage", "steeringUserMessage", "agentMessage"].contains(fields["type"]?.string() ?? "") { return .object([:]) }
        var values = fields.filter { ["id", "type", "status"].contains($0.key) }.reduce(into: [String: DesktopValue]()) {
            $0[$1.key] = Self.string($1.value, limit: $1.key == "id" ? 256 : 80)
        }
        values["questions"] = questions
        if fields["type"]?.string() == "subAgentActivity" {
            values["agentThreadId"] = try relationship(fields["agentThreadId"])
            let kind = fields["kind"]?.string(limit: 32)
            values["kind"] = kind.flatMap { ["started", "interacted", "completed", "interrupted", "closed"].contains($0) ? .text($0) : nil } ?? .null
        }
        if ["collabAgentToolCall", "collabToolCall"].contains(fields["type"]?.string() ?? "") {
            values["receiverThreadIds"] = try threadIDs(fields["receiverThreadIds"])
        }
        if !attentionOnly, Self.models.contains(fields["type"]?.string() ?? "") {
            values["hasGeneratedText"] = .boolean(try view.containsTextMetadata())
        }
        return .object(values)
    }
    private static func questionMarkers(_ view: JSONFieldView?) throws -> DesktopValue {
        guard let view, !view.isNull else { return .list([]) }
        return .list(try view.elements(maximumCount: 64).map { _ in .null })
    }
    private static func items(_ view: JSONFieldView?, hydrate: Bool, attentionOnly: Bool = false) throws -> DesktopValue {
        guard let view, !view.isNull else { return .items(count: 0, values: [:], hydrated: hydrate) }
        guard view.isArray else { throw JSONFieldView.Failure.malformed }
        var count = 0, values: [Int: DesktopValue] = [:]
        try view.forEachElement { item in
            if hydrate {
                let value = try Self.item(item, attentionOnly: attentionOnly)
                if value["id"]?.text != nil { values[count] = value }
            }
            count += 1
        }
        return .items(count: count, values: values, hydrated: hydrate)
    }
    private static func turn(_ view: JSONFieldView, hydrate: Bool, attentionOnly: Bool = false) throws -> DesktopValue {
        guard view.isObject else { return .object([:]) }
        let fields = try view.fields(["turnId", "status", "turnStartedAtMs", "items"])
        var values = fields.filter { ["turnId", "status"].contains($0.key) }.compactMapValues { Self.string($0) }
        if let started = fields["turnStartedAtMs"]?.number() { values["turnStartedAtMs"] = .number(started) }
        values["items"] = try Self.items(fields["items"], hydrate: hydrate, attentionOnly: attentionOnly)
        return .object(values)
    }
    private static func usage(_ view: JSONFieldView?) throws -> DesktopValue {
        guard let view, view.isObject else { return .object([:]) }
        var output: [String: DesktopValue] = [:]
        for (key, value) in try view.fields(["total", "last"]) where value.isObject {
            if let count = try value.fields(["outputTokens", "reasoningOutputTokens"])["outputTokens"]?.integer(), count >= 0 {
                var row: [String: DesktopValue] = ["outputTokens": .integer(count)]
                if let reasoning = try value.fields(["reasoningOutputTokens"])["reasoningOutputTokens"]?.integer(), reasoning >= 0 {
                    row["reasoningOutputTokens"] = .integer(reasoning)
                }
                output[key] = .object(row)
            }
        }
        return .object(output)
    }
    private static func runtime(_ view: JSONFieldView?) throws -> DesktopValue {
        guard let view, view.isObject else { return .object([:]) }
        let fields = try view.fields(["type", "activeFlags"])
        let flags = try fields["activeFlags"]?.elements(maximumCount: 64).compactMap { $0.string(limit: 64) }
            .filter { ["waitingOnApproval", "waitingOnUserInput"].contains($0) }.map(DesktopValue.text) ?? []
        var values: [String: DesktopValue] = ["activeFlags": .list(flags)]
        values["type"] = string(fields["type"], limit: 32)
        return .object(values)
    }
    private static func request(_ view: JSONFieldView, depth: Int = 0) throws -> DesktopValue {
        guard view.isObject, depth < 3 else { return .object([:]) }
        let fields = try view.fields(["id", "requestId", "itemId", "method", "type", "kind", "status", "request", "params", "isBlocking"])
        var values: [String: DesktopValue] = [:]
        for (key, value) in fields {
            if ["request", "params"].contains(key) { values[key] = try request(value, depth: depth + 1) }
            else if key == "isBlocking", let flag = value.boolean() { values[key] = .boolean(flag) }
            else if let identifier = value.scalarIdentifier() { values[key] = .text(identifier) }
        }
        return .object(values)
    }
    private static func requests(_ view: JSONFieldView?) throws -> DesktopValue {
        guard let view, !view.isNull else { return .list([]) }
        return .list(try view.elements(maximumCount: 64).map { try request($0) })
    }
    private static func review(_ fields: [String: JSONFieldView]) throws -> Bool {
        let source = fields["threadSource"]?.string()?.lowercased().replacingOccurrences(of: "_", with: "") ?? ""
        if ["guardianreview", "autoreview", "subagentreview"].contains(source) ||
           fields["latestModel"]?.string()?.lowercased().hasPrefix("codex-auto-review") == true { return true }
        if let value = fields["source"], value.isObject {
            let sub = try value.fields(["subAgent", "subagent"])
            if let role = sub["subAgent"] ?? sub["subagent"] {
                if role.string() == "review" { return true }
                if role.isObject {
                    let fields = try role.fields(["other", "review"])
                    return fields["review"] != nil || ["guardian", "autoreview", "auto_review"].contains(fields["other"]?.string() ?? "")
                }
            }
        }
        return false
    }
    private mutating func snapshot(_ view: JSONFieldView) throws {
        selectionResolved = false
        let fields = try view.fields(["title", "cwd", "latestModel", "threadSource", "source", "parentThreadId", "ephemeral", "latestTokenUsageInfo", "threadRuntimeStatus", "resumeState", "turns", "turnHistory", "requests"])
        guard fields["ephemeral"]?.boolean() != true else { throw DesktopProjectionFailure.ephemeral }
        guard !(try Self.review(fields)) else { throw DesktopProjectionFailure.review }
        var values = fields.filter { ["title", "cwd", "latestModel", "threadSource"].contains($0.key) }
            .reduce(into: [String: DesktopValue]()) { $0[$1.key] = Self.string($1.value, limit: $1.key == "cwd" ? 2048 : 256) ?? .null }
        values["source"] = try Self.relationship(fields["source"])
        values["parentThreadId"] = try Self.relationship(fields["parentThreadId"])
        values["latestTokenUsageInfo"] = try Self.usage(fields["latestTokenUsageInfo"])
        values["threadRuntimeStatus"] = try Self.runtime(fields["threadRuntimeStatus"])
        values["resumeState"] = Self.string(fields["resumeState"], limit: 32) ?? .null
        values["requests"] = try Self.requests(fields["requests"])
        var views: [String: JSONFieldView] = [:], turns: [DesktopValue] = []
        if let legacy = fields["turns"], !legacy.isNull {
            try legacy.forEachElement(maximumCount: 512) { value in
                views["legacy:\(turns.count)"] = value
                turns.append(try Self.turn(value, hydrate: false, attentionOnly: attentionOnly))
            }
        }
        values["turns"] = .list(turns); canonicalKeys = []
        if let history = fields["turnHistory"], history.isObject {
            let root = try history.fields(["kind", "history"])
            if root["kind"]?.string() == "canonical" {
                var entities: [String: DesktopValue] = [:]
                let container = try root["history"]?.fields(["entitiesByKey"])["entitiesByKey"]
                if let container, container.isObject {
                    try container.forEachField { key, value in
                        if entities[key] == nil { canonicalKeys.append(key) }
                        entities[key] = try Self.turn(value, hydrate: false, attentionOnly: attentionOnly); views[key] = value
                    }
                }
                values["turnHistory"] = .object(["kind": .text("canonical"), "history": .object(["entitiesByKey": .object(entities)])])
            }
        }
        tree = .object(values)
        selection = findCurrentPath(); selectionResolved = true
        if let path = selection, let last = path.last {
            let key: String
            switch last { case .key(let value): key = value; case .index(let value): key = "legacy:\(value)" }
            if let view = views[key] { try tree.patch(path[...], op: "replace", value: Self.turn(view, hydrate: true, attentionOnly: attentionOnly)) }
        }
    }
    private static func collection(_ view: JSONFieldView, canonical: Bool, attentionOnly: Bool, currentID: String?) throws -> DesktopValue {
        var keys: [String] = [], headers: [String: DesktopValue] = [:], views: [String: JSONFieldView] = [:]
        var selected: String?
        func append(_ key: String, _ value: JSONFieldView) throws {
            let header = try turn(value, hydrate: false, attentionOnly: attentionOnly)
            if headers[key] == nil { keys.append(key) }
            headers[key] = header; views[key] = value
            if header["turnId"]?.text != nil {
                if Self.prefers(header, over: selected.flatMap { headers[$0] }, currentID: currentID) { selected = key }
            }
        }
        if canonical { try view.forEachField { try append($0, $1) } }
        else { try view.forEachElement(maximumCount: 512) { try append(String(keys.count), $0) } }
        if let selected, let value = views[selected] { headers[selected] = try turn(value, hydrate: true, attentionOnly: attentionOnly) }
        return canonical ? .object(headers) : .list(keys.compactMap { headers[$0] })
    }
    private static func path(_ view: JSONFieldView?) throws -> [DesktopPath] {
        guard let view else { throw JSONFieldView.Failure.malformed }
        return try view.elements(maximumCount: 12).map {
            if let index = $0.integer(), index >= 0 { return .index(index) }
            if let key = $0.string() { return .key(key) }
            throw JSONFieldView.Failure.malformed
        }
    }
    private static func selectionAffected(_ path: [DesktopPath]) -> Bool {
        guard case .key(let root)? = path.first, ["turnHistory", "turns"].contains(root) else { return false }
        if path.count <= (root == "turns" ? 2 : 4) { return true }
        let headerDepth = root == "turns" ? 3 : 5
        return path.count == headerDepth && [.key("turnId"), .key("turnStartedAtMs"), .key("status")].contains(path.last ?? .key(""))
    }
    private func projectedValue(path: [DesktopPath], view: JSONFieldView?, op: String) throws -> DesktopValue? {
        guard case .key(let root)? = path.first else { return nil }
        let keys = path.compactMap { if case .key(let key) = $0 { return key }; return nil }
        if root == "resumeState", path.count == 1 { return op == "remove" ? .null : Self.string(view, limit: 32) ?? .null }
        if root == "ephemeral", path.count == 1 {
            guard op == "remove" || view?.boolean() != true else { throw DesktopProjectionFailure.ephemeral }
            return nil
        }
        if op == "remove" {
            if ["title", "cwd", "latestModel", "threadSource"].contains(root) { return path.count == 1 ? .null : nil }
            if root == "latestTokenUsageInfo" {
                return path.count == 1 || (path.count <= 3 && keys.count == path.count &&
                    ["total", "last"].contains(keys[1]) && (path.count == 2 || ["outputTokens", "reasoningOutputTokens"].contains(keys[2]))) ? .null : nil
            }
            if root == "source", keys.allSatisfy({ ["source", "subAgent", "subagent", "thread_spawn", "threadSpawn", "parent_thread_id", "parentThreadId"].contains($0) }) {
            return try Self.relationship(view)
        }
        if root == "parentThreadId", path.count == 1 { return try Self.relationship(view) }
        if root == "threadRuntimeStatus" { return path.count == 1 || keys == [root, "type"] || keys == [root, "activeFlags"] ? .null : nil }
            if root == "requests" {
                return keys.allSatisfy { ["requests", "request", "params", "id", "requestId", "itemId", "method", "type", "kind", "status", "isBlocking"].contains($0) } ? .null : nil
            }
            if root == "turns" || root == "turnHistory" {
                if path.count == 1 || (root == "turnHistory" && keys == [root, "kind"]) { return .null }
                if root == "turnHistory" && !path.starts(with: [.key(root), .key("history"), .key("entitiesByKey")]) { return nil }
                let start = root == "turns" ? 2 : 4
                if path.count <= start { return .null }
                let suffix = Array(path.dropFirst(start))
                if suffix.count == 1, case .key(let key) = suffix[0], ["turnId", "status", "turnStartedAtMs"].contains(key) { return .null }
                if case .key("items") = suffix[0] {
                    if suffix.count <= 2 { return .null }
                    if suffix.count == 3, case .key(let key) = suffix[2], ["id", "type", "status", "questions"].contains(key) { return .null }
                    if suffix.count == 4, suffix[2] == .key("questions") { return .null }
                }
            }
            return nil
        }
        if ["title", "cwd", "latestModel", "threadSource"].contains(root), path.count == 1 { return Self.string(view, limit: root == "cwd" ? 2048 : 256) ?? .null }
        if root == "latestTokenUsageInfo" {
            if path.count == 1 { return try Self.usage(view) }
            if path.count == 2 && ["total", "last"].contains(keys.last ?? "") {
                if let view, view.isObject {
                    var row: [String: DesktopValue] = [:]
                    for (key, field) in try view.fields(["outputTokens", "reasoningOutputTokens"]) {
                        if let count = field.integer(), count >= 0 { row[key] = .integer(count) }
                    }
                    return .object(row)
                }
                return .object([:])
            }
            if path.count == 3 && ["outputTokens", "reasoningOutputTokens"].contains(keys.last ?? ""), let count = view?.integer(), count >= 0 { return .integer(count) }
            return nil
        }
        if root == "threadRuntimeStatus" {
            if path.count == 1 { return try Self.runtime(view) }
            if keys == [root, "type"] { return Self.string(view, limit: 32) ?? .null }
            if keys == [root, "activeFlags"] {
                return .list(try view?.elements(maximumCount: 64).compactMap { $0.string(limit: 64) }.filter { ["waitingOnApproval", "waitingOnUserInput"].contains($0) }.map(DesktopValue.text) ?? [])
            }
            return nil
        }
        if root == "requests" {
            if path.count == 1 { return try Self.requests(view) }
            if path.count == 2, let view { return try Self.request(view) }
            if keys.allSatisfy({ ["requests", "request", "params", "id", "requestId", "itemId", "method", "type", "kind", "status", "isBlocking"].contains($0) }) {
                if let view, view.isObject { return try Self.request(view) }
                return Self.string(view) ?? view?.boolean().map(DesktopValue.boolean) ?? .null
            }
            return nil
        }
        if root == "turns" || root == "turnHistory" {
            let start = root == "turns" ? 2 : 4
            if root == "turns", path.count == 1, let view {
                return try Self.collection(view, canonical: false, attentionOnly: attentionOnly, currentID: currentTurnID)
            }
            if root == "turnHistory", path.count == 1, let view {
                let fields = try view.fields(["kind", "history"])
                var entities: DesktopValue = .object([:])
                if fields["kind"]?.string() == "canonical", let source = try fields["history"]?.fields(["entitiesByKey"])["entitiesByKey"], source.isObject {
                    entities = try Self.collection(source, canonical: true, attentionOnly: attentionOnly, currentID: currentTurnID)
                }
                return .object(["kind": Self.string(fields["kind"]) ?? .null, "history": .object(["entitiesByKey": entities])])
            }
            if root == "turnHistory", keys.prefix(3) != ["turnHistory", "history", "entitiesByKey"] { return keys == [root, "kind"] ? Self.string(view) ?? .null : nil }
            if root == "turnHistory", path.count == 3, let view {
                return try Self.collection(view, canonical: true, attentionOnly: attentionOnly, currentID: currentTurnID)
            }
            if path.count == start, let view {
                let header = try Self.turn(view, hydrate: false, attentionOnly: attentionOnly)
                let current = currentPath().flatMap { tree.at($0[...]) }
                let hydrate = path == currentPath() || Self.prefers(header, over: current, currentID: currentTurnID)
                return hydrate ? try Self.turn(view, hydrate: true, attentionOnly: attentionOnly) : header
            }
            guard path.count > start else { return op == "remove" ? .null : nil }
            let suffix = Array(path.dropFirst(start))
            if suffix.count == 1 {
                if case .key(let key) = suffix[0] {
                    if ["turnId", "status"].contains(key) { return Self.string(view) ?? .null }
                    if key == "turnStartedAtMs" { return view?.number().map(DesktopValue.number) ?? .null }
                    if key == "items" { return try Self.items(view, hydrate: Array(path.prefix(start)) == currentPath(), attentionOnly: attentionOnly) }
                }
            }
            if case .key("items") = suffix[0], suffix.count >= 2 {
                guard case .index(let index) = suffix[1], index < 8192 else { throw JSONFieldView.Failure.limit }
                if suffix.count == 2, let view { return try Self.item(view, attentionOnly: attentionOnly) }
                if suffix.count == 3, case .key(let key) = suffix[2], ["id", "type", "status"].contains(key) { return Self.string(view) ?? .null }
                if suffix.count == 3, suffix[2] == .key("agentThreadId") { return try Self.relationship(view) }
                if suffix.count == 3, suffix[2] == .key("kind") { return Self.string(view, limit: 32) }
                if suffix.count == 3, suffix[2] == .key("receiverThreadIds") { return try Self.threadIDs(view) }
                if suffix.count == 4, suffix[2] == .key("receiverThreadIds"), let raw = view?.string(), let id = UUID(uuidString: raw) { return .text(id.uuidString.lowercased()) }
                if suffix.count == 3, suffix[2] == .key("questions") { return try Self.questionMarkers(view) }
                if suffix.count == 4, suffix[2] == .key("questions") { return .null }
            }
        }
        return nil
    }
    private mutating func compactHistoricalItems() throws {
        guard let current = currentPath() else { return }
        let paths: [[DesktopPath]]
        if tree["turnHistory"]?["kind"]?.text == "canonical" { paths = canonicalKeys.map { [.key("turnHistory"), .key("history"), .key("entitiesByKey"), .key($0)] } }
        else { paths = tree["turns"]?.list.indices.map { [.key("turns"), .index($0)] } ?? [] }
        for path in paths where path != current {
            if case .items(let count, let values, let hydrated)? = tree.at((path + [.key("items")])[...]), hydrated || !values.isEmpty {
                try tree.patch((path + [.key("items")])[...], op: "replace", value: .items(count: count, values: [:], hydrated: false))
            }
        }
    }
    private mutating func refreshRequests() {
        requests = (tree["requests"]?.list ?? []).enumerated().compactMap { index, value in
            if ["resolved", "completed", "cancelled"].contains(value["status"]?.text ?? "") { return nil }
            let request = value["request"] ?? value
            let method = (request["method"]?.text ?? request["type"]?.text ?? request["kind"]?.text ?? "")
                .lowercased().replacingOccurrences(of: "_", with: "")
            let kind: PendingAttentionRequest.Kind
            if method.contains("requestuserinput") || method.contains("elicitation") { kind = .input }
            else if method.contains("requestapproval") || method.contains("approvalrequest") { kind = .approval }
            else { return nil }
            let identifier = value["id"]?.text ?? value["requestId"]?.text ?? request["id"]?.text ?? request["requestId"]?.text ?? "index:\(index)"
            let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
            return DesktopRequestDescriptor(id: digest, kind: kind)
        }
        // Desktop async questions are agent-message metadata, not server requests.
        // A later user message is the observable reply boundary; no answer text is read.
        guard let path = currentPath(), let turn = tree.at(path[...]), turn["status"]?.text == "inProgress",
              case .items(_, let items, _)? = turn["items"] else { return }
        let lastReply = items.filter { ["userMessage", "steeringUserMessage"].contains($0.value["type"]?.text ?? "") }.keys.max() ?? -1
        for index in items.keys.sorted() where index > lastReply {
            guard let item = items[index], item["type"]?.text == "agentMessage",
                  !(item["questions"]?.list.isEmpty ?? true), let id = item["id"]?.text else { continue }
            let digest = SHA256.hash(data: Data("async:\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
            requests.append(DesktopRequestDescriptor(id: digest, kind: .input))
        }
    }
    mutating func consume(_ change: JSONFieldView, owner: String, at now: Date = Date()) throws -> [[String: Any]] {
        let fields = try change.fields(["type", "revision", "baseRevision", "conversationState", "patches"])
        guard let revision = fields["revision"]?.integer(), revision >= 0 else { throw JSONFieldView.Failure.malformed }
        let snapshot = fields["type"]?.string() == "snapshot"
        var staged = self
        var rawPaths: [[DesktopPath]] = []
        var textPaths: [[DesktopPath]] = []
        if snapshot {
            guard let state = fields["conversationState"], state.isObject else { throw JSONFieldView.Failure.malformed }
            try staged.snapshot(state); staged.owner = owner
        } else {
            guard fields["type"]?.string() == "patches", self.owner == owner, let oldRevision = self.revision,
                  oldRevision < Int.max, fields["baseRevision"]?.integer() == oldRevision,
                  oldRevision + 1 == revision else { throw DesktopProjectionFailure.gap }
            for patch in try fields["patches"]?.elements(maximumCount: 4096) ?? [] {
                let p = try patch.fields(["op", "path", "value"])
                guard let op = p["op"]?.string(), ["add", "replace", "remove"].contains(op) else { throw JSONFieldView.Failure.malformed }
                let path = try Self.path(p["path"]); rawPaths.append(path)
                if op != "remove", path.contains(.key("items")), let raw = p["value"],
                   path.contains(where: { if case .key(let key) = $0 { return ["text", "delta", "content", "summary", "summaryText"].contains(key) }; return false }),
                   try raw.containsTextMetadata() { textPaths.append(path) }
                if let value = try staged.projectedValue(path: path, view: p["value"], op: op) {
                    try staged.tree.patch(path[...], op: op, value: value)
                    let prefix: [DesktopPath] = [.key("turnHistory"), .key("history"), .key("entitiesByKey")]
                    if path == [.key("turnHistory")] || path == prefix {
                        staged.canonicalKeys = []
                        var entities = p["value"]
                        if path == [.key("turnHistory")], let history = p["value"], history.isObject {
                            let root = try history.fields(["history"])
                            entities = try root["history"]?.fields(["entitiesByKey"])["entitiesByKey"]
                        }
                        if op != "remove", let entities, entities.isObject {
                            try entities.forEachField { key, _ in if !staged.canonicalKeys.contains(key) { staged.canonicalKeys.append(key) } }
                        }
                    } else if path.starts(with: prefix), path.count == 4, case .key(let key) = path[3] {
                        if op == "remove" { staged.canonicalKeys.removeAll { $0 == key } }
                        else if !staged.canonicalKeys.contains(key) { staged.canonicalKeys.append(key) }
                    }
                    if Self.selectionAffected(path) {
                        staged.selection = staged.findCurrentPath(); staged.selectionResolved = true
                        try staged.compactHistoricalItems()
                    }
                }
            }
        }
        staged.revision = revision
        let changedSelection = snapshot || rawPaths.contains(where: Self.selectionAffected)
        if changedSelection { staged.selection = staged.findCurrentPath(); staged.selectionResolved = true }
        let selected = staged.currentPath()
        var current = selected.flatMap { staged.tree.at($0[...]) }
        let reconnecting = requiresResumedRuntime && !runtimeAvailable
        let runtimeType = staged.tree["threadRuntimeStatus"]?["type"]?.text
        // Idle can precede final item/usage/turn patches. It cannot end a turn
        // that this owner already established, or erase its pending accounting.
        let observedTurn = !snapshot && runtimeAvailable && previousTurn?["status"]?.text == "inProgress" &&
            previousTurn?["turnId"]?.text == current?["turnId"]?.text
        staged.runtimeAvailable = !requiresResumedRuntime || (staged.tree["resumeState"]?.text == "resumed" &&
            !["systemError", "notLoaded"].contains(runtimeType ?? "") &&
            (current?["status"]?.text != "inProgress" || runtimeType == "active" || (runtimeType == "idle" && observedTurn)))
        if !staged.runtimeAvailable {
            staged.previousTurn = nil; staged.previousUsage = nil; staged.previousItems = [:]; staged.firstTextSeen = false
        }
        // Completed turns intentionally keep only item counts. Bookkeeping
        // patches after completion do not require those discarded item bodies.
        // Only an active turn needs a hydrated current-item projection.
        if let value = current, value["status"]?.text == "inProgress",
           case .items(let count, _, let hydrated)? = value["items"], !hydrated {
            if count > 0 { throw DesktopProjectionFailure.gap }
            if let selected { try staged.tree.patch((selected + [.key("items")])[...], op: "replace", value: .items(count: 0, values: [:], hydrated: true)) }
            current = selected.flatMap { staged.tree.at($0[...]) }
        }
        var events: [[String: Any]] = []
        func event(_ method: String, _ values: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": threadID, "at": now.timeIntervalSince1970].merging(values) { _, new in new }
        }
        if !attentionOnly && staged.runtimeAvailable {
            if snapshot || reconnecting || rawPaths.contains(where: { [.key("title"), .key("cwd"), .key("latestModel"), .key("threadSource"), .key("source"), .key("parentThreadId")].contains($0.first ?? .key("")) }) {
                var meta: [String: Any] = [:]
                for (source, target) in [("title", "name"), ("cwd", "cwd"), ("latestModel", "model"), ("threadSource", "source")] { meta[target] = staged.tree[source]?.text }
                let source = staged.tree["source"]
                let sub = source?["subAgent"] ?? source?["subagent"]
                let spawn = sub?["thread_spawn"] ?? sub?["threadSpawn"]
                meta["parentThreadId"] = staged.tree["parentThreadId"]?.text ?? spawn?["parent_thread_id"]?.text ?? spawn?["parentThreadId"]?.text
                events.append(event("metadata", meta))
            }
            if let current, let turn = current["turnId"]?.text {
                let status = current["status"]?.text ?? "", changed = previousTurn?["turnId"]?.text != turn
                if changed {
                    staged.previousItems = [:]; staged.previousUsage = nil; staged.firstTextSeen = false
                    if status == "inProgress" {
                        let milliseconds = current["turnStartedAtMs"]?.number ?? 0
                        let started = milliseconds > 0 && milliseconds <= now.timeIntervalSince1970 * 1000 + 5000 ? milliseconds / 1000 : now.timeIntervalSince1970
                        events.append(event(snapshot || reconnecting ? "turn/attached" : "turn/started", ["turnId": turn, "startedAt": started]))
                    }
                }
                let ending = previousTurn?["status"]?.text == "inProgress" && Self.terminal.contains(status)
                let items = Dictionary(current["items"]?.list.compactMap { item -> (String, DesktopValue)? in
                    item["id"]?.text.map { ($0, item) }
                } ?? [], uniquingKeysWith: { _, new in new })
                if status == "inProgress" || ending {
                    for item in current["items"]?.list ?? [] {
                        guard let id = item["id"]?.text, let kind = item["type"]?.text else { continue }
                        let old = staged.previousItems[id]
                        if RuntimeItemKind.isTool(kind) {
                            if item["status"]?.text == "inProgress" && old?["status"]?.text != "inProgress" { events.append(event("item/started", ["turnId": turn, "itemId": id, "itemType": RuntimeItemKind.normalized(kind)])) }
                            else if old?["status"]?.text == "inProgress", Self.terminal.contains(item["status"]?.text ?? "") { events.append(event("item/completed", ["turnId": turn, "itemId": id, "itemType": RuntimeItemKind.normalized(kind)])) }
                        } else if Self.models.contains(kind), Self.terminal.contains(item["status"]?.text ?? ""), old?["status"]?.text == "inProgress" {
                            events.append(event("item/completed", ["turnId": turn, "itemId": id, "itemType": kind]))
                        }
                    }
                    // Snapshots and whole-container replacements have no
                    // per-item text path. Restore the latest work stage from
                    // ordered metadata instead of waiting for a later delta.
                    let replacedItems = snapshot || reconnecting || rawPaths.contains { path in
                        guard let selected else { return false }
                        return selected.starts(with: path) || path == selected + [.key("items")]
                    }
                    if replacedItems, let latest = current["items"]?.list.last(where: {
                        Self.models.contains($0["type"]?.text ?? "") || RuntimeItemKind.isTool($0["type"]?.text ?? "")
                    }), let kind = latest["type"]?.text, Self.models.contains(kind), let id = latest["id"]?.text {
                        var marker: [String: Any] = ["turnId": turn, "itemId": id, "itemType": kind]
                        if !snapshot && !reconnecting, latest["hasGeneratedText"] == .boolean(true) {
                            marker["hasText"] = true
                            if !staged.firstTextSeen { marker["firstTextDelta"] = true; staged.firstTextSeen = true }
                        }
                        events.append(event("item/started", marker))
                    }
                    if !snapshot && !reconnecting {
                        for path in rawPaths {
                            guard let offset = path.firstIndex(of: .key("items")), Array(path.prefix(offset)) == selected,
                                  path.count > offset + 1, let item = staged.tree.at(path.prefix(offset + 2)),
                                  let kind = item["type"]?.text, Self.models.contains(kind), let id = item["id"]?.text else { continue }
                            var delta: [String: Any] = ["turnId": turn, "itemId": id]
                            let hasText = textPaths.contains(path)
                            if hasText {
                                delta["hasText"] = true
                                if !staged.firstTextSeen { delta["firstTextDelta"] = true; staged.firstTextSeen = true }
                            }
                            events.append(event(kind == "reasoning" ? "item/reasoning/textDelta" : "item/agentMessage/delta", delta))
                        }
                    }
                    let runtime = staged.tree["threadRuntimeStatus"]
                    var state: [String: Any] = ["flags": runtime?["activeFlags"]?.list.compactMap(\.text) ?? []]
                    state["status"] = runtime?["type"]?.text
                    if snapshot || changed || runtime != tree["threadRuntimeStatus"] {
                        events.append(event("thread/status/changed", state))
                    }
                }
                // Settle final usage before releasing the turn, even when one
                // atomic patch contains both the count and the completion.
                let lateUsage = requiresResumedRuntime && !snapshot && Self.terminal.contains(status) &&
                    previousTurn?["turnId"]?.text == turn && Self.terminal.contains(previousTurn?["status"]?.text ?? "")
                if let count = staged.tree["latestTokenUsageInfo"]?["total"]?["outputTokens"]?.integer, count != staged.previousUsage,
                   status == "inProgress" || ending || lateUsage {
                    var usage: [String: Any] = ["turnId": turn, "outputTokens": count]
                    usage["lastOutputTokens"] = staged.tree["latestTokenUsageInfo"]?["last"]?["outputTokens"]?.integer
                    usage["lastReasoningTokens"] = staged.tree["latestTokenUsageInfo"]?["last"]?["reasoningOutputTokens"]?.integer
                    func touchesUsage(_ field: String) -> Bool {
                        rawPaths.contains { $0.first == .key("latestTokenUsageInfo") && ($0.count == 1 || $0.dropFirst().first == .key(field)) }
                    }
                    // A total-only patch can still contain the previous request's
                    // last count. Treat split accounting as a baseline, not TPS.
                    let partial = usage["lastOutputTokens"] != nil && !(touchesUsage("total") && touchesUsage("last"))
                    usage["cachedUsage"] = snapshot || reconnecting || partial || (changed && !rawPaths.contains { $0.first == .key("latestTokenUsageInfo") })
                    if lateUsage { usage["terminalUsage"] = true }
                    events.append(event("thread/tokenUsage/updated", usage)); staged.previousUsage = count
                }
                if ending { events.append(event("turn/completed", ["turnId": turn, "status": status])) }
                staged.previousItems = items
            }
        }
        if let current, staged.runtimeAvailable {
            staged.previousTurn = .object(["turnId", "status", "turnStartedAtMs"].reduce(into: [:]) { $0[$1] = current[$1] })
        } else { staged.previousTurn = nil }
        let childStates = staged.subagentStates
        staged.collaborationThreadIDs = staged.projectedCollaborationThreadIDs
        if !attentionOnly && staged.runtimeAvailable, childStates != previousAgentStates || ((snapshot || reconnecting) && !childStates.isEmpty), let turn = staged.currentTurnID {
            events.append(event("subagents/updated", ["turnId": turn, "states": childStates]))
        }
        staged.previousAgentStates = childStates
        staged.isActive = staged.runtimeAvailable && current?["status"]?.text == "inProgress"
        staged.isTerminal = staged.runtimeAvailable && Self.terminal.contains(current?["status"]?.text ?? "")
        if staged.isTerminal, let selected, case .items(let count, _, _)? = current?["items"] {
            try staged.tree.patch((selected + [.key("items")])[...], op: "replace", value: .items(count: count, values: [:], hydrated: false))
            staged.previousItems.removeAll()
        }
        let attentionChanged = snapshot || changedSelection || rawPaths.contains { path in
            if path.first == .key("requests") { return true }
            guard let offset = path.firstIndex(of: .key("items")) else { return path.last == .key("status") }
            return path.count <= offset + 2 || path.last == .key("type") || path.last == .key("id") || path.contains(.key("questions"))
        }
        if attentionChanged { staged.refreshRequests() }
        let changedHistoricalItems = rawPaths.contains { path in
            guard let index = path.firstIndex(of: .key("items")) else { return false }
            return Array(path.prefix(index)) != selected
        }
        if changedSelection || changedHistoricalItems {
            try staged.compactHistoricalItems()
        }
        self = staged
        return events
    }
}

enum DesktopProjectionFailure: Error { case review, ephemeral, gap }
