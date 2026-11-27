@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import WinSDK
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
    func testWorkBuddyInstalledToAChosenFolderIsFoundThroughItsLinkHandler() throws {
        let home = try root(); defer { try? FileManager.default.removeItem(at: home) }
        let standard = home.appendingPathComponent("standard folders")
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        let chosen = home.appendingPathComponent("Apps 自选/WorkBuddy"), app = chosen.appendingPathComponent("WorkBuddy.exe")
        try executable(app)
        let notAnApp = home.appendingPathComponent("Other/WorkBuddy.exe")
        try FileManager.default.createDirectory(at: notAnApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture, not a PE image".utf8).write(to: notAnApp)
        let environment = ["ProgramFiles": WindowsCodexExecutableDiscovery.path(standard), "LOCALAPPDATA": WindowsCodexExecutableDiscovery.path(standard)]
        var schemes: [String] = []
        func found(_ handlers: [String: [String]]) -> Set<AgentProvider> {
            WindowsProviderInstallation.detect(userHome: home, environment: environment, applicationURLs: nil, systemBinDirectories: [],
                packageLocations: { _ in [] }, registeredHandlers: { scheme in schemes.append(scheme); return handlers[scheme] ?? [] }, antigravityApp: { _ in nil })
                .installed.intersection([.workbuddy, .workbuddyAI])
        }
        XCTAssertEqual(found([:]), [], "Nothing in the standard folders and no handler finds nothing")
        XCTAssertEqual(found(["workbuddy": [WindowsCodexExecutableDiscovery.path(app)]]), [.workbuddy])
        XCTAssertEqual(Set(schemes), ["workbuddy", "workbuddy-ai"], "Each edition asks for its own link scheme")
        XCTAssertEqual(found(["workbuddy-ai": [WindowsCodexExecutableDiscovery.path(app)]]), [], "An edition's handler must name its own executable")
        XCTAssertEqual(found(["workbuddy": [#"\\server\share\WorkBuddy.exe"#, "WorkBuddy.exe"]]), [], "Shares and relative paths are not installations")
        XCTAssertEqual(found(["workbuddy": [WindowsCodexExecutableDiscovery.path(notAnApp)]]), [], "A file that is not a program is not an installation")
        XCTAssertEqual(found(["workbuddy": ["X:\\absent\\WorkBuddy.exe", WindowsCodexExecutableDiscovery.path(app)]]), [.workbuddy],
            "HKLM's handler still counts after a stale HKCU one")
    }
    func testLinkHandlerPathsReadOnlyTheQuotedExecutableOfAValidScheme() throws {
        // HKEY_CURRENT_USER is a C cast macro; its value is a sign-extended LONG.
        let user = try XCTUnwrap(HKEY(bitPattern: Int(Int32(bitPattern: 0x80000001))))
        let scheme = "pacer-qa-" + UUID().uuidString.prefix(8).lowercased()
        let key = Array("Software\\Classes\\\(scheme)".utf16) + [0], command = Array("Software\\Classes\\\(scheme)\\shell\\open\\command".utf16) + [0]
        defer { _ = RegDeleteTreeW(user, key); _ = RegDeleteKeyW(user, key) }
        func register(_ value: String) {
            let data = Array(value.utf16) + [0]
            XCTAssertEqual(data.withUnsafeBytes { RegSetKeyValueW(user, command, nil, DWORD(REG_SZ), $0.baseAddress, DWORD($0.count)) }, LSTATUS(ERROR_SUCCESS))
        }
        register(#""D:\Apps 自选\WorkBuddy\WorkBuddy.exe" "%1""#)
        XCTAssertEqual(WindowsURLHandler.paths(scheme: scheme), [#"D:\Apps 自选\WorkBuddy\WorkBuddy.exe"#])
        register(#"D:\Apps\WorkBuddy\WorkBuddy.exe "%1""#)
        XCTAssertEqual(WindowsURLHandler.paths(scheme: scheme), [], "An unquoted command is ambiguous and never yields a path")
        for invalid in ["", "Bad", "../classes", "9scheme", String(repeating: "a", count: 33)] {
            XCTAssertEqual(WindowsURLHandler.paths(scheme: invalid), [], invalid)
        }
    }
}
#endif
