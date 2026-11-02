import Foundation

/// Source paths are returned only to an explicit settings query. They are not
/// added to activity snapshots, diagnostics, or quota history.
struct EngineCodexSourceReport: Codable, Equatable, Sendable {
    struct Candidate: Codable, Equatable, Sendable {
        let path: String
        let source: String
        let label: String
    }
    let executable: String
    let selectedExecutable: String?
    let executableIssue: String?
    let candidates: [Candidate]
    let home: String
    let effectiveHome: String
    let homeIssue: String?
    let historyTitle: String

    static func inspect(executable: String, home: String, defaultHome: URL) -> Self {
        let executable = WindowsExecutablePlatform().normalize(executable, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let home = WindowsExecutablePlatform().normalize(home, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let report = CodexExecutableResolver.discover(customPath: executable)
        var directory: ObjCBool = false
        let validHome = home.isEmpty || (isAbsolute(home) &&
            FileManager.default.fileExists(atPath: home, isDirectory: &directory) && directory.boolValue)
        return .init(executable: executable, selectedExecutable: report.selected.map { path($0.url) },
            executableIssue: report.issue, candidates: report.candidates.prefix(16).map {
                .init(path: path($0.url), source: $0.source, label: L10n.text("settings.cli_candidate", $0.source, path($0.url)))
            },
            home: home, effectiveHome: home.isEmpty ? path(defaultHome) : home,
            homeIssue: validHome ? nil : L10n.text("windows.settings.invalid_home"), historyTitle: L10n.text("settings.quota_history", "Codex"))
    }

    static func demo(executable: String, home: String, defaultHome: URL) -> Self {
        let executable = WindowsExecutablePlatform().normalize(executable, userHome: FileManager.default.homeDirectoryForCurrentUser), home = WindowsExecutablePlatform().normalize(home, userHome: FileManager.default.homeDirectoryForCurrentUser)
        let selected = executable.isEmpty ? path(defaultHome.deletingLastPathComponent().appendingPathComponent("Codex/codex.exe")) : executable
        let issue = !executable.isEmpty && !isAbsolute(executable) ? L10n.text("windows.cli.relative_path", executable) : nil
        let source = L10n.text(executable.isEmpty ? "cli.source_app" : "cli.source_manual")
        return .init(executable: executable, selectedExecutable: issue == nil ? selected : nil,
            executableIssue: issue, candidates: issue == nil ? [.init(path: selected, source: source,
                label: L10n.text("settings.cli_candidate", source, selected))] : [],
            home: home, effectiveHome: home.isEmpty ? path(defaultHome) : home,
            homeIssue: home.isEmpty || isAbsolute(home) ? nil : L10n.text("windows.settings.invalid_home"), historyTitle: L10n.text("settings.quota_history", "Codex"))
    }

    static func path(_ url: URL) -> String {
        #if os(Windows)
        return WindowsCodexExecutableDiscovery.path(url)
        #else
        return url.path
        #endif
    }
    private static func isAbsolute(_ value: String) -> Bool {
        #if os(Windows)
        return WindowsCodexExecutableDiscovery.absolute(value)
        #else
        return value.hasPrefix("/") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        #endif
    }
}

struct CodexSourceSettingsServices: Sendable {
    let inspect: @Sendable (String, String, URL) async -> EngineCodexSourceReport
    static var live: Self {
        .init(inspect: { executable, home, fallback in
            await Task.detached(priority: .utility) {
                EngineCodexSourceReport.inspect(executable: executable, home: home, defaultHome: fallback)
            }.value
        })
    }
}
