import Foundation

public enum CodexExecutableResolver {
    public struct Candidate: Identifiable, Equatable, Sendable {
        public let url: URL
        public let source: String
        public var id: String { url.path }
    }

    public struct Report: Equatable, Sendable {
        public let candidates: [Candidate]
        public let issue: String?
        public let searchedPaths: [String]
        public var selected: Candidate? { candidates.first }
    }

    /// Candidate ordering and explicit-selection failures are shared across hosts.
    public static func discover(customPath: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationURLs: [URL]? = nil, systemBinDirectories: [String]? = nil,
        platform: any ExecutablePlatform) -> Report {
        let requested = platform.normalize(customPath, userHome: userHome)
        if !requested.isEmpty { return customSelection(requested, platform: platform) }
        let paths = platform.searchPaths(environment: environment, userHome: userHome,
            applicationURLs: applicationURLs, systemBinDirectories: systemBinDirectories)
        var seenPaths = Set<String>(), seenExecutables = Set<String>(), candidates: [Candidate] = []
        let searched = paths.filter { seenPaths.insert($0.url.path).inserted }
        for entry in searched {
            let url = entry.url.standardizedFileURL
            guard platform.isExecutableFile(url), seenExecutables.insert(platform.executableIdentity(url)).inserted else { continue }
            candidates.append(Candidate(url: url, source: entry.source))
        }
        return Report(candidates: candidates, issue: candidates.isEmpty ? L10n.text("cli.not_found") : nil,
            searchedPaths: searched.map { $0.url.path })
    }

    public static func normalize(_ input: String, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value.removeFirst(); value.removeLast()
        }
        if value == "~" { return userHome.path }
        if value.hasPrefix("~/") { return userHome.appendingPathComponent(String(value.dropFirst(2))).path }
        return value
    }

    private static func customSelection(_ path: String, platform: any ExecutablePlatform) -> Report {
        func failed(_ reason: String, checked: [String] = []) -> Report {
            Report(candidates: [], issue: reason, searchedPaths: checked.isEmpty ? [path] : checked)
        }
        guard platform.isAbsolutePath(path) else { return failed(L10n.text("cli.relative_path", path)) }
        let selected = URL(fileURLWithPath: path).standardizedFileURL
        guard let kind = platform.selectionKind(selected) else {
            return failed(L10n.text("cli.path_missing", selected.path))
        }
        let urls = platform.selectionURLs(selected, isDirectory: kind == .directory)
        if let executable = urls.first(where: platform.isExecutableFile) {
            return Report(candidates: [Candidate(url: executable, source: L10n.text("cli.source_manual"))],
                issue: nil, searchedPaths: urls.map(\.path))
        }
        return failed(L10n.text(kind == .directory ? "cli.not_runnable" : "cli.not_executable", selected.path),
            checked: urls.map(\.path))
    }
}
