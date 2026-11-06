import XCTest
@testable import PacerCore

final class SharedHookInstallerTests: XCTestCase {
    private final class Storage: ClaudeHookStorage, @unchecked Sendable {
        var files: [URL: Data] = [:]
        var directories: Set<URL> = []
        var unsafe: Set<URL> = []
        var failures: Set<URL> = []
        var permissions: [URL: UInt16] = [:]
        var replacements = 0
        func validate(_ url: URL) throws { if unsafe.contains(url) { throw ClaudeHookInstaller.Failure.unsafePath } }
        func exists(_ url: URL) -> Bool { files[url] != nil || directories.contains(url) }
        func isDirectory(_ url: URL) -> Bool { directories.contains(url) }
        func isReadable(_ url: URL) -> Bool { files[url] != nil }
        func read(_ url: URL) throws -> Data { guard let data = files[url] else { throw CocoaError(.fileReadNoSuchFile) }; return data }
        func createDirectory(_ url: URL, permissions: UInt16) throws { try validate(url); directories.insert(url); self.permissions[url] = permissions }
        func replace(_ url: URL, with data: Data, permissions: UInt16) throws {
            try validate(url); if failures.contains(url) { throw CocoaError(.fileWriteUnknown) }
            files[url] = data; self.permissions[url] = permissions; replacements += 1
        }
        func remove(_ url: URL) throws { files.removeValue(forKey: url) }
    }
    private func fixture() -> (URL, Storage, ClaudeHookInstaller) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-hooks")
        let storage = Storage(); storage.directories.insert(home)
        let installer = ClaudeHookInstaller(storage: storage, python: "fixture-python", serialize: { arguments in
            arguments.map { "[" + $0 + "]" }.joined(separator: " ")
        })
        return (home, storage, installer)
    }
    private func object(_ url: URL, _ storage: Storage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: storage.read(url)) as? [String: Any])
    }
    func testInjectedPythonCommandsAtomicPermissionsAndIdempotence() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        let value = try object(settings, storage)
        let groups = try XCTUnwrap((value["hooks"] as? [String: [[String: Any]]])?["SessionStart"])
        let entry = try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap(entry["command"] as? String)
        XCTAssertTrue(command.hasPrefix("[fixture-python] [-S] [")); XCTAssertTrue(command.contains("[hook]"))
        XCTAssertEqual(storage.permissions[home.appendingPathComponent("pacer")], 0o700)
        XCTAssertEqual(storage.permissions[home.appendingPathComponent("pacer/hook.py")], 0o700)
        XCTAssertEqual(storage.permissions[settings], 0o600)
        XCTAssertEqual(storage.permissions[home.appendingPathComponent("pacer/installation.json")], 0o600)
        let writes = storage.replacements
        XCTAssertEqual(installer.ensureInstalled(home: home), .current); XCTAssertEqual(storage.replacements, writes)
        XCTAssertTrue(installer.details(home: home).telemetryConfigured)
    }
    func testProgressRingSwitchAddsAndRemovesTheBackgroundDisplayObserver() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let flag = ClaudeProgressRingSwitch.flagURL(home: home)
        func display() throws -> [[String: Any]]? { (try object(settings, storage)["hooks"] as? [String: [[String: Any]]])?["MessageDisplay"] }
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        XCTAssertNil(try display(), "Pacer telemetry alone keeps the display observer off")
        storage.files[flag] = Data("on\n".utf8)
        XCTAssertTrue(installer.details(home: home).updateAvailable)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        let entry = try XCTUnwrap((try display()?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["async"] as? Bool, true, "The observer runs in the background and never holds display")
        XCTAssertEqual(installer.ensureInstalled(home: home), .current)
        storage.files.removeValue(forKey: flag)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        XCTAssertNil(try display())
    }
    func testToolModeListsEnablesAndApprovesPacersPluginAndRemovesOnlyItsOwnEntries() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let flag = ClaudeProgressRingSwitch.flagURL(home: home), root = home.appendingPathComponent("pacer/plugin")
        let user: [String: Any] = ["permissions": ["allow": ["Bash(git status)"]], "enabledPlugins": ["other@market": true],
            "extraKnownMarketplaces": ["market": ["source": ["source": "github", "repo": "fixture/market"]]]]
        storage.files[settings] = try JSONSerialization.data(withJSONObject: user)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        storage.files[flag] = Data("tool\n".utf8)
        XCTAssertTrue(installer.details(home: home).updateAvailable)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        var value = try object(settings, storage)
        XCTAssertEqual((value["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(git status)", ClaudeHookInstaller.progressTool])
        XCTAssertEqual(value["enabledPlugins"] as? [String: Bool], ["other@market": true, "pacer@pacer": true])
        let source = try XCTUnwrap(((value["extraKnownMarketplaces"] as? [String: Any])?["pacer"] as? [String: Any])?["source"] as? [String: String])
        XCTAssertEqual(source, ["source": "directory", "path": root.path])
        XCTAssertNil((value["hooks"] as? [String: Any])?["MessageDisplay"], "The tool needs no display observer")
        let manifest = try object(root.appendingPathComponent("pacer/.claude-plugin/plugin.json"), storage)
        let server = try XCTUnwrap((manifest["mcpServers"] as? [String: Any])?["pacer"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "fixture-python")
        XCTAssertEqual(try object(root.appendingPathComponent(".claude-plugin/marketplace.json"), storage)["name"] as? String, "pacer")
        XCTAssertNotNil(storage.files[root.appendingPathComponent("pacer/progress_mcp.py")])
        XCTAssertEqual(storage.permissions[root], 0o700)
        XCTAssertEqual(installer.ensureInstalled(home: home), .current)
        storage.files.removeValue(forKey: flag)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        value = try object(settings, storage)
        XCTAssertTrue(NSDictionary(dictionary: value["permissions"] as? [String: Any] ?? [:]).isEqual(to: user["permissions"] as! [String: Any]))
        XCTAssertEqual(value["enabledPlugins"] as? [String: Bool], ["other@market": true])
        XCTAssertEqual((value["extraKnownMarketplaces"] as? [String: Any])?.keys.sorted(), ["market"])
        storage.files[flag] = Data("tool\n".utf8)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        try installer.uninstall(home: home)
        XCTAssertTrue(NSDictionary(dictionary: try object(settings, storage)).isEqual(to: user), "Uninstall leaves the user's own entries")
    }
    func testProgressPluginRefusesAForeignMarketplaceAndPreservesUntrackedEntries() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let user: [String: Any] = ["extraKnownMarketplaces": ["pacer": ["source": ["source": "directory", "path": "/user/market"]]],
            "enabledPlugins": ["pacer@pacer": false], "permissions": ["allow": [ClaudeHookInstaller.progressTool, "Read"]]]
        let bytes = try JSONSerialization.data(withJSONObject: user)
        storage.files[settings] = bytes; storage.files[ClaudeProgressRingSwitch.flagURL(home: home)] = Data("tool\n".utf8)
        XCTAssertThrowsError(try installer.install(home: home))
        XCTAssertEqual(storage.files[settings], bytes, "A name collision cannot replace the user's marketplace or plugin choice")
        storage.files.removeValue(forKey: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        try installer.uninstall(home: home)
        XCTAssertTrue(NSDictionary(dictionary: try object(settings, storage)).isEqual(to: user), "No ownership record means no plugin cleanup")
    }

    func testProgressPluginRestoresAPreviousDisabledValueAndKeepsAnExistingPermission() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let user: [String: Any] = ["extraKnownMarketplaces": ["pacer": ["source": ["source": "directory", "path": home.appendingPathComponent("pacer/plugin").path]]],
            "enabledPlugins": ["pacer@pacer": false], "permissions": ["allow": [ClaudeHookInstaller.progressTool, "Read"]]]
        storage.files[settings] = try JSONSerialization.data(withJSONObject: user)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        storage.files[ClaudeProgressRingSwitch.flagURL(home: home)] = Data("tool\n".utf8)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        XCTAssertEqual((try object(settings, storage)["enabledPlugins"] as? [String: Bool])?["pacer@pacer"], true)
        XCTAssertEqual(installer.ensureInstalled(home: home), .current, "Ownership is persisted by migration as well as initial install")
        storage.files.removeValue(forKey: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        XCTAssertEqual((try object(settings, storage)["enabledPlugins"] as? [String: Bool])?["pacer@pacer"], false)
        try installer.uninstall(home: home)
        XCTAssertTrue(NSDictionary(dictionary: try object(settings, storage)).isEqual(to: user))
    }

    func testProgressPluginCleanupPreservesUserEditsAndMigrationRollsBackItsLedger() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let flag = ClaudeProgressRingSwitch.flagURL(home: home), manifest = home.appendingPathComponent("pacer/installation.json")
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        let previousManifest = storage.files[manifest]
        storage.files[flag] = Data("tool\n".utf8); storage.failures.insert(settings)
        XCTAssertEqual(installer.ensureInstalled(home: home), .failed)
        XCTAssertEqual(storage.files[manifest], previousManifest, "A failed settings write cannot claim ownership")
        storage.failures.remove(settings)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        var edited = try object(settings, storage)
        edited["extraKnownMarketplaces"] = ["pacer": ["source": ["source": "directory", "path": "/user/replacement"]]]
        edited["enabledPlugins"] = ["pacer@pacer": false]
        edited["permissions"] = ["allow": [ClaudeHookInstaller.progressTool, "Read"]]
        storage.files[settings] = try JSONSerialization.data(withJSONObject: edited)
        storage.files.removeValue(forKey: flag)
        XCTAssertEqual(installer.ensureInstalled(home: home), .installed)
        try installer.uninstall(home: home)
        let result = try object(settings, storage)
        for key in ["extraKnownMarketplaces", "enabledPlugins", "permissions"] {
            XCTAssertTrue(NSDictionary(dictionary: result[key] as! [String: Any]).isEqual(to: edited[key] as! [String: Any]), key)
        }
    }

    func testConflictingTelemetryAndForeignStatusLineSurviveInstallAndUninstall() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let original: [String: Any] = ["env": ["OTEL_EXPORTER_OTLP_TRACES_HEADERS": "synthetic-header"],
            "statusLine": ["type": "command", "command": "fixture-renderer", "padding": 4],
            "hooks": ["SessionStart": [["matcher": "foreign", "hooks": [["type": "command", "command": "foreign-hook"]]]]]]
        storage.files[settings] = try JSONSerialization.data(withJSONObject: original)
        let status = try installer.install(home: home)
        XCTAssertTrue(status.telemetryConflict); XCTAssertFalse(status.telemetryConfigured)
        let configured = try object(settings, storage)
        XCTAssertEqual(configured["env"] as? [String: String], original["env"] as? [String: String])
        XCTAssertEqual((configured["statusLine"] as? [String: Any])?["padding"] as? Int, 4)
        XCTAssertNotNil((configured["hooks"] as? [String: Any])?["MessageDisplay"])
        try installer.uninstall(home: home)
        XCTAssertTrue(NSDictionary(dictionary: try object(settings, storage)).isEqual(to: original))
    }
    func testFailedAtomicSettingsReplacementPreservesOldSettingsAndManifest() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let original = Data(#"{"env":{"FOREIGN":"kept"}}"#.utf8)
        storage.files[settings] = original
        let manifest = home.appendingPathComponent("pacer/installation.json"), oldManifest = Data(#"{"version":0}"#.utf8)
        storage.files[manifest] = oldManifest; storage.failures.insert(settings)
        XCTAssertThrowsError(try installer.install(home: home))
        XCTAssertEqual(storage.files[settings], original); XCTAssertEqual(storage.files[manifest], oldManifest)
    }
    func testUnsafePathsMalformedAndOversizedSettingsRemainUntouched() throws {
        let (home, storage, installer) = fixture(), settings = home.appendingPathComponent("settings.json")
        let original = Data(#"{"foreign":1}"#.utf8)
        storage.files[settings] = original; storage.unsafe.insert(settings)
        XCTAssertThrowsError(try installer.install(home: home)); XCTAssertEqual(storage.files[settings], original)
        storage.unsafe.removeAll()
        for invalid in [Data("[1]".utf8), Data("{".utf8), Data(repeating: 32, count: 2 * 1024 * 1024 + 1)] {
            storage.files[settings] = invalid
            XCTAssertThrowsError(try installer.install(home: home)); XCTAssertEqual(storage.files[settings], invalid)
        }
        XCTAssertEqual(storage.replacements, 0)
    }
}
