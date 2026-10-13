import XCTest
@testable import PacerCore

final class CodexApplicationResolverTests: XCTestCase {
    /// The standalone Codex.app was renamed/merged into ChatGPT.app, which ships a
    /// newer bundled CLI. When both bundles are present, the resolver must pick the
    /// successor (ChatGPT.app) so Pacer does not launch the outdated CLI that rejects
    /// newer RPC params.
    func testChatGPTAppIsPreferredOverLegacyCodexApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chatgpt = root.appendingPathComponent("Applications/ChatGPT.app")
        let codex = root.appendingPathComponent("Applications/Codex.app")
        try makeStubApp(chatgpt, bundleID: "com.openai.codex")
        try makeStubApp(codex, bundleID: "com.openai.codex")

        let report = CodexExecutableResolver.discover(customPath: "", environment: [:],
            userHome: root, applicationURLs: CodexApplicationResolver.locations(userHome: root),
            systemBinDirectories: [])
        guard let selected = report.selected else {
            XCTFail("expected an executable to be resolved"); return
        }
        XCTAssertTrue(selected.url.path.contains("ChatGPT.app"),
            "legacy Codex.app must not win when ChatGPT.app is present, got \(selected.url.path)")
    }

    func testLegacyCodexAppStillResolvedWhenNoSuccessor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codex = root.appendingPathComponent("Applications/Codex.app")
        try makeStubApp(codex, bundleID: "com.openai.codex")
        let ordered = CodexApplicationResolver.orderedCandidates(
            successors: [], registered: [],
            legacy: [codex.standardizedFileURL])
        XCTAssertEqual(ordered.first?.standardizedFileURL, codex.standardizedFileURL)
    }

    func testOrderedCandidatesDropsDuplicatesAndPrefersSuccessors() {
        let chatgpt = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let codex = URL(fileURLWithPath: "/Applications/Codex.app")
        let registered = [codex.standardizedFileURL]
        let ordered = CodexApplicationResolver.orderedCandidates(
            successors: [chatgpt.standardizedFileURL],
            registered: registered,
            legacy: [codex.standardizedFileURL])
        XCTAssertEqual(ordered.first?.standardizedFileURL, chatgpt.standardizedFileURL)
        XCTAssertEqual(ordered.count, 2, "the duplicated Codex.app path must appear only once")
    }

    func testSuccessorApplicationsOnlyIncludesBundlesOnDisk() {
        // On CI or a machine without ChatGPT.app installed, the successor list is empty
        // and locations() falls back to the legacy path deterministically.
        let successors = CodexApplicationResolver.successorApplications()
        for url in successors {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func makeStubApp(_ url: URL, bundleID: String) throws {
        let contents = url.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let cli = macos.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
        </dict>
        </plist>
        """
        try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
    }
}
