import Foundation
import PacerCore

/// An explicit source-editor query. Paths never enter routine snapshots:
/// Settings asks here for the folder in use and the default it falls back to.
struct EngineProviderHomeReport: Codable, Equatable, Sendable {
    let provider: String, home: String, effectiveHome: String, defaultHome: String
    let issue: String?
    let readable: Bool

    static func inspect(provider: AgentProvider, home: String, fallback: URL, demo: Bool = false) -> Self {
        let home = WindowsExecutablePlatform().normalize(home, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let fallback = EngineCodexSourceReport.path(fallback)
        let effective = home.isEmpty ? fallback : home
        if demo && home.isEmpty {
            return .init(provider: provider.rawValue, home: home, effectiveHome: effective, defaultHome: fallback, issue: nil, readable: true)
        }
        #if os(Windows)
        let absolute = WindowsCodexExecutableDiscovery.absolute(effective)
        #else
        let absolute = effective.hasPrefix("/")
        #endif
        var directory: ObjCBool = false
        let exists = absolute && FileManager.default.fileExists(atPath: effective, isDirectory: &directory) && directory.boolValue
        return .init(provider: provider.rawValue, home: home, effectiveHome: effective, defaultHome: fallback,
            issue: home.isEmpty || exists ? nil : L10n.text("windows.settings.invalid_home"),
            readable: exists && FileManager.default.isReadableFile(atPath: effective))
    }
}
