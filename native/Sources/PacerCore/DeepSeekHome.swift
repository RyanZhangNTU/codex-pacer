import CoreServices
import Foundation

/// DeepSeek Harness keeps its data in `$DSH_HOME`, otherwise `~/.dsh`.
public enum DeepSeekHome {
    public static func resolve(configured: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let path = [configured, environment["DSH_HOME"]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let path else { return userHome.appendingPathComponent(".dsh", isDirectory: true).standardizedFileURL }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

/// How Harness pays for requests, which decides where Pacer reads the balance.
/// An account sign-in bills the platform wallet; an API key bills its owner.
public enum DeepSeekAuthMode: String, CaseIterable, Codable, Sendable {
    case account, apiKey

    /// The provider Harness used most recently wins over its configured default.
    /// Only provider names are read; the credentials file is never opened.
    public static func detect(home: URL, recentProvider: String? = nil) -> Self? {
        if let mode = recentProvider.flatMap(mode(provider:)) { return mode }
        for profile in ["desktop", "default", "headless"] {
            let url = home.appendingPathComponent("profiles/\(profile)/cordis.patch.yml")
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 256 * 1024,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").prefix(4096) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("provider:") else { continue }
                let value = trimmed.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if let mode = mode(provider: value) { return mode }
            }
        }
        return nil
    }

    static func mode(provider: String) -> Self? {
        switch provider.lowercased() {
        case "deepseek-account": .account
        case "deepseek-official", "deepseek-api-key", "deepseek": .apiKey
        default: nil
        }
    }
}

public enum DeepSeekApplicationResolver {
    public static let bundleIdentifier = "com.deepseek.dsh"
    private final class Located: @unchecked Sendable {
        let lock = NSLock(); var application: (url: URL?, at: Date)?
    }
    private static let located = Located()
    /// Task rows ask on every render; reuse a lookup for a minute.
    public static func cachedApplication(now: Date = Date()) -> URL? {
        located.lock.lock(); defer { located.lock.unlock() }
        if let value = located.application, now.timeIntervalSince(value.at) < 60 { return value.url }
        let url = find(); located.application = (url, now); return url
    }
    public static func find(applicationURLs: [URL]? = nil,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let registered = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
        let urls = applicationURLs ?? ([URL(fileURLWithPath: "/Applications/DeepSeek Harness.app"),
            userHome.appendingPathComponent("Applications/DeepSeek Harness.app")] + registered)
        return urls.prefix(12).first { $0.pathExtension.lowercased() == "app" && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier }
    }
}
