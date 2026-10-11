import XCTest
@testable import PacerCore

final class ThreadLinkTests: XCTestCase {
    private let uuid = "11111111-1111-4111-8111-111111111111"
    func testLocalConversationLinkRejectsInjectedMetadataAndUsesRolloutUUID() throws {
        var activity = SessionActivity(id: "rollout-2026-10-01-\(uuid).jsonl")
        XCTAssertEqual(activity.threadURL?.absoluteString, "codex://threads/" + uuid)
        activity.consume(try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-10-01T00:00:00Z", "type": "session_meta",
            "payload": ["id": "bad?prompt=send", "cwd": "/test"]
        ]))
        XCTAssertEqual(activity.threadURL?.absoluteString, "codex://threads/" + uuid)
    }

    func testRemoteConversationLinkTargetsItsConfiguredHost() throws {
        for host in ["remote-ssh-discovered:example-host", "remote-control:env_fixture"] {
            let activity = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "example-host", sourceHostID: host)
            let url = try XCTUnwrap(activity.threadURL)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "codex")
            XCTAssertEqual(components.host, "threads")
            XCTAssertEqual(components.path, "/" + uuid)
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "hostId", value: host)])
        }
    }
    func testHostCannotInjectPromptOrSelectAnUnsupportedSource() {
        let unsafe = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "bad", sourceHostID: "remote-ssh-discovered:host&prompt=send")
        XCTAssertNil(unsafe.threadURL)
        let control = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHostID: "remote-control:env_fixture&prompt=send")
        XCTAssertNil(control.threadURL)
        let unsupported = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "other", sourceHostID: "unsupported:anything")
        XCTAssertNil(unsupported.threadURL)
    }
}
