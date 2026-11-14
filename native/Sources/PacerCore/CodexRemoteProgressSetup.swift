import Foundation
import CryptoKit

/// Pacer's Codex progress tool on an SSH or WSL host. Codex starts MCP servers
/// from the config.toml of the host a task runs on, so the local registration
/// never reaches a remote task. Setup gives the host the same stdio reporter
/// the Windows app uses, run by the host's own python3, and one marked
/// `pacer_progress` table that Pacer owns. A same-name entry Pacer did not
/// write, or Pacer's table edited by hand, is left alone and reported as a
/// conflict. Hosts are set up again when the shipped files or the progress
/// ring switch change, with `ClaudeRemoteAutoSetup`'s schedule.
public enum CodexRemoteProgressSetup {
    public struct Status: Equatable, Sendable {
        public let configured: Bool
        public let conflict: Bool
        public init(configured: Bool, conflict: Bool) { self.configured = configured; self.conflict = conflict }
    }
    /// Configured digests by SSH alias or WSL source, as for Claude.
    public static let digestsKey = "codexRemoteProgressDigests"

    /// The remote command: Python 3.6+ with only the standard library. Off is
    /// stated too, so a host that had the tool loses Pacer's entries.
    public static func command(home: String, enabled: Bool) throws -> String {
        guard !home.isEmpty, home.utf8.count <= 4096,
              !home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ClaudeRemoteSetup.Failure.invalidTarget }
        let (installer, reporter) = try resources()
        var request: [String: Any] = ["home": home, "enabled": enabled]
        if enabled { request["reporter"] = reporter.base64EncodedString() }
        let payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return "python3 -u -c 'import base64;exec(base64.b64decode(\"\(installer.base64EncodedString())\").decode())' \(payload.base64EncodedString())"
    }

    /// Identifies the shipped installer and reporter, and whether the ring is on.
    public static func digest(enabled: Bool) throws -> String {
        let (installer, reporter) = try resources()
        var bytes = Data("codex-remote-progress".utf8); bytes.append(0); bytes.append(installer)
        if enabled { bytes.append(0); bytes.append(reporter) }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs setup on `target` through `transport`, which owns the SSH or WSL route.
    public static func install(target: RemoteActivityTarget, home: String? = nil, enabled: Bool,
                               transport: ClaudeRemoteSetup) async throws -> Status {
        let result = try await transport.run(target: target, command: try command(home: home ?? target.home, enabled: enabled))
        return try status(data: result.data, exitStatus: result.exitStatus)
    }

    static func status(data: Data, exitStatus: Int32) throws -> Status {
        guard data.count <= 4096 else { throw ClaudeRemoteSetup.Failure.invalidResponse }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw exitStatus == 0 ? ClaudeRemoteSetup.Failure.invalidResponse : ClaudeRemoteSetup.Failure.connectionFailed
        }
        if let error = value["error"] as? String {
            switch error {
            case "unsafePath": throw ClaudeRemoteSetup.Failure.unsafePath
            case "invalidSettings": throw ClaudeRemoteSetup.Failure.invalidSettings
            case "changedSettings": throw ClaudeRemoteSetup.Failure.changedSettings
            case "missingHome": throw ClaudeRemoteSetup.Failure.missingHome
            default: throw ClaudeRemoteSetup.Failure.setupFailed
            }
        }
        guard exitStatus == 0 else { throw ClaudeRemoteSetup.Failure.connectionFailed }
        let fields = try? JSONFieldView.document(data).fields(["configured", "conflict"])
        guard Set(value.keys) == ["configured", "conflict"], let configured = fields?["configured"]?.boolean(),
              let conflict = fields?["conflict"]?.boolean() else { throw ClaudeRemoteSetup.Failure.invalidResponse }
        return Status(configured: configured, conflict: conflict)
    }

    static func resources() throws -> (installer: Data, reporter: Data) {
        guard let installerURL = Bundle.module.url(forResource: "codex_remote_progress_setup", withExtension: "py"),
              let reporterURL = Bundle.module.url(forResource: "codex_progress_mcp", withExtension: "py"),
              let installer = try? Data(contentsOf: installerURL), !installer.isEmpty,
              let reporter = try? Data(contentsOf: reporterURL), !reporter.isEmpty else { throw ClaudeRemoteSetup.Failure.unavailableResources }
        return (installer, reporter)
    }

    public static func configuredDigests(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: digestsKey) as? [String: String] ?? [:]
    }

    public static func recordConfigured(alias: String, digest: String, defaults: UserDefaults = .standard) {
        var digests = configuredDigests(defaults: defaults)
        digests[alias] = digest
        // A bounded map; aliases come from validated targets.
        let kept = Dictionary(uniqueKeysWithValues: digests.sorted { $0.key < $1.key }.suffix(32).map { ($0.key, $0.value) })
        defaults.set(kept, forKey: digestsKey)
    }
}
