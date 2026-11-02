import Foundation
import PacerCore

public struct MacExecutablePlatform: ExecutablePlatform {
    public init() {}
    public func normalize(_ input: String, userHome: URL) -> String {
        CodexExecutableResolver.normalize(input, userHome: userHome)
    }
    static let appExecutables = [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex", "Contents/MacOS/codex"
    ]

    public func searchPaths(environment: [String: String], userHome: URL,
                            applicationURLs: [URL]?, systemBinDirectories: [String]?) -> [ExecutableSearchPath] {
        var paths: [(String, String)] = []
        let apps = applicationURLs ?? MacApplicationCatalog().locations(for: .codex, userHome: userHome)
        for app in apps.prefix(12) {
            for executable in Self.appExecutables {
                paths.append((app.appendingPathComponent(executable).path, L10n.text("cli.source_app")))
            }
        }
        paths.append((userHome.appendingPathComponent(".local/bin/codex").path, L10n.text("cli.source_user")))
        for directory in systemBinDirectories ?? ["/opt/homebrew/bin", "/usr/local/bin"] {
            paths.append((URL(fileURLWithPath: directory).appendingPathComponent("codex").path, L10n.text("cli.source_system")))
        }
        for directory in Self.absolutePathEntries(environment["PATH"] ?? "") {
            paths.append((URL(fileURLWithPath: directory).appendingPathComponent("codex").path, "PATH"))
        }
        for directory in Self.managerBinDirectories(environment: environment, userHome: userHome) {
            paths.append((URL(fileURLWithPath: directory).appendingPathComponent("codex").path, L10n.text("cli.source_manager")))
        }
        return paths.map { ExecutableSearchPath(url: URL(fileURLWithPath: $0.0), source: $0.1) }
    }
    public func isExecutableFile(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
    public func executableIdentity(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
    public func selectionKind(_ url: URL) -> ExecutableSelectionKind? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return nil }
        return directory.boolValue ? .directory : .file
    }
    public func isAbsolutePath(_ path: String) -> Bool { path.hasPrefix("/") }
    public func selectionURLs(_ url: URL, isDirectory: Bool) -> [URL] {
        guard isDirectory else { return [url] }
        return url.pathExtension.lowercased() == "app" ? Self.appExecutables.map { url.appendingPathComponent($0) }
            : [url.appendingPathComponent("codex")]
    }
    public func launchEnvironment(
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
        directories += Self.absolutePathEntries(inherited["PATH"] ?? "")
        directories += Self.managerBinDirectories(environment: inherited, userHome: userHome)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        result["PATH"] = directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return result
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
            let path = CodexExecutableResolver.normalize(value, userHome: userHome)
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

extension CodexExecutableResolver {
    public static func discover(customPath: String = "", environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser, applicationURLs: [URL]? = nil,
        systemBinDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> Report {
        discover(customPath: customPath, environment: environment, userHome: userHome, applicationURLs: applicationURLs,
            systemBinDirectories: systemBinDirectories, platform: MacExecutablePlatform())
    }
    public static func isExecutableFile(_ url: URL) -> Bool { MacExecutablePlatform().isExecutableFile(url) }
    public static func launchEnvironment(for executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        MacExecutablePlatform().launchEnvironment(for: executable, inherited: inherited, userHome: userHome)
    }
}
