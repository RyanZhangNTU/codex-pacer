import Foundation
import PacerCore

/// Script digests are cached per configured alias, without keys or settings
/// contents, together with why an alias's setup kept Pacer's request
/// telemetry off. That reason sets how soon the host is checked again.
final class WindowsClaudeRemoteDigestStore: @unchecked Sendable {
    /// Conflicts are optional within version 1; builds without them ignore the field.
    private struct Envelope: Codable {
        let version: Int
        let claudeRemoteSetupDigests: [String: String]
        var claudeRemoteTelemetryConflicts: [String: String]?
    }
    private struct State { var digests: [String: String]; var conflicts: [String: ClaudeTelemetryConflict] }
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
    private static func validAlias(_ alias: String) -> Bool {
        alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil
    }
    private func decode(_ data: Data) -> State? {
        guard data.count <= 16384, let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.claudeRemoteSetupDigests.count <= 32,
              value.claudeRemoteSetupDigests.allSatisfy({ alias, digest in
                  Self.validAlias(alias) && digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }),
              (value.claudeRemoteTelemetryConflicts?.count ?? 0) <= 32,
              value.claudeRemoteTelemetryConflicts?.keys.allSatisfy(Self.validAlias) ?? true else { return nil }
        // A reason a later build added, or one for an alias without a digest, is dropped.
        let conflicts = (value.claudeRemoteTelemetryConflicts ?? [:]).compactMapValues(ClaudeTelemetryConflict.init(rawValue:))
            .filter { value.claudeRemoteSetupDigests[$0.key] != nil && $0.value != ClaudeTelemetryConflict.none }
        return .init(digests: value.claudeRemoteSetupDigests, conflicts: conflicts)
    }
    private func read() -> Data? {
        guard safePath(), let info = files.metadata(file), info.isRegularFile, info.size <= 16384,
              let bytes = try? files.read(file, offset: 0, maximumBytes: 16385), bytes.count == info.size,
              files.metadata(file) == info else { return nil }
        return bytes
    }
    func load() -> [String: String] { lock.lock(); defer { lock.unlock() }; return read().flatMap(decode)?.digests ?? [:] }
    func loadConflicts() -> [String: ClaudeTelemetryConflict] { lock.lock(); defer { lock.unlock() }; return read().flatMap(decode)?.conflicts ?? [:] }
    func save(_ digests: [String: String]) { update { $0.digests = digests } }
    func save(conflicts: [String: ClaudeTelemetryConflict]) { update { $0.conflicts = conflicts } }
    /// Each save keeps the other half of the stored state.
    private func update(_ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard safePath() else { return }
        var state = State(digests: [:], conflicts: [:])
        if files.metadata(file) != nil || FileManager.default.fileExists(atPath: file.path) {
            // Preserve future or unreadable data; an uncached setup stays idempotent.
            guard let previous = read(), let decoded = decode(previous) else { return }
            state = decoded
        }
        change(&state)
        let conflicts = state.conflicts.filter { state.digests[$0.key] != nil && $0.value != ClaudeTelemetryConflict.none }
        let envelope = Envelope(version: 1, claudeRemoteSetupDigests: state.digests,
            claudeRemoteTelemetryConflicts: conflicts.isEmpty ? nil : conflicts.mapValues(\.rawValue))
        guard let bytes = try? JSONEncoder().encode(envelope), decode(bytes) != nil else { return }
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
            argumentBuilder: { target, requireHome, progressRing, automatic in
                if target.id.hasPrefix(ConnectionSource.wslPrefix) {
                    guard let wsl else { throw ClaudeRemoteSetup.Failure.invalidTarget }
                    return try wsl.setupArguments(target, requireHome: requireHome, progressRing: progressRing, automatic: automatic)
                }
                return try ClaudeRemoteSetup.arguments(target: target, requireHome: requireHome, progressRing: progressRing, automatic: automatic,
                    validDestination: { ClaudeSSHRouteResolver.validDestination($0) }, validIdentityFile: { WindowsSSHServices.validIdentity($0) })
            })
        return .init(digest: { $0 ? ringDigest : digest },
            install: { try await setup.install(target: $0, requireHome: true, progressRing: $1, automatic: $2) },
            shutdown: { await setup.shutdown() },
            loadDigests: { store.load() }, saveDigests: { store.save($0) },
            loadConflicts: { store.loadConflicts() }, saveConflicts: { store.save(conflicts: $0) })
    }
}
