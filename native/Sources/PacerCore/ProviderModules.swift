import Foundation

public enum ProviderModuleMode: String, CaseIterable, Codable, Sendable {
    case automatic, enabled, disabled
}

public struct ProviderInstallationDetection: Equatable, Sendable {
    public let installed: Set<AgentProvider>
    public var codexInstalled: Bool { isInstalled(.codex) }
    public var claudeInstalled: Bool { isInstalled(.claude) }
    public var deepseekInstalled: Bool { isInstalled(.deepseek) }

    public init(installed: Set<AgentProvider>) { self.installed = installed }
    public init(codexInstalled: Bool, claudeInstalled: Bool, deepseekInstalled: Bool = false, additional: Set<AgentProvider> = []) {
        var installed = additional
        if codexInstalled { installed.insert(.codex) }
        if claudeInstalled { installed.insert(.claude) }
        if deepseekInstalled { installed.insert(.deepseek) }
        self.init(installed: installed)
    }
    public func isInstalled(_ provider: AgentProvider) -> Bool { installed.contains(provider) }

    public static func detect(using probe: any ProviderInstallationProbe) -> Self { probe.detect() }

}

/// Automatic detection is a default, never an override of an explicit user choice.
public struct ProviderModules: Equatable, Sendable {
    private var modes: [AgentProvider: ProviderModuleMode] = [:]
    public var claudeMode: ProviderModuleMode {
        get { mode(for: .claude) }
        set { setMode(newValue, for: .claude) }
    }
    public init(codexMode: ProviderModuleMode = .automatic, claudeMode: ProviderModuleMode = .automatic,
                deepseekMode: ProviderModuleMode = .automatic) {
        setMode(codexMode, for: .codex); setMode(claudeMode, for: .claude); setMode(deepseekMode, for: .deepseek)
    }
    public func mode(for provider: AgentProvider) -> ProviderModuleMode {
        modes[provider] ?? Self.defaultMode(provider)
    }
    public mutating func setMode(_ mode: ProviderModuleMode, for provider: AgentProvider) {
        modes[provider] = mode == Self.defaultMode(provider) ? nil : mode
    }
    private static func defaultMode(_ provider: AgentProvider) -> ProviderModuleMode {
        HarnessRegistry.descriptor(for: provider)?.defaultMode ?? .disabled
    }
    public func enabledProviders(detection: ProviderInstallationDetection, supported: [AgentProvider] = HarnessRegistry.legacyIDs) -> Set<AgentProvider> {
        Set(supported.filter { provider in
            switch mode(for: provider) {
            case .automatic: detection.isInstalled(provider)
            case .enabled: true
            case .disabled: false
            }
        })
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        var modules = Self()
        for id in AgentProvider.allCases {
            if let mode = defaults.string(forKey: key(id)).flatMap(ProviderModuleMode.init(rawValue:)) {
                modules.setMode(mode, for: id)
            }
        }
        return modules
    }
    public func save(to defaults: UserDefaults = .standard) {
        for provider in AgentProvider.allCases { defaults.set(mode(for: provider).rawValue, forKey: Self.key(provider)) }
    }
    private static func key(_ provider: AgentProvider) -> String { "providerModule." + provider.rawValue }
}
