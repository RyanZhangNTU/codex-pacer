import XCTest
@testable import PacerCore

final class ThreadLinkTests: XCTestCase {
    private let uuid = "01a0f65c-8c61-76f2-8363-6f53e5c2a1b8"
    func testSshConversationLinkTargetsItsConfiguredHost() throws {
        let host = "remote-ssh-discovered:RTX-4090-1"
        let activity = SessionActivity(id: "rollout-\(uuid).jsonl", sourceHost: "4090", sourceHostID: host)
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
