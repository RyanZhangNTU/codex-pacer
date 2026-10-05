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
    public static let sampleInterval: TimeInterval = 5 * 60
    public static let maximumPoints = 2018
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

    /// Keep the first actual reading and the latest reading in each five-minute
    /// interval. This also bounds fine-grained caches written by older versions.
    public mutating func compact() {
        for index in cycles.indices {
            let cycle = cycles[index]
            var points: [QuotaPoint] = []
            for point in cycle.points.sorted(by: { $0.timestamp < $1.timestamp }) {
                Self.append(point, to: &points, origin: cycle.startedAt)
            }
            cycles[index].points = points
        }
    }

    private static func append(_ point: QuotaPoint, to points: inout [QuotaPoint], origin: Date) {
        if let last = points.last, last.timestamp == point.timestamp {
            points[points.count - 1] = point
        } else if points.count > 1, let last = points.last,
                  floor(last.timestamp.timeIntervalSince(origin) / sampleInterval) ==
                  floor(point.timestamp.timeIntervalSince(origin) / sampleInterval) {
            points[points.count - 1] = point
        } else { points.append(point) }
        if points.count > maximumPoints {
            points = [points[0]] + Array(points.suffix(maximumPoints - 1))
        }
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
                let origin = cycles[index].startedAt
                Self.append(point, to: &cycles[index].points, origin: origin)
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
    private struct Pending {
        let home: URL
        let snapshot: QuotaSnapshot
        let history: QuotaCycleHistory
    }
    private var pending: Pending?
    private var lastWritten: Pending?
    private var lastWriteAt: Date?
    private var scheduledFlush: Task<Void, Never>?
    public static let saveInterval: TimeInterval = 30 * 60
    public init(directory: URL) { cache = QuotaCycleCache(directory: directory) }
    deinit { scheduledFlush?.cancel() }
    public func restore(home: URL, accountScope: String, now: Date = Date()) -> (QuotaSnapshot, QuotaCycleHistory)? {
        cache.load(home: home, accountScope: accountScope, now: now)
    }
    public func save(home: URL, snapshot: QuotaSnapshot, history: QuotaCycleHistory,
                     now: Date = Date()) -> Bool {
        guard snapshot.accountScope != nil else { return true }
        let next = Pending(home: home, snapshot: snapshot, history: history)
        if let pending, !sameContext(pending, next), !flush(at: now) { return false }
        if let pending, sameContext(pending, next), snapshot.capturedAt < pending.snapshot.capturedAt { return true }
        pending = next
        if (lastWritten.map({ !sameContext($0, next) }) ?? true) ||
           now.timeIntervalSince(lastWriteAt ?? .distantPast) >= Self.saveInterval {
            return flush(at: now)
        }
        if scheduledFlush == nil {
            let delay = max(0, Self.saveInterval - now.timeIntervalSince(lastWriteAt ?? .distantPast))
            scheduledFlush = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }
                _ = await self?.flush()
            }
        }
        return true
    }
    @discardableResult
    public func flush(at now: Date = Date()) -> Bool {
        scheduledFlush?.cancel(); scheduledFlush = nil
        guard let value = pending else { return true }
        do {
            try cache.save(home: value.home, snapshot: value.snapshot, history: value.history)
            lastWritten = value; lastWriteAt = now; pending = nil
            return true
        } catch { return false }
    }
    private func sameContext(_ a: Pending, _ b: Pending) -> Bool {
        a.home.standardizedFileURL == b.home.standardizedFileURL &&
        a.snapshot.accountScope == b.snapshot.accountScope &&
        a.history.cycles.map { $0.id } == b.history.cycles.map { $0.id } &&
        a.history.cycles.map { $0.startedAt } == b.history.cycles.map { $0.startedAt }
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
        history.compact()
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
