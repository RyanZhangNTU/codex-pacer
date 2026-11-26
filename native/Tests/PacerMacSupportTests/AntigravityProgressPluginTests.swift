import Foundation
import XCTest
@testable import PacerCore
@testable import PacerMacSupport

final class AntigravityProgressPluginTests: XCTestCase {
    private typealias Setup = LocalHarnessProgressSetup
    private let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var config: URL { profile.appendingPathComponent(".gemini/config", isDirectory: true) }
    private var plugin: URL { config.appendingPathComponent("plugins/codex-pacer", isDirectory: true) }
    private var storage: MacProgressPluginStorage { .init(profile: profile) }
    private var queue = ProgressSetupQueue<LocalHarnessProgressSetup.Target>()

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: profile) }

    private func sync(module: Bool = true, ring: Bool = true, reporter: String = "/fixture/Pacer", reportAt: Date? = nil,
                      using override: (any ProgressPluginStorage)? = nil) async throws -> Setup.State? {
        let definition = AntigravityHarness.definition
        let dataHome = profile.appendingPathComponent("custom/activity")
        let target = try XCTUnwrap(definition.progressTarget(dataHome: dataHome, reporter: reporter, enabled: module && ring, userHome: profile))
        let ticket = try XCTUnwrap(queue.request(target, force: true))
        let result = await Setup.sync(ticket, storage: override ?? storage, reportAt: reportAt)
        XCTAssertTrue(queue.finish(ticket))
        XCTAssertFalse(storage.exists(dataHome))
        return result
    }
    func testInstallReinstallUpdateAndBothSwitches() async throws {
        let initial = try await sync()
        let added = try XCTUnwrap(initial?.addedAt)
        XCTAssertEqual(initial?.setup, .configured)
        XCTAssertEqual(try storage.names(in: plugin), ["rules", "plugin.json", "mcp_config.json"])
        XCTAssertEqual(try storage.read(plugin.appendingPathComponent("plugin.json")), AntigravityProgressPlugin.manifest)
        let rule = String(decoding: try storage.read(plugin.appendingPathComponent("rules/AGENTS.md")), as: UTF8.self)
        for literal in ["call_mcp_tool", "codex-pacer_pacer_progress", "report_progress", "{\"percent\": N}"] {
            XCTAssertTrue(rule.contains(literal))
        }
        let mcp = plugin.appendingPathComponent("mcp_config.json")
        let modified = try mcp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var value = try await sync(reportAt: added)
        XCTAssertEqual(value, initial)
        XCTAssertEqual(try mcp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        value = try await sync(reportAt: added.addingTimeInterval(1))
        XCTAssertEqual(value?.reported, true)
        value = try await sync(reporter: "/fixture/NewPacer")
        XCTAssertEqual(value?.reported, false)
        let expected = ["mcpServers": ["pacer_progress": ["command": "/fixture/NewPacer",
            "args": ["--task-progress-mcp", "--pacer-progress-flag", Setup.flag(config).path]]]]
        XCTAssertEqual(try JSONSerialization.jsonObject(with: storage.read(mcp)) as? NSDictionary, expected as NSDictionary)
        let sibling = config.appendingPathComponent("plugins/my-plugin")
        try storage.createDirectory(sibling, permissions: 0o700)
        for (module, ring) in [(true, false), (false, true)] {
            value = try await sync(module: module, ring: ring)
            XCTAssertNil(value)
            XCTAssertFalse(storage.exists(plugin)); XCTAssertFalse(storage.exists(Setup.flag(config)))
            XCTAssertTrue(storage.exists(sibling))
            value = try await sync()
            XCTAssertEqual(value?.reported, false)
        }
        XCTAssertFalse(storage.exists(config.appendingPathComponent("mcp_config.json")))
    }

    func testForeignModifiedAndLinkedFilesRemainUntouched() async throws {
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let manifest = plugin.appendingPathComponent("plugin.json")
        try Data("foreign".utf8).write(to: manifest)
        var value = try await sync()
        XCTAssertEqual(value?.setup, .conflict)
        XCTAssertEqual(try Data(contentsOf: manifest), Data("foreign".utf8))
        try FileManager.default.removeItem(at: plugin)
        _ = try await sync()
        let rule = plugin.appendingPathComponent("rules/AGENTS.md")
        try Data("edited".utf8).write(to: rule)
        value = try await sync()
        XCTAssertEqual(value?.setup, .conflict)
        XCTAssertFalse(storage.exists(Setup.flag(config)))
        value = try await sync(module: false)
        XCTAssertEqual(value?.setup, .conflict)
        XCTAssertEqual(try Data(contentsOf: rule), Data("edited".utf8))
        let outside = profile.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: rule)
        try FileManager.default.linkItem(at: outside, to: rule)
        value = try await sync()
        XCTAssertEqual(value?.setup, .conflict)
        try FileManager.default.removeItem(at: rule)
        try FileManager.default.createSymbolicLink(at: rule, withDestinationURL: outside)
        value = try await sync(module: false)
        XCTAssertEqual(value?.setup, .conflict)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rule.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }

    func testPluginDisabledInAntigravityRevokesReporterWithoutEditingSettings() async throws {
        _ = try await sync()
        let settings = config.appendingPathComponent("config.json")
        let contents = Data(#"{"plugins":{"codex-pacer":{"enabled":false},"user":{"enabled":true}},"other":"unrelated"}"#.utf8)
        try contents.write(to: settings)
        let target = Setup.Target(pluginProfile: profile, reporter: "/fixture/Pacer", enabled: true)
        XCTAssertEqual(Setup.apply(target, storage: storage, checkOnly: true), .configured)
        XCTAssertTrue(storage.exists(Setup.flag(config)), "A preflight only inspects the flag")
        var value = try await sync()
        XCTAssertEqual(value?.connection, .disabled)
        XCTAssertEqual(try storage.read(settings), contents)
        XCTAssertFalse(storage.exists(Setup.flag(config)))
        XCTAssertTrue(storage.exists(plugin))
        XCTAssertFalse(MacProgressPluginStorage.flagEnabled(Setup.flag(config)))
        try Data(#"{"plugins":{"codex-pacer":{"enabled":true}}}"#.utf8).write(to: settings)
        value = try await sync()
        XCTAssertEqual(value?.setup, .configured)
        XCTAssertTrue(storage.exists(Setup.flag(config)))
    }

    func testPreparedReporterOwnershipAndStandaloneUninstall() async throws {
        let target = Setup.Target(pluginProfile: profile, reporter: "/fixture/Pacer", enabled: true)
        let command = CodexProgressCommand(executable: URL(fileURLWithPath: "/fixture/runtime/python"),
            arguments: ["-I", "-S", "/fixture/progress.py", Setup.managedArgument, Setup.flag(config).path])
        func install(owned: Bool) async throws -> Setup.State? {
            let ticket = try XCTUnwrap(queue.request(target, force: true))
            let state = await Setup.sync(ticket, storage: storage, prepare: { _ in command },
                                         owns: { path, args, _ in owned && path == command.executable && args == command.arguments })
            XCTAssertTrue(queue.finish(ticket))
            return state
        }
        var state = try await install(owned: false)
        XCTAssertEqual(state?.setup, .failed); XCTAssertFalse(storage.exists(plugin))
        state = try await install(owned: true)
        XCTAssertEqual(state?.setup, .configured)
        let off = Setup.Target(pluginProfile: profile, reporter: "/fixture/Pacer", enabled: false)
        XCTAssertNil(Setup.apply(off, storage: storage, matchNativeReporter: true))
        XCTAssertTrue(storage.exists(plugin), "Another installation's uninstaller leaves the plugin in place")
        XCTAssertNil(Setup.apply(off, storage: storage, checkOnly: true, matchNativeReporter: true,
                                owns: { path, args, _ in path == command.executable && args == command.arguments }))
        XCTAssertTrue(storage.exists(plugin))
        XCTAssertNil(Setup.apply(off, storage: storage, matchNativeReporter: true,
                                owns: { path, args, _ in path == command.executable && args == command.arguments }))
        XCTAssertFalse(storage.exists(plugin))
    }

    func testLockedPluginRemovalIsRetriedAfterReporterIsRevoked() async throws {
        _ = try await sync()
        let locked = LockedDirectory(base: storage, locked: plugin)
        var value = try await sync(ring: false, using: locked)
        XCTAssertEqual(value?.setup, .removalPending)
        XCTAssertFalse(storage.exists(Setup.flag(config)))
        XCTAssertTrue(storage.exists(plugin))
        value = try await sync(ring: false)
        XCTAssertNil(value)
        XCTAssertFalse(storage.exists(plugin))
        XCTAssertFalse(storage.exists(Setup.flag(config).deletingLastPathComponent()))
    }

    private struct LockedDirectory: ProgressPluginStorage {
        let base: MacProgressPluginStorage
        let locked: URL
        func validate(_ url: URL) throws { try base.validate(url) }
        func exists(_ url: URL) -> Bool { base.exists(url) }
        func isDirectory(_ url: URL) -> Bool { base.isDirectory(url) }
        func isReadable(_ url: URL) -> Bool { base.isReadable(url) }
        func read(_ url: URL) throws -> Data { try base.read(url) }
        func createDirectory(_ url: URL, permissions: UInt16) throws { try base.createDirectory(url, permissions: permissions) }
        func replace(_ url: URL, with data: Data, permissions: UInt16) throws { try base.replace(url, with: data, permissions: permissions) }
        func remove(_ url: URL) throws { try base.remove(url) }
        func names(in directory: URL) throws -> Set<String> { try base.names(in: directory) }
        func removeEmptyDirectory(_ directory: URL) throws {
            if directory.path == locked.path { throw ProgressPluginRemovalError.inUse }
            try base.removeEmptyDirectory(directory)
        }
    }
}
