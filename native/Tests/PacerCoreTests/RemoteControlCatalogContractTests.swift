import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PacerCore

final class RemoteControlCatalogContractTests: XCTestCase {
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
}
