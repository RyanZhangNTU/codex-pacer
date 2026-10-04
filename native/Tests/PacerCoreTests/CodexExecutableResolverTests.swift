import XCTest
@testable import PacerCore

final class CodexExecutableResolverTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func executable(_ relative: String) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
    private func discover(_ custom: String = "", environment: [String: String] = [:],
                          apps: [URL] = [], bins: [String] = []) -> CodexExecutableResolver.Report {
        CodexExecutableResolver.discover(customPath: custom, environment: environment, userHome: root,
            applicationURLs: apps, systemBinDirectories: bins)
    }

    func testAppInNonstandardLocationAndCustomAppSelection() throws {
        let cli = try executable("Moved Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let app = root.appendingPathComponent("Moved Applications/Codex.app")
        XCTAssertEqual(discover(app.path).selected?.url, cli.standardizedFileURL)
        XCTAssertEqual(discover(apps: [app]).selected?.url, cli.standardizedFileURL)
    }
    func testNvmIsFoundWithoutShellPathAndNewestVersionWins() throws {
        _ = try executable(".nvm/versions/node/v9.9.0/bin/codex")
        _ = try executable(".nvm/versions/node/v22.0.0/bin/codex")
        let newest = try executable(".nvm/versions/node/v24.1.0/bin/codex")
        XCTAssertEqual(discover(environment: ["PATH": "/usr/bin:/bin"]).selected?.url, newest.standardizedFileURL)
    }
    func testCustomNodeManagerRootsAndNpmPrefix() throws {
        let fnm = try executable("custom-fnm/node-versions/v22.0.0/installation/bin/codex")
        XCTAssertEqual(discover(environment: ["FNM_DIR": root.appendingPathComponent("custom-fnm").path]).selected?.url, fnm.standardizedFileURL)
        let npm = try executable("custom-npm/bin/codex")
        XCTAssertEqual(discover(environment: ["NPM_CONFIG_PREFIX": root.appendingPathComponent("custom-npm").path]).selected?.url, npm.standardizedFileURL)
    }
    func testPathAndHomebrewLocationsAreSupported() throws {
        let cli = try executable("custom path/bin/codex")
        XCTAssertEqual(discover(environment: ["PATH": cli.deletingLastPathComponent().path]).selected?.url, cli.standardizedFileURL)
        XCTAssertEqual(discover(bins: [cli.deletingLastPathComponent().path]).selected?.url, cli.standardizedFileURL)
    }
    func testInvalidExplicitSelectionDoesNotSilentlyUseAnotherCli() throws {
        _ = try executable(".local/bin/codex")
        let report = discover(root.appendingPathComponent("missing/codex").path)
        XCTAssertNil(report.selected)
        XCTAssertEqual(report.issue, L10n.text("cli.path_missing", root.appendingPathComponent("missing/codex").path))
        XCTAssertNil(discover("relative/codex").selected)
    }
    func testDirectorySelectionResolvesCodexButDirectoryIsNotAnExecutable() throws {
        let cli = try executable("chosen folder/codex")
        XCTAssertEqual(discover(cli.deletingLastPathComponent().path).selected?.url, cli.standardizedFileURL)
        let fake = root.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertFalse(CodexExecutableResolver.isExecutableFile(fake))
        XCTAssertNil(discover().selected)
    }
    func testQuotedTildePathAndSymlinkDeduplication() throws {
        let cli = try executable(".nvm/versions/node/v24.1.0/bin/codex")
        let alias = root.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cli)
        XCTAssertEqual(discover("'~/.nvm/versions/node/v24.1.0/bin/codex'").selected?.url, cli.standardizedFileURL)
        let report = discover(environment: ["PATH": alias.deletingLastPathComponent().path])
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.selected?.url, alias.standardizedFileURL)
    }
    func testLaunchPathPreservesRuntimeDirectoryAndInheritedEnvironment() throws {
        let cli = try executable(".nvm/versions/node/v24.1.0/bin/codex")
        let result = CodexExecutableResolver.launchEnvironment(for: cli,
            inherited: ["PATH": "/usr/bin:/bin", "HTTPS_PROXY": "http://proxy.example:1234"], userHome: root)
        XCTAssertEqual(result["PATH"]?.split(separator: ":").first.map(String.init), cli.deletingLastPathComponent().path)
        XCTAssertEqual(result["HTTPS_PROXY"], "http://proxy.example:1234")
        XCTAssertTrue(result["PATH"]?.contains("/usr/bin") == true)
    }
}
