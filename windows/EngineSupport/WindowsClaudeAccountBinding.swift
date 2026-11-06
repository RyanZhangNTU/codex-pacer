#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

/// Reads bounded account metadata only. OAuth tokens and other applications'
/// cookie stores are outside this adapter.
enum WindowsClaudeAccountBinding {
    static func sameDirectory(_ first: URL, _ second: URL) -> Bool {
        let paths = [first, second].map { WindowsCodexExecutableDiscovery.path($0.standardizedFileURL) }
        guard paths.allSatisfy({ WindowsCodexExecutableDiscovery.absolute($0) && $0.utf16.count < 32768 }) else { return false }
        return pacer_same_directory(Array(paths[0].utf16) + [0], Array(paths[1].utf16) + [0]) != 0
    }
    static func observe(userHome: URL, home: URL, desktopFiles: [URL]? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeWebAccountBinding {
        let userHome = URL(fileURLWithPath: userHome.path, isDirectory: true)
        let standard = userHome.appendingPathComponent(".claude", isDirectory: true)
        let isDefault = home.standardizedFileURL == standard.standardizedFileURL || sameDirectory(home, standard)
        let effectiveHome = isDefault ? standard : home
        let files = WindowsFileSystem()
        let cli = ClaudeWebQuotaClient.observedBinding(userHome: userHome, home: effectiveHome,
            desktopConfiguration: nil, files: files)
        let bindings = isDefault ? (desktopFiles ?? locations(environment: environment)).prefix(16).map {
            ClaudeWebQuotaClient.observedBinding(userHome: userHome, home: effectiveHome,
                desktopConfiguration: $0, files: files)
        } : []
        let accounts = Set(([cli] + bindings).compactMap(\.accountID))
        return .init(accountID: cli.accountID ?? (accounts.count == 1 ? accounts.first : nil), organizationID: cli.organizationID,
            conflictingAccounts: cli.conflictingAccounts || bindings.contains(where: \.conflictingAccounts) || accounts.count > 1)
    }
    /// Desktop 4.23118 moves its data out of the MSIX package into a folder
    /// named for the package, and leaves this marker in each folder it left.
    static let movedMarker = ".user-data-left.claude_pzs8sxrjxfjjc"
    /// The active Desktop's `config.json`. Once the current folder has one,
    /// the older folders are leftovers; before that, a folder Desktop marked
    /// as moved is skipped, so a stale account cannot disable every mapping.
    static func locations(environment: [String: String], files: any PlatformFileSystem = WindowsFileSystem()) -> [URL] {
        if let current = current(environment), files.metadata(current)?.isRegularFile == true { return [current] }
        return legacy(environment).filter {
            files.metadata($0.deletingLastPathComponent().appendingPathComponent(movedMarker)) == nil
        }
    }
    /// Every `config.json` location Desktop has used, current layout first.
    static func candidates(environment: [String: String]) -> [URL] {
        [current(environment)].compactMap { $0 } + legacy(environment)
    }
    private static func folder(_ key: String, _ environment: [String: String]) -> URL? {
        guard let path = WindowsEnvironment.value(key, in: environment), WindowsCodexExecutableDiscovery.absolute(path) else { return nil }
        return URL(fileURLWithPath: path)
    }
    private static func current(_ environment: [String: String]) -> URL? {
        folder("LOCALAPPDATA", environment)?.appendingPathComponent("Claude-Data/claude_pzs8sxrjxfjjc/config.json")
    }
    private static func legacy(_ environment: [String: String]) -> [URL] {
        var result: [URL] = []
        if let roaming = folder("APPDATA", environment) { result.append(roaming.appendingPathComponent("Claude/config.json")) }
        if let local = folder("LOCALAPPDATA", environment) {
            let root = local.appendingPathComponent("Packages/Claude_pzs8sxrjxfjjc")
            result.append(root.appendingPathComponent("LocalCache/Roaming/Claude/config.json"))
            result.append(root.appendingPathComponent("RoamingState/Claude/config.json"))
        }
        return result
    }
}
#endif
