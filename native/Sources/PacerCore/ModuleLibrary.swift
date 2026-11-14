import Foundation

/// The services Pacer can follow, as the module library, onboarding and the
/// settings sidebar list them. Modules found on this computer, or turned on
/// explicitly, come first; the rest stay collapsed until someone opens them.
public struct ModuleLibrary: Equatable, Sendable {
    public enum State: String, Sendable {
        case on, off, notFound
        public var labelKey: String {
            switch self {
            case .on: "modules.state.on"
            case .off: "modules.state.off"
            case .notFound: "modules.state.not_found"
            }
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let provider: AgentProvider
        public let detected: Bool
        public let mode: ProviderModuleMode
        public let enabled: Bool
        public var id: String { provider.rawValue }
        /// Listed in the sidebar and onboarding without opening the library.
        public var prominent: Bool { detected || mode == .enabled }
        public var state: State { enabled ? .on : detected ? .off : .notFound }
        public var summaryKey: String { "module." + provider.rawValue + ".summary" }
        public var website: URL? { HarnessRegistry.descriptor(for: provider)?.website }
    }

    public let entries: [Entry]
    public var prominent: [Entry] { entries.filter(\.prominent) }
    public var collapsed: [Entry] { entries.filter { !$0.prominent } }

    /// `supported` lists the modules this host can run, in any order.
    public init(modules: ProviderModules, detection: ProviderInstallationDetection, supported: [AgentProvider]) {
        let enabled = modules.enabledProviders(detection: detection, supported: supported)
        entries = supported.sorted(by: HarnessRegistry.orderedBefore).map { provider in
            Entry(provider: provider, detected: detection.isInstalled(provider), mode: modules.mode(for: provider),
                  enabled: enabled.contains(provider))
        }
    }
}
