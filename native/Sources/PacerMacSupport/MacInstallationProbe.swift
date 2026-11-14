import CoreServices
import Foundation
import PacerCore

extension ProviderInstallationDetection {
    /// Detect known app/CLI locations without launching either app or reading authentication.
    /// `harnessHomes` holds the data folders chosen in Settings, by module ID.
    public static func detect(userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              applicationURLs: [AgentProvider: [URL]]? = nil,
                              systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
                              harnessHomes: [String: String] = [:]) -> Self {
        func appInstalled(_ provider: AgentProvider, bundleID: String, name: String) -> Bool {
            let urls: [URL]
            if let supplied = applicationURLs?[provider] { urls = supplied }
            else {
                let registered = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
                urls = [URL(fileURLWithPath: "/Applications/\(name).app"), userHome.appendingPathComponent("Applications/\(name).app")] + registered
            }
            return urls.prefix(12).contains { $0.pathExtension.lowercased() == "app" && Bundle(url: $0)?.bundleIdentifier == bundleID }
        }
        func cliInstalled(_ name: String) -> Bool {
            let paths = [userHome.appendingPathComponent(".local/bin").path] + systemBinDirectories +
                MacExecutablePlatform.managerBinDirectories(environment: environment, userHome: userHome) +
                (environment["PATH"] ?? "").split(separator: ":").prefix(128).map(String.init).filter { $0.hasPrefix("/") }
            return paths.contains {
                CodexExecutableResolver.isExecutableFile(URL(fileURLWithPath: $0).appendingPathComponent(name))
            }
        }
        let codex = appInstalled(.codex, bundleID: "com.openai.codex", name: "Codex") || cliInstalled("codex")
        let claude = appInstalled(.claude, bundleID: "com.anthropic.claudefordesktop", name: "Claude") || cliInstalled("claude")
        // Harness keeps its sessions in `$DSH_HOME` or `~/.dsh`; the app bundles `dsh`.
        let deepseek = appInstalled(.deepseek, bundleID: "com.deepseek.dsh", name: "DeepSeek Harness") || cliInstalled("dsh") ||
            FileManager.default.fileExists(atPath: DeepSeekHome.resolve(environment: environment, userHome: userHome)
                .appendingPathComponent("sessions").path)
        // A local module's data file counts too, like Harness's sessions: in its
        // default folder, the folder its environment names or the one chosen in Settings.
        func localData(_ definition: LocalHarnessDefinition) -> Bool {
            let chosen = [harnessHomes[definition.descriptor.id.rawValue], environment[definition.homeEnvironmentKey]]
                .compactMap { $0.map { ($0 as NSString).expandingTildeInPath } }.filter { $0.hasPrefix("/") }
            return ([definition.defaultHome(userHome: userHome)] + chosen.map { URL(fileURLWithPath: $0, isDirectory: true) })
                .contains(where: definition.hasLocalData)
        }
        let additional = HarnessRegistry.localHarnesses.filter { definition in
            guard definition.platforms.contains(.macOS) else { return false }
            return definition.macBundleIdentifiers.contains { identifier in
                definition.macApplicationNames.contains {
                    appInstalled(definition.descriptor.id, bundleID: identifier, name: $0)
                }
            } || localData(definition)
        }.map(\.descriptor.id)
        return Self(codexInstalled: codex, claudeInstalled: claude, deepseekInstalled: deepseek, additional: Set(additional))
    }
}
