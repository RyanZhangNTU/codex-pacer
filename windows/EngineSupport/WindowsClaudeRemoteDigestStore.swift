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
    static func live(ssh: WindowsSSHServices) -> Self? {
        guard let digest = try? ClaudeRemoteSetup.adapterDigest() else { return nil }
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacer/ClaudeRemote/setup-v1.json")
        let store = WindowsClaudeRemoteDigestStore(file: home)
        let setup = ClaudeRemoteSetup(executable: ssh.ssh, makeOperation: { executable, args in
            WindowsClaudeSetupOperation(executable: executable, arguments: args,
                environment: ssh.environment ?? ProcessInfo.processInfo.environment)
        }, validDestination: { ClaudeSSHRouteResolver.validDestination($0) }, validIdentityFile: { WindowsSSHServices.validIdentity($0) })
        return .init(digest: digest, install: { try await setup.install(target: $0, requireHome: true) }, shutdown: { await setup.shutdown() },
            loadDigests: { store.load() }, saveDigests: { store.save($0) })
    }
}
