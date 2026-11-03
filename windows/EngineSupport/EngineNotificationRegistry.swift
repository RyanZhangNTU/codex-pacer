import Foundation
import PacerCore

/// Windows notification arguments refer only to these bounded, expiring
/// records. Disk records contain hashes and fixed action names, never labels,
/// paths, URLs, task text, account identifiers or credentials.
struct EngineNotificationRegistry {
    struct Record: Codable, Equatable {
        let reference: String, kind: String, provider: AgentProvider, source: String, scope: String
        let target: String?
        let created: Date
    }
    struct Store {
        let url: URL
        let files: any PlatformFileSystem
        static var applicationDefault: Self {
            .init(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexPacer/Notifications/actions-v1.json"), files: WindowsFileSystem())
        }
    }
    private(set) var records: [Record]
    private let store: Store?
    static let capacity = 128
    static let lifetime: TimeInterval = 24 * 3600
    static func validReference(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validKind(_ value: String) -> Bool { ["showIsland", "openTask", "topUp", "openHarness", "snoozeSpike"].contains(value) }
    private static func valid(_ value: Record, at now: Date) -> Bool {
        validReference(value.reference) && validKind(value.kind) && ["local", "cloud", "quota", "wallet"].contains(value.scope) && value.source.utf8.count == 64 &&
            (value.target == nil || value.target?.utf8.count == 64) && (value.kind != "openTask" || value.target != nil) &&
            now >= value.created && now.timeIntervalSince(value.created) < lifetime
    }
    init(store: Store? = nil, now: Date) {
        self.store = store
        if let store, let meta = store.files.metadata(store.url), meta.isRegularFile, meta.size <= 64 * 1024,
           let data = try? store.files.read(store.url, offset: 0, maximumBytes: 64 * 1024),
           let saved = try? JSONDecoder().decode([Record].self, from: data), saved.count <= Self.capacity,
           Set(saved.map(\.reference)).count == saved.count, saved.allSatisfy({ Self.valid($0, at: now) }) { records = saved }
        else { records = [] }
    }
    private func save(_ values: [Record]) -> Bool {
        guard let store else { return true }
        if let existing = store.files.metadata(store.url), !existing.isRegularFile { return false }
        if let parent = store.files.metadata(store.url.deletingLastPathComponent()), !parent.isDirectory { return false }
        guard let bytes = try? JSONEncoder().encode(values), bytes.count <= 64 * 1024 else { return false }
        return store.files.replace(store.url, with: bytes)
    }
    mutating func issue(kind: String, provider: AgentProvider, source: String, scope: String = "local", target: String? = nil, now: Date) -> String? {
        let value = Record(reference: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                           kind: kind, provider: provider, source: source, scope: scope, target: target, created: now)
        guard Self.valid(value, at: now) else { return nil }
        var next = records.filter { Self.valid($0, at: now) }
        next.append(value)
        next = Array(next.suffix(Self.capacity))
        guard save(next) else { return nil }
        records = next; return value.reference
    }
    func record(_ reference: String, at now: Date) -> Record? {
        guard Self.validReference(reference) else { return nil }
        return records.first { $0.reference == reference && Self.valid($0, at: now) }
    }
    mutating func consume(_ reference: String, source: String?, kind: String, at now: Date) -> Record? {
        guard let value = record(reference, at: now), value.kind == kind, value.source == source else { return nil }
        let next = records.filter { $0.reference != reference && Self.valid($0, at: now) }
        guard save(next) else { return nil }
        records = next; return value
    }
    static func target(_ entry: ActivityNavigationRegistry.Entry) -> String {
        var fields = ["notification-task-v1", entry.target.id, entry.target.threadID ?? "", entry.target.parentThreadID ?? "",
                      entry.target.turnID ?? "", entry.target.phase.rawValue,
                      entry.target.phaseChangedAt.map { String($0.timeIntervalSince1970) } ?? "",
                      entry.target.claudeCloud?.completionMark.map { String($0.timeIntervalSince1970) } ?? ""]
        for member in entry.members {
            fields += [member.id, member.thread ?? "", member.parent ?? "", member.turn ?? "", member.phase.rawValue, member.ending ?? ""]
            if member.turn == nil { fields.append(member.started.map { String($0.timeIntervalSince1970) } ?? "") }
        }
        return CompletionDismissalStore.digest(fields)
    }
}

struct EngineNotificationActivation: Codable {
    let kind: String
    let link: EngineActivityLink?
}
