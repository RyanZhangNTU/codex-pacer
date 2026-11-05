import XCTest
@testable import PacerCore

final class ClaudeTelemetryProtocolTests: XCTestCase {
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
        process.executableURL = PythonFixture.executable
        process.arguments = ["-c", body, Data(ClaudeActivityProbe.script.utf8).base64EncodedString()]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let pythonFixture = try PythonFixture.prepare(process); defer { pythonFixture.remove() }; try process.run()
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
            // A subagent's span names its agent instead of a prompt; Core binds it only to an observed child.
            (try payload([replacing("prompt.id", with: context("agent") + [["key": "agent_id", "value": ["stringValue": "fixture-child"]]])]), 200, 1),
            (try payload([replacing("prompt.id", with: context("agent") + [["key": "agent_id", "value": ["stringValue": "fixture child\n"]]])]), 200, 0),
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
}
