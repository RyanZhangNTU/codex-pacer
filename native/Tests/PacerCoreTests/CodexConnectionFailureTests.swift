import XCTest
@testable import PacerCore

final class CodexConnectionFailureTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ content: String, executable: Bool = false) throws -> URL {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: path)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
        return path
    }

    private func server(account: [String: Any] = [
        "account": ["type": "chatgpt", "planType": "pro"],
        "workspaceRouting": ["chatgptAccountId": "fixture", "backendOrigin": "test"]
    ], failure: [String: Any]? = nil, paramsRejection: String? = nil, malformedAfterQuota: Bool = false,
       quota: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]) throws -> String {
        func encoded(_ value: [String: Any]) throws -> String {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            return json.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "'", with: "'\\''")
        }
        let accountJSON = try encoded(account)
        let quotaJSON = try encoded(failure.map { ["error": $0] } ?? ["result": quota])
        let quotaFields = String(quotaJSON.dropFirst().dropLast())
        let rejectionJSON = try encoded(["code": -32600, "message": paramsRejection ?? ""])
        // The external printf makes one write, so a malformed trailer arrives in the reply's read.
        let trailer = malformedAfterQuota ? #"not json\n"# : ""
        return #"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> '\#(root.appendingPathComponent("requests.log").path)'
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -n "$id" ] || continue
          case "$line" in
            *initialize*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *account/read*) printf '{"id":%s,"result":\#(accountJSON)}\n' "$id" ;;
            *account/rateLimits/read*)
              if [ '\#(paramsRejection != nil)' = true ] && printf '%s' "$line" | /usr/bin/grep -q '"params"'; then
                printf '{"id":%s,"error":\#(rejectionJSON)}\n' "$id"
              else
                /usr/bin/printf '{"id":%s,\#(quotaFields)}\n\#(trailer)' "$id"
              fi ;;
          esac
        done
        """#
    }

    private func client(_ script: String, timeout: TimeInterval = 1) throws -> CodexClient {
        let path = try write(UUID().uuidString + ".sh", script)
        return CodexClient(executable: URL(fileURLWithPath: "/bin/sh"), home: root, arguments: [path.path], timeout: timeout)
    }

    func testRpcErrorPreservesCodeMethodAndReasonWithoutCredentials() async throws {
        let client = try client(server(failure: [
            "code": -32001, "message": "HTTP 403: workspace quota denied; access_token=fixture-private-token user@example.test"
        ]))
        defer { Task { await client.disconnect() } }
        do { _ = try await client.readQuota(); XCTFail("expected error") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("account/rateLimits/read"))
            XCTAssertTrue(message.contains("-32001"))
            XCTAssertTrue(message.contains("HTTP 403"))
            XCTAssertTrue(message.contains("workspace quota denied"))
            XCTAssertFalse(message.contains("fixture-private-token"))
            XCTAssertFalse(message.contains("user@example.test"))
        }
    }

    func testNotLoggedInDoesNotMakeAQuotaRequest() async throws {
        let client = try client(server(account: ["account": NSNull(), "requiresOpenaiAuth": true]))
        defer { Task { await client.disconnect() } }
        do { _ = try await client.readQuota(); XCTFail("expected missing login") }
        catch CodexClientError.notLoggedIn { }
        catch { XCTFail("unexpected \(error)") }
        let requests = try String(contentsOf: root.appendingPathComponent("requests.log"))
        XCTAssertTrue(requests.contains("account/read"))
        XCTAssertFalse(requests.contains("account/rateLimits/read"))
    }

    func testKnownNonChatGPTAccountsHaveSpecificReasons() async throws {
        for kind in ["apiKey", "amazonBedrock"] {
            let client = try client(server(account: ["account": ["type": kind], "requiresOpenaiAuth": false]))
            do { _ = try await client.readQuota(); XCTFail("expected unsupported auth") }
            catch CodexClientError.unsupportedAccount(let label) {
                XCTAssertTrue(kind == "apiKey" ? label.contains("API Key") : label.contains("Amazon Bedrock"))
            }
            catch { XCTFail("unexpected \(error)") }
            await client.disconnect()
        }
    }

    private static let unitParams = "Invalid request: invalid type: map, expected unit"

    private func quotaRequests() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("requests.log")).split(separator: "\n").compactMap {
            let request = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            return request?["method"] as? String == "account/rateLimits/read" ? request : nil
        }
    }

    /// Expects two reads to fail with the server's own rate-limit error without keeping the
    /// legacy request shape, then returns the quota requests that were sent.
    private func quotaRequestsAfterFailures(_ script: String, code: Int, message: String,
                                            file: StaticString = #filePath, line: UInt = #line) async throws -> [[String: Any]] {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("requests.log"))
        let client = try client(script)
        for _ in 0..<2 {
            do { _ = try await client.readQuota(); XCTFail("expected RPC failure", file: file, line: line) }
            catch CodexClientError.server(let method, let actualCode, let actualMessage) {
                XCTAssertEqual(method, "account/rateLimits/read", file: file, line: line)
                XCTAssertEqual(actualCode, code, file: file, line: line)
                XCTAssertEqual(actualMessage, message, file: file, line: line)
            }
            catch { XCTFail("unexpected \(error)", file: file, line: line) }
            let legacy = await client.usesLegacyRateLimitRequest()
            XCTAssertFalse(legacy, "A failed read must not keep the legacy request shape", file: file, line: line)
        }
        await client.disconnect()
        return try quotaRequests()
    }

    func testLegacyCliRetriesOnceAndKeepsParamlessRequestsForTheConnection() async throws {
        for (hasRouting, rejection) in [(true, Self.unitParams), (false, "Invalid Type: Map, Expected Unit at line 1 column 64")] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("requests.log"))
            var account: [String: Any] = ["account": ["type": "chatgpt", "planType": "pro"]]
            if hasRouting {
                account["workspaceRouting"] = ["chatgptAccountId": "fixture", "backendOrigin": "test"]
            }
            let client = try client(server(account: account, paramsRejection: rejection,
                quota: ["accountId": "fixture", "rateLimits": ["primary": ["usedPercent": 41, "windowDurationMins": 300]]]))
            let quota = try await client.readQuota()
            XCTAssertEqual(quota.windows.first?.usedPercent, 41)
            XCTAssertEqual(quota.accountScope != nil, hasRouting, "The fallback must preserve verified scope without inventing identity")
            let legacyAfterProbe = await client.usesLegacyRateLimitRequest()
            _ = try await client.readQuota()
            await client.disconnect()
            let legacyAfterDisconnect = await client.usesLegacyRateLimitRequest()
            _ = try await client.readQuota()
            await client.disconnect()
            XCTAssertTrue(legacyAfterProbe)
            XCTAssertFalse(legacyAfterDisconnect)
            let requests = try quotaRequests()
            XCTAssertEqual(requests.map { $0["params"] != nil }, [true, false, false, true, false],
                           "Probe once per connection, then omit params entirely until it closes")
            XCTAssertEqual((requests.first?["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool, false)
            XCTAssertEqual(Set(requests.compactMap { $0["id"] as? Int }).count, requests.count)
        }
    }

    func testDisconnectDuringCompatibilityRetryDoesNotCarryLegacyShapeToTheNextConnection() async throws {
        // The retry reply and a malformed line share one read: the reply resumes the request,
        // then the malformed line disconnects before the quota read finishes.
        let client = try client(server(paramsRejection: Self.unitParams, malformedAfterQuota: true))
        for _ in 0..<2 {
            let quota = try await client.readQuota()
            XCTAssertEqual(quota.windows.first?.usedPercent, 25)
            let legacy = await client.usesLegacyRateLimitRequest()
            XCTAssertFalse(legacy, "A closed connection's retry must not mark its replacement as legacy")
        }
        await client.disconnect()
        XCTAssertEqual(try quotaRequests().map { $0["params"] != nil }, [true, false, true, false],
                       "Each new connection must probe with params again")
    }

    func testConcurrentReadsShareOneCompatibilityProbe() async throws {
        let client = try client(server(paramsRejection: Self.unitParams))
        async let first = client.readQuota()
        async let second = client.readQuota()
        let (a, b) = try await (first, second)
        await client.disconnect()
        XCTAssertEqual([a, b].map { $0.windows.first?.usedPercent }, [25, 25])
        let shapes = try quotaRequests().map { $0["params"] != nil }
        XCTAssertEqual(shapes.first, true)
        XCTAssertEqual(shapes.filter { $0 }.count, 1, "Concurrent reads must not probe twice")
    }

    func testModernCliUsesOneRequestWithResetDetails() async throws {
        let client = try client(server())
        for _ in 0..<2 {
            let quota = try await client.readQuota()
            XCTAssertEqual(quota.windows.first?.usedPercent, 25)
        }
        let legacy = await client.usesLegacyRateLimitRequest()
        await client.disconnect()
        XCTAssertFalse(legacy)
        let requests = try quotaRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { ($0["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool == false })
    }

    func testOtherRpcFailuresDoNotTriggerCompatibilityRetry() async throws {
        for (code, message) in [
            (-32600, "codex account authentication required to read rate limits"),
            (-32600, "Invalid request: invalid type: map, expected string"),
            (-32600, "Invalid request: invalid type: map, expected unit variant Mode::Auto"),
            (-32600, "Invalid request: invalid type: map, expected unit struct Empty"),
            (-32601, Self.unitParams)
        ] {
            let requests = try await quotaRequestsAfterFailures(server(failure: ["code": code, "message": message]),
                                                                code: code, message: message)
            XCTAssertEqual(requests.map { $0["params"] != nil }, [true, true], message)
        }
    }

    func testCompatibilityRetryIsBoundedAndPreservesItsFailure() async throws {
        for (code, message) in [(-32600, Self.unitParams), (-32001, "Quota temporarily unavailable")] {
            let requests = try await quotaRequestsAfterFailures(
                server(failure: ["code": code, "message": message], paramsRejection: Self.unitParams),
                code: code, message: message)
            XCTAssertEqual(requests.map { $0["params"] != nil }, [true, false, true, false],
                           "A failed retry must not make a third request, and the next read probes again")
        }
    }

    func testCompatibilityRetryStillRejectsMismatchedAccount() async throws {
        let client = try client(server(paramsRejection: Self.unitParams,
            quota: ["accountId": "other-fixture", "rateLimits": ["primary": ["usedPercent": 41, "windowDurationMins": 300]]]))
        for _ in 0..<2 {
            do { _ = try await client.readQuota(); XCTFail("expected account mismatch") }
            catch CodexClientError.accountMismatch { }
            catch { XCTFail("unexpected \(error)") }
            let scope = await client.currentAccountScope()
            let legacy = await client.usesLegacyRateLimitRequest()
            XCTAssertNil(scope)
            XCTAssertFalse(legacy)
        }
        await client.disconnect()
        XCTAssertEqual(try quotaRequests().map { $0["params"] != nil }, [true, false, true, false])
    }

    func testEarlyExitRetainsStderrAndExitStatus() async throws {
        let client = try client("printf 'env: node: No such file or directory\\naccess_token=private-startup-token\\n' >&2\nexit 127\n")
        defer { Task { await client.disconnect() } }
        do { _ = try await client.readQuota(); XCTFail("expected startup error") }
        catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("127"), message)
            XCTAssertTrue(message.contains("env: node"), message)
            XCTAssertTrue(message.contains(L10n.text("cli.missing_node")), message)
            XCTAssertFalse(message.contains("private-startup-token"))
        }
    }

    func testLargeStderrIsDrainedWithoutBlockingAndBounded() async throws {
        let noise = String(repeating: "diagnostic line\n", count: 3000)
        let noiseFile = try write("noise.txt", noise)
        let client = try client("cat '\(noiseFile.path)' >&2\nprintf '\\nconnection refused\\n' >&2\nexit 2\n", timeout: 2)
        defer { Task { await client.disconnect() } }
        do { _ = try await client.readQuota(); XCTFail("expected process failure") }
        catch {
            XCTAssertLessThan(error.localizedDescription.count, 2000)
            guard case CodexClientError.processExited = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("connection refused"))
        }
    }

    func testWrongProtocolIsNotMisreportedAsAnAuthenticationFailure() async throws {
        let client = try client("IFS= read -r line\nprintf 'not an app-server response\\n'\nsleep 1\n")
        defer { Task { await client.disconnect() } }
        do { _ = try await client.readQuota(); XCTFail("expected protocol error") }
        catch CodexClientError.invalidReply(let method, let reason) {
            XCTAssertEqual(method, "initialize")
            XCTAssertTrue(reason == L10n.text("cli.not_json"))
        }
        catch { XCTFail("unexpected \(error)") }
    }

    func testNpmLauncherFindsNodeBesideItWithGuiPath() async throws {
        _ = try write("nvm/node/bin/node", "#!/bin/sh\n" + server(), executable: true)
        let cli = try write("nvm/node/bin/codex", "#!/usr/bin/env node\n// fixture\n", executable: true)
        let client = CodexClient(executable: cli, home: root, timeout: 2, environment: ["PATH": "/usr/bin:/bin"])
        defer { Task { await client.disconnect() } }
        let snapshot = try await client.readQuota()
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 75)
    }

    func testNonRunnableBinaryReportsLaunchFailureAndPath() async throws {
        let cli = try write("bad-architecture/codex", "not an executable image\n", executable: true)
        let client = CodexClient(executable: cli, home: root, timeout: 1)
        defer { Task { await client.disconnect() } }
        do { _ = try await client.readQuota(); XCTFail("expected launch error") }
        catch CodexClientError.launchFailed(let path, let reason) {
            XCTAssertEqual(path, cli.path)
            XCTAssertFalse(reason.isEmpty)
        }
        catch { XCTFail("unexpected \(error)") }
    }
}
