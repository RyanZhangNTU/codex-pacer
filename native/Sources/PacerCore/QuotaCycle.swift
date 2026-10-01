import Foundation
import CryptoKit

public struct QuotaPoint: Codable, Equatable, Sendable, Identifiable {
    public let timestamp: Date
    public let remaining: Double
    public var id: Date { timestamp }
}

public struct QuotaCycle: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let bucketName: String?
    public let startedAt: Date
    public let resetsAt: Date
    public var points: [QuotaPoint]

    public func displayPoints(limit: Int = 240) -> [QuotaPoint] {
        guard points.count > limit, limit > 1 else { return points }
        // Preserve endpoints; the persisted readings themselves are not interpolated.
        return (0..<limit).map { points[Int(Double($0) * Double(points.count - 1) / Double(limit - 1))] }
    }
}

/// Only the current seven-day cycle for each bucket is retained.
public struct QuotaCycleHistory: Codable, Equatable, Sendable {
    public private(set) var cycles: [QuotaCycle] = []
    public private(set) var accountScope: String?
    public private(set) var lastCapturedAt: Date?
    private var retention: TimeInterval { 7 * 86400 }
    public init() {}
    public mutating func prune(at now: Date) {
        let oldest = now.addingTimeInterval(-retention)
        for index in cycles.indices { cycles[index].points.removeAll { $0.timestamp < oldest } }
        cycles.removeAll { $0.resetsAt <= now || $0.points.isEmpty }
    }

    public mutating func record(_ snapshot: QuotaSnapshot) {
        guard let scope = snapshot.accountScope else { return }
        if scope != accountScope { cycles.removeAll(); lastCapturedAt = nil; accountScope = scope }
        guard snapshot.capturedAt >= (lastCapturedAt ?? .distantPast) else { return }
        lastCapturedAt = snapshot.capturedAt
        prune(at: snapshot.capturedAt)
        let oldest = snapshot.capturedAt.addingTimeInterval(-retention)
        let weekly = snapshot.buckets.flatMap { bucket in
            bucket.windows.filter { $0.durationMinutes == 10080 }.map { (bucket, $0) }
        }
        let ids = Set(weekly.map { $0.1.id })
        cycles.removeAll { !ids.contains($0.id) || $0.resetsAt <= oldest }
        for (bucket, window) in weekly {
            guard let reset = window.resetsAt, reset > snapshot.capturedAt,
                  let remaining = window.remainingPercent else { continue }
            let start = reset.addingTimeInterval(-retention)
            let existing = cycles.firstIndex { $0.id == window.id }
            // Deadline changes identify a new window, including an early manual reset.
            // Small server timestamp corrections do not repeatedly erase a curve.
            let earlyReset = existing.map { index in
                reset > cycles[index].resetsAt && remaining >= (cycles[index].points.last?.remaining ?? remaining) + 5
            } ?? false
            if let index = existing, !earlyReset, abs(cycles[index].resetsAt.timeIntervalSince(reset)) <= 60 {
                let earliest = max(cycles[index].startedAt, oldest)
                cycles[index].points.removeAll { $0.timestamp < earliest }
                let point = QuotaPoint(timestamp: snapshot.capturedAt, remaining: remaining)
                if cycles[index].points.last?.timestamp == point.timestamp {
                    cycles[index].points[cycles[index].points.count - 1] = point
                } else { cycles[index].points.append(point) }
                if cycles[index].points.count > 20161 {
                    // Bound manual-refresh bursts while retaining the newest readings.
                    let first = cycles[index].points.first!
                    cycles[index].points = [first] + Array(cycles[index].points.suffix(20160))
                }
            } else {
                if let existing { cycles.remove(at: existing) }
                cycles.append(QuotaCycle(id: window.id, bucketName: bucket.name, startedAt: start,
                    resetsAt: reset, points: [QuotaPoint(timestamp: snapshot.capturedAt, remaining: remaining)]))
            }
        }
    }

    public func currentCycle(for window: QuotaWindow?, at now: Date) -> QuotaCycle? {
        guard let window, window.durationMinutes == 10080, let reset = window.resetsAt else { return nil }
        return cycles.first { $0.id == window.id && abs($0.resetsAt.timeIntervalSince(reset)) <= 60 &&
            now.timeIntervalSince($0.startedAt) <= retention && !$0.points.isEmpty }
    }
}

public actor QuotaHistoryStore {
    private let cache: QuotaCycleCache
    public init(directory: URL) { cache = QuotaCycleCache(directory: directory) }
    public func restore(home: URL, accountScope: String, now: Date = Date()) -> (QuotaSnapshot, QuotaCycleHistory)? {
        cache.load(home: home, accountScope: accountScope, now: now)
    }
    public func save(home: URL, snapshot: QuotaSnapshot, history: QuotaCycleHistory) -> Bool {
        do { try cache.save(home: home, snapshot: snapshot, history: history); return true }
        catch { return false }
    }
}

/// One private file per Codex home. It contains quota readings, not session history.
public struct QuotaCycleCache: Sendable {
    private enum CacheError: Error { case oversized }
    private let directory: URL
    private struct Envelope: Codable {
        let version: Int
        let snapshot: QuotaSnapshot
        let history: QuotaCycleHistory
    }
    public init(directory: URL) { self.directory = directory }

    public func load(home: URL, accountScope: String, now: Date = Date()) -> (QuotaSnapshot, QuotaCycleHistory)? {
        let file = location(home)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 3 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.version == 1, value.snapshot.accountScope == accountScope,
              value.history.accountScope == accountScope,
              now.timeIntervalSince(value.snapshot.capturedAt) >= -60,
              now.timeIntervalSince(value.snapshot.capturedAt) <= 7 * 86400 else { return nil }
        var history = value.history
        history.prune(at: now)
        if history != value.history { try? save(home: home, snapshot: value.snapshot, history: history) }
        return (value.snapshot, history)
    }

    public func save(home: URL, snapshot: QuotaSnapshot, history: QuotaCycleHistory) throws {
        guard snapshot.accountScope != nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Envelope(version: 1, snapshot: snapshot, history: history))
        guard data.count <= 3 * 1024 * 1024 else { throw CacheError.oversized }
        let file = location(home)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func location(_ home: URL) -> URL {
        let hash = SHA256.hash(data: Data(home.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("cycle-\(hash).json")
    }
}
