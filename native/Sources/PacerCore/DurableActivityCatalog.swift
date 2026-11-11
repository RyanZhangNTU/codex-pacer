import Foundation

/// Only a fresh catalog grants live access. Suspension lets the host keep the
/// account's inbox hidden until its scope is verified again.
package enum DurableCatalogPublication: Equatable, Sendable {
    case available(DurableActivityCatalog)
    case suspended
    case accountVerified(String)
    case revoked

    package var catalog: DurableActivityCatalog? {
        if case .available(let catalog) = self { return catalog }
        return nil
    }
}

/// Catalog reads may retry many times under the same account. Only a new
/// access boundary needs to be sent to the desktop session.
package struct DurableAccountPublication {
    package private(set) var scope: String?
    private var boundary: DurableCatalogPublication?

    package init() {}

    package mutating func suspend() -> DurableCatalogPublication? {
        guard boundary == nil else { return nil }
        boundary = .suspended
        return boundary
    }

    package mutating func verify(_ scope: String) -> DurableCatalogPublication? {
        guard self.scope != scope else { return nil }
        self.scope = scope
        boundary = .accountVerified(scope)
        return boundary
    }

    package mutating func catalogAvailable() { boundary = nil }

    package mutating func revoke() -> DurableCatalogPublication? {
        scope = nil
        guard boundary != .revoked else { return nil }
        boundary = .revoked
        return boundary
    }
}

/// The catalog grants access to a thread on this executor. Lifecycle and
/// progress require evidence from IPC or that thread's own Durable history.
public struct DurableActivityCatalog: Equatable, Sendable {
    public static let hostID = "durable"
    public let scope: String
    public let threadIDs: Set<String>
    package let activeThreadIDs: Set<String>
    package static let capacity = 64

    public init(scope: String, threadIDs: [String]) {
        self.init(scope: scope, threadIDs: threadIDs, activeThreadIDs: [])
    }

    package init(scope: String, threadIDs: [String], activeThreadIDs: Set<String>) {
        self.scope = scope
        self.threadIDs = Set(threadIDs.prefix(Self.capacity).compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        self.activeThreadIDs = self.threadIDs.intersection(activeThreadIDs)
    }

    /// Idle rows expire unless the reader is still checking a turn that was active.
    package static let recentWindow: TimeInterval = 180

    public struct Page: Sendable {
        package let entries: [Entry]
        public var threadIDs: [String] { entries.map(\.id) }
        public let nextCursor: String?
        /// The oldest update among all rows on the page, of any source.
        package let oldestUpdate: Date?
    }

    package struct Entry: Sendable {
        package let id: String
        package let name: String?
        package let updatedAt: Date?
        package let active: Bool
    }

    package static func page(_ result: JSONFieldView, environmentID: String, retaining: Set<String> = [],
                             now: Date = Date()) throws -> Page {
        let fields = try result.fields(["data", "nextCursor"])
        guard let data = fields["data"], data.isArray else { throw CodexClientError.invalidResponse }
        let recent = now.addingTimeInterval(-recentWindow).timeIntervalSince1970
        var threads: [Entry] = [], oldest: Double?
        for entry in try data.elements(maximumCount: 100) {
            let row = try entry.fields(["id", "name", "threadSource", "updatedAt", "status", "environments", "ephemeral"])
            let updated = row["updatedAt"]?.number()
            if let updated { oldest = min(oldest ?? updated, updated) }
            let status = try row["status"].flatMap { $0.isObject ? try $0.fields(["type"])["type"]?.string() : nil }
            guard let environments = row["environments"], environments.isArray else { continue }
            let local = try environments.elements(maximumCount: 32).contains { environment in
                try environment.fields(["environmentId"])["environmentId"]?.string(limit: 128) == environmentID
            }
            guard local else { continue }
            guard row["ephemeral"]?.boolean() != true,
                  ["aeon", "aeon_child"].contains(row["threadSource"]?.string() ?? ""),
                  let value = row["id"]?.string(limit: 36), let id = UUID(uuidString: value)?.uuidString.lowercased(),
                  status == "active" || (updated ?? 0) >= recent || retaining.contains(id) else { continue }
            threads.append(Entry(id: id, name: row["name"]?.string(limit: 512),
                                 updatedAt: updated.map(Date.init(timeIntervalSince1970:)), active: status == "active"))
        }
        return Page(entries: threads, nextCursor: fields["nextCursor"]?.string(limit: 1024),
                    oldestUpdate: oldest.map(Date.init(timeIntervalSince1970:)))
    }
}
