#if os(Windows)
import Foundation
import PacerCore
import WinSDK

struct WindowsDurableProgressMailbox {
    static let owner = Data("codex-pacer-durable-progress-v1\n".utf8)
    let home: URL
    private let storage = WindowsLocalProfileStorage()
    var root: URL { home.appendingPathComponent("pacer/codex-progress/durable-marketplace", isDirectory: true) }
    var marker: URL { root.appendingPathComponent(".pacer-owner") }
    private var directory: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    private var lock: URL { directory.appendingPathComponent("write.lock") }
    private var snapshot: URL { directory.appendingPathComponent("latest.json") }

    func validateOwner() throws {
        for path in [home, home.appendingPathComponent("pacer"), root.deletingLastPathComponent(), root, marker] {
            try storage.validate(path)
        }
        guard try storage.read(marker) == Self.owner else { throw ClaudeHookInstaller.Failure.unsafePath }
    }

    func prepare() throws {
        try validateOwner()
        try storage.validate(directory)
        if !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
        try storage.validate(lock)
        if !storage.exists(lock) { try storage.replace(lock, with: Data([0]), permissions: 0o600) }
    }

    func read(at now: Date) -> [String: DurableProgressReceipt] {
        guard (try? validateOwner()) != nil, (try? storage.validate(directory)) != nil,
              (try? storage.validate(snapshot)) != nil,
              let data = try? WindowsFileSystem().read(snapshot, offset: 0, maximumBytes: 64 * 1024 + 1),
              data.count <= 64 * 1024,
              let values = try? JSONDecoder().decode([String: DurableProgressReceipt].self, from: data),
              values.count <= 64 else { return [:] }
        return values.filter { $0.key == $0.value.threadID + ":" + $0.value.turnID && $0.value.isRecent(at: now) }
    }

    func removeFiles(checkOnly: Bool) throws {
        try validateOwner()
        try storage.validate(directory)
        for file in [snapshot, lock] {
            try storage.validate(file)
            if storage.exists(file) {
                guard !storage.isDirectory(file) else { throw ClaudeHookInstaller.Failure.unsafePath }
                if !checkOnly { try storage.remove(file) }
            }
        }
        if !checkOnly, storage.exists(directory) { _ = RemoveDirectoryW(WindowsLocalProfileStorage.wide(directory)) }
    }
}

/// The same switch revokes the CLI and Durable reporters. The private
/// marketplace is loaded on the next executor registration.
package enum WindowsDurableProgressSetup {
    private static let market = "codex-pacer-local"
    private static let plugin = "pacer-progress"
    private static let version = "1.0.0"

    package static func wasConfigured(in home: URL) -> Bool {
        (try? WindowsDurableProgressMailbox(home: home).validateOwner()) != nil
    }

    package static func apply(home: URL, reporter: CodexProgressCommand?, checkOnly: Bool = false, fallbackExecutable: String = "") async -> Bool {
        if reporter != nil, !WindowsActivityNavigation.isDefaultProfile(home, provider: .codex) { return true }
        if reporter == nil, !WindowsLocalProfileStorage().exists(WindowsDurableProgressMailbox(home: home).marker) { return true }
        let installed = WindowsCodexExecutableDiscovery.packageLocations().prefix(12).lazy.compactMap(WindowsDurableExecutor.cli(in:)).first
        let cli = installed ?? (reporter == nil ? CodexClient.findExecutable(customPath: fallbackExecutable) : nil)
        return await apply(home: home, reporter: reporter, cli: cli, checkOnly: checkOnly)
    }

    static func apply(home: URL, reporter: CodexProgressCommand?, cli: URL?, checkOnly: Bool = false) async -> Bool {
        let storage = WindowsLocalProfileStorage(), mailbox = WindowsDurableProgressMailbox(home: home)
        let root = mailbox.root, config = home.appendingPathComponent("config.toml")
        let enabled = reporter != nil
        if !enabled, !storage.exists(mailbox.marker) { return true }
        if enabled, cli == nil { return !storage.exists(mailbox.marker) }
        let marketDir = root.appendingPathComponent(".agents/plugins", isDirectory: true)
        let pluginDir = root.appendingPathComponent("plugins/" + plugin, isDirectory: true)
        let metadata = pluginDir.appendingPathComponent(".codex-plugin", isDirectory: true)
        let marketFile = marketDir.appendingPathComponent("marketplace.json")
        let pluginFile = metadata.appendingPathComponent("plugin.json")
        let mcp = pluginDir.appendingPathComponent(".mcp.json")
        let dirs = [marketDir.deletingLastPathComponent(), marketDir, pluginDir.deletingLastPathComponent(), pluginDir, metadata]
        let files = [marketFile, pluginFile, mcp]
        do {
            for path in [home, config, root, mailbox.marker] + dirs + files { try storage.validate(path) }
            if storage.exists(root) { try mailbox.validateOwner() }
            if !enabled { try mailbox.removeFiles(checkOnly: true) }
            var matches = false
            if let reporter, !checkOnly {
                try Task.checkCancellation()
                if !storage.exists(root) {
                    try storage.createDirectory(root, permissions: 0o700)
                    try storage.replace(mailbox.marker, with: WindowsDurableProgressMailbox.owner, permissions: 0o600)
                }
                for dir in dirs where !storage.exists(dir) { try storage.createDirectory(dir, permissions: 0o700) }
                try mailbox.prepare()
                let command = CodexProgressCommand(executable: URL(fileURLWithPath: reporter.executable),
                    arguments: reporter.arguments + [CodexProgressReporter.durableArgument])
                let manifest = try write(["mcpServers": ["pacer_progress": command.value]], to: mcp, storage: storage)
                try write(["name": plugin, "version": version, "description": "Report task progress to Codex Pacer.",
                           "mcpServers": "./.mcp.json"], to: pluginFile, storage: storage)
                try write(["name": market, "interface": ["displayName": "Codex Pacer (local)"],
                           "plugins": [["name": plugin, "source": ["source": "local", "path": "./plugins/" + plugin],
                                        "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"]]]], to: marketFile, storage: storage)
                let cache = home.appendingPathComponent("plugins/cache/\(market)/\(plugin)/\(version)/.mcp.json")
                try storage.validate(cache)
                matches = (try? storage.read(cache)) == manifest
            }
            var removeSource = !enabled
            if enabled || storage.exists(config) {
                guard let cli else { return false }
                let client = CodexClient(executable: cli, home: home, timeout: 3)
                do {
                    _ = try await client.setDurableProgressPlugin(market: market, plugin: plugin, source: root,
                        enabled: enabled, cachedManifestMatches: matches, checkOnly: checkOnly, pathsMatch: samePath)
                } catch CodexClientError.server("marketplace/add", -32601, _) where enabled {
                    // This CLI cannot add the marketplace. Keep the ordinary reporter.
                    removeSource = true
                } catch {
                    await client.shutdown()
                    throw error
                }
                await client.shutdown()
            }
            if removeSource, !checkOnly {
                try mailbox.removeFiles(checkOnly: false)
                for file in files where storage.exists(file) { try storage.remove(file) }
                for dir in dirs.reversed() { _ = RemoveDirectoryW(WindowsLocalProfileStorage.wide(dir)) }
                try storage.remove(mailbox.marker)
                _ = RemoveDirectoryW(WindowsLocalProfileStorage.wide(root))
            }
            return true
        } catch { return false }
    }

    @discardableResult
    private static func write(_ value: [String: Any], to file: URL, storage: WindowsLocalProfileStorage) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if (try? storage.read(file)) != bytes { try storage.replace(file, with: bytes, permissions: 0o600) }
        return bytes
    }

    private static func samePath(_ value: String, _ expected: URL) -> Bool {
        let path = value.hasPrefix(#"\\?\"#) ? String(value.dropFirst(4)) : value
        guard WindowsCodexExecutableDiscovery.absolute(path) else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path.caseInsensitiveCompare(expected.standardizedFileURL.path) == .orderedSame
    }
}
#endif
