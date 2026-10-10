import Foundation

/// The service that owns a session. Host names alone are not session identity.
public enum AgentProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude
    public var id: String { rawValue }
    public var displayName: String { self == .codex ? "Codex" : "Claude" }

    /// Keep existing Codex keys unchanged so its retained state remains compatible.
    public func activityID(sessionID: String, sourceHostID: String? = nil) -> String {
        let host = sourceHostID ?? "local"
        return (self == .claude ? "claude:" : "") + host + ":" + sessionID
    }

    public func validatedSessionID(_ value: String) -> String? {
        if let uuid = UUID(uuidString: value) { return uuid.uuidString.lowercased() }
        guard self == .claude, !value.isEmpty, value.utf8.count <= 256,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    func sessionID(in identity: String) -> String? {
        if self == .claude {
            return validatedSessionID(String(identity.split(separator: ":").last ?? ""))
        }
        // Dotted SSH aliases must not be interpreted as a rollout extension.
        return (UUID(uuidString: String(identity.suffix(36))) ??
            UUID(uuidString: String((identity as NSString).deletingPathExtension.suffix(36))))?.uuidString.lowercased()
    }
}
