#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

enum WindowsPackageLocations {
    static func find(family: String) -> [URL] {
        guard !family.isEmpty, family.utf16.count < 255, !family.utf16.contains(0) else { return [] }
        let name = Array(family.utf16) + [0]
        var result: [URL] = []
        for index in 0..<32 {
            var path = [UInt16](repeating: 0, count: 32768)
            guard pacer_package_path(name, index, &path, path.count) != 0 else { break }
            let value = String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
            if WindowsCodexExecutableDiscovery.absolute(value) { result.append(URL(fileURLWithPath: value)) }
        }
        return result
    }
}

/// The executables URL schemes are registered to open with.
enum WindowsURLHandler {
    /// The quoted executable in the scheme's open command, from HKCU then HKLM.
    static func paths(scheme: String) -> [String] {
        guard scheme.range(of: "^[a-z][a-z0-9+.-]{0,31}$", options: .regularExpression) != nil else { return [] }
        let name = Array(scheme.utf16) + [0]
        return (0..<2).compactMap { index in
            var path = [UInt16](repeating: 0, count: 32768)
            guard pacer_url_handler_path(name, index, &path, path.count) != 0 else { return nil }
            return String(decoding: path.prefix { $0 != 0 }, as: UTF16.self)
        }
    }
    /// A path on a drive letter, never a share or a relative path.
    static func localDrivePath(_ value: String) -> Bool {
        value.utf16.count < 32768 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }
}

/// Only installation metadata and known executable locations are inspected.
/// Detection never launches a provider or opens authentication files.
enum WindowsProviderInstallation {
    static func detect(userHome: URL, environment: [String: String], applicationURLs: [AgentProvider: [URL]]?,
                       systemBinDirectories: [String],
                       packageLocations: (String) -> [URL] = { WindowsPackageLocations.find(family: $0) },
                       registeredHandlers: (String) -> [String] = WindowsURLHandler.paths) -> ProviderInstallationDetection {
        let codexApps = applicationURLs?[.codex] ?? packageLocations("OpenAI.Codex_2p2nqsd0c76g0")
        // Registered MSIX identity is authoritative for installation. Some
        // packages deny binary reads, even though the app is available to launch.
        let registeredCodex = applicationURLs?[.codex] == nil && !codexApps.isEmpty
        let codex = registeredCodex || CodexExecutableResolver.discover(environment: environment, userHome: userHome,
            applicationURLs: codexApps, systemBinDirectories: systemBinDirectories).selected != nil
        let claudeApps = applicationURLs?[.claude] ?? packageLocations("Claude_pzs8sxrjxfjjc")
        let registeredClaude = applicationURLs?[.claude] == nil && !claudeApps.isEmpty
        func executable(_ url: URL) -> Bool { CodexExecutableResolver.isExecutableFile(url) }
        func app(_ roots: [URL], paths: [String]) -> Bool {
            roots.prefix(12).contains { root in paths.contains { executable(root.appendingPathComponent($0)) } }
        }
        var directories = (WindowsEnvironment.value("PATH", in: environment) ?? "").split(separator: ";")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .filter(WindowsCodexExecutableDiscovery.absolute)
        directories += systemBinDirectories.filter(WindowsCodexExecutableDiscovery.absolute)
        directories.insert(WindowsCodexExecutableDiscovery.path(userHome.appendingPathComponent(".local/bin")), at: 0)
        var seen = Set<String>()
        let bounded = directories.filter { seen.insert($0.lowercased()).inserted }.prefix(128).map { URL(fileURLWithPath: $0) }
        func cli(_ name: String) -> Bool { bounded.contains { executable($0.appendingPathComponent(name + ".exe")) } }
        let claude = registeredClaude || app(claudeApps, paths: ["app/Claude.exe", "Claude.exe"]) || cli("claude")
        let deepseekPath = WindowsEnvironment.value("DSH_HOME", in: environment)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let deepseekHome = deepseekPath.map { URL(fileURLWithPath: WindowsCodexExecutableDiscovery.normalize($0, userHome: userHome)) }
            ?? userHome.appendingPathComponent(".dsh")
        var isDirectory: ObjCBool = false
        let hasSessions = FileManager.default.fileExists(atPath: deepseekHome.appendingPathComponent("sessions").path,
            isDirectory: &isDirectory) && isDirectory.boolValue
        let desktop = WindowsDeepSeekApplication.find(applicationURLs: applicationURLs?[.deepseek], userHome: userHome, environment: environment) != nil
        let deepseek = desktop || app(applicationURLs?[.deepseek] ?? [], paths: ["app/dsh.exe", "dsh.exe"]) || cli("dsh") || hasSessions
        let additional = HarnessRegistry.localHarnesses.filter { definition in
            guard definition.platforms.contains(.windows) else { return false }
            if let supplied = applicationURLs?[definition.descriptor.id] { return supplied.contains(where: executable) }
            // Explicit application lists make installation probes deterministic in tests.
            guard applicationURLs == nil else { return false }
            let roots = ["ProgramFiles", "LOCALAPPDATA"].compactMap { WindowsEnvironment.value($0, in: environment) }
                .filter(WindowsCodexExecutableDiscovery.absolute)
            let home = definition.resolveHome(override: WindowsEnvironment.value(definition.homeEnvironmentKey, in: environment),
                isAbsolute: WindowsCodexExecutableDiscovery.absolute, userHome: userHome)
            // An app installed to a folder of the user's choosing is found
            // through the link handler it registers, by its executable's name.
            let names = Set(definition.windowsExecutables.compactMap { $0.split(separator: "/").last.map { $0.lowercased() } })
            let registered = definition.conversationScheme.map(registeredHandlers) ?? []
            let handler = registered.prefix(2).contains { path in
                WindowsURLHandler.localDrivePath(path) && names.contains(URL(fileURLWithPath: path).lastPathComponent.lowercased())
                    && executable(URL(fileURLWithPath: path))
            }
            return app(roots.map { URL(fileURLWithPath: $0) }, paths: definition.windowsExecutables) || handler || definition.hasLocalData(home: home)
        }.map(\.descriptor.id)
        return .init(codexInstalled: codex, claudeInstalled: claude, deepseekInstalled: deepseek, additional: Set(additional))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
