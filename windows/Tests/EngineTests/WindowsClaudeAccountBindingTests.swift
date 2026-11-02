#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsClaudeAccountBindingTests: XCTestCase {
    private let account = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let organization = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-claude-binding-中文-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func write(_ object: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
    private func cli(_ id: String) -> [String: Any] { ["oauthAccount": ["accountUuid": id, "organizationUuid": organization]] }
    func testPhysicalDefaultDirectoryHandlesCaseAndNeverTreatsAFileAsADirectory() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".claude"), otherHome = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true)
        let upper = URL(fileURLWithPath: WindowsCodexExecutableDiscovery.path(home).uppercased())
        XCTAssertTrue(WindowsClaudeAccountBinding.sameDirectory(home, upper)); XCTAssertFalse(WindowsClaudeAccountBinding.sameDirectory(home, otherHome))
        let file = root.appendingPathComponent("file"); try Data("metadata".utf8).write(to: file)
        XCTAssertFalse(WindowsClaudeAccountBinding.sameDirectory(file, file))
        try write(cli(account), to: root.appendingPathComponent(".claude.json"))
        let value = WindowsClaudeAccountBinding.observe(userHome: root, home: upper, desktopFiles: [])
        XCTAssertEqual(value.accountID, account); XCTAssertEqual(value.organizationID, organization); XCTAssertFalse(value.conflictingAccounts)
    }
    func testCustomHomeCannotImportDefaultDesktopOrDefaultCLIAccount() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("custom"), desktop = root.appendingPathComponent("desktop.json")
        try write(cli(account), to: root.appendingPathComponent(".claude.json"))
        try write(cli(other), to: home.appendingPathComponent(".claude.json"))
        try write(["lastKnownAccountUuid": account], to: desktop)
        let value = WindowsClaudeAccountBinding.observe(userHome: root, home: home, desktopFiles: [desktop])
        XCTAssertEqual(value.accountID, other); XCTAssertEqual(value.organizationID, organization); XCTAssertFalse(value.conflictingAccounts)
    }
    func testDirectoryJunctionUsesTheActualDefaultProfileMetadata() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".claude"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write(cli(account), to: root.appendingPathComponent(".claude.json"))
        let system = WindowsEnvironment.value("SystemRoot", in: ProcessInfo.processInfo.environment) ?? "C:\\Windows"
        let process = Process(); process.executableURL = URL(fileURLWithPath: system).appendingPathComponent("System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path $env:PACER_CLAUDE_TEST_LINK -Target $env:PACER_CLAUDE_TEST_TARGET | Out-Null"]
        process.environment = WindowsEnvironment.replacing("PACER_CLAUDE_TEST_LINK", with: WindowsCodexExecutableDiscovery.path(alias), in:
            WindowsEnvironment.replacing("PACER_CLAUDE_TEST_TARGET", with: WindowsCodexExecutableDiscovery.path(home), in: ProcessInfo.processInfo.environment))
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<500 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); XCTFail("The private junction fixture exceeded its deadline"); return }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(WindowsClaudeAccountBinding.sameDirectory(alias, home))
        XCTAssertEqual(WindowsClaudeAccountBinding.observe(userHome: root, home: alias, desktopFiles: []).accountID, account)
    }
    func testConflictingAndMalformedClaimedAccountsFailClosedAndMetadataUpdatesAreObserved() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".claude"), desktop = root.appendingPathComponent("desktop.json"), second = root.appendingPathComponent("second.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write(cli(account), to: root.appendingPathComponent(".claude.json"))
        try write(["lastKnownAccountUuid": other], to: desktop)
        XCTAssertTrue(WindowsClaudeAccountBinding.observe(userHome: root, home: home, desktopFiles: [desktop]).conflictingAccounts)
        try write(["lastKnownAccountUuid": account, "padding": "updated"], to: desktop)
        XCTAssertFalse(WindowsClaudeAccountBinding.observe(userHome: root, home: home, desktopFiles: [desktop]).conflictingAccounts)
        try write(["lastKnownAccountUuid": other], to: second)
        XCTAssertTrue(WindowsClaudeAccountBinding.observe(userHome: root, home: home, desktopFiles: [desktop, second]).conflictingAccounts)
        try write(cli("malformed-claimed-account"), to: root.appendingPathComponent(".claude.json"))
        XCTAssertTrue(WindowsClaudeAccountBinding.observe(userHome: root, home: home, desktopFiles: []).conflictingAccounts)
    }
    func testMetadataLocationsHonorWindowsEnvironmentCasingAndIgnoreRelativePaths() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = WindowsCodexExecutableDiscovery.path(root)
        let locations = WindowsClaudeAccountBinding.locations(environment: ["aPpDaTa": path, "localappdata": path])
        XCTAssertEqual(locations.count, 3); XCTAssertTrue(locations.allSatisfy { $0.lastPathComponent == "config.json" })
        XCTAssertTrue(WindowsClaudeAccountBinding.locations(environment: ["APPDATA": "relative", "LOCALAPPDATA": "bad\npath"]).isEmpty)
    }
}
#endif
