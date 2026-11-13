import CoreServices
import Foundation
import PacerCore

public struct MacApplicationCatalog: ApplicationCatalog {
    public init() {}
    public func locations(for provider: AgentProvider, userHome: URL) -> [URL] {
        guard let (identifier, name) = Self.identity(provider) else { return [] }
        let registered = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
        return [URL(fileURLWithPath: "/Applications/" + name + ".app"),
            userHome.appendingPathComponent("Applications/" + name + ".app")] + registered
    }
    public func isApplication(_ url: URL, provider: AgentProvider) -> Bool {
        guard let (identifier, _) = Self.identity(provider) else { return false }
        return url.pathExtension.lowercased() == "app" && Bundle(url: url)?.bundleIdentifier == identifier
    }
    private static func identity(_ provider: AgentProvider) -> (String, String)? {
        switch provider {
        case .codex: ("com.openai.codex", "Codex")
        case .claude: ("com.anthropic.claudefordesktop", "Claude")
        case .deepseek: ("com.deepseek.dsh", "DeepSeek Harness")
        default: nil
        }
    }
}

extension CodexApplicationResolver {
    public static func locations(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        locations(userHome: userHome, catalog: MacApplicationCatalog())
    }
    public static func find(applicationURLs: [URL]? = nil,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        find(applicationURLs: applicationURLs, userHome: userHome, catalog: MacApplicationCatalog())
    }
}
