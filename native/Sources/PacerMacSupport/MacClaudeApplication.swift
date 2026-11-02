import CoreServices
import Foundation
import PacerCore

private final class MacClaudeLocationCache: @unchecked Sendable {
    static let shared = MacClaudeLocationCache()
    let lock = NSLock()
    var application: (url: URL?, at: Date)?
}

extension ClaudeApplicationResolver {
    private static var located: MacClaudeLocationCache { MacClaudeLocationCache.shared }
    /// Task rows ask on every render whether Claude can open; installations
    /// change rarely, so reuse a lookup for a minute instead of rescanning.
    public static func cachedApplication(now: Date = Date()) -> URL? {
        located.lock.lock(); defer { located.lock.unlock() }
        if let value = located.application, now.timeIntervalSince(value.at) < 60 { return value.url }
        let url = find(); located.application = (url, now); return url
    }

    public static func locations(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let registered = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        return [URL(fileURLWithPath: "/Applications/Claude.app"),
                userHome.appendingPathComponent("Applications/Claude.app")] + registered
    }

    public static func find(applicationURLs: [URL]? = nil,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        (applicationURLs ?? locations(userHome: userHome)).first {
            $0.pathExtension.lowercased() == "app" && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier
        }
    }

    /// Desktop downloads its CLI separately. Look only in known installation roots;
    /// detection never launches Claude or creates a session.
    public static func findExecutable(
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationURLs: [URL]? = nil,
        systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        let root = userHome.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        for version in versions.filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending })
            .prefix(12) {
            candidates += bundledExecutables(in: version)
            let builds = (try? manager.contentsOfDirectory(at: version, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])) ?? []
            for build in builds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(8)
                where (try? build.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                candidates += bundledExecutables(in: build)
            }
        }
        for app in (applicationURLs ?? locations(userHome: userHome)).prefix(12)
            where Bundle(url: app)?.bundleIdentifier == bundleIdentifier {
            candidates += ["Contents/Resources/claude", "Contents/MacOS/claude"].map { app.appendingPathComponent($0) }
        }
        candidates.append(userHome.appendingPathComponent(".local/bin/claude"))
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }.prefix(64)
        candidates += (systemBinDirectories + Array(pathDirectories)).map {
            URL(fileURLWithPath: $0).appendingPathComponent("claude")
        }
        var seen = Set<String>()
        return candidates.first {
            seen.insert($0.standardizedFileURL.path).inserted && CodexExecutableResolver.isExecutableFile($0)
        }
    }

    public static func isInstalled(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        find(userHome: userHome) != nil || findExecutable(userHome: userHome) != nil
    }

    private static func bundledExecutables(in directory: URL) -> [URL] {
        ["claude.app/Contents/MacOS/claude", "Claude Code.app/Contents/MacOS/claude", "claude"].map {
            directory.appendingPathComponent($0)
        }
    }
}
