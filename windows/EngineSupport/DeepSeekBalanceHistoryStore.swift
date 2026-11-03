import Foundation

/// One app-owned numeric history, matching the Mac preference's source binding.
/// Keys, account identities, task names and source paths are never encoded.
actor DeepSeekBalanceHistoryStore {
    private struct Envelope: Codable { let version: Int; let history: DeepSeekBalanceHistory }
    private let file: URL
    private let files: any PlatformFileSystem
    private var latestRevision: UInt64 = 0
    init(file: URL, files: any PlatformFileSystem = WindowsFileSystem()) { self.file = file; self.files = files }
    func load(now: Date) -> DeepSeekBalanceHistory {
        guard let data = read(), let value = decode(data, now: now) else { return .init() }
        return value
    }
    private func read() -> Data? {
        guard let info = files.metadata(file), info.isRegularFile, info.size <= 65536,
              let data = try? files.read(file, offset: 0, maximumBytes: 65537), data.count == info.size else { return nil }
        return data
    }
    private func decode(_ data: Data, now: Date) -> DeepSeekBalanceHistory? {
        let earliest = Date(timeIntervalSince1970: 0), latest = now.addingTimeInterval(60)
        func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite && value >= earliest && value <= latest }
        guard data.count <= 65536,
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
              zip(value.history.samples, value.history.samples.dropFirst()).allSatisfy({ $0.0.at < $0.1.at }) else { return nil }
        return value.history
    }
    func save(_ history: DeepSeekBalanceHistory, revision: UInt64 = 0) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(Envelope(version: 1, history: history)), data.count <= 65536 else { return }
        if files.metadata(file) != nil || FileManager.default.fileExists(atPath: file.path) {
            guard let existing = read(), decode(existing, now: .distantFuture) != nil else { return }
        }
        guard decode(data, now: .distantFuture) != nil else { return }
        _ = files.replace(file, with: data)
    }
}
