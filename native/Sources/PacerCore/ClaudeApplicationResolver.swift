import Foundation
import CoreServices

public enum ClaudeApplicationResolver {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    private final class Located: @unchecked Sendable {
        let lock = NSLock(); var application: (url: URL?, at: Date)?; var executable: (url: URL?, at: Date)?
    }
    private static let located = Located()
    /// Task rows ask on every render whether Claude can open; installations
    /// change rarely, so reuse a lookup for a minute instead of rescanning.
    public static func cachedApplication(now: Date = Date()) -> URL? {
        located.lock.lock(); defer { located.lock.unlock() }
        if let value = located.application, now.timeIntervalSince(value.at) < 60 { return value.url }
        let url = find(); located.application = (url, now); return url
    }
    public static func cachedExecutable(now: Date = Date()) -> URL? {
        located.lock.lock(); defer { located.lock.unlock() }
        if let value = located.executable, now.timeIntervalSince(value.at) < 60 { return value.url }
        let url = findExecutable(); located.executable = (url, now); return url
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

    /// Desktop mirrors SSH/WSL transcripts into its default local Claude home.
    /// Exclude only a unique active-profile remote context; never infer a host
    /// from a UUID shared by independently observed local/SSH sessions.
    public static func remoteMirrorSessionIDs(claudeHome: URL,
                                             userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        guard claudeHome.standardizedFileURL == userHome.appendingPathComponent(".claude").standardizedFileURL else { return [] }
        let records = Dictionary(grouping: desktopMetadata(userHome: userHome), by: { $0.canonicalCLI! })
        return Set(records.compactMap { id, contexts in
            guard contexts.count == 1, let context = contexts.first,
                  (context.sshConfig != nil) != (context.wslConfig != nil) else { return nil }
            if let ssh = context.sshConfig {
                guard !ssh.sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ssh.sshHost.utf8.count <= 256,
                      !ssh.sshHost.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      ssh.sshPort.map({ (1...65_535).contains($0) }) ?? true else { return nil }
            }
            return id
        })
    }

    /// Prefer an existing Desktop context only when its stored host route agrees
    /// with the source that supplied the observed CLI session. An SSH activity
    /// never borrows a local session's UUID or a connection's display name.
    public static func desktopSessionID(for sessionID: String, sourceHostID: String?,
                                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) async -> String? {
        await desktopSessionID(for: sessionID, sourceHostID: sourceHostID, userHome: userHome) { host, port in
            await ClaudeSSHRouteResolver.resolve(host: host, port: port)
        }
    }

    static func desktopSessionID(for sessionID: String, sourceHostID: String?, userHome: URL,
                                resolve: @escaping @Sendable (String, Int?) async -> ClaudeSSHRoute?) async -> String? {
        guard sessionID.count == 36, let session = UUID(uuidString: sessionID) else { return nil }
        let records = await Task.detached(priority: .utility) { desktopMetadata(userHome: userHome) }.value
        guard !Task.isCancelled else { return nil }
        let candidates = records.filter { $0.canonicalCLI == session.uuidString.lowercased() }
        if sourceHostID == nil {
            let local = candidates.filter { $0.sshConfig == nil && $0.wslConfig == nil }
            return Set(local.map(\.sessionId)).count == 1 ? local.first?.sessionId : nil
        }
        let prefix = "remote-ssh-discovered:"
        guard let sourceHostID, sourceHostID.hasPrefix(prefix) else { return nil }
        let alias = String(sourceHostID.dropFirst(prefix.count))
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil,
              let target = await resolve(alias, nil) else { return nil }
        let remote = candidates.filter { $0.sshConfig != nil && $0.wslConfig == nil }
        guard remote.count <= 4 else { return nil }
        var matches = Set<String>()
        for metadata in remote {
            guard !Task.isCancelled else { return nil }
            guard let connection = metadata.sshConfig,
                  let route = await resolve(connection.sshHost, connection.sshPort), route == target else { continue }
            matches.insert(metadata.sessionId)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private struct DesktopSSHConfig: Decodable, Sendable { let sshHost: String; let sshPort: Int? }
    private struct DesktopContextMarker: Decodable, Sendable {
        private enum Keys: String, CodingKey { case distribution }
        init(from decoder: Decoder) throws { _ = try decoder.container(keyedBy: Keys.self) }
    }
    private struct DesktopSessionMetadata: Decodable, Sendable {
        let sessionId: String
        let cliSessionId: String?
        let sshConfig: DesktopSSHConfig?
        let wslConfig: DesktopContextMarker?
        var canonicalCLI: String? { cliSessionId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() }
    }

    private static func desktopMetadata(userHome: URL) -> [DesktopSessionMetadata] {
        struct DesktopConfig: Decodable { let lastKnownAccountUuid: String? }
        let base = userHome.appendingPathComponent("Library/Application Support/Claude")
        guard let configData = ClaudeCredentialStore.boundedData(at: base.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(DesktopConfig.self, from: configData),
              let account = config.lastKnownAccountUuid, UUID(uuidString: account) != nil else { return [] }
        let root = base.appendingPathComponent("claude-code-sessions").appendingPathComponent(account)
        let manager = FileManager.default
        func directory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard directory(root) else { return [] }
        let organizations = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles])) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && directory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(16)
        var result: [DesktopSessionMetadata] = [], checked = 0
        for org in organizations {
            let files = ((try? manager.contentsOfDirectory(at: org, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("local_") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard checked < 128 else { return result }
                checked += 1
                let name = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: String(name.dropFirst("local_".count))) != nil,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let data = ClaudeCredentialStore.boundedData(at: file),
                      let metadata = try? JSONDecoder().decode(DesktopSessionMetadata.self, from: data), metadata.sessionId == name,
                      metadata.canonicalCLI != nil else { continue }
                result.append(metadata)
            }
        }
        return result
    }

    private static func bundledExecutables(in directory: URL) -> [URL] {
        ["claude.app/Contents/MacOS/claude", "Claude Code.app/Contents/MacOS/claude", "claude"].map {
            directory.appendingPathComponent($0)
        }
    }
}
