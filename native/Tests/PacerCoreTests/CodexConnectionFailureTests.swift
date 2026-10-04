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
    ], failure: [String: Any]? = nil) throws -> String {
        func encoded(_ value: [String: Any]) throws -> String {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            return json.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "'", with: "'\\''")
        }
        let accountJSON = try encoded(account)
        let quotaJSON = try encoded(failure.map { ["error": $0] } ?? [
            "result": ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]
        ])
        let quotaFields = String(quotaJSON.dropFirst().dropLast())
        return #"""
        while IFS= read -r line; do
          printf '%s\n' "$line" >> '\#(root.appendingPathComponent("requests.log").path)'
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -n "$id" ] || continue
          case "$line" in
            *initialize*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *account/read*) printf '{"id":%s,"result":\#(accountJSON)}\n' "$id" ;;
            *account/rateLimits/read*) printf '{"id":%s,\#(quotaFields)}\n' "$id" ;;
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
