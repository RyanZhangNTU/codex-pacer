import Foundation
import CoreServices

public enum ProviderModuleMode: String, CaseIterable, Codable, Sendable {
    case automatic, enabled, disabled
}

public struct ProviderInstallationDetection: Equatable, Sendable {
    public let codexInstalled: Bool
    public let claudeInstalled: Bool
    public let deepseekInstalled: Bool
    public init(codexInstalled: Bool, claudeInstalled: Bool, deepseekInstalled: Bool = false) {
        self.codexInstalled = codexInstalled; self.claudeInstalled = claudeInstalled; self.deepseekInstalled = deepseekInstalled
    }
    public func isInstalled(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .codex: codexInstalled
        case .claude: claudeInstalled
        case .deepseek: deepseekInstalled
        }
    }

    /// Detect known app/CLI locations without launching either app or reading authentication.
    public static func detect(userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              applicationURLs: [AgentProvider: [URL]]? = nil,
                              systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> Self {
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
                CodexExecutableResolver.managerBinDirectories(environment: environment, userHome: userHome) +
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
        return Self(codexInstalled: codex, claudeInstalled: claude, deepseekInstalled: deepseek)
    }
}

/// Automatic detection is a default, never an override of an explicit user choice.
public struct ProviderModules: Equatable, Sendable {
    public var codexMode: ProviderModuleMode
    public var claudeMode: ProviderModuleMode
    public var deepseekMode: ProviderModuleMode
    public init(codexMode: ProviderModuleMode = .automatic, claudeMode: ProviderModuleMode = .automatic,
                deepseekMode: ProviderModuleMode = .automatic) {
        self.codexMode = codexMode; self.claudeMode = claudeMode; self.deepseekMode = deepseekMode
    }
    public func mode(for provider: AgentProvider) -> ProviderModuleMode {
        switch provider {
        case .codex: codexMode
        case .claude: claudeMode
        case .deepseek: deepseekMode
        }
    }
    public mutating func setMode(_ mode: ProviderModuleMode, for provider: AgentProvider) {
        switch provider {
        case .codex: codexMode = mode
        case .claude: claudeMode = mode
        case .deepseek: deepseekMode = mode
        }
    }
    public func enabledProviders(detection: ProviderInstallationDetection = .detect()) -> Set<AgentProvider> {
        Set(AgentProvider.allCases.filter { provider in
            switch mode(for: provider) {
            case .automatic: detection.isInstalled(provider)
            case .enabled: true
            case .disabled: false
            }
        })
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        func mode(_ provider: AgentProvider) -> ProviderModuleMode {
            defaults.string(forKey: key(provider)).flatMap(ProviderModuleMode.init(rawValue:)) ?? .automatic
        }
        return Self(codexMode: mode(.codex), claudeMode: mode(.claude), deepseekMode: mode(.deepseek))
    }
    public func save(to defaults: UserDefaults = .standard) {
        for provider in AgentProvider.allCases { defaults.set(mode(for: provider).rawValue, forKey: Self.key(provider)) }
    }
    private static func key(_ provider: AgentProvider) -> String { "providerModule." + provider.rawValue }
}
