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
        find(applicationURLs: applicationURLs, userHome: userHome, catalog: MacApplicationCatalog())
    }
}
