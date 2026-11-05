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

    // ClaudeSSHDiscoveryTests in PacerCore covers route validation on every
    // host; this case adds the Mac file system's symbolic-link refusal.
    func testASymlinkedDesktopConfigurationIsIgnored() async throws {
        let root = try fixture()
        let external = root.appendingPathComponent("external.json")
        try write(["configs": [["sshHost": "unsafe-link"]]], "external.json", root: root)
        let file = root.appendingPathComponent(desktop)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        let discovery = ClaudeSSHDiscovery { _, _ in nil }
        let linked = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        XCTAssertTrue(linked.isEmpty)
        // The same file read directly is a valid route, so only the link is refused.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: external, to: file)
        let direct = await discovery.configured(codexHome: root, claudeHome: root.appendingPathComponent(".claude"), userHome: root)
        XCTAssertEqual(direct.count, 1)
    }
}
