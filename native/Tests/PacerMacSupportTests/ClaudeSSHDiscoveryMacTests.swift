import PacerMacSupport
import XCTest
@testable import PacerCore

final class ClaudeSSHDiscoveryMacTests: XCTestCase {
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


}
