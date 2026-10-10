import XCTest
import PacerCore
@testable import PacerIsland

final class ClaudeConversationOpenerTests: XCTestCase {
    private let session = "e0c2a517-74bc-43ec-a806-e9187a72fcc8"

    func testLocalResumeCommandKeepsLiteralPathsAndAddsOnlyDocumentedResumeFlags() throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-opener-" + UUID().uuidString)
        let directory = home.appendingPathComponent("work '$(printf PACER_EXPANDED) space", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("cli '$(printf PACER_EXPANDED); literal")
        // This fixture records shell arguments; it never invokes Claude or UI.
        try "#!/usr/bin/python3\nimport json,os,sys\nprint(json.dumps({'arguments':sys.argv[1:],'directory':os.getcwd(),'home':os.environ.get('CLAUDE_CONFIG_DIR')}))\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let userHome = home.appendingPathComponent("user")
        let defaultHome = userHome.appendingPathComponent(".claude")
        let customHome = home.appendingPathComponent("profile '$(printf PACER_EXPANDED) `literal` space")
        for (desktop, selectedHome) in [(false, defaultHome), (true, defaultHome), (true, customHome)] {
            let command = try XCTUnwrap(ClaudeConversationOpener.localResumeCommand(executable: executable,
                session: session.uppercased(), directory: directory, desktop: desktop, home: selectedHome, userHome: userHome))
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = "/private/tmp/wrong-inherited-profile"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(observed["arguments"] as? [String], desktop && selectedHome == defaultHome ? ["--desktop", "--resume", session] : ["--resume", session])
            XCTAssertEqual(observed["home"] as? String, selectedHome.path)
            let observedDirectory = URL(fileURLWithPath: try XCTUnwrap(observed["directory"] as? String))
            XCTAssertEqual(observedDirectory.resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
        }
    }

    func testLocalResumeCommandRejectsInjectedSessionAndNonFileDestinations() {
        let executable = URL(fileURLWithPath: "/private/tmp/fixture-cli")
        for value in ["", "not-a-session", session + "; printf injected", "--print", "local_" + session] {
            XCTAssertNil(ClaudeConversationOpener.localResumeCommand(executable: executable,
                session: value, directory: nil, desktop: true))
        }
        XCTAssertNil(ClaudeConversationOpener.localResumeCommand(executable: URL(string: "https://example.com/cli")!,
            session: session, directory: nil, desktop: false))
        XCTAssertNil(ClaudeConversationOpener.localResumeCommand(executable: executable, session: session,
            directory: URL(string: "https://example.com/project")!, desktop: true))
        XCTAssertNil(ClaudeConversationOpener.localResumeCommand(executable: executable, session: session,
            directory: nil, desktop: true, home: URL(string: "https://example.com/profile")!))
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
