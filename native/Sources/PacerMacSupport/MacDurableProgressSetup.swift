import Darwin
import Foundation
import PacerCore

/// The native progress switch owns this local marketplace. Durable and local
/// sessions use the same reporter and immediate revocation flag.
public enum MacDurableProgressSetup {
    private static let market = "codex-pacer-local"
    private static let plugin = "pacer-progress"
    private static let version = "1.0.0"
    private static let marker = Data("codex-pacer-durable-progress-v1\n".utf8)
    private enum Result { case unchanged, changed, failed }

    public static func apply(home: URL, reporter: URL?, customExecutable: String) async -> Bool {
        let home = home.standardizedFileURL
        await MacDurableRefresh.shared.begin(home: home)
        let result = await reconcile(home: home, reporter: reporter, customExecutable: customExecutable)
        let recorded = await MacDurableRefresh.shared.finish(home: home, changed: result == .changed)
        return recorded && result != .failed
    }

    private static func reconcile(home: URL, reporter: URL?, customExecutable: String) async -> Result {
        let storage = MacClaudeHookStorage()
        let pacer = home.appendingPathComponent("pacer", isDirectory: true)
        let progress = pacer.appendingPathComponent("codex-progress", isDirectory: true)
        let root = progress.appendingPathComponent("durable-marketplace", isDirectory: true)
        let owner = root.appendingPathComponent(".pacer-owner")
        let config = home.appendingPathComponent("config.toml")
        if reporter == nil, !storage.exists(root) { return .unchanged }
        let application = desktopExecutor(home: home)?.application ?? CodexApplicationResolver.find()
        let executable: URL?
        if let application {
            executable = MacDurableExecutor.verifiedCLI(in: application)
        } else {
            executable = reporter == nil ? CodexClient.findExecutable(customPath: customExecutable) : nil
        }
        guard let executable else { return reporter != nil || !storage.exists(owner) ? .unchanged : .failed }
        do {
            for path in [home, config, pacer, progress, root, owner] { try storage.validate(path) }
            if storage.exists(root) {
                guard try storage.read(owner) == marker else { return .failed }
            } else if reporter == nil { return .unchanged }
            let marketDirectory = root.appendingPathComponent(".agents/plugins", isDirectory: true)
            let pluginDirectory = root.appendingPathComponent("plugins/" + plugin, isDirectory: true)
            let metadata = pluginDirectory.appendingPathComponent(".codex-plugin", isDirectory: true)
            let marketFile = marketDirectory.appendingPathComponent("marketplace.json")
            let pluginFile = metadata.appendingPathComponent("plugin.json")
            let mcp = pluginDirectory.appendingPathComponent(".mcp.json")
            let mailbox = MacDurableProgressMailbox(home: home)
            let directories = [marketDirectory.deletingLastPathComponent(), marketDirectory, pluginDirectory.deletingLastPathComponent(), pluginDirectory, metadata]
            for path in directories + [marketFile, pluginFile, mcp] { try storage.validate(path) }
            var matches = false
            if let reporter {
                if !storage.exists(root) {
                    try storage.createDirectory(root, permissions: 0o700)
                    try storage.replace(owner, with: marker, permissions: 0o600)
                }
                for directory in directories where !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
                try mailbox.prepare()
                let tool = CodexProgressCommand.durable(executable: reporter, home: home)
                let server = try JSONSerialization.data(withJSONObject: ["mcpServers": ["pacer_progress": tool.value]], options: [.sortedKeys])
                try write(server, to: mcp, storage: storage)
                try write(JSONSerialization.data(withJSONObject: [
                    "name": plugin, "version": version, "description": "Progress reporting for Codex Pacer.", "mcpServers": "./.mcp.json"
                ], options: [.sortedKeys]), to: pluginFile, storage: storage)
                try write(JSONSerialization.data(withJSONObject: [
                    "name": market, "interface": ["displayName": "Codex Pacer (local)"],
                    "plugins": [["name": plugin, "source": ["source": "local", "path": "./plugins/" + plugin],
                                 "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"]]]
                ], options: [.sortedKeys]), to: marketFile, storage: storage)
                let cache = home.appendingPathComponent("plugins/cache/\(market)/\(plugin)/\(version)/.mcp.json")
                try storage.validate(cache)
                matches = (try? storage.read(cache)) == server
            }
            let client = CodexClient(executable: executable, home: home, timeout: 8)
            let changed: Bool
            do {
                changed = try await client.setDurableProgressPlugin(market: market, plugin: plugin, source: root,
                                                                     enabled: reporter != nil, cachedManifestMatches: matches)
            } catch CodexClientError.server(_, -32601, _) {
                await client.shutdown()
                return .unchanged
            } catch {
                await client.shutdown()
                return .failed
            }
            await client.shutdown()
            if reporter == nil {
                try mailbox.discard()
                for path in [marketFile, pluginFile, mcp, owner] where storage.exists(path) {
                    try storage.validate(path); try storage.remove(path)
                }
                for directory in directories.reversed() { _ = rmdir(directory.path) }
                _ = rmdir(root.path)
            }
            return changed ? .changed : .unchanged
        } catch { return .failed }
    }

    private static func write(_ bytes: Data, to path: URL, storage: MacClaudeHookStorage) throws {
        if (try? storage.read(path)) != bytes { try storage.replace(path, with: bytes, permissions: 0o600) }
    }

    private static func desktopExecutor(home: URL) -> MacDurableExecutor? {
        guard let socket = try? NativeDesktopCollector.connect(home: home) else { return nil }
        defer { Darwin.close(socket) }
        guard let peer = NativeDesktopCollector.peerPID(socket) else { return nil }
        return MacDurableExecutor.find(peer: peer)
    }
}
