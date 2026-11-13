import Foundation

public enum ProviderIcon {
    public static func resource(for provider: AgentProvider, outline: Bool = false) -> URL? {
        let name = "provider-" + provider.rawValue + (outline ? "-outline" : "")
        return Bundle.module.url(forResource: name, withExtension: "png")
    }
}
