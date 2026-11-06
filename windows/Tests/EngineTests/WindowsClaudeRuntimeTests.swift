import Foundation
import XCTest
import PacerCore
import WinSDK
@testable import WindowsInstallerSupport

final class WindowsClaudeRuntimeTests: XCTestCase {
    func testOwnerPolicyRequiresElevatedEnabledAdministratorsAndRejectsOtherOwners() throws {
        func sid(_ kind: WELL_KNOWN_SID_TYPE) throws -> UnsafeMutableRawPointer {
            let value = UnsafeMutableRawPointer.allocate(byteCount: 68, alignment: MemoryLayout<UInt64>.alignment)
            var size: DWORD = 68
            guard CreateWellKnownSid(kind, nil, value, &size) else { value.deallocate(); throw ClaudeHookInstaller.Failure.unsafePath }
            addTeardownBlock { value.deallocate() }
            return value
        }
        let user = try sid(WinLocalSystemSid), admin = try sid(WinBuiltinAdministratorsSid), other = try sid(WinWorldSid)
        for elevated in [false, true] {
            for enabled in [false, true] {
                XCTAssertTrue(WindowsClaudeFileOwner.allows(user, user: user, administrators: admin, elevated: elevated, administratorsEnabled: enabled))
                XCTAssertEqual(WindowsClaudeFileOwner.allows(admin, user: user, administrators: admin, elevated: elevated, administratorsEnabled: enabled), elevated && enabled)
                XCTAssertFalse(WindowsClaudeFileOwner.allows(other, user: user, administrators: admin, elevated: elevated, administratorsEnabled: enabled), "Another owner stays foreign even for an elevated administrator")
            }
        }
    }
    private func fixture(aliasAncestors: Bool = false) throws -> (base: URL, root: URL, homes: [URL]) {
        let originalTemporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let temporary = aliasAncestors ? WindowsClaudeHookCommands.shortPath(originalTemporary).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? originalTemporary : originalTemporary
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
            if let short = WindowsClaudeHookCommands.shortPath(directory.appendingPathComponent("python.exe")),
               WindowsClaudeHookCommands.selection(WindowsClaudeHookCommands.arguments(python: directory.appendingPathComponent("python.exe"), home: home, kind: .hook)).mode == "shortPath" {
                XCTAssertTrue(try command(home).hasPrefix(short + " -S "))
            } else { XCTAssertTrue(try command(home).contains(fixture.root.path + "/" + pin.identifier + "/python.exe")) }
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
        XCTAssertEqual(try command(home), WindowsClaudeHookCommands.command(python: fixture.root.appendingPathComponent(try WindowsPythonPin.load().identifier + "/python.exe"), home: home, kind: .hook))
        XCTAssertFalse(try command(home).hasPrefix("python3"))
        let pin = try WindowsPythonPin.load()
        let old = fixture.root.appendingPathComponent("0.0.1-111111111111/python.exe")
        var value = try read(home.appendingPathComponent("settings.json"))
        let current = try command(home), prior = WindowsClaudeHookCommands.legacySerialize(WindowsClaudeHookCommands.arguments(python: old, home: home, kind: .hook))
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
        var line = try XCTUnwrap(value["statusLine"] as? [String: Any]); line["command"] = WindowsClaudeHookCommands.legacySerialize(WindowsClaudeHookCommands.arguments(python: old, home: home, kind: .statusLine)); value["statusLine"] = line
        try write(value, home.appendingPathComponent("settings.json"))
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        if runtime.inspect(home: home).launchMode == "shortPath" {
            XCTAssertEqual(try command(home), WindowsClaudeHookCommands.command(python: fixture.root.appendingPathComponent(pin.identifier + "/python.exe"), home: home, kind: .hook))
        } else { XCTAssertTrue(try command(home).contains(pin.identifier)) }
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
        if let short = WindowsClaudeHookCommands.shortPath(old.appendingPathComponent("python.exe")) {
            value["foreignHook"] = ["command": short + " user-script.py"]
            try write(value, other.appendingPathComponent("settings.json")); try store.collect(keeping: pin.identifier)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "An 8.3 reference in another home protects the same runtime")
            value["foreignHook"] = ["command": short.replacingOccurrences(of: "/", with: "\\") + " user-script.py"]
            try write(value, other.appendingPathComponent("settings.json")); try store.collect(keeping: pin.identifier)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "A backslash 8.3 reference must also retain its runtime")
        }
        value.removeValue(forKey: "foreignHook"); try write(value, other.appendingPathComponent("settings.json"))
        let manifestURL = other.appendingPathComponent("pacer/installation.json")
        var manifest = try read(manifestURL)
        let before = manifest
        manifest["previousStatusLine"] = ["type": "command", "command": old.appendingPathComponent("python.exe").path + " user-renderer.py"]
        try write(manifest, manifestURL); try store.collect(keeping: pin.identifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "A saved renderer remains an active dependency of the wrapper")
        if let short = WindowsClaudeHookCommands.shortPath(old.appendingPathComponent("python.exe")) {
            manifest["previousStatusLine"] = ["type": "command", "command": short + " user-renderer.py"]
            try write(manifest, manifestURL); try store.collect(keeping: pin.identifier)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "A saved renderer's 8.3 dependency cannot be collected")
        }
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
    func testOwnerChecksAndRuntimeCleanupAcceptLongLocalPaths() throws {
        let fixture = try fixture()
        var directory = fixture.base
        for index in 0..<10 { directory.appendPathComponent("长路径 空格 segment-\(index)") }
        let home = directory.appendingPathComponent("Claude home")
        let root = directory.appendingPathComponent("Local/CodexPacer/ClaudeRuntime")
        XCTAssertGreaterThan(home.path.utf16.count, 260)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write(original, home.appendingPathComponent("settings.json"))
        let runtime = WindowsClaudeHookRuntime(root: root)
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        if runtime.inspect(home: home).launchMode == "shortPath" {
            XCTAssertTrue(try command(home).hasPrefix(try XCTUnwrap(WindowsClaudeHookCommands.shortPath(root)) + "/"))
        } else { XCTAssertTrue(try command(home).contains(root.path)) }
        try runtime.uninstall(homes: [home], checkOnly: true)
        try runtime.uninstall(homes: [home])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: try read(home.appendingPathComponent("settings.json"))))
    }
    func testLaunchSelectionPrefersDirectThenShortPathsThenPowerShell() throws {
        let python = URL(fileURLWithPath: "C:/Pacer/3.14.10-90905e64a840/python.exe"), home = URL(fileURLWithPath: "C:/Claude/中文")
        let values = WindowsClaudeHookCommands.arguments(python: python, home: home, kind: .hook)
        let direct = WindowsClaudeHookCommands.selection(values, shorten: { _ in XCTFail("Safe paths need no filesystem lookup"); return nil })
        XCTAssertEqual(direct.mode, "direct"); XCTAssertEqual(direct.command, values.joined(separator: " "))
        let spaced = URL(fileURLWithPath: "C:/Claude Home/用户")
        let arguments = WindowsClaudeHookCommands.arguments(python: python, home: spaced, kind: .hook)
        let short = WindowsClaudeHookCommands.selection(arguments, shorten: { $0 == python ? "C:/PACER/31410~1/python.exe" : "C:/CLAUDE~1/用户" })
        XCTAssertEqual(short.mode, "shortPath")
        XCTAssertEqual(short.command, "C:/PACER/31410~1/python.exe -S C:/CLAUDE~1/用户/pacer/hook.py hook C:/CLAUDE~1/用户")
        let fallback = WindowsClaudeHookCommands.selection(arguments, shorten: { _ in nil })
        XCTAssertEqual(fallback.mode, "powershell")
        XCTAssertTrue(fallback.command.hasPrefix(WindowsClaudeHookCommands.powershellPrefix))
        XCTAssertTrue(fallback.command.contains("\"" + python.path + "\"")); XCTAssertTrue(fallback.command.hasSuffix("\"" + spaced.path + "\""))
        XCTAssertFalse(fallback.command.contains("/D/C"))
        XCTAssertEqual(WindowsClaudeHookCommands.selection(arguments, shorten: { $0.path }).mode, "powershell", "A volume returning its unchanged long name has no usable short path")
        for unsafe in ["C:/Claude space", "C:/Claude&other", "C:/Claude(test)", "C:/Claude'quote", "C:/Claude;other", "C:/Claude[other]"] {
            XCTAssertFalse(WindowsClaudeHookCommands.directSafe(unsafe))
        }
    }
    func testEveryOwnedWindowsFormMigratesAndUninstallsExactly() throws {
        let fixture = try fixture(aliasAncestors: true), home = fixture.homes[0], runtime = WindowsClaudeHookRuntime(root: fixture.root)
        try write(original, home.appendingPathComponent("settings.json"))
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        let python = fixture.root.appendingPathComponent(try WindowsPythonPin.load().identifier + "/python.exe")
        for site in [false, true] {
            for kind in [ClaudeHookInstaller.CommandKind.hook, .statusLine] {
                let values = WindowsClaudeHookCommands.arguments(python: python, home: home, kind: kind, site: site)
                for (index, command) in [WindowsClaudeHookCommands.serialize(values), WindowsClaudeHookCommands.legacySerialize(values), WindowsClaudeHookCommands.fallback(values)].enumerated() {
                    XCTAssertTrue(WindowsClaudeHookCommands.owned(command, home: home, root: fixture.root, kind: kind), "Owned form \(index), kind \(kind), site \(site), including a short ancestor")
                    XCTAssertFalse(WindowsClaudeHookCommands.owned(command + " extra", home: home, root: fixture.root, kind: kind))
                    XCTAssertFalse(WindowsClaudeHookCommands.owned(command, home: fixture.homes[1], root: fixture.root, kind: kind))
                }
            }
        }
        // The slow form can become stale when a usable short name appears.
        var value = try read(home.appendingPathComponent("settings.json"))
        let current = try command(home)
        var hooks = try XCTUnwrap(value["hooks"] as? [String: [[String: Any]]])
        for event in hooks.keys { hooks[event] = hooks[event]?.map { group in
            var group = group
            group["hooks"] = (group["hooks"] as? [[String: Any]])?.map { entry in
                var entry = entry
                if entry["command"] as? String == current { entry["command"] = WindowsClaudeHookCommands.fallback(WindowsClaudeHookCommands.arguments(python: python, home: home, kind: .hook)) }
                return entry
            }; return group
        } }
        value["hooks"] = hooks
        var line = try XCTUnwrap(value["statusLine"] as? [String: Any])
        line["command"] = WindowsClaudeHookCommands.fallback(WindowsClaudeHookCommands.arguments(python: python, home: home, kind: .statusLine)); value["statusLine"] = line
        try write(value, home.appendingPathComponent("settings.json"))
        XCTAssertEqual(runtime.ensure(home: home, package: try package).state, "ready")
        XCTAssertEqual(try command(home), current)
        try runtime.uninstall(homes: [home])
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: try read(home.appendingPathComponent("settings.json"))))
    }
    func testProgressRingHookAsksForTheMarkerAndHidesItOnScreen() throws {
        let home = try fixture().homes[0], python = try package.appendingPathComponent("python.exe"), pacer = home.appendingPathComponent("pacer")
        try FileManager.default.createDirectory(at: pacer, withIntermediateDirectories: true)
        let hook = pacer.appendingPathComponent("hook.py"); try WindowsClaudeHookRuntime.script().write(to: hook)
        func run(_ event: [String: Any], entrypoint: String? = nil) throws -> String {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = python; process.arguments = ["-S", hook.path, "hook", home.path]
            var environment = ProcessInfo.processInfo.environment.filter { $0.key.uppercased() != "CLAUDE_CODE_ENTRYPOINT" }
            if let entrypoint { environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint }
            process.environment = environment
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event)); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self)
        }
        func shown(_ text: String) throws -> String? {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return (value["hookSpecificOutput"] as? [String: Any])?["displayContent"] as? String
        }
        let open = "\u{27E6}", close = "\u{27E7}"
        let prompt: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "synthetic-ring-session", "prompt_id": "synthetic-prompt", "prompt": "PRIVATE"]
        XCTAssertEqual(try run(prompt), "", "The ring stays off until its switch file exists")
        try Data("on\n".utf8).write(to: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertTrue(try run(prompt).contains("additionalContext"))
        func message(_ index: Int, _ delta: String, agent: String? = nil) -> [String: Any] {
            var value = prompt.merging(["hook_event_name": "MessageDisplay", "turn_id": "turn", "message_id": "message", "final": false, "index": index, "delta": delta]) { _, new in new }
            if let agent { value["agent_id"] = agent }
            return value
        }
        // Claude shows displayContent in place of the lines; its stored message keeps the marker.
        XCTAssertEqual(try shown(run(message(0, open + "62%" + close + " Reading the docs next.\n"))), "Reading the docs next.\n")
        XCTAssertEqual(try shown(run(message(0, open + "63%" + close + "\n\n## Next\n"))), "## Next\n")
        for unchanged in [message(1, open + "70%" + close + " later\n"), message(0, "No marker\n"),
                          message(0, open + "120%" + close + " x\n"), message(0, open + "50%" + close + " x\n", agent: "child")] {
            XCTAssertEqual(try run(unchanged), "", "Only a valid leading marker of a main-thread message is hidden")
        }
        // "tool" in the switch asks for the report_progress tool of Pacer's plugin, but only a
        // session that started with the plugin enabled has it; its input is read before the call runs.
        try Data("tool\n".utf8).write(to: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertEqual(try run(prompt), "", "A session without the plugin is never asked to call it")
        let start: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "synthetic-ring-session", "source": "startup"]
        XCTAssertEqual(try run(start), "")
        XCTAssertEqual(try run(prompt), "", "A session that started before the plugin was enabled still lacks it")
        try JSONSerialization.data(withJSONObject: ["enabledPlugins": ["pacer@pacer": true]]).write(to: home.appendingPathComponent("settings.json"))
        // Claude Desktop adds a newly enabled plugin to running sessions; other clients wait for a new session.
        let running = prompt.merging(["session_id": "synthetic-running-session"]) { _, new in new }
        XCTAssertEqual(try run(running), "")
        XCTAssertTrue(try run(running, entrypoint: "claude-desktop").contains(ClaudeHookInstaller.progressTool))
        XCTAssertEqual(try run(start), "")
        XCTAssertTrue(try run(prompt).contains(ClaudeHookInstaller.progressTool))
        XCTAssertFalse(try run(prompt).contains("points or more"), "Without a step, every batch reports")
        try Data("tool 15\n".utf8).write(to: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertTrue(try run(prompt).contains("moves 15 points or more"))
        try Data("tool progress\n".utf8).write(to: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertTrue(try run(prompt).contains("whenever you make progress"))
        try Data("tool 99\n".utf8).write(to: ClaudeProgressRingSwitch.flagURL(home: home))
        XCTAssertFalse(try run(prompt).contains("points or more"), "A step outside 1-50 falls back to every batch")
        func report(_ input: [String: Any], _ id: String, tool: String = "mcp__pacer__report_progress", agent: String? = nil) -> [String: Any] {
            var value = prompt.merging(["hook_event_name": "PreToolUse", "tool_name": tool, "tool_use_id": id, "tool_input": input]) { _, new in new }
            if let agent { value["agent_id"] = agent }
            return value
        }
        for event in [report(["percent": 55], "toolu_a"), report(["percent": true], "toolu_b"), report(["percent": 101], "toolu_c"),
                      report(["percent": 70], "toolu_d", tool: "Read"), report(["percent": 80], "toolu_e", agent: "child")] {
            XCTAssertEqual(try run(event), "", "A tool call never changes Claude's decision")
        }
        // A woken turn continues the typed request: no second line, and its prompt row says so.
        let wake = prompt.merging(["prompt_id": "woken-prompt", "prompt": "<task-notification>\n<task-id>x</task-id>"]) { _, new in new }
        XCTAssertEqual(try run(wake), "")
        // Stop: background work makes the turn wait; otherwise a final estimate is asked for once.
        let stop: [String: Any] = ["hook_event_name": "Stop", "session_id": "synthetic-ring-session", "prompt_id": "synthetic-prompt",
                                   "stop_hook_active": false, "session_crons": [],
                                   "background_tasks": [["id": "b1", "type": "shell", "status": "running", "description": "PRIVATE"]]]
        XCTAssertEqual(try run(stop), "", "Waiting for background work never blocks the stop")
        var unnamed = stop; unnamed["background_tasks"] = [["id": "b2", "type": "local_powershell", "status": "running", "description": "PRIVATE"]]
        XCTAssertEqual(try run(unnamed), "", "A task kind Claude Code has no label for still counts as work")
        var idle = stop; idle["background_tasks"] = [["id": "m1", "type": "monitor", "status": "running", "description": "PRIVATE"]]
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try run(idle).utf8)) as? [String: Any])
        XCTAssertEqual(block["decision"] as? String, "block")
        XCTAssertTrue((block["reason"] as? String)?.contains("final progress estimate") == true)
        let reason = try XCTUnwrap(block["reason"] as? String)
        XCTAssertTrue(reason.contains("one call to " + ClaudeHookInstaller.progressTool), "One report ends the request; the tool only acknowledges it")
        XCTAssertTrue(reason.hasSuffix("Once it returns, end your turn without writing anything."), "Only the number comes back, without a closing message")
        var again = idle; again["stop_hook_active"] = true
        XCTAssertEqual(try run(again), "", "The stop hook's own continuation is never blocked")
        XCTAssertEqual(try run(idle), "", "A request is asked once")
        let all = try String(contentsOf: pacer.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let rows = all.filter { $0["kind"] as? String == "progress" }
        XCTAssertEqual(rows.compactMap { $0["progress"] as? Int }, [62, 63, 55])
        XCTAssertEqual(all.first { $0["promptId"] as? String == "woken-prompt" && $0["kind"] as? String == "prompt" }?["wake"] as? Bool, true)
        XCTAssertEqual(all.filter { $0["kind"] as? String == "waiting" }.compactMap { $0["background"] as? [String] }, [["shell"], ["local_powershell"]])
        XCTAssertFalse(all.contains { String(describing: $0).contains("PRIVATE") && $0["kind"] as? String != "prompt" })
    }
}
