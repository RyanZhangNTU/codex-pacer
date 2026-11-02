import Foundation

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

    public static func detect(using probe: any ProviderInstallationProbe) -> Self { probe.detect() }

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
    public func enabledProviders(detection: ProviderInstallationDetection) -> Set<AgentProvider> {
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
