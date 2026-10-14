import XCTest
@testable import PacerCore

final class RemoteControlCatalogTests: XCTestCase {
    private func fixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["electron-remote-control-client-enrollments": [
            "synthetic": ["accountUserId": "user", "clientId": "client"]]])
            .write(to: home.appendingPathComponent(".codex-global-state.json"))
        try Data("synthetic-profile".utf8).write(to: home.appendingPathComponent("auth.json"))
        return home
    }
    private func clientFactory() throws -> @Sendable (URL) -> CodexClient? {
        let auth = try self.auth()
        let replies = try JSONSerialization.data(withJSONObject: [
            "initialize": ["capabilities": [:]],
            "account/read": ["account": ["type": "chatgpt"], "workspaceRouting": ["chatgptAccountId": "account", "backendOrigin": "https://chatgpt.com"]],
            "getAuthStatus": ["authMethod": "chatgpt", "authToken": auth.token]])
        let script = """
        import sys,json
        replies=json.loads(\(String(reflecting: String(decoding: replies, as: UTF8.self))))
        for line in sys.stdin:
            value=json.loads(line)
            if 'id' not in value:continue
            assert value['method'] in replies
            print(json.dumps({'id':value['id'],'result':replies[value['method']]}),flush=True)
        """
        return { home in CodexClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home, arguments: ["-u", "-c", script]) }
    }
    private func auth(account: String = "account", routed: String = "account", origin: String = "https://chatgpt.com") throws -> RemoteControlCatalogAuthorization {
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": account,
            "chatgpt_account_user_id": "user", "user_id": "legacy-user"]]).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try .init(account: JSONSerialization.data(withJSONObject: ["account": ["type": "chatgpt"],
            "workspaceRouting": ["chatgptAccountId": routed, "backendOrigin": origin]]),
            auth: JSONSerialization.data(withJSONObject: ["authMethod": "chatgpt", "authToken": "e30." + payload + ".signature"]))
    }
    func testCatalogUsesOnlyCurrentClientPairingsAndNamesIncludingOfflineDevices() async throws {
        let identity = RemoteControlCatalogIdentity(clients: [.init(accountUserID: "user", id: "client")], localEnvironmentID: "self", selectedHost: nil)
        let targets = try await RemoteControlCatalog.readTargets(authorization: auth(), clientID: "client", identity: identity) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/backend-api/codex/remote/control/clients/client/environments")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
            return try JSONSerialization.data(withJSONObject: ["items": [
                ["env_id": "env_work", "display_name": "Workstation", "online": true, "private_key": "PRIVATE"],
                ["env_id": "env_notebook", "host_name": "Notebook", "online": false],
                ["env_id": "self", "name": "This Mac", "online": true]], "cursor": NSNull()])
        }
        XCTAssertEqual(targets.map(\.name), ["Workstation", "Notebook"])
        XCTAssertEqual(targets.map(\.online), [true, false])
        XCTAssertFalse(String(describing: targets).contains("PRIVATE"))
    }
    func testAuthorizationCannotCrossAccountsOrSendTokensToAnUntrustedOrigin() throws {
        XCTAssertThrowsError(try auth(routed: "other"))
        for origin in ["https://chatgpt.com.evil.invalid", "http://chatgpt.com", "https://chatgpt.com/private", "https://chatgpt.com?token=private"] {
            XCTAssertThrowsError(try auth(origin: origin))
        }
    }
    func testOnlyPublicEnrollmentMetadataIsSelectedAndAmbiguousClientsAreRejected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config: [String: Any] = ["electron-remote-control-client-enrollments": [
            "current": ["accountUserId": "user", "clientId": "current-client", "keyId": "PRIVATE", "privateKey": "PRIVATE"],
            "other": ["accountUserId": "other-user", "clientId": "other-client"]],
            "remote-projects": [["hostId": "remote-control:deleted", "label": "PRIVATE"]]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".codex-global-state.json"))
        let identity = try XCTUnwrap(RemoteControlCatalogIdentity.read(home: home))
        XCTAssertEqual(identity.clientID(for: try auth()), "current-client")
        XCTAssertFalse(String(describing: identity).contains("PRIVATE"))
        let ambiguous = RemoteControlCatalogIdentity(clients: [.init(accountUserID: "user", id: "one"), .init(accountUserID: "user", id: "two")], localEnvironmentID: nil, selectedHost: nil)
        XCTAssertNil(ambiguous.clientID(for: try auth()))
        for id in ["bad/path", "bad?query", "bad\n", String(repeating: "x", count: 129)] { XCTAssertFalse(RemoteControlCatalogIdentity.validIdentifier(id)) }
    }
    func testRepeatedPaginationCannotPublishAPartialCatalog() async throws {
        let identity = RemoteControlCatalogIdentity(clients: [], localEnvironmentID: nil, selectedHost: nil)
        do {
            _ = try await RemoteControlCatalog.readTargets(authorization: auth(), clientID: "client", identity: identity) { _ in
                try JSONSerialization.data(withJSONObject: ["items": [["env_id": "one", "name": "One"]], "cursor": "same"])
            }
            XCTFail("Repeated cursors must not confirm an incomplete device list")
        } catch {}
    }
    func testExplicitRefreshRetainsVerifiedNamesOnTransientFailureButNotAfterProfileReplacement() async throws {
        actor Fetches {
            var count = 0
            func response() throws -> Data {
                count += 1
                if count > 1 { throw URLError(.timedOut) }
                return try JSONSerialization.data(withJSONObject: ["items": [["env_id": "work", "name": "Workstation", "online": true]], "cursor": NSNull()])
            }
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try JSONSerialization.data(withJSONObject: ["electron-remote-control-client-enrollments": [
            "synthetic": ["accountUserId": "user", "clientId": "client"]]])
            .write(to: home.appendingPathComponent(".codex-global-state.json"))
        let profile = home.appendingPathComponent("auth.json")
        try Data("synthetic-profile".utf8).write(to: profile)
        let auth = try self.auth()
        let replies = try JSONSerialization.data(withJSONObject: [
            "initialize": ["capabilities": [:]],
            "account/read": ["account": ["type": "chatgpt"], "workspaceRouting": ["chatgptAccountId": "account", "backendOrigin": "https://chatgpt.com"]],
            "getAuthStatus": ["authMethod": "chatgpt", "authToken": auth.token]])
        let script = """
        import sys,json
        replies=json.loads(\(String(reflecting: String(decoding: replies, as: UTF8.self))))
        for line in sys.stdin:
            value=json.loads(line)
            if 'id' not in value:continue
            method=value['method']
            assert method in replies
            print(json.dumps({'id':value['id'],'result':replies[method]}),flush=True)
        """
        let fetches = Fetches()
        let catalog = RemoteControlCatalog(fetch: { _ in try await fetches.response() }, makeClient: { home in
            CodexClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), home: home, arguments: ["-u", "-c", script])
        })
        let now = Date()
        let first = await catalog.targets(home: home, now: now)
        XCTAssertEqual(first?.first?.name, "Workstation")
        await catalog.invalidate()
        let retained = await catalog.targets(home: home, now: now.addingTimeInterval(1))
        XCTAssertEqual(retained?.first?.name, "Workstation", "Refresh expires the catalog without losing verified names on a temporary network failure")
        let attempts = await fetches.count
        XCTAssertEqual(attempts, 2)
        try Data("different-synthetic-profile".utf8).write(to: profile)
        let replaced = await catalog.targets(home: home, now: now.addingTimeInterval(2))
        XCTAssertNil(replaced, "A replaced authentication profile cannot reuse the former account's catalog")
        await catalog.shutdown()
    }
    func testSelectedNinthDeviceIsIncludedWithoutWaitingForCatalogExpiry() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let catalog = RemoteControlCatalog(fetch: { _ in
            try JSONSerialization.data(withJSONObject: ["items": (0..<9).map {
                ["env_id": "env_\($0)", "name": "Device \($0)", "online": true] as [String: Any]
            }, "cursor": NSNull()])
        }, makeClient: try clientFactory())
        let first = await catalog.targets(home: home)
        XCTAssertEqual(first?.count, 8)
        XCTAssertFalse(first?.contains { $0.id == "remote-control:env_8" } ?? true)
        let file = home.appendingPathComponent(".codex-global-state.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        state["selected-remote-host-id"] = "remote-control:env_8"
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        let selected = await catalog.targets(home: home)
        XCTAssertEqual(selected?.first?.id, "remote-control:env_8")
        await catalog.shutdown()
    }
    func testAuthenticationReplacementDuringFetchRejectsOldCatalog() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let catalog = RemoteControlCatalog(fetch: { _ in
            try Data("replacement-profile".utf8).write(to: home.appendingPathComponent("auth.json"))
            return try JSONSerialization.data(withJSONObject: ["items": [["env_id": "old", "name": "Old account device"]], "cursor": NSNull()])
        }, makeClient: try clientFactory())
        let result = await catalog.targets(home: home)
        XCTAssertNil(result, "No caller should receive a catalog fetched before an in-flight account replacement")
        await catalog.shutdown()
    }
}
