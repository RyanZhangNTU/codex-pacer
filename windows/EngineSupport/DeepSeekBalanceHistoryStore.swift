import Foundation

/// One app-owned numeric history, matching the Mac preference's source binding.
/// Keys, account identities, task names and source paths are never encoded.
actor DeepSeekBalanceHistoryStore {
    private struct Envelope: Codable { let version: Int; let history: DeepSeekBalanceHistory }
    private let file: URL
    private var latestRevision: UInt64 = 0
    init(file: URL) { self.file = file }
    func load(now: Date) -> DeepSeekBalanceHistory {
        let earliest = Date(timeIntervalSince1970: 0), latest = now.addingTimeInterval(60)
        func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite && value >= earliest && value <= latest }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let count = attributes[.size] as? NSNumber, count.intValue <= 65536,
              let data = try? Data(contentsOf: file), data.count <= 65536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["history"] as? [String: Any], let charged = raw["charged"] as? [NSNumber],
              charged.count <= 64, charged.count.isMultiple(of: 2),
              charged.enumerated().allSatisfy({ $0.offset.isMultiple(of: 2) ? validDate(Date(timeIntervalSinceReferenceDate: $0.element.doubleValue)) :
                  $0.element.doubleValue.isFinite && $0.element.doubleValue >= 0 }),
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.history.source == nil || ["web", "apiKey"].contains(value.history.source!),
              value.history.since.map(validDate) != false,
              value.history.samples.count <= 512,
              value.history.samples.allSatisfy({ $0.total.isFinite && (0..<1e9).contains($0.total) &&
                  validDate($0.at) }),
              zip(value.history.samples, value.history.samples.dropFirst()).allSatisfy({ $0.0.at < $0.1.at }) else { return .init() }
        return value.history
    }
    func save(_ history: DeepSeekBalanceHistory, revision: UInt64 = 0) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(Envelope(version: 1, history: history)), data.count <= 65536 else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
        } catch { /* A failed cache write cannot replace a valid live balance. */ }
    }
}
