import Foundation

/// A catalog page only grants permission to follow a thread. Runtime evidence
/// still comes from its Desktop IPC owner.
public struct DurableActivityCatalog: Equatable, Sendable {
    public static let hostID = "durable"
    public let scope: String
    public let threadIDs: Set<String>

    public init(scope: String, threadIDs: [String]) {
        self.scope = scope
        self.threadIDs = Set(threadIDs.prefix(64).compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
    }

    public struct Page: Sendable {
        public let threadIDs: [String]
        public let nextCursor: String?
        public let executorIdle: Bool
    }

    package static func page(_ result: JSONFieldView, environmentID: String, retaining: Set<String> = [],
                             now: Date = Date()) throws -> Page {
        let fields = try result.fields(["data", "nextCursor"])
        guard let data = fields["data"], data.isArray else { throw CodexClientError.invalidResponse }
        let recent = now.addingTimeInterval(-180).timeIntervalSince1970
        let quietSince = now.addingTimeInterval(-60).timeIntervalSince1970
        var threads: [String] = [], idle = true
        for entry in try data.elements(maximumCount: 100) {
            let row = try entry.fields(["id", "threadSource", "updatedAt", "status", "environments", "ephemeral"])
            let status = try row["status"].flatMap { $0.isObject ? try $0.fields(["type"])["type"]?.string() : nil }
            guard let environments = row["environments"], environments.isArray else {
                if status == "active" { idle = false }
                continue
            }
            let local = try environments.elements(maximumCount: 32).contains { environment in
                try environment.fields(["environmentId"])["environmentId"]?.string(limit: 128) == environmentID
            }
            guard local else { continue }
            let updated = row["updatedAt"]?.number()
            if status != "idle" || (updated ?? .infinity) >= quietSince { idle = false }
            guard row["ephemeral"]?.boolean() != true,
                  ["aeon", "aeon_child"].contains(row["threadSource"]?.string() ?? ""),
                  let value = row["id"]?.string(limit: 36), let id = UUID(uuidString: value)?.uuidString.lowercased(),
                  status == "active" || (updated ?? 0) >= recent || retaining.contains(id) else { continue }
            threads.append(id)
        }
        let next = fields["nextCursor"]?.string(limit: 1024)
        if fields["nextCursor"]?.isNull != true, next == nil { idle = false }
        return Page(threadIDs: threads, nextCursor: next, executorIdle: idle)
    }
}
