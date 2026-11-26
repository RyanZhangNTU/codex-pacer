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
    public static let antigravity = Self(registeredID: "antigravity")
    public static let workbuddy = Self(registeredID: "workbuddy")
    public static let workbuddyAI = Self(registeredID: "workbuddy-ai")
    public static var allCases: [Self] { HarnessRegistry.ids }

    public var id: String { rawValue }
    package var quotaGroups: HarnessQuotaGroups? { HarnessRegistry.descriptor(for: self)?.quotaGroups }
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
        // Dotted SSH aliases must not be interpreted as a rollout extension.
        return CodexRolloutName.threadID(in: identity) ?? CodexRolloutName.threadID(in: (identity as NSString).deletingPathExtension)
    }
}

/// Codex names a rollout `rollout-<time>-<thread>.jsonl`. A reverted thread
/// keeps its ID and gets a new file with a distinct rollout ID after it,
/// `rollout-<time>-<thread>_<rollout>.jsonl`; the thread is always the first.
enum CodexRolloutName {
    /// The thread ID that ends `name`, which has no extension.
    static func threadID(in name: String) -> String? {
        let tail = name.suffix(73)
        if tail.count == 73, tail.dropFirst(36).first == "_", UUID(uuidString: String(tail.suffix(36))) != nil,
           let thread = UUID(uuidString: String(tail.prefix(36))) {
            return thread.uuidString.lowercased()
        }
        return UUID(uuidString: String(name.suffix(36)))?.uuidString.lowercased()
    }

    /// The thread ID of a rollout file.
    static func threadID(of file: URL) -> String? { threadID(in: file.deletingPathExtension().lastPathComponent) }
}
