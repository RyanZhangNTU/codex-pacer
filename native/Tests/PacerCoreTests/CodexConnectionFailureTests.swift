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
    ], failure: [String: Any]? = nil, rejectObjectParams: Bool = false,
       quota: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]) throws -> String {
        func encoded(_ value: [String: Any]) throws -> String {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            return json.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "'", with: "'\\''")
        }
        let accountJSON = try encoded(account)
        let quotaJSON = try encoded(failure.map { ["error": $0] } ?? ["result": quota])
        let quotaFields = String(quotaJSON.dropFirst().dropLast())
        return #"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> '\#(root.appendingPathComponent("requests.log").path)'
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -n "$id" ] || continue
          case "$line" in
            *initialize*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *account/read*) printf '{"id":%s,"result":\#(accountJSON)}\n' "$id" ;;
            *account/rateLimits/read*)
              if [ '\#(rejectObjectParams)' = true ] && printf '%s' "$line" | /usr/bin/grep -q '"params"'; then
                printf '{"id":%s,"error":{"code":-32600,"message":"Invalid request: invalid type: map, expected unit"}}\n' "$id"
              else
                printf '{"id":%s,\#(quotaFields)}\n' "$id"
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

    private func quotaRequests() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("requests.log")).split(separator: "\n").compactMap {
            let request = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            return request?["method"] as? String == "account/rateLimits/read" ? request : nil
        }
    }

    func testLegacyCliRejectsParamObjectButSucceedsWithoutParams() async throws {
        for hasRouting in [true, false] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("requests.log"))
            var account: [String: Any] = ["account": ["type": "chatgpt", "planType": "pro"]]
            if hasRouting {
                account["workspaceRouting"] = ["chatgptAccountId": "fixture", "backendOrigin": "test"]
            }
            let client = try client(server(account: account, rejectObjectParams: true,
                quota: ["accountId": "fixture", "rateLimits": ["primary": ["usedPercent": 41, "windowDurationMins": 300]]]))
            let quota = try await client.readQuota()
            await client.disconnect()
            XCTAssertEqual(quota.windows.first?.usedPercent, 41)
            XCTAssertEqual(quota.accountScope != nil, hasRouting, "The fallback must preserve verified scope without inventing identity")
            let requests = try quotaRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual((requests.first?["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool, false)
            XCTAssertNil(requests.last?["params"], "The retry must omit params entirely")
            XCTAssertNotEqual(requests.first?["id"] as? Int, requests.last?["id"] as? Int)
        }
    }

    func testModernCliUsesOneRequestWithResetDetails() async throws {
        let client = try client(server())
        let quota = try await client.readQuota()
        await client.disconnect()
        XCTAssertEqual(quota.windows.first?.usedPercent, 25)
        let requests = try quotaRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual((requests.first?["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool, false)
    }

    func testOtherRpcFailuresDoNotTriggerCompatibilityRetry() async throws {
        for (code, message) in [
            (-32600, "codex account authentication required to read rate limits"),
            (-32600, "Invalid request: invalid type: map, expected string"),
            (-32601, "Invalid request: invalid type: map, expected unit")
        ] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("requests.log"))
            let client = try client(server(failure: ["code": code, "message": message]))
            do { _ = try await client.readQuota(); XCTFail("expected RPC failure") }
            catch CodexClientError.server(let method, let actualCode, let actualMessage) {
                XCTAssertEqual(method, "account/rateLimits/read")
                XCTAssertEqual(actualCode, code)
                XCTAssertEqual(actualMessage, message)
            }
            catch { XCTFail("unexpected \(error)") }
            await client.disconnect()
            XCTAssertEqual(try quotaRequests().count, 1)
        }
    }

    func testCompatibilityRetryIsBoundedAndPreservesItsFailure() async throws {
        for (code, message) in [
            (-32600, "Invalid request: invalid type: map, expected unit"),
            (-32001, "Quota temporarily unavailable")
        ] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("requests.log"))
            let client = try client(server(failure: ["code": code, "message": message], rejectObjectParams: true))
            do { _ = try await client.readQuota(); XCTFail("expected retry failure") }
            catch CodexClientError.server(let method, let actualCode, let actualMessage) {
                XCTAssertEqual(method, "account/rateLimits/read")
                XCTAssertEqual(actualCode, code)
                XCTAssertEqual(actualMessage, message)
            }
            catch { XCTFail("unexpected \(error)") }
            await client.disconnect()
            let requests = try quotaRequests()
            XCTAssertEqual(requests.count, 2, "A failed retry must not make a third request")
            XCTAssertNil(requests.last?["params"])
        }
    }

    func testCompatibilityRetryStillRejectsMismatchedAccount() async throws {
        let client = try client(server(rejectObjectParams: true,
            quota: ["accountId": "other-fixture", "rateLimits": ["primary": ["usedPercent": 41, "windowDurationMins": 300]]]))
        do { _ = try await client.readQuota(); XCTFail("expected account mismatch") }
        catch CodexClientError.accountMismatch { }
        catch { XCTFail("unexpected \(error)") }
        let scope = await client.currentAccountScope()
        await client.disconnect()
        XCTAssertNil(scope)
        XCTAssertEqual(try quotaRequests().count, 2)
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
