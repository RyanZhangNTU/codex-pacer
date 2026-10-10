import XCTest
@testable import PacerCore

final class ClaudeApplicationResolverTests: XCTestCase {
    func testBundleIdentityAndRelocatedApplicationDetection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, identifier: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let wrong = try app("Claude", identifier: "test.unrelated"), moved = try app("Relocated Claude", identifier: ClaudeApplicationResolver.bundleIdentifier)
        XCTAssertEqual(ClaudeApplicationResolver.find(applicationURLs: [wrong, moved]), moved)
        XCTAssertNil(ClaudeApplicationResolver.find(applicationURLs: [wrong]))
    }

    func testBundledCliFindsNewestNumericVersionAndFallsBackToUserInstallation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        func executable(_ relative: String) throws -> URL {
            let path = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path
        }
        let older = try executable("Library/Application Support/Claude/claude-code/2.1.9/hash/claude.app/Contents/MacOS/claude")
        let newest = try executable("Library/Application Support/Claude/claude-code/2.1.293/hash/claude.app/Contents/MacOS/claude")
        let user = try executable(".local/bin/claude")
        XCTAssertEqual(ClaudeApplicationResolver.findExecutable(userHome: root, environment: [:], applicationURLs: [], systemBinDirectories: [])?.resolvingSymlinksInPath(), newest.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: newest)
        XCTAssertEqual(ClaudeApplicationResolver.findExecutable(userHome: root, environment: [:], applicationURLs: [], systemBinDirectories: [])?.resolvingSymlinksInPath(), older.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: older)
        XCTAssertEqual(ClaudeApplicationResolver.findExecutable(userHome: root, environment: [:], applicationURLs: [], systemBinDirectories: [])?.resolvingSymlinksInPath(), user.resolvingSymlinksInPath())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: user.path)
        XCTAssertNil(ClaudeApplicationResolver.findExecutable(userHome: root, environment: ["PATH": "relative/bin"], applicationURLs: [], systemBinDirectories: []))
    }

    func testDesktopSessionMapUsesActiveAccountAndOnlyValidatedIdentifiers() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", org = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let cli = "cccccccc-cccc-cccc-cccc-cccccccccccc", local = "local_dddddddd-dddd-dddd-dddd-dddddddddddd"
        let base = root.appendingPathComponent("Library/Application Support/Claude")
        let metadataRoot = base.appendingPathComponent("claude-code-sessions/\(account)/\(org)")
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: base.appendingPathComponent("config.json"))
        let record: [String: Any] = ["sessionId": local, "cliSessionId": cli, "title": "private-fixture-title", "completedTurns": 99]
        try JSONSerialization.data(withJSONObject: record).write(to: metadataRoot.appendingPathComponent(local + ".json"))
        let oldAccount = base.appendingPathComponent("claude-code-sessions/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/\(org)")
        try FileManager.default.createDirectory(at: oldAccount, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_ffffffff-ffff-ffff-ffff-ffffffffffff", "cliSessionId": cli])
            .write(to: oldAccount.appendingPathComponent("local_ffffffff-ffff-ffff-ffff-ffffffffffff.json"))
        XCTAssertEqual(ClaudeApplicationResolver.desktopSessionMap(userHome: root), [cli: local])
        try JSONSerialization.data(withJSONObject: ["sessionId": "local_wrong", "cliSessionId": cli])
            .write(to: metadataRoot.appendingPathComponent(local + ".json"))
        XCTAssertTrue(ClaudeApplicationResolver.desktopSessionMap(userHome: root).isEmpty)
    }

    func testRemoteDesktopMappingRequiresMatchingCanonicalHostUserAndPort() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", org = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let cli = "cccccccc-cccc-cccc-cccc-cccccccccccc", local = "local_dddddddd-dddd-dddd-dddd-dddddddddddd"
        let base = root.appendingPathComponent("Library/Application Support/Claude")
        let metadata = base.appendingPathComponent("claude-code-sessions/\(account)/\(org)")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account]).write(to: base.appendingPathComponent("config.json"))
        let record: [String: Any] = ["sessionId": local, "cliSessionId": cli,
                                    "sshConfig": ["sshHost": "fixture-user@fixture.example", "sshPort": 2222, "name": "A100"]]
        try JSONSerialization.data(withJSONObject: record).write(to: metadata.appendingPathComponent(local + ".json"))
        XCTAssertTrue(ClaudeApplicationResolver.desktopSessionMap(userHome: root).isEmpty)
        let route = ClaudeSSHRoute(hostname: "fixture.example", user: "fixture-user", port: 2222)
        let matched = await ClaudeApplicationResolver.desktopSessionID(for: cli, sourceHostID: "remote-ssh-discovered:A100", userHome: root) { host, port in
            host == "A100" || (host == "fixture-user@fixture.example" && port == 2222) ? route : nil
        }
        XCTAssertEqual(matched, local)
        for mismatch in [ClaudeSSHRoute(hostname: "other.example", user: route.user, port: route.port),
                         ClaudeSSHRoute(hostname: route.hostname, user: "other-user", port: route.port),
                         ClaudeSSHRoute(hostname: route.hostname, user: route.user, port: 22)] {
            let rejected = await ClaudeApplicationResolver.desktopSessionID(for: cli, sourceHostID: "remote-ssh-discovered:A100", userHome: root) { host, _ in
                host == "A100" ? mismatch : route
            }
            XCTAssertNil(rejected)
        }
        let wrongNamespace = await ClaudeApplicationResolver.desktopSessionID(for: cli, sourceHostID: nil, userHome: root) { _, _ in route }
        XCTAssertNil(wrongNamespace)
        let duplicate = "local_eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        var second = record; second["sessionId"] = duplicate
        try JSONSerialization.data(withJSONObject: second).write(to: metadata.appendingPathComponent(duplicate + ".json"))
        let ambiguous = await ClaudeApplicationResolver.desktopSessionID(for: cli, sourceHostID: "remote-ssh-discovered:A100", userHome: root) { _, _ in route }
        XCTAssertNil(ambiguous)
    }

    func testRemoteMirrorExclusionRequiresDefaultHomeUniqueActiveProfileContext() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", org = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let cli = "cccccccc-cccc-cccc-cccc-cccccccccccc", desktop = "local_dddddddd-dddd-dddd-dddd-dddddddddddd"
        let base = root.appendingPathComponent("Library/Application Support/Claude")
        let metadata = base.appendingPathComponent("claude-code-sessions/\(account)/\(org)")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account]).write(to: base.appendingPathComponent("config.json"))
        func write(_ value: [String: Any]) throws {
            let name = try XCTUnwrap(value["sessionId"] as? String)
            try JSONSerialization.data(withJSONObject: value).write(to: metadata.appendingPathComponent(name + ".json"))
        }
        let remote: [String: Any] = ["sessionId": desktop, "cliSessionId": cli.uppercased(), "sshConfig": ["sshHost": "fixture-user@fixture.example"]]
        try write(remote)
        let home = root.appendingPathComponent(".claude")
        XCTAssertEqual(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root), [cli])
        XCTAssertTrue(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: root.appendingPathComponent("custom-claude"), userHome: root).isEmpty)
        // A genuine local context with the same UUID prevents a global UUID
        // exclusion; matching UUIDs alone never establish remote ownership.
        let local: [String: Any] = ["sessionId": "local_eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "cliSessionId": cli]
        try write(local)
        XCTAssertTrue(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root).isEmpty)
        try FileManager.default.removeItem(at: metadata.appendingPathComponent((local["sessionId"] as! String) + ".json"))
        // Conflicting remote contexts and conflicting transport markers are
        // ambiguous too; do not assign either of their hosts to a local file.
        var another = remote; another["sessionId"] = local["sessionId"]; another["sshConfig"] = ["sshHost": "other.example"]
        try write(another)
        XCTAssertTrue(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root).isEmpty)
        try FileManager.default.removeItem(at: metadata.appendingPathComponent((local["sessionId"] as! String) + ".json"))
        var conflict = remote; conflict["wslConfig"] = [:] as [String: String]; try write(conflict)
        XCTAssertTrue(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root).isEmpty)
        var wsl = remote; wsl.removeValue(forKey: "sshConfig"); wsl["wslConfig"] = [:] as [String: String]; try write(wsl)
        XCTAssertEqual(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root), [cli])
        wsl["wslConfig"] = "not-a-context"; try write(wsl)
        XCTAssertTrue(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root).isEmpty)
        try write(remote)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "ffffffff-ffff-ffff-ffff-ffffffffffff"])
            .write(to: base.appendingPathComponent("config.json"))
        XCTAssertTrue(ClaudeApplicationResolver.remoteMirrorSessionIDs(claudeHome: home, userHome: root).isEmpty)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-resolver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
