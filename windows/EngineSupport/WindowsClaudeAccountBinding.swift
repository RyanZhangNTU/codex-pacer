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
    static func locations(environment: [String: String]) -> [URL] {
        var result: [URL] = []
        if let roaming = WindowsEnvironment.value("APPDATA", in: environment), WindowsCodexExecutableDiscovery.absolute(roaming) {
            result.append(URL(fileURLWithPath: roaming).appendingPathComponent("Claude/config.json"))
        }
        if let local = WindowsEnvironment.value("LOCALAPPDATA", in: environment), WindowsCodexExecutableDiscovery.absolute(local) {
            let root = URL(fileURLWithPath: local).appendingPathComponent("Packages/Claude_pzs8sxrjxfjjc")
            result.append(root.appendingPathComponent("LocalCache/Roaming/Claude/config.json"))
            result.append(root.appendingPathComponent("RoamingState/Claude/config.json"))
        }
        return result
    }
}
#endif
