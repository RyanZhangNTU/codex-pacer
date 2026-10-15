import XCTest
import PacerCore
@testable import PacerIsland

final class ClaudeConversationOpenerTests: XCTestCase {
    private let session = "e0c2a517-74bc-43ec-a806-e9187a72fcc8"

    func testManagedRemoteResumeKeepsDestinationPortAndLiteralIdentityPath() throws {
        let identity = "/fixture/key '$(printf injected) `literal`"
        let target = RemoteActivityTarget(id: "remote-ssh-discovered:claude-fixture", name: "Fixture", alias: "claude-fixture",
            home: "~/.claude", sshDestination: "fixture@example.test", sshPort: 2222, sshIdentityFile: identity)
        let command = try XCTUnwrap(ClaudeConversationOpener.remoteResumeCommand(target: target, session: session))
        XCTAssertTrue(command.contains("'2222'"))
        XCTAssertTrue(command.contains("'fixture@example.test'"))
        XCTAssertTrue(command.contains("'" + identity.replacingOccurrences(of: "'", with: "'\\''") + "'"))
        XCTAssertTrue(command.contains("'StrictHostKeyChecking=yes'"))
        XCTAssertNil(ClaudeConversationOpener.remoteResumeCommand(target: target, session: session + ";bad"))
    }

    func testDesktopMappingHonorsLocalProfileAndIndependentSSHRoute() async throws {
        let userHome = URL(fileURLWithPath: "/private/tmp/pacer-synthetic-user")
        let defaultHome = userHome.appendingPathComponent(".claude")
        let customHome = userHome.appendingPathComponent("custom-profile")
        actor Lookup {
            var calls: [(String, String?)] = []
            func lookup(_ session: String, _ host: String?) -> String? {
                calls.append((session, host)); return "local_" + session
            }
            func count() -> Int { calls.count }
            func lastHost() -> String? { calls.last?.1 }
        }
        let lookup = Lookup()
        let local = SessionActivity(id: "synthetic-local", provider: .claude, sessionID: session)
        let custom = await ClaudeConversationOpener.desktopDestination(for: local, home: customHome,
            userHome: userHome, lookup: { await lookup.lookup($0, $1) })
        XCTAssertNil(custom)
        let skippedCount = await lookup.count(); XCTAssertEqual(skippedCount, 0)
        let standardURL = await ClaudeConversationOpener.desktopDestination(for: local, home: defaultHome,
            userHome: userHome, lookup: { await lookup.lookup($0, $1) })
        let standard = try XCTUnwrap(standardURL)
        XCTAssertEqual(URLComponents(url: standard, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "local_" + session)
        let host = "remote-ssh-discovered:SyntheticHost"
        let remote = SessionActivity(id: "synthetic-remote", sourceHostID: host, provider: .claude, sessionID: session)
        let remoteURL = await ClaudeConversationOpener.desktopDestination(for: remote, home: customHome,
            userHome: userHome, lookup: { await lookup.lookup($0, $1) })
        XCTAssertNotNil(remoteURL)
        let total = await lookup.count(), observedHost = await lookup.lastHost()
        XCTAssertEqual(total, 2); XCTAssertEqual(observedHost, host)
    }
}
