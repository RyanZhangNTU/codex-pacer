@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsCodexExecutableTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-cli-" + UUID().uuidString + "-中文 space")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func executable(_ destination: URL) throws {
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let source = URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func testDesktopDiscoverySelectsWindowsPEAndRejectsTheBundledLinuxBinary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = root.appendingPathComponent("app/resources/codex.exe"), linux = root.appendingPathComponent("app/resources/codex")
        try executable(windows)
        try Data([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0]).write(to: linux)
        let report = CodexExecutableResolver.discover(environment: [:], userHome: root, applicationURLs: [root], systemBinDirectories: [])
        XCTAssertEqual(report.selected?.url, windows)
        XCTAssertTrue(CodexExecutableResolver.isExecutableFile(windows))
        XCTAssertFalse(CodexExecutableResolver.isExecutableFile(linux))
        let invalid = CodexExecutableResolver.discover(customPath: WindowsCodexExecutableDiscovery.path(linux),
            environment: [:], userHome: root, applicationURLs: [root], systemBinDirectories: [])
        XCTAssertTrue(invalid.candidates.isEmpty)
        XCTAssertNotNil(invalid.issue)
    }
    func testNpmNativeBinaryIsFoundBehindTheLauncherUsingCaseInsensitivePath() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("npm prefix")
        let binary = prefix.appendingPathComponent("node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe")
        try executable(binary)
        let report = CodexExecutableResolver.discover(environment: ["pAtH": "\"" + WindowsCodexExecutableDiscovery.path(prefix) + "\";relative"],
            userHome: root, applicationURLs: [], systemBinDirectories: [])
        XCTAssertEqual(report.selected?.url, binary)
        XCTAssertFalse(report.searchedPaths.contains { $0.hasPrefix("relative") || $0.contains("/opt/homebrew") })
    }
    func testManualSelectionAcceptsQuotedUnicodeFoldersAndNeverFallsBackFromInvalidInput() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("codex.exe")
        try executable(binary)
        let report = CodexExecutableResolver.discover(customPath: "\"" + WindowsCodexExecutableDiscovery.path(root) + "\"",
            environment: [:], userHome: root, applicationURLs: [], systemBinDirectories: [])
        XCTAssertEqual(report.selected?.url, binary)
        let invalid = CodexExecutableResolver.discover(customPath: "relative\\codex.exe",
            environment: ["Path": WindowsCodexExecutableDiscovery.path(root)], userHome: root, applicationURLs: [], systemBinDirectories: [])
        XCTAssertTrue(invalid.candidates.isEmpty)
        XCTAssertFalse(invalid.issue?.contains("windows.cli.") ?? true, "Windows diagnostics must resolve from the shared platform catalog")
        XCTAssertFalse(invalid.issue?.contains("%1$@") ?? true)
        XCTAssertEqual(URL(fileURLWithPath: WindowsExecutablePlatform().normalize("~\\codex.exe", userHome: root)), binary)
    }
    func testLaunchEnvironmentUsesWindowsSeparatorsWithoutDuplicateCaseVariants() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("tools")
        let inherited = ["pAtH": WindowsCodexExecutableDiscovery.path(extra) + ";" + WindowsCodexExecutableDiscovery.path(extra).uppercased(),
            "USERPROFILE": "fixture", "UNCHANGED": "value"]
        let environment = CodexExecutableResolver.launchEnvironment(for: root.appendingPathComponent("codex.exe"), inherited: inherited, userHome: root)
        XCTAssertEqual(environment.filter { $0.key.lowercased() == "path" }.count, 1)
        XCTAssertEqual(environment["UNCHANGED"], "value")
        XCTAssertEqual(environment["USERPROFILE"], "fixture")
        XCTAssertEqual(environment["Path"]?.split(separator: ";").count, 2)
        XCTAssertTrue(environment["Path"]?.hasPrefix(WindowsCodexExecutableDiscovery.path(root) + ";") == true)
    }
    func testWindowsOnlyDiagnosticsUseTheOriginalPrintfFormatterInBothLanguages() {
        let path = "C:\\中文 space\\codex.exe"
        for language in AppLanguage.allCases {
            let message = L10n.text("windows.cli.relative_path", path, language: language)
            XCTAssertTrue(message.contains(path))
            XCTAssertFalse(message.contains("%1$@"))
            XCTAssertFalse(message.contains("windows.cli."))
            XCTAssertFalse(message.contains("Codex.app"))
        }
    }
}
#endif
