import Foundation

/// Decode the wire once in small chunks. Transcript strings and unrelated
/// fields never become Swift strings or a complete in-memory wire frame.
struct DesktopFrameDecoder {
    struct Frame {
        let data: Data
        let peakBufferedBytes: Int
    }
    private indirect enum Value {
        case object([(String, Value)]), array([Value]), string(String), rawString(Data, Bool), number(String), boolean(Bool), longString, rejected, null
        subscript(_ key: String) -> Value? {
            guard case .object(let fields) = self else { return nil }
            return fields.last { $0.0 == key }?.1
        }
        var text: String? { if case .string(let value) = self { return value }; return nil }
        var metadataText: String? {
            if case .rawString(let data, _) = self { return try? JSONDecoder().decode(String.self, from: data) }
            return text
        }
        var isRejected: Bool { if case .rejected = self { return true }; return false }
        var number: Double? { if case .number(let value) = self { return Double(value) }; return nil }
        var cost: Int {
            switch self {
            case .object(let fields): return 32 + fields.reduce(0) { $0 + $1.0.utf8.count + $1.1.cost + 32 }
            case .array(let values): return 32 + values.reduce(0) { $0 + $1.cost + 16 }
            case .string(let value), .number(let value): return value.utf8.count + 32
            case .rawString(let value, _): return value.count + 32
            default: return 16
            }
        }
        func replacing(_ key: String, with value: Value) -> Value {
            guard case .object(let fields) = self else { return self }
            return .object(fields.filter { $0.0 != key } + [(key, value)])
        }
    }
    private enum Context {
        case envelope, params, change, state, history, historyContainer, canonicalTurns, turns, turn, items, item
        case usage, counter, runtime, requests, request, relationship, patches, patch, path, questions, text, deferred, generic
    }
    private static let maximumMetadataBytes = 16 * 1024 * 1024
    private var cursor: Cursor
    private let observedTurnIDs: Set<String>

    init(byteCount: Int, observedTurnIDs: Set<String> = [], read: @escaping (Int) throws -> Data) {
        cursor = Cursor(remaining: byteCount, read: read)
        self.observedTurnIDs = observedTurnIDs
    }
    mutating func decode() throws -> Frame {
        let value = try parse(.envelope, depth: 0)
        try cursor.whitespace()
        guard try cursor.peek() == nil else { throw JSONFieldView.Failure.malformed }
        var bytes = Data()
        try encode(value, into: &bytes)
        return Frame(data: bytes, peakBufferedBytes: cursor.peakBufferedBytes)
    }
    private func field(_ key: String, in context: Context) -> Context? {
        switch context {
        case .envelope:
            if key == "params" { return .params }
            if key == "result" { return .generic }
            return ["type", "method", "requestId", "resultType", "version", "sourceClientId", "targetClientIds"].contains(key) ? .generic : nil
        case .params:
            if key == "change" { return .change }
            return ["hostId", "conversationId", "following", "clientId", "status"].contains(key) ? .generic : nil
        case .change:
            if key == "conversationState" { return .state }
            if key == "patches" { return .patches }
            return ["type", "revision", "baseRevision"].contains(key) ? .generic : nil
        case .state:
            switch key {
            case "turns": return .turns
            case "turnHistory": return .history
            case "latestTokenUsageInfo": return .usage
            case "threadRuntimeStatus": return .runtime
            case "requests": return .requests
            case "source", "parentThreadId": return .relationship
            default: return ["title", "cwd", "latestModel", "threadSource", "ephemeral", "resumeState"].contains(key) ? .generic : nil
            }
        case .history: return key == "kind" ? .generic : key == "history" ? .historyContainer : nil
        case .historyContainer: return key == "entitiesByKey" ? .canonicalTurns : nil
        case .turn: return key == "items" ? .items : ["turnId", "status", "turnStartedAtMs"].contains(key) ? .generic : nil
        case .item:
            if ["text", "delta", "content", "summary", "summaryText"].contains(key) { return .text }
            if key == "questions" { return .questions }
            if key == "agentThreadId" { return .relationship }
            return ["id", "type", "status", "receiverThreadIds", "kind"].contains(key) ? .generic : nil
        case .usage: return ["total", "last"].contains(key) ? .counter : nil
        case .counter: return ["outputTokens", "reasoningOutputTokens"].contains(key) ? .generic : nil
        case .runtime: return ["type", "activeFlags"].contains(key) ? .generic : nil
        case .request:
            if ["request", "params"].contains(key) { return .request }
            return ["id", "requestId", "itemId", "method", "type", "kind", "status", "isBlocking"].contains(key) ? .generic : nil
        case .relationship:
            return ["subAgent", "subagent", "thread_spawn", "threadSpawn", "parent_thread_id", "parentThreadId", "other", "review"].contains(key) ? .relationship : nil
        case .patch:
            if key == "path" { return .path }
            return key == "value" ? .deferred : key == "op" ? .generic : nil
        case .text: return ["text", "delta", "content", "summary", "summaryText"].contains(key) ? .text : nil
        case .deferred, .generic:
            // Patch values can precede their paths. Reduce their possible
            // metadata shapes here, then let the existing path checks select it.
            if let value = field(key, in: .state) ?? field(key, in: .turn) ?? field(key, in: .item) ??
                field(key, in: .request) ?? field(key, in: .usage) ?? field(key, in: .counter) ??
                field(key, in: .runtime) ?? field(key, in: .relationship) { return value }
            if key == "history" { return .historyContainer }
            if key == "entitiesByKey" { return .canonicalTurns }
            return key == "clientId" ? .generic : nil
        default: return nil
        }
    }
    private mutating func parse(_ context: Context, depth: Int) throws -> Value {
        guard depth <= 128 else { throw JSONFieldView.Failure.malformed }
        try cursor.whitespace()
        guard let byte = try cursor.peek() else { throw JSONFieldView.Failure.malformed }
        switch byte {
        case 123:
            if context == .canonicalTurns { return try turns(canonical: true, depth: depth) }
            return try object(context, depth: depth)
        case 91:
            if context == .turns { return try turns(canonical: false, depth: depth) }
            return try array(context, depth: depth)
        case 34:
            if context == .text { return try cursor.string(limit: 0).nonempty ? .string("x") : .string("") }
            if context == .deferred {
                let scalar = try cursor.string(limit: 12_290, decode: false)
                return scalar.raw.map { .rawString($0, scalar.nonempty) } ?? (scalar.nonempty ? .longString : .null)
            }
            let scalar = try cursor.string(limit: context == .generic ? 12_290 : 1538)
            return scalar.value.map(Value.string) ?? (scalar.nonempty ? .longString : .null)
        case 116: try cursor.literal("true"); return .boolean(true)
        case 102: try cursor.literal("false"); return .boolean(false)
        case 110: try cursor.literal("null"); return .null
        case 45, 48...57: return try cursor.number().map(Value.number) ?? .null
        default: throw JSONFieldView.Failure.malformed
        }
    }
    private mutating func object(_ context: Context, depth: Int) throws -> Value {
        try cursor.require(123); try cursor.whitespace()
        var fields: [(String, Value)] = [], cost = 32, rejected = false
        if try cursor.consume(125) { return .object(fields) }
        repeat {
            try cursor.whitespace()
            let key = try cursor.string(limit: 1538).value
            try cursor.whitespace(); try cursor.require(58); try cursor.whitespace()
            let child = key.flatMap { field($0, in: context) }
            let next = try cursor.peek()
            if !rejected, let key, child != nil || (context == .deferred && next == 123) {
                let opaque = child == nil
                let selected: Context
                if context == .deferred, next == 123 { selected = .deferred }
                else { selected = context == .deferred && child == .generic ? .deferred : child ?? .deferred }
                let value = try parse(selected, depth: depth + 1)
                if opaque && header(value).id == nil && !value.isRejected {
                    // An unknown key may name a canonical turn, never an
                    // arbitrary tool-result or prompt object.
                    try cursor.whitespace()
                    if try cursor.consume(125) { break }
                    try cursor.require(44)
                    continue
                }
                cost += key.utf8.count + value.cost + 32
                fields.append((key, value))
                if context == .deferred, header(value).id != nil {
                    if !compactCandidates(&fields) { rejected = true }
                    cost = 32 + fields.reduce(0) { $0 + $1.0.utf8.count + $1.1.cost + 32 }
                }
                if rejected || cost > Self.maximumMetadataBytes || fields.count > (context == .generic || context == .deferred ? 512 : 128) {
                    rejected = true; fields.removeAll()
                } else if value.isRejected && ![Context.envelope, .params, .item, .turn].contains(context) {
                    rejected = true; fields.removeAll()
                }
            } else { try cursor.skip(depth: depth + 1) }
            try cursor.whitespace()
            if try cursor.consume(125) { break }
            try cursor.require(44)
        } while true
        if rejected { return .rejected }
        let value = Value.object(fields)
        if context == .patch { return sanitizedPatch(value) }
        return context == .turn ? compact(value, keepItems: true) : value
    }
    private mutating func array(_ context: Context, depth: Int) throws -> Value {
        try cursor.require(91); try cursor.whitespace()
        var values: [Value] = [], cost = 32, rejected = false, count = 0
        let child: Context = context == .items ? .item : context == .patches ? .patch : context == .requests ? .request : context
        let maximum = context == .path ? 12 : context == .requests || context == .questions ? 64 : context == .patches ? 4096 : context == .text ? 2048 : 8192
        if try cursor.consume(93) { return .array(values) }
        repeat {
            if count >= maximum { rejected = true; values.removeAll() }
            let value: Value
            if rejected || context == .questions { try cursor.skip(depth: depth + 1); value = .null }
            else { value = try parse(child, depth: depth + 1) }
            count += 1
            if !rejected {
                cost += value.cost + 16
                values.append(value)
                if context == .deferred, header(value).id != nil {
                    var candidates = values.enumerated().map { (String($0.offset), $0.element) }
                    if !compactCandidates(&candidates) { rejected = true }
                    values = candidates.map(\.1)
                    cost = 32 + values.reduce(0) { $0 + $1.cost + 16 }
                }
                if cost > Self.maximumMetadataBytes || value.isRejected || rejected { rejected = true; values.removeAll() }
            }
            try cursor.whitespace()
            if try cursor.consume(93) { return rejected ? .rejected : .array(values) }
            try cursor.require(44)
        } while true
    }
    private func header(_ value: Value) -> DesktopTurnHeader {
        DesktopTurnHeader(id: value["turnId"]?.metadataText, status: value["status"]?.metadataText, startedAt: value["turnStartedAtMs"]?.number)
    }
    private func sanitizedPatch(_ patch: Value) -> Value {
        guard case .array(let path)? = patch["path"] else { return patch }
        let keys = path.compactMap(\.text)
        guard let root = keys.first else { return patch }
        let scalarRoots = ["title", "cwd", "latestModel", "threadSource", "resumeState", "ephemeral"]
        func metadata() -> Value { patch.replacing("value", with: resolveStrings(patch["value"] ?? .null)) }
        if scalarRoots.contains(root) { return path.count == 1 ? metadata() : patch.replacing("value", with: .null) }
        if root == "parentThreadId" { return path.count == 1 ? metadata() : patch.replacing("value", with: .null) }
        if root == "source" {
            return keys.allSatisfy { ["source", "subAgent", "subagent", "thread_spawn", "threadSpawn", "parent_thread_id", "parentThreadId"].contains($0) }
                ? metadata() : patch.replacing("value", with: .null)
        }
        if root == "latestTokenUsageInfo" {
            let allowed = path.count == 1 || (path.count <= 3 && keys.count == path.count &&
                ["total", "last"].contains(keys[1]) && (path.count == 2 || ["outputTokens", "reasoningOutputTokens"].contains(keys[2])))
            return allowed ? metadata() : patch.replacing("value", with: .null)
        }
        if root == "threadRuntimeStatus" {
            return path.count == 1 || keys == [root, "type"] || keys == [root, "activeFlags"]
                ? metadata() : patch.replacing("value", with: .null)
        }
        if root == "requests" {
            return keys.allSatisfy { ["requests", "request", "params", "id", "requestId", "itemId", "method", "type", "kind", "status", "isBlocking"].contains($0) }
                ? metadata() : patch.replacing("value", with: .null)
        }
        guard ["turns", "turnHistory"].contains(root) else { return patch.replacing("value", with: .null) }
        let start = root == "turns" ? 2 : 4
        if path.count <= start { return metadata() }
        let suffix = Array(path.dropFirst(start)), field = suffix.first?.text
        if ["turnId", "status", "turnStartedAtMs"].contains(field ?? "") { return suffix.count == 1 ? metadata() : patch.replacing("value", with: .null) }
        guard field == "items" else { return patch.replacing("value", with: .null) }
        if suffix.count <= 2 { return metadata() }
        let itemField = suffix[2].text ?? ""
        if itemField == "questions" {
            if suffix.count == 3, case .array(let questions)? = patch["value"] {
                return patch.replacing("value", with: .array(questions.map { _ in .null }))
            }
            return patch.replacing("value", with: .null)
        }
        if ["text", "delta", "content", "summary", "summaryText"].contains(itemField) {
            return patch.replacing("value", with: .string(textPresent(patch["value"] ?? .null) ? "x" : ""))
        }
        return ["id", "type", "status", "questions", "receiverThreadIds", "agentThreadId", "kind"].contains(itemField)
            ? metadata() : patch.replacing("value", with: .null)
    }
    private func resolveStrings(_ value: Value) -> Value {
        switch value {
        case .rawString(let data, _): return (try? JSONDecoder().decode(String.self, from: data)).map(Value.string) ?? .null
        case .array(let values): return .array(values.map(resolveStrings))
        case .object(let fields): return .object(fields.map { ($0.0, resolveStrings($0.1)) })
        default: return value
        }
    }
    private func textPresent(_ value: Value, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        switch value {
        case .string(let value): return !value.isEmpty
        case .longString: return true
        case .rawString(_, let nonempty): return nonempty
        case .array(let values): return values.contains { textPresent($0, depth: depth + 1) }
        case .object(let fields):
            return Dictionary(fields, uniquingKeysWith: { _, last in last }).contains {
                ["text", "delta", "content", "summary", "summaryText"].contains($0.key) && textPresent($0.value, depth: depth + 1)
            }
        default: return false
        }
    }
    private func compact(_ value: Value, keepItems: Bool) -> Value {
        guard let items = value["items"] else { return value }
        let count: Int, values: [Value]
        if case .array(let raw) = items { count = raw.count; values = raw }
        else if let size = items["_pacerCount"]?.number, case .array(let raw)? = items["_pacerItems"] {
            count = Int(size); values = raw
        } else { return value }
        return value.replacing("items", with: .object([("_pacerCount", .number(String(count))),
            ("_pacerItems", .array(keepItems ? values : [])), ("_pacerHydrated", .boolean(keepItems))]))
    }
    private func compactCandidates(_ values: inout [(String, Value)]) -> Bool {
        var selected: Int?
        for index in values.indices where header(values[index].1).id != nil {
            if header(values[index].1).prefers(over: selected.map { header(values[$0].1) }, currentID: nil) { selected = index }
        }
        for index in values.indices where index != selected && !observedTurnIDs.contains(header(values[index].1).id ?? "") {
            values[index].1 = compact(values[index].1, keepItems: false)
        }
        guard let selected else { return true }
        if case .boolean(false)? = values[selected].1["items"]?["_pacerHydrated"] { return false }
        return true
    }
    private mutating func turns(canonical: Bool, depth: Int) throws -> Value {
        try cursor.require(canonical ? 123 : 91); try cursor.whitespace()
        let end: UInt8 = canonical ? 125 : 93
        var values: [(String, Value)] = [], cost = 32, rejected = false, count = 0
        if try cursor.consume(end) { return canonical ? .object([]) : .array([]) }
        repeat {
            if count >= 512 { rejected = true; values.removeAll() }
            let key: String
            if canonical {
                let parsed = try cursor.string(limit: 1538).value
                if parsed == nil { rejected = true; values.removeAll() }
                key = parsed ?? ""; try cursor.whitespace(); try cursor.require(58)
            } else { key = String(count) }
            count += 1
            if rejected {
                try cursor.skip(depth: depth + 1)
                try cursor.whitespace()
                if try cursor.consume(end) { return .rejected }
                try cursor.require(44); try cursor.whitespace()
                continue
            }
            let value = try parse(.turn, depth: depth + 1)
            if canonical, let duplicate = values.firstIndex(where: { $0.0 == key }) {
                cost -= key.utf8.count + values[duplicate].1.cost + 32
                values[duplicate].1 = value
            } else { values.append((key, value)) }
            cost += key.utf8.count + value.cost + 32
            // Release historical item metadata as soon as a later candidate
            // wins. Only the winner and already-observed turns stay hydrated.
            // An abnormal duplicate key can make a discarded turn win again.
            // Resync just that thread instead of inventing missing item state.
            if !compactCandidates(&values) { rejected = true }
            cost = 32 + values.reduce(0) { $0 + $1.0.utf8.count + $1.1.cost + 32 }
            if cost > Self.maximumMetadataBytes { rejected = true }
            if rejected { values.removeAll() }
            try cursor.whitespace()
            if try cursor.consume(end) {
                if rejected { return .rejected }
                return canonical ? .object(values) : .array(values.map(\.1))
            }
            try cursor.require(44); try cursor.whitespace()
        } while true
    }
    private func encode(_ value: Value, into data: inout Data) throws {
        func append(_ bytes: Data) throws { guard data.count + bytes.count <= Self.maximumMetadataBytes else { throw JSONFieldView.Failure.limit }; data.append(bytes) }
        switch value {
        case .object(let fields):
            try append(Data([123]))
            for (index, field) in fields.enumerated() {
                if index > 0 { try append(Data([44])) }
                try append(JSONEncoder().encode(field.0)); try append(Data([58])); try encode(field.1, into: &data)
            }
            try append(Data([125]))
        case .array(let values):
            try append(Data([91]))
            for (index, value) in values.enumerated() {
                if index > 0 { try append(Data([44])) }
                try encode(value, into: &data)
            }
            try append(Data([93]))
        case .string(let value): try append(JSONEncoder().encode(value))
        case .number(let value): try append(Data(value.utf8))
        case .boolean(let value): try append(Data((value ? "true" : "false").utf8))
        case .rejected: try append(Data(#"{"_pacerRejected":true}"#.utf8))
        case .rawString, .longString, .null: try append(Data("null".utf8))
        }
    }
    private struct Cursor {
        var remaining: Int
        let read: (Int) throws -> Data
        private var bytes: [UInt8] = []
        private var position = 0
        private(set) var peakBufferedBytes = 0
        init(remaining: Int, read: @escaping (Int) throws -> Data) { self.remaining = remaining; self.read = read }
        mutating func peek() throws -> UInt8? {
            if position == bytes.count {
                guard remaining > 0 else { return nil }
                let count = min(64 * 1024, remaining), data = try read(count)
                guard data.count == count else { throw JSONFieldView.Failure.malformed }
                bytes = Array(data); position = 0; remaining -= count
                peakBufferedBytes = max(peakBufferedBytes, bytes.count)
            }
            return bytes[position]
        }
        mutating func take() throws -> UInt8 {
            guard let byte = try peek() else { throw JSONFieldView.Failure.malformed }
            position += 1; return byte
        }
        mutating func whitespace() throws {
            while let byte = try peek(), [9, 10, 13, 32].contains(byte) { position += 1 }
        }
        mutating func consume(_ byte: UInt8) throws -> Bool {
            guard try peek() == byte else { return false }; position += 1; return true
        }
        mutating func require(_ byte: UInt8) throws { guard try consume(byte) else { throw JSONFieldView.Failure.malformed } }
        mutating func literal(_ value: String) throws { for byte in value.utf8 { try require(byte) } }
        mutating func number() throws -> String? {
            var raw: [UInt8] = []
            func record(_ byte: UInt8) { if raw.count < 65 { raw.append(byte) } }
            if try consume(45) { record(45) }
            if try consume(48) {
                record(48)
                if let byte = try peek(), (48...57).contains(byte) { throw JSONFieldView.Failure.malformed }
            } else {
                guard let byte = try peek(), (49...57).contains(byte) else { throw JSONFieldView.Failure.malformed }
                while let byte = try peek(), (48...57).contains(byte) { record(try take()) }
            }
            if try consume(46) {
                record(46); guard let byte = try peek(), (48...57).contains(byte) else { throw JSONFieldView.Failure.malformed }
                while let byte = try peek(), (48...57).contains(byte) { record(try take()) }
            }
            if let byte = try peek(), byte == 101 || byte == 69 {
                record(try take())
                if let byte = try peek(), byte == 43 || byte == 45 { record(try take()) }
                guard let byte = try peek(), (48...57).contains(byte) else { throw JSONFieldView.Failure.malformed }
                while let byte = try peek(), (48...57).contains(byte) { record(try take()) }
            }
            return raw.count <= 64 ? String(bytes: raw, encoding: .utf8) : nil
        }
        mutating func string(limit: Int, decode: Bool = true) throws -> (value: String?, nonempty: Bool, raw: Data?) {
            try require(34)
            var raw: [UInt8] = [34], nonempty = false, overflow = false
            func record(_ byte: UInt8) { if raw.count < limit { raw.append(byte) } else { overflow = true } }
            func hexDigit(_ byte: UInt8) throws -> UInt32 {
                switch byte {
                case 48...57: return UInt32(byte - 48)
                case 65...70: return UInt32(byte - 55)
                case 97...102: return UInt32(byte - 87)
                default: throw JSONFieldView.Failure.malformed
                }
            }
            while true {
                let byte = try take(); record(byte)
                if byte == 34 { break }
                nonempty = true
                if byte == 92 {
                    let escape = try take(); record(escape)
                    if escape == 117 {
                        var code: UInt32 = 0
                        for _ in 0..<4 { let digit = try take(); record(digit); code = code * 16 + (try hexDigit(digit)) }
                        if (0xD800...0xDBFF).contains(code) {
                            try require(92); record(92); try require(117); record(117)
                            var low: UInt32 = 0
                            for _ in 0..<4 { let digit = try take(); record(digit); low = low * 16 + (try hexDigit(digit)) }
                            guard (0xDC00...0xDFFF).contains(low) else { throw JSONFieldView.Failure.malformed }
                        } else if (0xDC00...0xDFFF).contains(code) { throw JSONFieldView.Failure.malformed }
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw JSONFieldView.Failure.malformed }
                } else if byte < 32 { throw JSONFieldView.Failure.malformed }
                else if byte >= 128 {
                    let count: Int
                    switch byte { case 0xC2...0xDF: count = 1; case 0xE0...0xEF: count = 2; case 0xF0...0xF4: count = 3; default: throw JSONFieldView.Failure.malformed }
                    for index in 0..<count {
                        let next = try take(); record(next)
                        guard (0x80...0xBF).contains(next), index != 0 ||
                            ((byte != 0xE0 || next >= 0xA0) && (byte != 0xED || next <= 0x9F) &&
                             (byte != 0xF0 || next >= 0x90) && (byte != 0xF4 || next <= 0x8F)) else { throw JSONFieldView.Failure.malformed }
                    }
                }
            }
            let data = overflow ? nil : Data(raw)
            return (decode ? try data.map { try JSONDecoder().decode(String.self, from: $0) } : nil, nonempty, data)
        }
        mutating func skip(depth: Int) throws {
            guard depth <= 128 else { throw JSONFieldView.Failure.malformed }
            try whitespace()
            guard let byte = try peek() else { throw JSONFieldView.Failure.malformed }
            switch byte {
            case 34: _ = try string(limit: 0)
            case 123:
                try require(123); try whitespace(); if try consume(125) { return }
                repeat {
                    try whitespace(); _ = try string(limit: 0); try whitespace(); try require(58)
                    try skip(depth: depth + 1); try whitespace(); if try consume(125) { return }; try require(44)
                } while true
            case 91:
                try require(91); try whitespace(); if try consume(93) { return }
                repeat { try skip(depth: depth + 1); try whitespace(); if try consume(93) { return }; try require(44) } while true
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            case 45, 48...57: _ = try number()
            default: throw JSONFieldView.Failure.malformed
            }
        }
    }
}

/// Shared chronology rules keep the streaming reader and sparse projection in
/// agreement, including timestamp-less turns already observed before reconnect.
struct DesktopTurnHeader {
    let id: String?
    let status: String?
    let startedAt: Double?
    func prefers(over previous: DesktopTurnHeader?, currentID: String?) -> Bool {
        guard let previous else { return true }
        let start = startedAt.flatMap { $0 > 0 ? $0 : nil }, oldStart = previous.startedAt.flatMap { $0 > 0 ? $0 : nil }
        if let start, let oldStart, start != oldStart { return start > oldStart }
        if (status == "inProgress") != (previous.status == "inProgress") { return status == "inProgress" }
        if let currentID, (id == currentID) != (previous.id == currentID) { return id == currentID }
        if (start != nil) != (oldStart != nil) { return start != nil }
        return true
    }
}
