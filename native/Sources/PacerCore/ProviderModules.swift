import Foundation
import CoreServices

public enum ProviderModuleMode: String, CaseIterable, Codable, Sendable {
    case automatic, enabled, disabled
}

public struct ProviderInstallationDetection: Equatable, Sendable {
    public let codexInstalled: Bool
    public let claudeInstalled: Bool
    public init(codexInstalled: Bool, claudeInstalled: Bool) {
        self.codexInstalled = codexInstalled; self.claudeInstalled = claudeInstalled
    }
    public func isInstalled(_ provider: AgentProvider) -> Bool {
        provider == .codex ? codexInstalled : claudeInstalled
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
        return Self(codexInstalled: codex, claudeInstalled: claude)
    }
}

/// Automatic detection is a default, never an override of an explicit user choice.
public struct ProviderModules: Equatable, Sendable {
    public var codexMode: ProviderModuleMode
    public var claudeMode: ProviderModuleMode
    public init(codexMode: ProviderModuleMode = .automatic, claudeMode: ProviderModuleMode = .automatic) {
        self.codexMode = codexMode; self.claudeMode = claudeMode
    }
    public func mode(for provider: AgentProvider) -> ProviderModuleMode { provider == .codex ? codexMode : claudeMode }
    public mutating func setMode(_ mode: ProviderModuleMode, for provider: AgentProvider) {
        if provider == .codex { codexMode = mode } else { claudeMode = mode }
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
        return Self(codexMode: mode(.codex), claudeMode: mode(.claude))
    }
    public func save(to defaults: UserDefaults = .standard) {
        for provider in AgentProvider.allCases { defaults.set(mode(for: provider).rawValue, forKey: Self.key(provider)) }
    }
    private static func key(_ provider: AgentProvider) -> String { "providerModule." + provider.rawValue }
}
