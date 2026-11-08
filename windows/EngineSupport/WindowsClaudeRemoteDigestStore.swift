import Foundation
import PacerCore

/// Script digests are cached per configured alias, without keys or settings contents.
final class WindowsClaudeRemoteDigestStore: @unchecked Sendable {
    private struct Envelope: Codable { let version: Int; let claudeRemoteSetupDigests: [String: String] }
    private let lock = NSLock()
    private let file: URL
    private let files: any PlatformFileSystem
    init(file: URL, files: any PlatformFileSystem = WindowsFileSystem()) { self.file = file; self.files = files }
    private func safePath() -> Bool {
        var path = file
        while true {
            if let info = files.metadata(path), path == file ? !info.isRegularFile : !info.isDirectory { return false }
            let parent = path.deletingLastPathComponent()
            if parent == path { return true }
            path = parent
        }
    }
    private func decode(_ data: Data) -> [String: String]? {
        guard data.count <= 16384, let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.claudeRemoteSetupDigests.count <= 32,
              value.claudeRemoteSetupDigests.allSatisfy({ alias, digest in
                  alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil &&
                  digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }) else { return nil }
        return value.claudeRemoteSetupDigests
    }
    private func read() -> Data? {
        guard safePath(), let info = files.metadata(file), info.isRegularFile, info.size <= 16384,
              let bytes = try? files.read(file, offset: 0, maximumBytes: 16385), bytes.count == info.size,
              files.metadata(file) == info else { return nil }
        return bytes
    }
    func load() -> [String: String] { lock.lock(); defer { lock.unlock() }; return read().flatMap(decode) ?? [:] }
    func save(_ digests: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        guard safePath(), let bytes = try? JSONEncoder().encode(Envelope(version: 1, claudeRemoteSetupDigests: digests)), decode(bytes) != nil else { return }
        if files.metadata(file) != nil || FileManager.default.fileExists(atPath: file.path) {
            // Preserve future or unreadable data; an uncached setup stays idempotent.
            guard let previous = read(), decode(previous) != nil else { return }
        }
        _ = files.replace(file, with: bytes)
    }
}

extension EngineClaudeRemoteServices {
    static func live(ssh: WindowsSSHServices? = nil, wsl: WindowsWSLServices? = nil) -> Self? {
        guard ssh != nil || wsl != nil, let digest = try? ClaudeRemoteSetup.adapterDigest(),
              let ringDigest = try? ClaudeRemoteSetup.adapterDigest(progressRing: true) else { return nil }
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacer/ClaudeRemote/setup-v1.json")
        let store = WindowsClaudeRemoteDigestStore(file: home)
        let setup = ClaudeRemoteSetup(executable: ssh?.ssh ?? WindowsExecutables.ssh, makeOperation: { executable, args in
            WindowsClaudeSetupOperation(executable: executable, arguments: args,
                environment: ssh?.environment ?? ProcessInfo.processInfo.environment, wsl: wsl)
        }, validDestination: { ClaudeSSHRouteResolver.validDestination($0) }, validIdentityFile: { WindowsSSHServices.validIdentity($0) },
            argumentBuilder: { target, requireHome, progressRing in
                if target.id.hasPrefix(ConnectionSource.wslPrefix) {
                    guard let wsl else { throw ClaudeRemoteSetup.Failure.invalidTarget }
                    return try wsl.setupArguments(target, requireHome: requireHome, progressRing: progressRing)
                }
                return try ClaudeRemoteSetup.arguments(target: target, requireHome: requireHome, progressRing: progressRing,
                    validDestination: { ClaudeSSHRouteResolver.validDestination($0) }, validIdentityFile: { WindowsSSHServices.validIdentity($0) })
            })
        return .init(digest: { $0 ? ringDigest : digest }, install: { try await setup.install(target: $0, requireHome: true, progressRing: $1) },
            shutdown: { await setup.shutdown() },
            loadDigests: { store.load() }, saveDigests: { store.save($0) })
    }
}
