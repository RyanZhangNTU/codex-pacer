@testable import PacerEngineSupport
import Foundation
import XCTest
import PacerCore
@testable import WindowsInstallerSupport

final class WindowsInstallerHooksTests: XCTestCase {
    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-install-hooks-中文-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    func testUninstallRestoresOnlyUserSettingsThroughSharedInstaller() throws {
        let home = try fixture(), settings = home.appendingPathComponent("settings.json")
        let original: [String: Any] = [
            "hooks": ["Stop": [["matcher": "user", "hooks": [["type": "command", "command": "echo synthetic user"]]]]],
            "env": ["USER_SETTING": "keep"],
            "statusLine": ["type": "command", "command": "echo synthetic status", "padding": 2],
            "userOption": ["preserve": true]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        _ = try WindowsClaudeHookCleanup.installer().install(home: home)
        let installed = try Data(contentsOf: settings)
        let manifest = try Data(contentsOf: home.appendingPathComponent("pacer/installation.json"))
        try WindowsClaudeHookCleanup.uninstall(home: home, checkOnly: true)
        XCTAssertEqual(try Data(contentsOf: settings), installed)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("pacer/installation.json")), manifest)
        try WindowsClaudeHookCleanup.uninstall(home: home)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: restored))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pacer/installation.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("pacer/hook.py").path))
        try WindowsClaudeHookCleanup.uninstall(home: home)
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to:
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])))
    }
    func testDeepSeekProgressUninstallChecksEveryConfiguredHomeBeforeRemovingIt() throws {
        let owned = try fixture(), edited = try fixture(), untouched = try fixture()
        for home in [owned, edited] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles"), withIntermediateDirectories: true)
            try Data("- id: user\n".utf8).write(to: home.appendingPathComponent("cordis.patch.yml"))
            XCTAssertEqual(DeepSeekProgressSetup.apply(home: home, enabled: true, storage: WindowsLocalProfileStorage()), .ready)
        }
        let patch = edited.appendingPathComponent("cordis.patch.yml")
        let changed = Data(String(decoding: try Data(contentsOf: patch), as: UTF8.self).replacingOccurrences(of: "transport: stdio", with: "transport: http").utf8)
        try changed.write(to: patch)
        let installed = try Data(contentsOf: owned.appendingPathComponent("cordis.patch.yml"))
        XCTAssertThrowsError(try WindowsDeepSeekProgressCleanup.unregister(homes: [owned, edited, untouched], checkOnly: true))
        XCTAssertEqual(try Data(contentsOf: owned.appendingPathComponent("cordis.patch.yml")), installed, "A check changes no home")
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.appendingPathComponent("pacer/deepseek-progress/enabled").path))
        XCTAssertThrowsError(try WindowsDeepSeekProgressCleanup.unregister(homes: [owned, edited, untouched], checkOnly: false))
        XCTAssertEqual(try Data(contentsOf: owned.appendingPathComponent("cordis.patch.yml")), Data("- id: user\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.appendingPathComponent("pacer/deepseek-progress/report-progress.mjs").path))
        XCTAssertEqual(try Data(contentsOf: patch), changed, "An edited entry stays for manual cleanup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: edited.appendingPathComponent("pacer/deepseek-progress/enabled").path))
        XCTAssertNoThrow(try WindowsDeepSeekProgressCleanup.unregister(homes: [owned, untouched], checkOnly: false))
    }
    func testUserEditsAfterInstallArePreserved() throws {
        let home = try fixture(), settings = home.appendingPathComponent("settings.json")
        _ = try WindowsClaudeHookCleanup.installer().install(home: home)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        value["statusLine"] = ["type": "command", "command": "user replacement"]
        var env = value["env"] as? [String: String] ?? [:]
        env["CLAUDE_CODE_ENABLE_TELEMETRY"] = "user replacement"; value["env"] = env
        var hooks = value["hooks"] as? [String: Any] ?? [:]
        hooks["UserEvent"] = [["hooks": [["type": "command", "command": "unrelated user hook"]]]]; value["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: value).write(to: settings)
        try WindowsClaudeHookCleanup.uninstall(home: home)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((restored["statusLine"] as? [String: String])?["command"], "user replacement")
        XCTAssertEqual((restored["env"] as? [String: String])?["CLAUDE_CODE_ENABLE_TELEMETRY"], "user replacement")
        XCTAssertEqual((restored["hooks"] as? [String: Any])?.count, 1)
        XCTAssertNotNil((restored["hooks"] as? [String: Any])?["UserEvent"])
    }
    func testInvalidAndOversizedSettingsFailWithoutChangingBytes() throws {
        for bytes in [Data("invalid synthetic account-private task-private".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
            let home = try fixture(), settings = home.appendingPathComponent("settings.json")
            _ = try WindowsClaudeHookCleanup.installer().install(home: home)
            try bytes.write(to: settings)
            XCTAssertThrowsError(try WindowsClaudeHookCleanup.uninstall(home: home, checkOnly: true))
            XCTAssertThrowsError(try WindowsClaudeHookCleanup.uninstall(home: home)) { error in
                XCTAssertFalse(error.localizedDescription.contains("account-private"))
                XCTAssertFalse(error.localizedDescription.contains("task-private"))
            }
            XCTAssertEqual(try Data(contentsOf: settings), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("pacer/installation.json").path))
        }
    }
    func testNoManifestIsANoOpAndSystemOwnedFilesAreRejected() throws {
        let home = try fixture(), settings = home.appendingPathComponent("settings.json")
        let bytes = Data("{\"user\":\"preserve\"}".utf8); try bytes.write(to: settings)
        try WindowsClaudeHookCleanup.uninstall(home: home)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        if let system = ProcessInfo.processInfo.environment["SystemRoot"] {
            XCTAssertThrowsError(try WindowsClaudeHookStorage().validate(URL(fileURLWithPath: system).appendingPathComponent("System32/kernel32.dll")))
        }
    }
}
