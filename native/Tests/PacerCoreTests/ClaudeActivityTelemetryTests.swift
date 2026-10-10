import XCTest
import Darwin
@testable import PacerCore

final class ClaudeActivityTelemetryTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Data] = []
        func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    private func attributes(_ values: [String: Any]) -> [[String: Any]] {
        values.map { key, value in
            let field: String
            if value is Bool { field = "boolValue" }
            else if value is Int { field = "intValue" }
            else if value is Double { field = "doubleValue" }
            else { field = "stringValue" }
            return ["key": key, "value": [field: value is Int ? String(value as! Int) : value]]
        }
    }

    private func span(_ values: [String: Any] = [:], name: String = "claude_code.llm_request") -> [String: Any] {
        let defaults: [String: Any] = ["session.id": "session-1", "prompt.id": "prompt-1", "request_id": "req_1",
                                      "output_tokens": 160, "duration_ms": 2000.0, "ttft_ms": 240.0,
                                      "first_content_ms": 300.0, "model": "claude-sonnet-4-6", "success": true]
        return ["name": name, "startTimeUnixNano": "1790000000000000000", "endTimeUnixNano": "1790000002000000000",
                "attributes": attributes(defaults.merging(values) { _, supplied in supplied })]
    }

    private func payload(_ spans: [[String: Any]], resource: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resourceSpans": [["resource": ["attributes": attributes(resource)],
                                                                    "scopeSpans": [["spans": spans]]]]])
    }

    private func records(_ data: Data) throws -> [[String: Any]] {
        let frames = try ClaudeActivityTelemetry.frames(data)
        return try frames.flatMap { frame -> [[String: Any]] in
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            XCTAssertEqual(value["kind"] as? String, "claudeBatch")
            return try XCTUnwrap(value["records"] as? [[String: Any]])
        }
    }

    private func python(_ body: String, input: Data) throws -> Data {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", body, Data(ClaudeActivityProbe.script.utf8).base64EncodedString()]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
        return output
    }

    private func gzip(_ data: Data) throws -> Data {
        try python("import gzip,sys\nsys.stdout.buffer.write(gzip.compress(sys.stdin.buffer.read(),mtime=0))", input: data)
    }

    func testNativeAndSSHProjectionAgreeOnTypedNumbersAliasesAndInvalidEvidence() throws {
        let session = "AAAAAAAA-1111-4111-8111-111111111111"
        var alias = span()
        alias["startTimeUnixNano"] = "1.79e18"
        alias["endTimeUnixNano"] = "1790000002e9"
        alias["status"] = ["code": 1]
        let base: [[String: Any]] = [
            ["key": "session.id", "value": ["stringValue": session]],
            ["key": "prompt.id", "value": ["stringValue": "typed-prompt"]],
            ["key": "gen_ai.response.id", "value": ["stringValue": "req_alias"]],
            ["key": "gen_ai.request.model", "value": ["stringValue": "claude-fixture"]],
            ["key": "output_tokens", "value": ["intValue": "1.6e2"]],
            ["key": "duration_ms", "value": ["doubleValue": "2e3"]],
            ["key": "ttft_ms", "value": ["intValue": "2.4e2"]],
            ["key": "success", "value": ["boolValue": true]],
            ["key": "user_prompt", "value": ["stringValue": "PRIVATE synthetic content"]]
        ]
        alias["attributes"] = base
        func replacing(_ key: String, with extra: [[String: Any]]) -> [String: Any] {
            var result = alias
            result["attributes"] = base.filter { $0["key"] as? String != key } + extra
            return result
        }
        func changing(_ key: String, to value: [String: Any]) -> [String: Any] { replacing(key, with: [["key": key, "value": value]]) }
        func context(_ value: String) -> [[String: Any]] { [["key": "llm_request.context", "value": ["stringValue": value]]] }
        var statusError = alias; statusError["status"] = ["code": 2]
        var invalidStatus = alias; invalidStatus["status"] = false
        var invalidOwner = alias
        invalidOwner["attributes"] = base.filter { $0["key"] as? String != "session.id" } +
            [["key": "session.id", "value": "invalid AnyValue"]]
        var fractionalTime = alias; fractionalTime["startTimeUnixNano"] = "1790000000000000000.1"
        var nonfinite = String(decoding: try payload([alias]), as: UTF8.self)
        nonfinite.removeLast(); nonfinite += ",\"ignoredPrivate\":NaN}"
        let cases: [(Data, Int, Int)] = [
            (try payload([alias]), 200, 1),
            (try payload([changing("output_tokens", to: ["intValue": "1.5"])]), 200, 0),
            (try payload([changing("output_tokens", to: ["intValue": "1.0000000000000000001"])]), 200, 0),
            (try payload([changing("output_tokens", to: ["boolValue": true])]), 200, 0),
            (try payload([changing("output_tokens", to: ["intValue": "160", "doubleValue": 160])]), 200, 0),
            (try payload([changing("duration_ms", to: ["doubleValue": "Infinity"])]), 200, 0),
            (try payload([changing("request_id", to: ["stringValue": ""])]), 200, 0),
            (try payload([changing("session.id", to: ["stringValue": session + "\n"])]), 200, 0),
            (try payload([changing("success", to: ["boolValue": false])]), 200, 0),
            (try payload([changing("model", to: ["stringValue": "invalid model"])]), 200, 1),
            (try payload([statusError, fractionalTime]), 200, 0),
            (Data(nonfinite.utf8), 400, 0),
            (try payload([invalidStatus]), 200, 0),
            (try payload([invalidOwner], resource: ["session.id": "resource-owner"]), 200, 0),
            (try payload([replacing("prompt.id", with: context("interaction"))]), 200, 1),
            (try payload([replacing("prompt.id", with: context("interaction") + [["key": "prompt.id", "value": ["stringValue": "invalid prompt"]]])]), 200, 0),
            (try payload([replacing("prompt.id", with: [])]), 200, 0),
            (try payload([replacing("prompt.id", with: context("standalone"))]), 200, 0)
        ]
        let input = try JSONSerialization.data(withJSONObject: cases.map { $0.0.base64EncodedString() })
        let script = """
        import base64,json,sys
        namespace={'__name__':'pacer_fixture'}
        source=base64.b64decode(sys.argv[1]).decode()
        exec(compile(source,'pacer_otlp_fixture','exec'),namespace)
        output=[]
        for encoded in json.load(sys.stdin):
            try:output.append({'status':200,'records':namespace['otlp_records'](base64.b64decode(encoded))})
            except namespace['OTLPFailure'] as error:output.append({'status':error.status,'records':[]})
        print(json.dumps(output,separators=(',',':')))
        """
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(with: python(script, input: input)) as? [[String: Any]])
        XCTAssertEqual(remote.count, cases.count)
        for (index, sample) in cases.enumerated() {
            let observed = try XCTUnwrap(remote[index]["records"] as? [[String: Any]])
            XCTAssertEqual(remote[index]["status"] as? Int, sample.1, "case \(index)")
            if sample.1 == 400 { XCTAssertThrowsError(try records(sample.0)); continue }
            let native = try records(sample.0)
            XCTAssertEqual(native.count, sample.2, "case \(index)")
            XCTAssertTrue((native as NSArray).isEqual(to: observed), "case \(index)")
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: native), as: UTF8.self).contains("PRIVATE"))
            if index == cases.count - 3 { XCTAssertNil(native.first?["promptId"], "Context correlation never invents a prompt ID") }
            if index == 0 {
                XCTAssertEqual(native.first?["sessionId"] as? String, session.lowercased())
                XCTAssertEqual(native.first?["outputTokens"] as? Int, 160)
                XCTAssertEqual(native.first?["requestId"] as? String, "req_alias")
            }
            if index == 9 { XCTAssertNil(native.first?["model"]) }
        }
    }

    func testGzipSocketMatchesIdentityAndRejectsCorruptionAndExpansionOverflow() throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        let body = try payload([span(["user_prompt": "PRIVATE synthetic gzip prompt"])])
        let compressed = try gzip(body)
        XCTAssertEqual(try ClaudeActivityTelemetry.decodedBody(compressed, encoding: "gzip"), body)
        let remoteProgram = """
        import base64,json,sys
        namespace={'__name__':'pacer_fixture'}
        exec(compile(base64.b64decode(sys.argv[1]).decode(),'pacer_gzip_fixture','exec'),namespace)
        output=[]
        for encoded in json.load(sys.stdin):
            raw=base64.b64decode(encoded)
            try:
                header=('POST /v1/traces HTTP/1.1\\r\\nContent-Type: application/json\\r\\nContent-Encoding: gzip\\r\\nContent-Length: '+str(len(raw))).encode()
                size,encoding=namespace['otlp_request_header'](header)
                decoded=namespace['otlp_decoded_body'](raw,encoding)
                namespace['otlp_records'](decoded)
                output.append(200)
            except namespace['OTLPFailure'] as error:output.append(error.status)
        print(json.dumps(output))
        """
        var corrupt = compressed; corrupt[corrupt.count - 1] ^= 0xff
        let bomb = try gzip(Data(repeating: 32, count: ClaudeActivityTelemetry.maximumBodyBytes + 1))
        let cases: [(Data, Int)] = [(compressed, 200), (compressed.dropLast(), 400),
            (corrupt, 400), (compressed + Data("trailing".utf8), 400), (bomb, 413)]
        let remote = try XCTUnwrap(JSONSerialization.jsonObject(with: python(remoteProgram,
            input: JSONSerialization.data(withJSONObject: cases.map { $0.0.base64EncodedString() }))) as? [Int])
        XCTAssertEqual(remote, cases.map { $0.1 })
        for (data, status) in cases {
            let fd = try connect(receiver.listeningPort); defer { Darwin.close(fd) }
            let header = Data("POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: \(data.count)\r\n\r\n".utf8)
            try send(header + data, to: fd)
            XCTAssertTrue(try response(fd).hasPrefix("HTTP/1.1 \(status)"))
        }
        XCTAssertEqual(frames.all().count, 1)
        XCTAssertEqual(receiver.counters, .init(httpRequests: 5, projectedRequests: 1, missingCorrelations: 0, rejectedRequests: 4))
        XCTAssertFalse(frames.all().contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
    }

    func testProjectsOnlyAuthoritativeNumericRequestsAndNeverPrivateContent() throws {
        var request = span(["agent_id": "agent-2", "parent_agent_id": "agent-1",
                            "user_prompt": String(repeating: "PRIVATE", count: 10_000),
                            "response.model_output": "PRIVATE response", "input_tokens": 9000,
                            "error": "PRIVATE path", "tool_input": "PRIVATE command"])
        request["events"] = [["name": "tool.output", "attributes": attributes(["output": "PRIVATE output"])]]
        let bytes = try payload([request, span(name: "claude_code.interaction"), span(name: "claude_code.tool")],
                                resource: ["user.account_uuid": "PRIVATE account", "user.email": "PRIVATE email"])
        let frames = try ClaudeActivityTelemetry.frames(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(String(decoding: frames[0], as: UTF8.self).contains("PRIVATE"))
        let result = try records(bytes)
        XCTAssertEqual(result.count, 1)
        let record = try XCTUnwrap(result.first)
        XCTAssertEqual(Set(record.keys), ["kind", "sessionId", "promptId", "requestId", "agentId", "parentAgentId", "at",
                                         "startedAt", "durationMs", "outputTokens", "ttftMs", "firstContentMs", "model", "success"])
        XCTAssertEqual(record["kind"] as? String, "request")
        XCTAssertEqual(record["sessionId"] as? String, "session-1")
        XCTAssertEqual(record["agentId"] as? String, "agent-2")
        XCTAssertEqual(record["parentAgentId"] as? String, "agent-1")
        XCTAssertEqual(record["outputTokens"] as? Int, 160)
        XCTAssertEqual(record["durationMs"] as? Double, 2000)
        XCTAssertEqual(record["ttftMs"] as? Double, 240)
        XCTAssertEqual(record["firstContentMs"] as? Double, 300)
        XCTAssertEqual(try XCTUnwrap(record["startedAt"] as? Double), 1_790_000_000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(record["at"] as? Double), 1_790_000_002, accuracy: 0.000001)
    }

    func testResourceIdentifiersAreFallbacksAndSpanIdentifiersTakePrecedence() throws {
        var request = span()
        request["attributes"] = attributes(["request_id": "req-1", "duration_ms": 1500, "output_tokens": 40,
                                            "session.id": "span-session", "gen_ai.request.model": "claude-opus-4-6"])
        let result = try records(payload([request], resource: ["session.id": "resource-session", "prompt.id": "resource-prompt"]))
        let record = try XCTUnwrap(result.first)
        XCTAssertEqual(record["sessionId"] as? String, "span-session")
        XCTAssertEqual(record["promptId"] as? String, "resource-prompt")
        XCTAssertEqual(record["model"] as? String, "claude-opus-4-6")
        XCTAssertNil(record["success"])
    }

    func testFailedMissingOrUnsafeRequestsCannotManufactureMetricsOrCompletion() throws {
        var failedStatus = span()
        failedStatus["status"] = ["code": 2, "message": "PRIVATE failure"]
        var failedNamedStatus = span()
        failedNamedStatus["status"] = ["code": "STATUS_CODE_ERROR", "message": "PRIVATE failure"]
        var missingPrompt = span()
        missingPrompt["attributes"] = attributes(["session.id": "session-1", "request_id": "req-1", "output_tokens": 10, "duration_ms": 100])
        var reversed = span()
        reversed["endTimeUnixNano"] = "1789999999000000000"
        let rows = [span(["success": false]), span(["success": "false"]), failedStatus, failedNamedStatus, missingPrompt, reversed,
                    span(["session.id": "PRIVATE/session"]), span(["request_id": String(repeating: "a", count: 257)]),
                    span(["output_tokens": -1]), span(["output_tokens": 1.5]), span(["duration_ms": 0]),
                    span(name: "claude_code.interaction")]
        XCTAssertTrue(try ClaudeActivityTelemetry.frames(payload(rows)).isEmpty)
        let optionalRows = try records(payload([span(["ttft_ms": -1, "first_content_ms": 9000,
                                                      "agent_id": "bad agent", "model": "PRIVATE model"])]))
        let record = try XCTUnwrap(optionalRows.first)
        XCTAssertNil(record["ttftMs"])
        XCTAssertNil(record["firstContentMs"])
        XCTAssertNil(record["agentId"])
        XCTAssertNil(record["model"])
    }

    func testMalformedSkippedContentAndBoundedPayloadsAreRejectedAtomically() throws {
        let bytes = try payload([span()])
        var text = String(decoding: bytes, as: UTF8.self)
        text.removeLast(); text += #", "PRIVATE":"\uD800"}"#
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(Data(text.utf8)))
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(Data(repeating: 32, count: ClaudeActivityTelemetry.maximumBodyBytes + 1)))
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(payload(Array(repeating: span(), count: 513))))
        var oversized = span()
        oversized["attributes"] = (0..<257).map { ["key": "private-\($0)", "value": ["stringValue": "PRIVATE"]] }
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(payload([oversized])))
        XCTAssertThrowsError(try ClaudeActivityTelemetry.frames(Data(#"{"resourceSpans":{}}"#.utf8)))
        XCTAssertTrue(try ClaudeActivityTelemetry.frames(Data(#"{"resourceMetrics":[{"PRIVATE":"private"}]}"#.utf8)).isEmpty)
    }

    private func connect(_ port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in(), timeout = timeval(tv_sec: 2, tv_usec: 0), noSignal: Int32 = 1
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    private func send(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { throw POSIXError(.EPIPE) }
            offset += count
        }
    }

    private func response(_ fd: Int32) throws -> String {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, 4096, 0) }
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(.EIO) }
            result.append(contentsOf: buffer.prefix(count))
            if result.count > 4096 { throw POSIXError(.EFBIG) }
        }
        return String(decoding: result, as: UTF8.self)
    }

    func testNativeLoopbackReceiverAcceptsFragmentedJSONAndReportsPortConflicts() async throws {
        let frames = Frames(), delivered = expectation(description: "sanitized OTLP frame")
        let receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0); delivered.fulfill() }
        try receiver.start(); defer { receiver.stop() }
        let port = receiver.listeningPort
        XCTAssertGreaterThan(port, 0)
        let conflicting = ClaudeActivityTelemetry(port: port) { _ in XCTFail("unowned port cannot deliver") }
        XCTAssertThrowsError(try conflicting.start()) { error in XCTAssertEqual((error as? POSIXError)?.code, .EADDRINUSE) }
        conflicting.stop()
        let fd = try connect(port); defer { Darwin.close(fd) }
        let body = try payload([span(["user_prompt": "PRIVATE test prompt"])])
        let header = Data("POST /v1/traces HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nAuthorization: PRIVATE ignored\r\n\r\n".utf8)
        try send(header.prefix(19), to: fd)
        try send(header.dropFirst(19), to: fd)
        try send(body.prefix(17), to: fd)
        try send(body.dropFirst(17), to: fd)
        XCTAssertTrue(try response(fd).hasPrefix("HTTP/1.1 200 OK"))
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(frames.all().count, 1)
        XCTAssertFalse(frames.all().contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
        XCTAssertEqual(receiver.counters, .init(httpRequests: 1, projectedRequests: 1, missingCorrelations: 0, rejectedRequests: 0))
        receiver.stop()
        let replacement = ClaudeActivityTelemetry(port: port) { _ in }
        try replacement.start(); replacement.stop()
    }

    func testReceiverRejectsUnboundedFramingAndUnsupportedSignalsWithoutFrames() throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        let cases: [(String, Int)] = [
            ("POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
            ("POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 1048577\r\n\r\n", 413),
            ("POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}", 400),
            ("POST /v1/traces HTTP/1.1\r\nContent-Type: application/x-protobuf\r\nContent-Length: 2\r\n\r\n{}", 415),
            ("POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\n\r\n", 411),
            ("POST /v1/logs HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", 404),
            ("POST /v1/traces HTTP/1.1\r\nX-Private: " + String(repeating: "x", count: 16_384) + "\r\n\r\n", 431)
        ]
        for (request, status) in cases {
            let fd = try connect(receiver.listeningPort)
            defer { Darwin.close(fd) }
            try send(Data(request.utf8), to: fd)
            XCTAssertTrue(try response(fd).hasPrefix("HTTP/1.1 \(status)"), "status \(status)")
        }
        XCTAssertTrue(frames.all().isEmpty)
    }

    func testConnectionBudgetRejectsNinthClientAndStopWakesPartialRequests() async throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        var held: [Int32] = []
        defer { for fd in held { Darwin.close(fd) } }
        for _ in 0..<8 {
            let fd = try connect(receiver.listeningPort); held.append(fd)
            try send(Data("POST /v1/".utf8), to: fd)
        }
        // Existing incomplete clients occupy the request workers. The ninth
        // connection must close without gaining a worker or consuming a body.
        try await Task.sleep(nanoseconds: 100_000_000)
        let excess = try connect(receiver.listeningPort); defer { Darwin.close(excess) }
        var byte: UInt8 = 0
        let count = Darwin.recv(excess, &byte, 1, 0), excessError = errno
        XCTAssertTrue(count == 0 || (count == -1 && excessError == ECONNRESET))
        receiver.stop()
        for fd in held {
            let stoppedCount = Darwin.recv(fd, &byte, 1, 0), stoppedError = errno
            XCTAssertTrue(stoppedCount == 0 || (stoppedCount == -1 && stoppedError == ECONNRESET))
        }
        XCTAssertTrue(frames.all().isEmpty)
    }

    func testCountersDistinguishMissingCorrelationFailedMetricsAndMalformedSchema() throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        XCTAssertEqual(receiver.counters, .init(httpRequests: 0, projectedRequests: 0, missingCorrelations: 0, rejectedRequests: 0))
        var missingPrompt = span()
        missingPrompt["attributes"] = attributes(["session.id": "session-1", "request_id": "req-1", "duration_ms": 100,
                                                  "output_tokens": 20, "user_prompt": "PRIVATE prompt"])
        let inputs: [(Data, Int)] = [
            (try payload([span(), span(name: "claude_code.interaction")]), 200),
            (try payload([missingPrompt]), 200),
            (try payload([span(["success": "false", "error": "PRIVATE failure"])]), 200),
            (try payload([span(["output_tokens": 1.5])]), 200),
            (Data(#"{"resourceSpans":{},"private":"PRIVATE body"}"#.utf8), 400)
        ]
        for (body, status) in inputs {
            let fd = try connect(receiver.listeningPort); defer { Darwin.close(fd) }
            let header = Data("POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            try send(header + body, to: fd)
            XCTAssertTrue(try response(fd).hasPrefix("HTTP/1.1 \(status)"))
        }
        XCTAssertEqual(receiver.counters, .init(httpRequests: 5, projectedRequests: 1, missingCorrelations: 1, rejectedRequests: 3))
        XCTAssertEqual(frames.all().count, 1)
        XCTAssertFalse(frames.all().contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
    }
}
