#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsProviderInstallationTests: XCTestCase {
    private let noApps: [AgentProvider: [URL]] = [.codex: [], .claude: [], .deepseek: []]
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-install-" + UUID().uuidString + "-中文 space")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func executable(_ file: URL) throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")
            .appendingPathComponent("System32/cmd.exe")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: file)
    }
    func testProvidedApplicationRootsUseWindowsExecutablesAndRemainProviderScoped() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent("codex"), claude = home.appendingPathComponent("claude")
        try executable(codex.appendingPathComponent("app/resources/codex.exe"))
        try executable(claude.appendingPathComponent("app/Claude.exe"))
        let found = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: [.codex: [codex], .claude: [claude], .deepseek: []], systemBinDirectories: [])
        XCTAssertEqual(found, .init(codexInstalled: true, claudeInstalled: true))
        let wrongProvider = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: [.codex: [claude], .claude: [codex], .deepseek: [claude]], systemBinDirectories: [])
        XCTAssertEqual(wrongProvider, .init(codexInstalled: false, claudeInstalled: false))
    }
    func testRegisteredMsixMetadataDoesNotRequireReadingProtectedBinariesAndExplicitRootsRemainIsolated() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        var families: [String] = []
        let found = WindowsProviderInstallation.detect(userHome: home, environment: [:], applicationURLs: [.deepseek: []],
            systemBinDirectories: [], packageLocations: { family in
                families.append(family); return [home.appendingPathComponent("protected-package")]
            })
        XCTAssertEqual(found, .init(codexInstalled: true, claudeInstalled: true))
        XCTAssertEqual(Set(families), ["OpenAI.Codex_2p2nqsd0c76g0", "Claude_pzs8sxrjxfjjc"])
        let overridden = WindowsProviderInstallation.detect(userHome: home, environment: [:], applicationURLs: noApps,
            systemBinDirectories: [], packageLocations: { _ in XCTFail("Explicit fixture roots cannot fall through to installed packages"); return [home] })
        XCTAssertEqual(overridden, .init(codexInstalled: false, claudeInstalled: false))
    }
    func testNativeCliLocationsAndCaseInsensitiveQuotedPathNeverNeedShellLaunchers() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        let tools = home.appendingPathComponent("tools 中文")
        try executable(home.appendingPathComponent(".local/bin/claude.exe"))
        try executable(tools.appendingPathComponent("dsh.exe"))
        let found = ProviderInstallationDetection.detect(userHome: home,
            environment: ["pAtH": "relative;\"" + WindowsCodexExecutableDiscovery.path(tools) + "\""],
            applicationURLs: noApps, systemBinDirectories: [])
        XCTAssertEqual(found, .init(codexInstalled: false, claudeInstalled: true, deepseekInstalled: true))
        try FileManager.default.removeItem(at: tools.appendingPathComponent("dsh.exe"))
        try Data("fixture, not a PE image".utf8).write(to: tools.appendingPathComponent("dsh.exe"))
        XCTAssertFalse(ProviderInstallationDetection.detect(userHome: home,
            environment: ["Path": WindowsCodexExecutableDiscovery.path(tools)], applicationURLs: noApps,
            systemBinDirectories: []).deepseekInstalled)
    }
    func testDeepSeekDataDetectionRequiresADirectoryAndHonorsCustomHomeCasing() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("dsh data 中文")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let sessions = custom.appendingPathComponent("sessions")
        try Data().write(to: sessions)
        let environment = ["dSh_HoMe": WindowsCodexExecutableDiscovery.path(custom)]
        XCTAssertFalse(ProviderInstallationDetection.detect(userHome: home, environment: environment,
            applicationURLs: noApps, systemBinDirectories: []).deepseekInstalled)
        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        XCTAssertTrue(ProviderInstallationDetection.detect(userHome: home, environment: environment,
            applicationURLs: noApps, systemBinDirectories: []).deepseekInstalled)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".dsh/sessions"), withIntermediateDirectories: true)
        XCTAssertTrue(ProviderInstallationDetection.detect(userHome: home, environment: ["DSH_HOME": "   "],
            applicationURLs: noApps, systemBinDirectories: []).deepseekInstalled)
    }
    func testDiscoveryBudgetsExcludeLaterPathsAndMalformedPackageFamilies() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        var directories = (0..<128).map { WindowsCodexExecutableDiscovery.path(home.appendingPathComponent("missing\($0)")) }
        let late = home.appendingPathComponent("late")
        try executable(late.appendingPathComponent("claude.exe")); directories.append(WindowsCodexExecutableDiscovery.path(late))
        XCTAssertFalse(ProviderInstallationDetection.detect(userHome: home, environment: ["PATH": directories.joined(separator: ";")],
            applicationURLs: noApps, systemBinDirectories: []).claudeInstalled)
        XCTAssertTrue(WindowsPackageLocations.find(family: "").isEmpty)
        XCTAssertTrue(WindowsPackageLocations.find(family: String(repeating: "x", count: 255)).isEmpty)
        XCTAssertTrue(WindowsPackageLocations.find(family: "bad\0family").isEmpty)
    }
}
#endif
