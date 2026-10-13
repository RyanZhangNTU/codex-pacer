import Foundation
import CoreServices

public enum CodexApplicationResolver {
    /// The standalone Codex.app was renamed and merged into ChatGPT.app, which
    /// ships a newer bundled CLI. When both exist, the successor must be preferred
    /// so Pacer does not launch an outdated CLI that rejects newer RPC params.
    private static let successorApplicationNames = ["ChatGPT.app"]

    public static func locations(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let legacy = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            userHome.appendingPathComponent("Applications/Codex.app"),
        ]
        let registered: [URL] = LSCopyApplicationURLsForBundleIdentifier("com.openai.codex" as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        return orderedCandidates(successors: successorApplications(), registered: registered, legacy: legacy)
    }

    /// Apps that superseded the standalone Codex.app, kept only when present on disk.
    public static func successorApplications() -> [URL] {
        successorApplicationNames
            .map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Deterministic resolver ordering: successors first, then any Launch
    /// Services–registered install, then the legacy hardcoded Codex.app path as a
    /// last resort. Duplicates are dropped so the same bundle is never tried twice.
    public static func orderedCandidates(successors: [URL], registered: [URL], legacy: [URL]) -> [URL] {
        var ordered: [URL] = []
        var seen = Set<URL>()
        func append(_ url: URL) {
            let key = url.standardizedFileURL
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(key)
        }
        for url in successors { append(url) }
        for url in registered where !legacy.contains(url) { append(url) }
        for url in legacy { append(url) }
        return ordered
    }

    public static func find(applicationURLs: [URL]? = nil,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        (applicationURLs ?? locations(userHome: userHome)).first {
            $0.pathExtension.lowercased() == "app" && Bundle(url: $0)?.bundleIdentifier == "com.openai.codex"
        }
    }
}
