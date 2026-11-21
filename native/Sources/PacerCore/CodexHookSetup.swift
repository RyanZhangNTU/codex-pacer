import Foundation

/// What one setup pass found, for `CodexHookStatus.evaluate`.
public struct CodexHookSetupResult: Equatable, Sendable {
    /// False when this Codex has no plugin hooks; nil when it could not be asked.
    public let supportsHooks: Bool?
    /// Whether Codex lists Pacer's plugin as installed; nil after a failure.
    public let installed: Bool?
    /// Codex's trust state of each of Pacer's hooks; nil when unknown.
    public let trust: [String]?
    public init(supportsHooks: Bool?, installed: Bool?, trust: [String]?) {
        self.supportsHooks = supportsHooks; self.installed = installed; self.trust = trust
    }
}

/// Installs, refreshes or removes Pacer's Codex hooks, the same way on every
/// platform: the platform's launcher and program, the plugin files under
/// `CodexHookPlugin.Layout`, then Codex's own marketplace and plugin calls.
public enum CodexHookSetup {
    public static func apply(home: URL, enabled: Bool, launcher: any CodexHookLauncher,
                             storage: any ClaudeHookStorage, client: CodexClient) async -> CodexHookSetupResult {
        let layout = CodexHookPlugin.Layout(home: home)
        do {
            for path in layout.directories + [layout.owner, layout.marketplace, layout.manifest, layout.hooks] { try storage.validate(path) }
            if storage.exists(layout.root), try storage.read(layout.owner) != CodexHookPlugin.ownerMarker {
                return .init(supportsHooks: nil, installed: nil, trust: nil)
            }
        } catch { return .init(supportsHooks: nil, installed: nil, trust: nil) }
        guard enabled else {
            guard storage.exists(layout.root) else {
                try? launcher.remove(home: home)
                return .init(supportsHooks: nil, installed: false, trust: nil)
            }
            do {
                _ = try await client.setLocalPlugin(market: CodexHookPlugin.market, plugin: CodexHookPlugin.plugin, source: layout.root,
                                                    enabled: false, cachedManifestMatches: false,
                                                    pathsMatch: { launcher.samePath($0, $1) })
            } catch CodexClientError.server(_, -32601, _) {
                // A Codex without plugins cannot have loaded ours; remove the files.
            } catch { return .init(supportsHooks: nil, installed: nil, trust: nil) }
            for path in [layout.hooks, layout.manifest, layout.marketplace, layout.owner] where storage.exists(path) { try? storage.remove(path) }
            for directory in layout.directories.reversed() { try? storage.remove(directory) }
            try? launcher.remove(home: home)
            return .init(supportsHooks: nil, installed: false, trust: nil)
        }
        let files: [(relativePath: String, data: Data)]
        do {
            try launcher.prepare(home: home)
            files = try CodexHookPlugin.files(command: launcher.command(home: home), commandWindows: launcher.commandWindows(home: home))
            if !storage.exists(layout.root) {
                try storage.createDirectory(layout.root, permissions: 0o700)
                try storage.replace(layout.owner, with: CodexHookPlugin.ownerMarker, permissions: 0o600)
            }
            for directory in layout.directories where !storage.exists(directory) { try storage.createDirectory(directory, permissions: 0o700) }
            for file in files {
                let path = layout.root.appendingPathComponent(file.relativePath)
                if (try? storage.read(path)) != file.data { try storage.replace(path, with: file.data, permissions: 0o600) }
            }
        } catch { return .init(supportsHooks: nil, installed: nil, trust: nil) }
        // Codex copies an installed plugin into its cache; an identical copy needs no reinstall.
        let cached = home.appendingPathComponent("plugins/cache/\(CodexHookPlugin.market)/\(CodexHookPlugin.plugin)/\(CodexHookPlugin.version)/hooks/hooks.json")
        let matches = (try? storage.validate(cached)) != nil && (try? storage.read(cached)) == files.last?.data
        do {
            _ = try await client.setLocalPlugin(market: CodexHookPlugin.market, plugin: CodexHookPlugin.plugin, source: layout.root,
                                                enabled: true, cachedManifestMatches: matches,
                                                pathsMatch: { launcher.samePath($0, $1) })
        } catch CodexClientError.server(_, -32601, _) {
            return .init(supportsHooks: false, installed: false, trust: nil)
        } catch { return .init(supportsHooks: nil, installed: nil, trust: nil) }
        do {
            return .init(supportsHooks: true, installed: true, trust: try await client.pluginHookTrust(pluginID: CodexHookPlugin.id))
        } catch CodexClientError.server(_, -32601, _) {
            return .init(supportsHooks: false, installed: true, trust: nil)
        } catch { return .init(supportsHooks: true, installed: true, trust: nil) }
    }

    /// The trust state alone, for a Settings refresh while the user approves in Codex.
    public static func trust(client: CodexClient) async -> [String]? {
        try? await client.pluginHookTrust(pluginID: CodexHookPlugin.id)
    }
}

/// Where the user allows Pacer's hooks, and when to ask Codex again whether
/// they did. Codex records hook trust in its user config, so a change to that
/// file is when to ask; a slower check covers trust kept elsewhere, such as a
/// managed config, and gives up after an hour as the setup recheck did.
public struct CodexHookTrustWatch: Sendable {
    /// Codex opens its settings at this link; its Hooks page has no link of its own.
    public static let settingsURL = URL(string: "codex://settings")!
    public static let interval: TimeInterval = 2
    public static let fallback: TimeInterval = 60
    public static let fallbackLimit = 60
    public static func trustFile(home: URL) -> URL { home.appendingPathComponent("config.toml") }

    private var stamp: Date?
    private var checkedAt: Date
    private var fallbacks = 0

    /// `stamp` is the trust file's modification date when the watch starts, nil if it is missing.
    public init(stamp: Date?, now: Date) { self.stamp = stamp; checkedAt = now }

    /// Whether to ask Codex for the hooks' trust now.
    public mutating func shouldCheck(stamp current: Date?, now: Date) -> Bool {
        if current != stamp {
            stamp = current; checkedAt = now
            return true
        }
        guard fallbacks < Self.fallbackLimit, now.timeIntervalSince(checkedAt) >= Self.fallback else { return false }
        fallbacks += 1; checkedAt = now
        return true
    }
}
