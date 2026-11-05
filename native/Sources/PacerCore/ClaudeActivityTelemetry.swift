import Foundation
import CGzip

public enum TelemetryTransportFailure: Error { case timeout, closed, unavailable }
public protocol TelemetryConnection: AnyObject, Sendable {
    func read(maximumBytes: Int, timeout: TimeInterval) throws -> Data
    func write(_ data: Data) throws
    /// Interrupts blocked IO; the worker retains close ownership.
    func interrupt()
    func close()
}
public protocol TelemetryListener: AnyObject, Sendable {
    var port: UInt16 { get }
    func stop()
}
public protocol TelemetryTransport: Sendable {
    /// Binding is synchronous. Accepted connections are delivered asynchronously.
    func listen(port: UInt16, backlog: Int,
                accepted: @escaping @Sendable (any TelemetryConnection) -> Void) throws -> any TelemetryListener
}

/// Pacer's loopback OTLP endpoint. HTTP limits, numeric projection and privacy
/// rules are shared; the host supplies socket ownership and interruptible IO.
public final class ClaudeActivityTelemetry: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public let httpRequests: Int
        public let projectedRequests: Int
        public let missingCorrelations: Int
        public let rejectedRequests: Int
    }
    static let maximumBodyBytes = 1024 * 1024
    static let maximumHeaderBytes = 16 * 1024
    static let maximumConnections = 8
    private static let requestTimeout: TimeInterval = 5
    private let port: UInt16
    private let transport: any TelemetryTransport
    private let onFrame: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var listener: (any TelemetryListener)?
    private var generation = UUID()
    private var connections: [UUID: any TelemetryConnection] = [:]
    private var counts = Counters(httpRequests: 0, projectedRequests: 0, missingCorrelations: 0, rejectedRequests: 0)
    public var listeningPort: UInt16 { lock.lock(); defer { lock.unlock() }; return listener?.port ?? 0 }
    public var counters: Counters { lock.lock(); defer { lock.unlock() }; return counts }
    /// Accepted clients that still hold a request worker; tests wait on it.
    var openConnections: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    private func recordCounters(http: Int = 0, projected: Int = 0, missing: Int = 0, rejected: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        func adding(_ value: Int, _ increment: Int) -> Int { value > Int.max - increment ? Int.max : value + increment }
        counts = Counters(httpRequests: adding(counts.httpRequests, http), projectedRequests: adding(counts.projectedRequests, projected),
                          missingCorrelations: adding(counts.missingCorrelations, missing), rejectedRequests: adding(counts.rejectedRequests, rejected))
    }
    public init(port: UInt16 = 4319, transport: any TelemetryTransport, onFrame: @escaping @Sendable (Data) -> Void) {
        self.port = port; self.transport = transport; self.onFrame = onFrame
    }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { throw TelemetryTransportFailure.unavailable }
        let token = UUID(); generation = token
        listener = try transport.listen(port: port, backlog: Self.maximumConnections) { [weak self] connection in
            guard let self else { connection.close(); return }
            self.accept(connection, generation: token)
        }
    }
    public func stop() {
        lock.lock()
        let listener = self.listener, clients = Array(connections.values)
        self.listener = nil; generation = UUID()
        lock.unlock()
        for client in clients { client.interrupt() }
        listener?.stop()
    }
    deinit { stop() }
    private func accept(_ client: any TelemetryConnection, generation token: UUID) {
        let id = UUID()
        lock.lock()
        let allowed = generation == token && listener != nil && connections.count < Self.maximumConnections
        if allowed { connections[id] = client }
        lock.unlock()
        guard allowed else { client.close(); return }
        DispatchQueue.global(qos: .utility).async { [self] in receive(client, id: id, generation: token) }
    }
    private func receive(_ client: any TelemetryConnection, id: UUID, generation token: UUID) {
        defer {
            client.close()
            lock.lock(); connections.removeValue(forKey: id); lock.unlock()
        }
        do {
            let body = try Self.requestBody(client) { recordCounters(http: 1) }
            let projection = try Self.project(body)
            lock.lock(); let current = generation == token && listener != nil; lock.unlock()
            if current {
                recordCounters(projected: projection.projectedRequests, missing: projection.missingCorrelations, rejected: projection.rejectedRequests)
                for frame in projection.frames { onFrame(frame) }
            }
            Self.respond(client, status: 200, reason: "OK")
        } catch let error as HTTPFailure {
            recordCounters(rejected: 1); Self.respond(client, status: error.status, reason: error.reason)
        } catch is JSONFieldView.Failure {
            recordCounters(rejected: 1); Self.respond(client, status: 400, reason: "Bad Request")
        } catch { recordCounters(rejected: 1) }
    }
    private struct HTTPFailure: Error { let status: Int; let reason: String }
    private static func requestBody(_ client: any TelemetryConnection, onRequest: () -> Void) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
        var buffer = Data()
        func append(upTo count: Int = 4096) throws {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HTTPFailure(status: 408, reason: "Request Timeout") }
            do {
                let bytes = try client.read(maximumBytes: min(4096, count), timeout: remaining)
                guard !bytes.isEmpty else { throw TelemetryTransportFailure.closed }
                buffer.append(bytes)
            } catch TelemetryTransportFailure.timeout { throw HTTPFailure(status: 408, reason: "Request Timeout") }
        }
        let separator = Data([13, 10, 13, 10])
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            try append()
            headerEnd = buffer.range(of: separator)
            guard (headerEnd?.upperBound ?? buffer.count) <= maximumHeaderBytes else { throw HTTPFailure(status: 431, reason: "Request Header Fields Too Large") }
        }
        onRequest()
        let end = headerEnd!.upperBound
        guard let header = String(data: buffer.prefix(end), encoding: .utf8) else { throw HTTPFailure(status: 400, reason: "Bad Request") }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else { throw HTTPFailure(status: 400, reason: "Bad Request") }
        guard request[0] == "POST" else { throw HTTPFailure(status: 405, reason: "Method Not Allowed") }
        guard request[1] == "/v1/traces" else { throw HTTPFailure(status: 404, reason: "Not Found") }
        var headers: [String: String] = [:]
        let selected: Set<String> = ["content-length", "content-type", "content-encoding", "transfer-encoding"]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line.first != " " && line.first != "\t" else { throw HTTPFailure(status: 400, reason: "Bad Request") }
            let name = line[..<colon].lowercased()
            guard selected.contains(name) else { continue }
            guard headers[name] == nil else { throw HTTPFailure(status: 400, reason: "Bad Request") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPFailure(status: 400, reason: "Bad Request") }
        let encoding = headers["content-encoding"]?.lowercased() ?? "identity"
        guard ["identity", "gzip"].contains(encoding),
              headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw HTTPFailure(status: 415, reason: "Unsupported Media Type") }
        guard let declared = headers["content-length"] else { throw HTTPFailure(status: 411, reason: "Length Required") }
        guard !declared.isEmpty, declared.count <= 8, declared.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(declared) else { throw HTTPFailure(status: 400, reason: "Bad Request") }
        guard count > 0, count <= maximumBodyBytes else { throw HTTPFailure(status: 413, reason: "Content Too Large") }
        guard buffer.count - end <= count else { throw HTTPFailure(status: 400, reason: "Bad Request") }
        while buffer.count - end < count { try append(upTo: count - (buffer.count - end)) }
        return try Self.decodedBody(buffer.subdata(in: end..<buffer.count), encoding: encoding)
    }

    static func decodedBody(_ data: Data, encoding: String) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBodyBytes else { throw HTTPFailure(status: 413, reason: "Content Too Large") }
        if encoding == "identity" { return data }
        guard encoding == "gzip" else { throw HTTPFailure(status: 415, reason: "Unsupported Media Type") }
        var output = Data(count: maximumBodyBytes + 1), written = 0
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                pacer_gzip_decode(input.bindMemory(to: UInt8.self).baseAddress, data.count,
                    result.bindMemory(to: UInt8.self).baseAddress, maximumBodyBytes, &written)
            }
        }
        guard status != -2 else { throw HTTPFailure(status: 413, reason: "Content Too Large") }
        guard status == 1 else { throw HTTPFailure(status: 400, reason: "Bad Request") }
        output.count = written
        return output
    }
    private static func respond(_ client: any TelemetryConnection, status: Int, reason: String) {
        try? client.write(Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8))
    }

    /// Shared wire projection for fixture checks and native/remote parity. No
    /// terminal task state is inferred from an interaction span ending.
    static func frames(_ data: Data) throws -> [Data] {
        try project(data).frames
    }

    private struct Projection {
        var frames: [Data] = []
        var projectedRequests = 0
        var missingCorrelations = 0
        var rejectedRequests = 0
    }

    private static func project(_ data: Data) throws -> Projection {
        let root = try JSONFieldView.document(data, maximumBytes: maximumBodyBytes)
        guard root.isObject else { throw JSONFieldView.Failure.malformed }
        let fields = try root.fields(["resourceSpans"])
        guard let resources = fields["resourceSpans"] else { return Projection() }
        guard resources.isArray else { throw JSONFieldView.Failure.malformed }
        var records: [[String: Any]] = [], spanCount = 0, missingCount = 0, rejectedCount = 0
        try resources.forEachElement(maximumCount: 64) { resource in
            guard resource.isObject else { throw JSONFieldView.Failure.malformed }
            let r = try resource.fields(["resource", "scopeSpans"])
            var common: [String: JSONFieldView] = [:]
            if let view = r["resource"] {
                guard view.isObject else { throw JSONFieldView.Failure.malformed }
                common = try attributes(try view.fields(["attributes"])["attributes"])
            }
            guard let scopes = r["scopeSpans"] else { return }
            guard scopes.isArray else { throw JSONFieldView.Failure.malformed }
            try scopes.forEachElement(maximumCount: 128) { scope in
                guard scope.isObject else { throw JSONFieldView.Failure.malformed }
                guard let spans = try scope.fields(["spans"])["spans"] else { return }
                guard spans.isArray else { throw JSONFieldView.Failure.malformed }
                try spans.forEachElement(maximumCount: 512) { span in
                    spanCount += 1; guard spanCount <= 512 else { throw JSONFieldView.Failure.limit }
                    guard span.isObject else { throw JSONFieldView.Failure.malformed }
                    if let value = try request(span, common: common, missing: &missingCount, rejected: &rejectedCount) { records.append(value) }
                }
            }
        }
        var result = Projection()
        result.missingCorrelations = missingCount; result.rejectedRequests = rejectedCount
        if !records.isEmpty {
            result.projectedRequests = records.count
            result.frames = [try JSONSerialization.data(withJSONObject: ["kind": "claudeBatch", "records": records], options: [.sortedKeys])]
        }
        return result
    }

    private static let allowedAttributes: Set<String> = [
        "session.id", "prompt.id", "llm_request.context", "agent_id", "parent_agent_id", "request_id", "gen_ai.response.id",
        "duration_ms", "output_tokens", "ttft_ms", "first_content_ms", "model", "gen_ai.request.model", "success"
    ]

    private static func attributes(_ view: JSONFieldView?) throws -> [String: JSONFieldView] {
        guard let view else { return [:] }
        guard view.isArray else { throw JSONFieldView.Failure.malformed }
        var result: [String: JSONFieldView] = [:]
        try view.forEachElement(maximumCount: 256) { attribute in
            guard attribute.isObject else { throw JSONFieldView.Failure.malformed }
            guard let key = try attribute.fields(["key"])["key"]?.string(limit: 128), allowedAttributes.contains(key) else { return }
            // An unselected AnyValue is never decoded, including its nested
            // string/array/kvlist contents, even if content gates were enabled.
            if let value = try attribute.fields(["value"])["value"] { result[key] = value }
        }
        return result
    }

    private static func string(_ view: JSONFieldView?, limit: Int = 256) throws -> String? {
        guard let view, view.isObject else { return nil }
        let fields = try view.fields(["stringValue", "intValue", "doubleValue", "boolValue", "arrayValue", "kvlistValue", "bytesValue"])
        guard fields.count == 1 else { return nil }
        return fields["stringValue"]?.string(limit: limit)
    }

    private static func identifier(_ view: JSONFieldView?) throws -> String? {
        guard let value = try string(view, limit: 257) else { return nil }
        return ClaudeActivityRecord.identifier(value)
    }

    private static func number(_ view: JSONFieldView?) throws -> Double? {
        guard let view, view.isObject else { return nil }
        let values = try view.fields(["stringValue", "intValue", "doubleValue", "boolValue", "arrayValue", "kvlistValue", "bytesValue"])
        guard values.count == 1 else { return nil }
        if let value = values["intValue"]?.signedInteger() { return Double(value) }
        if let value = values["doubleValue"] {
            let result = value.number() ?? value.string(limit: 65).flatMap { text -> Double? in
                guard text.utf8.count <= 64, text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil else { return nil }
                return Double(text)
            }
            if let result, result.isFinite { return result }
        }
        return nil
    }

    private static func timestamp(_ view: JSONFieldView?) -> Double? {
        guard let view else { return nil }
        guard let value = view.unsignedInteger(), value > 0 else { return nil }
        return Double(value) / 1_000_000_000
    }

    private static func request(_ span: JSONFieldView, common: [String: JSONFieldView], missing: inout Int, rejected: inout Int) throws -> [String: Any]? {
        let fields = try span.fields(["name", "startTimeUnixNano", "endTimeUnixNano", "attributes", "status"])
        guard fields["name"]?.string(limit: 64) == "claude_code.llm_request" else { return nil }
        let values = common.merging(try attributes(fields["attributes"])) { _, selected in selected }
        let prompt = try identifier(values["prompt.id"])
        // Current Claude Code omits prompt.id on request spans. A main-conversation
        // request binds to the session's current turn; a subagent's request names
        // its agent and binds only to that already observed child's turn.
        guard let session = try identifier(values["session.id"]),
              let request = try identifier(values["request_id"] ?? values["gen_ai.response.id"]),
              values["prompt.id"] == nil || prompt != nil,
              try prompt != nil || string(values["llm_request.context"], limit: 32) == "interaction" || identifier(values["agent_id"]) != nil
        else { missing += 1; return nil }
        if let status = fields["status"], !status.isNull {
            guard status.isObject else { rejected += 1; return nil }
            let code = try status.fields(["code"])["code"]
            if let code, !code.isNull,
               code.hasNonemptyString || (code.signedInteger().map({ !(0...1).contains($0) }) ?? true) { rejected += 1; return nil }
        }
        var successValue: Bool?
        if let success = values["success"] {
            guard success.isObject else { rejected += 1; return nil }
            let explicit = try success.fields(["boolValue", "stringValue", "intValue", "doubleValue", "arrayValue", "kvlistValue", "bytesValue"])
            if explicit.count == 1 {
                successValue = explicit["boolValue"]?.boolean()
                if successValue == nil, let text = explicit["stringValue"]?.string(limit: 6)?.lowercased(), ["true", "false"].contains(text) { successValue = text == "true" }
            }
            guard successValue == true else { rejected += 1; return nil }
        }
        guard let start = timestamp(fields["startTimeUnixNano"]), let end = timestamp(fields["endTimeUnixNano"]), end > start,
              let duration = try number(values["duration_ms"]), duration >= 10, duration <= 3_600_000,
              let output = try number(values["output_tokens"]), output > 0, output <= 1_000_000_000_000, output.rounded(.towardZero) == output else { rejected += 1; return nil }
        var record: [String: Any] = ["kind": "request", "sessionId": session, "requestId": request,
                                   "at": end, "startedAt": start, "durationMs": duration, "outputTokens": Int(output)]
        if let prompt { record["promptId"] = prompt }
        if let agent = try identifier(values["agent_id"]) { record["agentId"] = agent }
        if let parent = try identifier(values["parent_agent_id"]) { record["parentAgentId"] = parent }
        for (input, key) in [("ttft_ms", "ttftMs"), ("first_content_ms", "firstContentMs")] {
            if let value = try number(values[input]), value >= 0, value <= duration { record[key] = value }
        }
        if let model = try string(values["model"] ?? values["gen_ai.request.model"], limit: 129), !model.isEmpty, model.count <= 128,
           model.utf8.allSatisfy({ byte in (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 58, 95].contains(byte) }) { record["model"] = model }
        if successValue == true { record["success"] = true }
        return record
    }
}
