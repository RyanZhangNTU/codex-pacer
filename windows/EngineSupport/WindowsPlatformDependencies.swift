#if os(Windows)
import Foundation
import CryptoKit
import CWindowsSupport

struct WindowsExecutablePlatform: ExecutablePlatform {
    func normalize(_ input: String, userHome: URL) -> String { WindowsCodexExecutableDiscovery.normalize(input, userHome: userHome) }
    func isAbsolutePath(_ path: String) -> Bool { WindowsCodexExecutableDiscovery.absolute(path) }
    func isExecutableFile(_ url: URL) -> Bool { WindowsCodexExecutableDiscovery.isExecutable(url) }
    func executableIdentity(_ url: URL) -> String { WindowsCodexExecutableDiscovery.path(url.resolvingSymlinksInPath()).lowercased() }
    func searchPaths(environment: [String: String], userHome: URL, applicationURLs: [URL]?, systemBinDirectories: [String]?) -> [ExecutableSearchPath] {
        WindowsCodexExecutableDiscovery.searchPaths(environment: environment, userHome: userHome,
            applicationURLs: applicationURLs, systemBinDirectories: systemBinDirectories ?? [])
    }
    func selectionKind(_ url: URL) -> ExecutableSelectionKind? {
        guard let info = WindowsFileSystem().metadata(url, followingSymbolicLinks: true) else { return nil }
        return info.isDirectory ? .directory : .file
    }
    func selectionURLs(_ url: URL, isDirectory: Bool) -> [URL] {
        isDirectory ? WindowsCodexExecutableDiscovery.folderURLs(url) : [url]
    }
    func launchEnvironment(for executable: URL, inherited: [String: String], userHome: URL) -> [String: String] {
        WindowsCodexExecutableDiscovery.launchEnvironment(executable: executable, inherited: inherited)
    }
}

extension CodexExecutableResolver {
    public static func discover(customPath: String = "", environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser, applicationURLs: [URL]? = nil,
        systemBinDirectories: [String] = []) -> Report {
        discover(customPath: customPath, environment: environment, userHome: userHome,
            applicationURLs: applicationURLs, systemBinDirectories: systemBinDirectories, platform: WindowsExecutablePlatform())
    }
    public static func isExecutableFile(_ url: URL) -> Bool { WindowsExecutablePlatform().isExecutableFile(url) }
    public static func launchEnvironment(for executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        WindowsExecutablePlatform().launchEnvironment(for: executable, inherited: inherited, userHome: userHome)
    }
}

extension CodexClient {
    public init(executable: URL, home: URL, arguments: [String] = ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"],
                timeout: TimeInterval = 12, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(executable: executable, home: home, arguments: arguments, timeout: timeout, environment: environment,
            processes: WindowsChildProcessLauncher(), executables: WindowsExecutablePlatform(), files: WindowsFileSystem())
    }
    public static func findExecutable(customPath: String = "") -> URL? { CodexExecutableResolver.discover(customPath: customPath).selected?.url }
}

struct WindowsInstallationProbe: ProviderInstallationProbe {
    let userHome: URL, environment: [String: String], applicationURLs: [AgentProvider: [URL]]?, systemBinDirectories: [String]
    func detect() -> ProviderInstallationDetection {
        WindowsProviderInstallation.detect(userHome: userHome, environment: environment,
            applicationURLs: applicationURLs, systemBinDirectories: systemBinDirectories)
    }
}
extension ProviderInstallationDetection {
    public static func detect(userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment, applicationURLs: [AgentProvider: [URL]]? = nil,
        systemBinDirectories: [String] = []) -> Self {
        detect(using: WindowsInstallationProbe(userHome: userHome, environment: environment,
            applicationURLs: applicationURLs, systemBinDirectories: systemBinDirectories))
    }
}

enum DeepSeekSessionLocks {
    static func name(for path: URL) -> String {
        let canonical = WindowsCodexExecutableDiscovery.path(path.standardizedFileURL).lowercased()
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Local\\dsh-session-lock-" + hash
    }
    static func held(_ locks: [String: URL]) -> Set<String> {
        Set(locks.filter { _, path in
            pacer_named_semaphore_exists(Array((name(for: path) + "\0").utf16)) != 0
        }.keys)
    }
}

extension ClaudeDesktopRecords {
    static func load(configFiles: [URL]) -> [Record] { load(configFiles: configFiles, files: WindowsFileSystem()) }
}

public enum ClaudeSSHRouteResolver {
    static let maximumOutputBytes = ClaudeSSHRouteRules.maximumOutputBytes
    static func parse(_ data: Data) -> ClaudeSSHRoute? { ClaudeSSHRouteRules.parse(data, normalizeIPv6: WindowsIP.normalizedIPv6) }
    static func validDestination(_ value: String) -> Bool { ClaudeSSHRouteRules.validDestination(value, normalizeIPv6: WindowsIP.normalizedIPv6) }
    public static func resolve(host: String, port: Int? = nil, executable: URL? = nil,
                               timeout: TimeInterval = 3) async -> ClaudeSSHRoute? {
        guard validDestination(host), port.map({ (1...65535).contains($0) }) ?? true,
              timeout.isFinite, timeout > 0, !Task.isCancelled else { return nil }
        var arguments = ["-G", "-o", "CanonicalizeHostname=no", "-o", "PermitLocalCommand=no",
                         "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"]
        if let port { arguments += ["-p", String(port)] }
        arguments += ["--", host]
        guard let data = await WindowsSubprocess.capture(executable: executable ?? WindowsExecutables.ssh, arguments: arguments,
            timeout: min(3, timeout), limit: maximumOutputBytes) else { return nil }
        return parse(data)
    }
}
#endif
