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

    func testSshConversationLinkTargetsItsConfiguredHost() throws {
        let host = "remote-ssh-discovered:example-host"
        let activity = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "example-host", sourceHostID: host)
        let url = try XCTUnwrap(activity.threadURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "codex")
        XCTAssertEqual(components.host, "threads")
        XCTAssertEqual(components.path, "/" + uuid)
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "hostId", value: host)])
    }
    func testHostCannotInjectPromptOrSelectAnUnsupportedSource() {
        let unsafe = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "bad", sourceHostID: "remote-ssh-discovered:host&prompt=send")
        XCTAssertNil(unsafe.threadURL)
        let unsupported = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "other", sourceHostID: "remote-control:anything")
        XCTAssertNil(unsupported.threadURL)
    }
}
