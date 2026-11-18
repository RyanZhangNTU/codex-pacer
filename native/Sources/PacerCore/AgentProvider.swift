import Foundation

/// The service that owns a session. Host names alone are not session identity.
public struct AgentProvider: RawRepresentable, Hashable, CaseIterable, Codable, Sendable, Identifiable {
    public let rawValue: String
    package init(registeredID: String) { rawValue = registeredID }
    public init?(rawValue: String) {
        guard let id = HarnessRegistry.registeredID(rawValue) else { return nil }
        self = id
    }

    public static let codex = Self(registeredID: "codex")
    public static let claude = Self(registeredID: "claude")
    public static let deepseek = Self(registeredID: "deepseek")
    public static let workbuddy = Self(registeredID: "workbuddy")
    public static let workbuddyAI = Self(registeredID: "workbuddy-ai")
    public static var allCases: [Self] { HarnessRegistry.ids }

    public var id: String { rawValue }
    public var displayName: String { HarnessRegistry.descriptor(for: self)?.name ?? rawValue }
    public var taskSymbol: String { HarnessRegistry.descriptor(for: self)?.symbol ?? "circle" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Harness ID")
        }
        self = id
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Keep existing Codex keys unchanged so its retained state remains compatible.
    public func activityID(sessionID: String, sourceHostID: String? = nil) -> String {
        let host = sourceHostID ?? "local"
        return (self == .codex ? "" : rawValue + ":") + host + ":" + sessionID
    }

    public func validatedSessionID(_ value: String) -> String? {
        if let uuid = UUID(uuidString: value) { return uuid.uuidString.lowercased() }
        guard self != .codex, self != .deepseek, !value.isEmpty, value.utf8.count <= 256,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    func sessionID(in identity: String) -> String? {
        if self != .codex {
            return validatedSessionID(String(identity.split(separator: ":").last ?? ""))
        }
        // A resumed rollout appends its own UUID after the original thread UUID.
        if identity.hasPrefix("rollout-"), identity.hasSuffix(".jsonl"),
           let separator = identity.lastIndex(of: "_"),
           UUID(uuidString: String(identity[identity.index(after: separator)...].dropLast(6))) != nil,
           let thread = UUID(uuidString: String(identity[..<separator].suffix(36))) {
            return thread.uuidString.lowercased()
        }
        // Dotted SSH aliases must not be interpreted as a rollout extension.
        return (UUID(uuidString: String(identity.suffix(36))) ??
            UUID(uuidString: String((identity as NSString).deletingPathExtension.suffix(36))))?.uuidString.lowercased()
    }
}
