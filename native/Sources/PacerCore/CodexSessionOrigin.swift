import Foundation

/// Launch classification only: raw client names never enter activity or frames.
/// Verified against openai/codex rust-v0.162.1:
/// login/src/auth/default_client.rs (first-party clients), tui/src/lib.rs and
/// exec/src/lib.rs (initialize.clientInfo.name). Desktop uses "Codex Desktop".
public struct CodexSessionOrigin: Equatable, Sendable {
    public let embedded: Bool
    public let ignored: Bool
    public init(embedded: Bool, ignored: Bool) { self.embedded = embedded; self.ignored = ignored }
    public static let officialClients = ["Codex Desktop", "codex_cli_rs", "codex-tui", "codex_vscode",
                                         "codex_exec", "codex_atlas", "codex_chatgpt_desktop"]

    public static func classify(originator: String?, cwd: String?) -> Self? {
        guard let originator, !originator.isEmpty, originator.utf8.count <= 256 else { return nil }
        let embedded = !officialClients.contains(originator)
        let parts = (cwd ?? "").split(separator: "/")
        // Zotero Agent 0.14.0 uses these dedicated translation/catalog folders.
        // Its Codex ACP adapter ignores ephemeral, so these rollouts exist.
        let translation = parts.suffix(2).map(String.init) == ["zotero-chat", "translate"]
        let catalog = parts.last?.hasPrefix("zotero-chat-catalog.") == true
        return Self(embedded: embedded, ignored: embedded && (translation || catalog))
    }

    static func sanitized(_ values: [String: Any]) -> Self? {
        if let originator = values["originator"] as? String { return classify(originator: originator, cwd: values["cwd"] as? String) }
        if let embedded = values["embedded"] as? Bool, let ignored = values["ignoredSession"] as? Bool {
            return Self(embedded: embedded, ignored: ignored)
        }
        return classify(originator: values["originator"] as? String, cwd: values["cwd"] as? String)
    }

    /// Resolve descendants against their current parent, without changing the
    /// reader's baseline. Provider and host-qualified IDs prevent cross-talk.
    public static func inheriting(_ values: [SessionActivity]) -> [SessionActivity] {
        var result = Dictionary(values.map { ($0.canonicalized().id, $0) }, uniquingKeysWith: { _, latest in latest })
        for _ in 0..<64 {
            var changed = false
            for (id, value) in result where value.provider == .codex {
                guard let parent = value.parentThreadID,
                      let origin = result[AgentProvider.codex.activityID(sessionID: parent, sourceHostID: value.sourceHostID)]?.codexOrigin,
                      origin != value.codexOrigin else { continue }
                result[id]?.inheritCodexOrigin(origin); changed = true
            }
            if !changed { break }
        }
        return values.compactMap { result[$0.canonicalized().id] }
    }

    /// Generated from the same client list as the native policy. Both SSH
    /// adapters use this definition; parity tests cover the path rules.
    static let python = """
    CODEX_OFFICIAL_CLIENTS = \(String(data: try! JSONSerialization.data(withJSONObject: officialClients), encoding: .utf8)!)
    def codex_origin(originator,cwd):
        if not isinstance(originator,str) or not originator or len(originator.encode('utf-8'))>256:return None
        embedded=originator not in CODEX_OFFICIAL_CLIENTS
        parts=[v for v in (cwd if isinstance(cwd,str) else '').split('/') if v]
        ignored=embedded and (parts[-2:]==['zotero-chat','translate'] or bool(parts and parts[-1].startswith('zotero-chat-catalog.')))
        return {'embedded':embedded,'ignoredSession':ignored}
    """
}

/// Bounded metadata-only lookup, also used before a runtime subscription. The
/// tail permits an official client to resume a previously embedded thread.
public struct CodexRolloutMetadata: Sendable {
    public let origin: CodexSessionOrigin
    public let url: URL
    public let observedAt: Date?
    public let parentThreadID: String?
    private static let dates = LogDateParser()
    static func read(_ url: URL, threadID: String? = nil) -> Self? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        var head = Data()
        while head.count < 1024 * 1024, !head.contains(10) {
            guard let chunk = try? handle.read(upToCount: 32768), !chunk.isEmpty else { break }
            head.append(chunk)
        }
        var rows = head.split(separator: 10).map(Data.init)
        if size > UInt64(head.count), head.last != 10 { rows.removeLast() }
        if size > UInt64(head.count) {
            try? handle.seek(toOffset: size - min(size, 128 * 1024))
            let tail = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
            rows += tail.split(separator: 10).dropFirst().map(Data.init)
        }
        var found: Self?
        for row in rows {
            guard row.count <= 1024 * 1024,
                  let document = try? JSONFieldView.document(row, maximumBytes: 1024 * 1024),
                  let root = try? document.fields(["type", "payload", "timestamp"]), root["type"]?.string(limit: 32) == "session_meta",
                  let fields = try? root["payload"]?.fields(["id", "originator", "cwd", "source", "parent_thread_id", "parentThreadId"]),
                  threadID == nil || fields["id"]?.string(limit: 36)?.lowercased() == threadID?.lowercased() else { continue }
            let at = root["timestamp"]?.string().flatMap(dates.parse)
            if let previous = found?.observedAt, let at, at < previous { continue }
            let source = try? fields["source"]?.fields(["subAgent", "subagent"])
            let sub = try? (source?["subAgent"] ?? source?["subagent"])?.fields(["thread_spawn", "threadSpawn"])
            let spawn = try? (sub?["thread_spawn"] ?? sub?["threadSpawn"])?.fields(["parent_thread_id", "parentThreadId"])
            let parent = (fields["parent_thread_id"] ?? fields["parentThreadId"] ?? spawn?["parent_thread_id"] ?? spawn?["parentThreadId"])?
                .string(limit: 36).flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
            guard let origin = CodexSessionOrigin.classify(originator: fields["originator"]?.string(limit: 256), cwd: fields["cwd"]?.string(limit: 4096)) ??
                (parent == nil ? nil : CodexSessionOrigin(embedded: false, ignored: false)) else { continue }
            found = Self(origin: origin, url: url, observedAt: at, parentThreadID: parent)
        }
        return found
    }
}

/// One lookup object per collector; no global profile or account cache.
final class CodexOriginLookup {
    private let home: URL
    private var files: [URL] = []
    private var scannedAt = Date.distantPast
    private var cache: [URL: (inode: UInt64, size: UInt64, modified: Date, value: CodexRolloutMetadata?)] = [:]
    init(home: URL) { self.home = home }
    func lookup(_ threadID: String) -> CodexRolloutMetadata? {
        lookup(threadID, visited: [])
    }
    private func lookup(_ threadID: String, visited: Set<String>) -> CodexRolloutMetadata? {
        guard UUID(uuidString: threadID) != nil, !visited.contains(threadID), visited.count < 64 else { return nil }
        let now = Date()
        if now.timeIntervalSince(scannedAt) >= 2 {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
            var candidates = SessionIndex.files(home: home, limit: 256)
            for day in [now, now.addingTimeInterval(-86400)] {
                let directory = home.appendingPathComponent("sessions/" + formatter.string(from: day))
                candidates += ((try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension == "jsonl" }
            }
            let dated = Set(candidates).map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            files = dated.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(512).map(\.0)
            scannedAt = now; cache = cache.filter { files.contains($0.key) }
        }
        guard let file = files.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(threadID.lowercased()) }),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value, let modified = attributes[.modificationDate] as? Date else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let value: CodexRolloutMetadata?
        if let old = cache[file], old.inode == inode, old.size == size, old.modified == modified { value = old.value }
        else { value = CodexRolloutMetadata.read(file, threadID: threadID); cache[file] = (inode, size, modified, value) }
        if let value, let parent = value.parentThreadID, let owner = lookup(parent, visited: visited.union([threadID])) {
            return CodexRolloutMetadata(origin: owner.origin, url: value.url,
                observedAt: owner.observedAt ?? value.observedAt, parentThreadID: parent)
        }
        return value
    }
}
