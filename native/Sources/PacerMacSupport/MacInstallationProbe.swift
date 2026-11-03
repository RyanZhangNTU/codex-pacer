import CoreServices
import Foundation
import PacerCore

public struct MacInstallationProbe: ProviderInstallationProbe {
    public let userHome: URL
    public let environment: [String: String]
    public let applicationURLs: [AgentProvider: [URL]]?
    public let systemBinDirectories: [String]
    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationURLs: [AgentProvider: [URL]]? = nil, systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        self.userHome = userHome; self.environment = environment
        self.applicationURLs = applicationURLs; self.systemBinDirectories = systemBinDirectories
    }
    public func detect() -> ProviderInstallationDetection {
        ProviderInstallationDetection.detect(userHome: userHome, environment: environment,
            applicationURLs: applicationURLs, systemBinDirectories: systemBinDirectories)
    }
}

extension ProviderInstallationDetection {
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
        return Self(codexInstalled: codex, claudeInstalled: claude, deepseekInstalled: deepseek)
    }
}
