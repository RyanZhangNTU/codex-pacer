import Foundation
import CoreServices

public enum CodexApplicationResolver {
    public static func locations(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let registered = LSCopyApplicationURLsForBundleIdentifier("com.openai.codex" as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        return [URL(fileURLWithPath: "/Applications/Codex.app"), userHome.appendingPathComponent("Applications/Codex.app")] + registered
    }

    public static func find(applicationURLs: [URL]? = nil,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        (applicationURLs ?? locations(userHome: userHome)).first {
            $0.pathExtension.lowercased() == "app" && Bundle(url: $0)?.bundleIdentifier == "com.openai.codex"
        }
    }
}
