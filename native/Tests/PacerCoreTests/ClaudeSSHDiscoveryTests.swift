import XCTest
@testable import PacerCore

final class ClaudeSSHDiscoveryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-ssh-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ value: [String: Any], _ relative: String, root: URL) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
    }
    private let desktop = "Library/Application Support/Claude/ssh_configs.json"

    func testManagedListsDeduplicateCanonicalRoutesAndPreserveCodexIdentityAndClaudeOptions() async throws {
        let root = try fixture(), home = root.appendingPathComponent(".claude"), codex = root.appendingPathComponent(".codex")
        let id = "remote-ssh-discovered:gpu-alias"
        try write(["codex-managed-remote-connections": [["source": "discovered", "hostId": id, "alias": "gpu-alias"]],
            "remote-connection-auto-connect-by-host-id": [id: true]], ".codex/.codex-global-state.json", root: root)
        try write(["configs": [
            ["id": "shared", "name": "GPU", "sshHost": "fixture@gpu.example", "sshIdentityFile": "/fixture/key file"],
            ["id": "only", "name": "Claude only", "sshHost": "fixture@only.example", "sshPort": 2200],
            ["id": "overridden", "name": "Old", "sshHost": "old.example"]], "trustedHosts": ["not-a-target.example"],
            "privateKey": "PRIVATE"], desktop, root: root)
        try write(["sshConfigs": [["id": "overridden", "name": "User settings", "sshHost": "new.example"]]],
            ".claude/settings.json", root: root)
        let discovery = ClaudeSSHDiscovery { host, port in
            .init(hostname: host == "gpu-alias" || host == "fixture@gpu.example" ? "gpu.example" : host,
                  user: "fixture", port: port ?? 22)
        }
        let targets = await discovery.configured(codexHome: codex, claudeHome: home, userHome: root)
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets.first?.id, id)
        XCTAssertEqual(targets.first?.alias, "gpu-alias")
        XCTAssertEqual(targets.first?.sshIdentityFile, "/fixture/key file")
        let only = try XCTUnwrap(targets.first { $0.name == "Claude only" })
        XCTAssertEqual(only.effectiveSSHHost, "fixture@only.example")
        XCTAssertEqual(only.sshPort, 2200)
        XCTAssertTrue(only.id.hasPrefix("remote-ssh-discovered:claude-"))
        XCTAssertEqual(targets.first { $0.name == "User settings" }?.effectiveSSHHost, "new.example")
        XCTAssertFalse(targets.contains { $0.effectiveSSHHost == "old.example" || $0.effectiveSSHHost == "not-a-target.example" })
        XCTAssertFalse(String(describing: targets).contains("PRIVATE"))
        let before = targets.map(\.id)
        try write(["sshConfigs": [["id": "overridden", "name": "Renamed", "sshHost": "new.example"]]], ".claude/settings.json", root: root)
        let renamed = await discovery.configured(codexHome: codex, claudeHome: home, userHome: root)
        XCTAssertEqual(renamed.map(\.id), before, "Display names do not replace sources")
        try write(["configs": []], desktop, root: root)
        try write(["sshConfigs": []], ".claude/settings.json", root: root)
        let removed = await discovery.configured(codexHome: codex, claudeHome: home, userHome: root)
        XCTAssertEqual(removed.map(\.id), [id], "Removing a host in Claude removes only its source")
    }

    func testInvalidRoutesAndIdentityPathsAreRejectedButBrokenSafeRoutesRemainVisible() async throws {
        let root = try fixture()
        try write(["configs": [
            ["sshHost": "fixture@valid.example", "sshPort": 2222, "sshIdentityFile": "/fixture/key's name"],
            ["sshHost": "::1", "sshPort": 22],
            ["sshHost": "-oProxyCommand=bad"], ["sshHost": "host\n"], ["sshHost": "user@host;bad"],
            ["sshHost": "safe", "sshPort": true], ["sshHost": "safe", "sshPort": 0],
            ["sshHost": "safe", "sshIdentityFile": "-oBad"], ["sshHost": "safe", "sshIdentityFile": "/key\n"]]], desktop, root: root)
        let discovery = ClaudeSSHDiscovery { _, _ in nil }
        let targets = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        XCTAssertEqual(targets.count, 2)
        let args = try XCTUnwrap(targets.first?.sshArguments())
        XCTAssertEqual(Array(args.suffix(6)), ["-p", "2222", "-i", "/fixture/key's name", "--", "fixture@valid.example"])
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        let installer = try ClaudeRemoteSetup.arguments(target: targets[0])
        XCTAssertEqual(Array(installer.dropLast()), args, "Collection and setup use the same route and key")
        try FileManager.default.removeItem(at: root.appendingPathComponent(desktop))
        let external = root.appendingPathComponent("external.json")
        try JSONSerialization.data(withJSONObject: ["configs": [["sshHost": "unsafe-link"]]]).write(to: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(desktop), withDestinationURL: external)
        let linked = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        XCTAssertTrue(linked.isEmpty)
    }

    func testDiscoveryIsBoundedAndCachesRouteReadsUntilSSHConfigurationChanges() async throws {
        actor Reads {
            var count = 0
            func resolve(_ host: String, _ port: Int?) -> ClaudeSSHRoute { count += 1; return .init(hostname: host, user: "fixture", port: port ?? 22) }
        }
        let root = try fixture(), reads = Reads()
        try write(["configs": (0..<20).map { ["id": String($0), "name": "Host \($0)", "sshHost": "host-\($0)"] }], desktop, root: root)
        let discovery = ClaudeSSHDiscovery { await reads.resolve($0, $1) }
        let first = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        XCTAssertEqual(first.count, 8)
        let initial = await reads.count
        _ = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        let cached = await reads.count
        XCTAssertEqual(cached, initial)
        let ssh = root.appendingPathComponent(".ssh/config")
        try FileManager.default.createDirectory(at: ssh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Host host-0\nHostName changed.example\n".utf8).write(to: ssh)
        _ = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        let changed = await reads.count
        XCTAssertGreaterThan(changed, cached)
    }
}
