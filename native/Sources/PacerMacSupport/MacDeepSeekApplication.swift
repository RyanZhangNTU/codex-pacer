import CoreServices
import Foundation
import PacerCore

private final class MacDeepSeekLocationCache: @unchecked Sendable {
    static let shared = MacDeepSeekLocationCache()
    let lock = NSLock()
    var application: (url: URL?, at: Date)?
}
extension DeepSeekApplicationResolver {
    private static var located: MacDeepSeekLocationCache { MacDeepSeekLocationCache.shared }
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
