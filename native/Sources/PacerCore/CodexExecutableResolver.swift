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

    private static let appExecutables = [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex", "Contents/MacOS/codex"
    ]

    /// Searches only known installation locations; never runs a login shell or scans the whole disk.
    public static func discover(
        customPath: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationURLs: [URL]? = nil,
        systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) -> Report {
        let requested = normalize(customPath, userHome: userHome)
        if !requested.isEmpty { return customSelection(requested) }

        var paths: [(String, String)] = []
        let apps = applicationURLs ?? CodexApplicationResolver.locations(userHome: userHome)
        for app in apps.prefix(12) {
            for executable in appExecutables {
                paths.append((app.appendingPathComponent(executable).path, L10n.text("cli.source_app")))
            }
        }
        paths.append((userHome.appendingPathComponent(".local/bin/codex").path, L10n.text("cli.source_user")))
        for directory in systemBinDirectories {
            paths.append((URL(fileURLWithPath: directory).appendingPathComponent("codex").path, L10n.text("cli.source_system")))
        }
        for directory in absolutePathEntries(environment["PATH"] ?? "") {
            paths.append((URL(fileURLWithPath: directory).appendingPathComponent("codex").path, "PATH"))
        }
        for directory in managerBinDirectories(environment: environment, userHome: userHome) {
            paths.append((URL(fileURLWithPath: directory).appendingPathComponent("codex").path, L10n.text("cli.source_manager")))
        }
        var seenPaths = Set<String>(), seenExecutables = Set<String>(), candidates: [Candidate] = []
        let searched = paths.filter { seenPaths.insert($0.0).inserted }
        for (path, source) in searched {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isExecutableFile(url), seenExecutables.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            candidates.append(Candidate(url: url, source: source))
        }
        let issue = candidates.isEmpty
            ? L10n.text("cli.not_found")
            : nil
        return Report(candidates: candidates, issue: issue, searchedPaths: searched.map(\.0))
    }

    public static func isExecutableFile(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// npm launchers commonly use /usr/bin/env node, even when the GUI has a minimal PATH.
    public static func launchEnvironment(
        for executable: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var result = inherited
        var directories = [executable.deletingLastPathComponent().path]
        let resolved = executable.resolvingSymlinksInPath().path
        if let range = resolved.range(of: "/lib/node_modules/") {
            directories.append(String(resolved[..<range.lowerBound]) + "/bin")
        }
        directories += absolutePathEntries(inherited["PATH"] ?? "")
        directories += managerBinDirectories(environment: inherited, userHome: userHome)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        result["PATH"] = directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return result
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

    private static func customSelection(_ path: String) -> Report {
        func failed(_ reason: String, checked: [String] = []) -> Report {
            Report(candidates: [], issue: reason, searchedPaths: checked.isEmpty ? [path] : checked)
        }
        guard path.hasPrefix("/") else {
            return failed(L10n.text("cli.relative_path", path))
        }
        let selected = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory) else {
            return failed(L10n.text("cli.path_missing", selected.path))
        }
        let urls: [URL]
        if isDirectory.boolValue {
            urls = selected.pathExtension.lowercased() == "app"
                ? appExecutables.map { selected.appendingPathComponent($0) }
                : [selected.appendingPathComponent("codex")]
        } else { urls = [selected] }
        if let executable = urls.first(where: isExecutableFile) {
            return Report(candidates: [Candidate(url: executable, source: L10n.text("cli.source_manual"))], issue: nil, searchedPaths: urls.map(\.path))
        }
        if isDirectory.boolValue {
            return failed(L10n.text("cli.not_runnable", selected.path), checked: urls.map(\.path))
        }
        return failed(L10n.text("cli.not_executable", selected.path))
    }

    private static func absolutePathEntries(_ value: String) -> [String] {
        value.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    static func managerBinDirectories(environment: [String: String], userHome: URL) -> [String] {
        func home(_ relative: String) -> String { userHome.appendingPathComponent(relative).path }
        var paths = [
            home(".npm-global/bin"), home(".npm/bin"), home(".volta/bin"), home(".asdf/shims"),
            home(".local/share/mise/shims"), home(".local/share/pnpm"), home("Library/pnpm"),
            home(".bun/bin"), home(".nvm/current/bin"), home(".fnm/current/bin")
        ]
        for (key, suffix) in [
            ("NVM_BIN", ""), ("NPM_CONFIG_PREFIX", "bin"), ("npm_config_prefix", "bin"),
            ("VOLTA_HOME", "bin"), ("ASDF_DATA_DIR", "shims"), ("MISE_DATA_DIR", "shims"),
            ("PNPM_HOME", ""), ("FNM_MULTISHELL_PATH", "bin")
        ] {
            if let value = environment[key], value.hasPrefix("/") {
                paths.append(suffix.isEmpty ? value : URL(fileURLWithPath: value).appendingPathComponent(suffix).path)
            }
        }
        func managerRoot(_ key: String, fallback: String) -> String {
            guard let value = environment[key] else { return fallback }
            let path = normalize(value, userHome: userHome)
            return path.hasPrefix("/") ? path : fallback
        }
        let nvm = managerRoot("NVM_DIR", fallback: home(".nvm"))
        let fnm = managerRoot("FNM_DIR", fallback: home(".local/share/fnm"))
        for (directory, suffix) in [
            (nvm + "/versions/node", "bin"),
            (fnm + "/node-versions", "installation/bin"),
            (home("Library/Application Support/fnm/node-versions"), "installation/bin"),
            (home(".fnm/node-versions"), "installation/bin"),
            (home(".asdf/installs/nodejs"), "bin"),
            (home(".local/share/mise/installs/node"), "bin")
        ] where directory.hasPrefix("/") {
            let versions = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            paths += versions.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }.prefix(64).map { $0.appendingPathComponent(suffix).path }
        }
        return paths
    }
}
