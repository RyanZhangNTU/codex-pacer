import Foundation
import Darwin
import zlib

/// Pacer owns this loopback-only OTLP HTTP/JSON endpoint. Exported spans are
/// reduced to request identifiers and numeric timing before leaving the reader.
/// Prompt, account, tool, error and response content are validated but skipped.
final class ClaudeActivityTelemetry: @unchecked Sendable {
    struct Counters: Equatable, Sendable {
        let httpRequests: Int
        let projectedRequests: Int
        let missingCorrelations: Int
        let rejectedRequests: Int
    }
    static let maximumBodyBytes = 1024 * 1024
    static let maximumHeaderBytes = 16 * 1024
    static let maximumConnections = 8
    private static let requestTimeout: TimeInterval = 5

    private let port: UInt16
    private let onFrame: @Sendable (Data) -> Void
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "pacer.claude.telemetry", qos: .utility)
    private let acceptQueueKey = DispatchSpecificKey<Bool>()
    private var listener: DispatchSourceRead?
    private var listenerClosed: DispatchSemaphore?
    private var listenerDescriptor: Int32 = -1
    private var generation = UUID()
    private var connections: Set<Int32> = []
    private var boundPort: UInt16 = 0
    private var counts = Counters(httpRequests: 0, projectedRequests: 0, missingCorrelations: 0, rejectedRequests: 0)

    /// Port zero is useful for an isolated socket fixture. Production uses 4319.
    var listeningPort: UInt16 { lock.lock(); defer { lock.unlock() }; return boundPort }
    var counters: Counters { lock.lock(); defer { lock.unlock() }; return counts }

    private func recordCounters(http: Int = 0, projected: Int = 0, missing: Int = 0, rejected: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        func adding(_ value: Int, _ increment: Int) -> Int { value > Int.max - increment ? Int.max : value + increment }
        counts = Counters(httpRequests: adding(counts.httpRequests, http), projectedRequests: adding(counts.projectedRequests, projected),
                          missingCorrelations: adding(counts.missingCorrelations, missing), rejectedRequests: adding(counts.rejectedRequests, rejected))
    }

    init(port: UInt16 = 4319, onFrame: @escaping @Sendable (Data) -> Void) {
        self.port = port; self.onFrame = onFrame
        acceptQueue.setSpecific(key: acceptQueueKey, value: true)
    }

    /// Binding is synchronous: an occupied port is an error, never an available
    /// telemetry source. The listener accepts only IPv4 loopback connections.
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { throw POSIXError(.EALREADY) }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.socketError() }
        var owned = true
        defer { if owned { Darwin.close(fd) } }
        try Self.closeOnExec(fd)
        var reuse: Int32 = 1
        guard Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else { throw Self.socketError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, Darwin.listen(fd, Int32(Self.maximumConnections)) == 0 else { throw Self.socketError() }
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Self.socketError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }) == 0 else { throw Self.socketError() }
        let token = UUID(), source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        let closed = DispatchSemaphore(value: 0)
        generation = token; listenerDescriptor = fd; boundPort = UInt16(bigEndian: address.sin_port)
        source.setEventHandler { [weak self] in self?.acceptConnections(fd, generation: token) }
        source.setCancelHandler { Darwin.close(fd); closed.signal() }
        listener = source; listenerClosed = closed; owned = false
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = listener, fd = listenerDescriptor, closed = listenerClosed
        listener = nil; listenerClosed = nil; listenerDescriptor = -1; boundPort = 0; generation = UUID()
        for client in connections { _ = Darwin.shutdown(client, SHUT_RDWR) }
        lock.unlock()
        // Shutdown wakes blocked readers. Each owned worker closes its socket;
        // the source's cancel handler closes its listener after pending events.
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        source?.cancel()
        // Module toggles can immediately start a new owner of the same port.
        // Await descriptor release, except when deinitializing on this queue.
        if DispatchQueue.getSpecific(key: acceptQueueKey) == nil { _ = closed?.wait(timeout: .now() + 1) }
    }

    deinit { stop() }

    private static func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func closeOnExec(_ fd: Int32) throws {
        let flags = Darwin.fcntl(fd, F_GETFD)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw socketError() }
    }

    private func acceptConnections(_ fd: Int32, generation token: UUID) {
        while true {
            lock.lock()
            let current = listenerDescriptor == fd && generation == token
            lock.unlock()
            guard current else { return }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            let allowed = listenerDescriptor == fd && generation == token && connections.count < Self.maximumConnections
            if allowed { connections.insert(client) }
            lock.unlock()
            guard allowed else { Darwin.close(client); continue }
            DispatchQueue.global(qos: .utility).async { [self] in receive(client, generation: token) }
        }
    }

    private func receive(_ fd: Int32, generation token: UUID) {
        defer {
            lock.lock(); connections.remove(fd); Darwin.close(fd); lock.unlock()
        }
        do {
            try Self.closeOnExec(fd)
            let flags = Darwin.fcntl(fd, F_GETFL)
            guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw Self.socketError() }
            var noSignal: Int32 = 1, sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
            guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
                  Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout.size(ofValue: sendTimeout))) == 0 else { throw Self.socketError() }
            let body = try Self.requestBody(fd) { recordCounters(http: 1) }
            let projection = try Self.project(body)
            lock.lock(); let current = generation == token && listener != nil; lock.unlock()
            if current {
                recordCounters(projected: projection.projectedRequests, missing: projection.missingCorrelations, rejected: projection.rejectedRequests)
                for frame in projection.frames { onFrame(frame) }
            }
            Self.respond(fd, status: 200, reason: "OK")
        } catch let error as HTTPFailure {
            recordCounters(rejected: 1)
            Self.respond(fd, status: error.status, reason: error.reason)
        } catch is JSONFieldView.Failure {
            recordCounters(rejected: 1)
            Self.respond(fd, status: 400, reason: "Bad Request")
        } catch {
            recordCounters(rejected: 1)
            // Neither a rejected payload nor transport errors are logged: they
            // can contain arbitrary private input and do not prove availability.
        }
    }

    private struct HTTPFailure: Error {
        let status: Int
        let reason: String
    }

    private static func requestBody(_ fd: Int32, onRequest: () -> Void) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
        var buffer = Data(), scratch = [UInt8](repeating: 0, count: 4096)
        func append(upTo count: Int = 4096) throws {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HTTPFailure(status: 408, reason: "Request Timeout") }
            let microseconds = max(1, Int(remaining * 1_000_000))
            var timeout = timeval(tv_sec: microseconds / 1_000_000, tv_usec: Int32(microseconds % 1_000_000))
            guard Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else { throw socketError() }
            let capacity = min(scratch.count, count)
            let received = scratch.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, capacity, 0) }
            if received > 0 { buffer.append(contentsOf: scratch.prefix(received)) }
            else if received < 0 && errno == EINTR { try append(upTo: count) }
            else if received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw HTTPFailure(status: 408, reason: "Request Timeout") }
            else { throw POSIXError(.EPIPE) }
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
        return try decodedBody(buffer.subdata(in: end..<buffer.count), encoding: encoding)
    }

    static func decodedBody(_ data: Data, encoding: String) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBodyBytes else { throw HTTPFailure(status: 413, reason: "Content Too Large") }
        if encoding == "identity" { return data }
        guard encoding == "gzip" else { throw HTTPFailure(status: 415, reason: "Unsupported Media Type") }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HTTPFailure(status: 400, reason: "Bad Request")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var result = Data(), chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let capacity = min(chunk.count, maximumBodyBytes - result.count + 1)
                let before = stream.total_in
                let status = chunk.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress; stream.avail_out = uInt(capacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = capacity - Int(stream.avail_out)
                guard produced <= maximumBodyBytes - result.count else { throw HTTPFailure(status: 413, reason: "Content Too Large") }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, !result.isEmpty else { throw HTTPFailure(status: 400, reason: "Bad Request") }
                    return result
                }
                guard status == Z_OK, produced > 0 || stream.total_in > before else { throw HTTPFailure(status: 400, reason: "Bad Request") }
            }
        }
    }

    private static func respond(_ fd: Int32, status: Int, reason: String) {
        let data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { return }
        }
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
        "session.id", "prompt.id", "agent_id", "parent_agent_id", "request_id", "gen_ai.response.id",
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
        guard let session = try identifier(values["session.id"]), let prompt = try identifier(values["prompt.id"]),
              let request = try identifier(values["request_id"] ?? values["gen_ai.response.id"]) else { missing += 1; return nil }
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
        var record: [String: Any] = ["kind": "request", "sessionId": session, "promptId": prompt, "requestId": request,
                                   "at": end, "startedAt": start, "durationMs": duration, "outputTokens": Int(output)]
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
