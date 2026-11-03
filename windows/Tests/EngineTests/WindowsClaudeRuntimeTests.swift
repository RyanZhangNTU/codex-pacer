import Foundation
import XCTest
import PacerCore
@testable import WindowsInstallerSupport

final class WindowsClaudeRuntimeTests: XCTestCase {
    private func fixture() throws -> (base: URL, root: URL, homes: [URL]) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let base = temporary.appendingPathComponent("pacer-runtime-中文-" + UUID().uuidString, isDirectory: true)
        let homes = [base.appendingPathComponent("Claude 一号"), base.appendingPathComponent("Claude 二号")]
        for home in homes { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        addTeardownBlock {
            guard base.standardizedFileURL.path.lowercased().hasPrefix(temporary.path.lowercased() + "/"), base.lastPathComponent.hasPrefix("pacer-runtime-") else { return }
            try? FileManager.default.removeItem(at: base)
        }
        return (base, base.appendingPathComponent("Local 数据/CodexPacer/ClaudeRuntime"), homes)
    }
    private var package: URL { get throws {
        URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_CLAUDE_PYTHON_PACKAGE"]), isDirectory: true)
    } }
    private let original: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo synthetic-user"]]]]],
        "statusLine": ["type": "command", "command": "echo synthetic-status", "padding": 2], "env": ["USER_VALUE": "keep"]]
    private func write(_ object: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url) }
    private func read(_ url: URL) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
    private func command(_ home: URL) throws -> String {
        let value = try read(home.appendingPathComponent("settings.json"))
        let groups = try XCTUnwrap((value["hooks"] as? [String: [[String: Any]]])?["SessionStart"])
        return try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    func testMultipleHomesShareRuntimeAndUninstallRestoresBoth() throws {
        let fixture = try fixture(), runtime = WindowsClaudeHookRuntime(root: fixture.root)
        for home in fixture.homes {
            try write(original, home.appendingPathComponent("settings.json"))
            XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pacer/runtime").path))
        }
        let pin = try WindowsPythonPin.load()
        let directory = fixture.root.appendingPathComponent(pin.identifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("python.exe").path))
        let versions = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".pacer-owned.json" }
        XCTAssertEqual(versions.count, 1)
        for home in fixture.homes {
            XCTAssertTrue(try command(home).contains(fixture.root.path + "/" + pin.identifier + "/python.exe"))
            let before = try Data(contentsOf: home.appendingPathComponent("settings.json"))
            XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
            XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("settings.json")), before, "An already-current configuration is not rewritten")
        }
        let movedPackage = fixture.base.appendingPathComponent("移动 安装/Python")
        try FileManager.default.createDirectory(at: movedPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try package, to: movedPackage)
        let beforeMove = try command(fixture.homes[0])
        XCTAssertEqual(runtime.ensure(home: fixture.homes[0], package: movedPackage).state, "ready")
        XCTAssertEqual(try command(fixture.homes[0]), beforeMove, "Moving the application does not stale its Python command")
        try runtime.uninstall(homes: [fixture.homes[0]], checkOnly: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
        try runtime.uninstall(homes: [fixture.homes[0]]) // The second home comes from the owned index.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        for home in fixture.homes {
            XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: try read(home.appendingPathComponent("settings.json"))))
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("pacer/hook.py").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pacer/installation.json").path))
        }
    }
    func testLegacyCommandsMigrateWithoutReplacingTheOriginalStatusLine() throws {
        let fixture = try fixture(), home = fixture.homes[0]
        try write(original, home.appendingPathComponent("settings.json"))
        _ = try WindowsClaudeHookCleanup.installer().install(home: home)
        let runtime = WindowsClaudeHookRuntime(root: fixture.root)
        let legacyStatus = try WindowsClaudeHookCommands.installer(home: home, root: fixture.root, storage: WindowsClaudeHookStorage()).details(home: home)
        XCTAssertTrue(legacyStatus.hooksConfigured, "The Windows matcher must recognize the original hook commands")
        XCTAssertTrue(legacyStatus.statusLineConfigured, "The Windows matcher must recognize the original wrapper")
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        let manifest = try read(home.appendingPathComponent("pacer/installation.json"))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(manifest["previousStatusLine"]), options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: XCTUnwrap(original["statusLine"]), options: [.sortedKeys]))
        XCTAssertTrue(try command(home).hasPrefix("cmd.exe /D/C call \""))
        XCTAssertFalse(try command(home).hasPrefix("python3"))
        let pin = try WindowsPythonPin.load()
        let old = fixture.root.appendingPathComponent("0.0.1-111111111111/python.exe")
        var value = try read(home.appendingPathComponent("settings.json"))
        let current = try command(home), prior = WindowsClaudeHookCommands.command(python: old, home: home, kind: .hook)
        var hooks = try XCTUnwrap(value["hooks"] as? [String: [[String: Any]]])
        for event in hooks.keys {
            hooks[event] = hooks[event]?.map { group in
                var group = group
                group["hooks"] = (group["hooks"] as? [[String: Any]])?.map { entry in
                    var entry = entry; if entry["command"] as? String == current { entry["command"] = prior }; return entry
                }; return group
            }
        }
        value["hooks"] = hooks
        var line = try XCTUnwrap(value["statusLine"] as? [String: Any]); line["command"] = WindowsClaudeHookCommands.command(python: old, home: home, kind: .statusLine); value["statusLine"] = line
        try write(value, home.appendingPathComponent("settings.json"))
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        XCTAssertTrue(try command(home).contains(pin.identifier))
        try runtime.uninstall(homes: [home])
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: try read(home.appendingPathComponent("settings.json"))))
    }
    private func oldVersion(_ root: URL) throws -> URL {
        let directory = root.appendingPathComponent("0.0.1-111111111111")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data("synthetic runtime, never executed".utf8)
        try bytes.write(to: directory.appendingPathComponent("python.exe"))
        try write(["schemaVersion": 1, "owner": "CodexPacer", "version": "0.0.1", "archiveSHA256": String(repeating: "1", count: 64),
            "files": [["name": "python.exe", "bytes": bytes.count, "sha256": WindowsClaudeRuntimeStore.digest(bytes)]]], directory.appendingPathComponent(".pacer-owned.json"))
        return directory
    }
    func testGCProtectsOtherHomesForeignHooksAndSavedRenderers() throws {
        let fixture = try fixture(), runtime = WindowsClaudeHookRuntime(root: fixture.root), store = WindowsClaudeRuntimeStore(root: fixture.root)
        for home in fixture.homes { try write(original, home.appendingPathComponent("settings.json")); XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready") }
        let old = try oldVersion(fixture.root), pin = try WindowsPythonPin.load(), other = fixture.homes[1]
        var value = try read(other.appendingPathComponent("settings.json"))
        value["foreignHook"] = ["command": "\"" + old.appendingPathComponent("python.exe").path + "\" user-script.py"]
        try write(value, other.appendingPathComponent("settings.json"))
        try store.collect(keeping: pin.identifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "A foreign hook in another home protects its dependency")
        value.removeValue(forKey: "foreignHook"); try write(value, other.appendingPathComponent("settings.json"))
        let manifestURL = other.appendingPathComponent("pacer/installation.json")
        var manifest = try read(manifestURL)
        let before = manifest
        manifest["previousStatusLine"] = ["type": "command", "command": old.appendingPathComponent("python.exe").path + " user-renderer.py"]
        try write(manifest, manifestURL); try store.collect(keeping: pin.identifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "A saved renderer remains an active dependency of the wrapper")
        try write(before, manifestURL); try store.collect(keeping: pin.identifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(pin.identifier).path))
    }
    func testInvalidConfigurationAndForeignRuntimeAreNeverRemoved() throws {
        let fixture = try fixture(), home = fixture.homes[0], runtime = WindowsClaudeHookRuntime(root: fixture.root)
        let settings = home.appendingPathComponent("settings.json"), invalid = Data("invalid SYNTHETIC_PRIVATE_TOKEN".utf8)
        try invalid.write(to: settings)
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "failed")
        XCTAssertEqual(try Data(contentsOf: settings), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        try write(original, settings); XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        try invalid.write(to: settings)
        XCTAssertThrowsError(try runtime.uninstall(homes: [home], checkOnly: true))
        XCTAssertEqual(try Data(contentsOf: settings), invalid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
        try write(original, settings)
        let old = try oldVersion(fixture.root), extra = old.appendingPathComponent("user-file.txt")
        try Data("user bytes".utf8).write(to: extra)
        XCTAssertThrowsError(try WindowsClaudeRuntimeStore(root: fixture.root).collect(keeping: try WindowsPythonPin.load().identifier))
        XCTAssertEqual(try Data(contentsOf: extra), Data("user bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("python.exe").path))
        try FileManager.default.removeItem(at: extra)
        let binary = old.appendingPathComponent("python.exe"), changed = Data("user-modified binary".utf8)
        try changed.write(to: binary)
        let before = try Data(contentsOf: settings)
        XCTAssertThrowsError(try runtime.uninstall(homes: [home], checkOnly: true))
        XCTAssertEqual(try Data(contentsOf: binary), changed, "A marker alone cannot authorize deletion of modified content")
        XCTAssertEqual(try Data(contentsOf: settings), before, "Failed runtime preflight cannot remove the current hooks")
        try Data("synthetic runtime, never executed".utf8).write(to: binary)
        try invalid.write(to: fixture.homes[1].appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try WindowsClaudeRuntimeStore(root: fixture.root).collect(keeping: try WindowsPythonPin.load().identifier, extraHomes: fixture.homes))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "Invalid JSON in any scanned home must retain an apparently unreferenced version")
    }
    func testCommandOwnershipIsExactAndShellPathsAreQuoted() throws {
        let fixture = try fixture(), home = fixture.homes[0], pin = try WindowsPythonPin.load()
        let python = fixture.root.appendingPathComponent(pin.identifier + "/python.exe")
        let command = WindowsClaudeHookCommands.command(python: python, home: home, kind: .hook)
        XCTAssertTrue(command.contains("\"" + python.path + "\"")); XCTAssertTrue(command.hasSuffix("\"" + home.path + "\""))
        XCTAssertTrue(WindowsClaudeHookCommands.owned(command, home: home, root: fixture.root, kind: .hook))
        XCTAssertFalse(WindowsClaudeHookCommands.owned(command + " extra", home: home, root: fixture.root, kind: .hook))
        XCTAssertFalse(WindowsClaudeHookCommands.owned(command, home: fixture.homes[1], root: fixture.root, kind: .hook))
        XCTAssertFalse(WindowsClaudeHookCommands.owned(command, home: home, root: fixture.root, kind: .statusLine))
        XCTAssertFalse(WindowsClaudeHookCommands.owned(command.replacingOccurrences(of: pin.identifier, with: "../outside"), home: home, root: fixture.root, kind: .hook))
        XCTAssertFalse(WindowsClaudeRuntimeStore.validIdentifier(pin.identifier + "\n"))
        XCTAssertThrowsError(try WindowsClaudeHookCommands.validate(python: python, home: home.appendingPathComponent("unsafe%PATH%")))
    }
}
