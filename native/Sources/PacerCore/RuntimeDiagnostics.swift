import Foundation
import CryptoKit
import Darwin

/// Explicit local troubleshooting only. Disabled by default, bounded to 1 MiB,
/// and excludes display text, paths, requests, token values and raw identifiers.
public enum RuntimeDiagnostics {
    private static let sink = Sink()
    public static var enabled: Bool { sink.enabled }
    private static func identifier(_ value: String?) -> String? {
        value.map { SHA256.hash(data: Data($0.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }
    }
    public static func record(_ stage: String, source: String, frame: [String: Any]? = nil,
                              activities: [SessionActivity] = [], status: RuntimeStreamStatus? = nil) {
        guard enabled else { return }
        var row: [String: Any] = ["at": Date().timeIntervalSince1970, "stage": stage,
            "source": identifier(source) ?? "none"]
        if let frame {
            row["kind"] = frame["kind"] as? String
            row["bytes"] = frame["diagnosticBytes"] as? Int
            row["events"] = (frame["events"] as? [[String: Any]] ?? []).prefix(32).map { event -> [String: Any] in
                var value: [String: Any] = [:]
                value["thread"] = identifier(event["threadId"] as? String)
                value["turn"] = identifier(event["turnId"] as? String)
                value["method"] = (event["method"] as? String).map { String($0.prefix(80)) }
                value["status"] = (event["status"] as? String).map { String($0.prefix(32)) }
                value["at"] = event["at"] as? Double
                return value
            }
            if let threads = frame["threadIds"] as? [String] { row["hints"] = threads.prefix(32).compactMap { identifier($0) } }
        }
        row["activities"] = activities.prefix(32).map { value -> [String: Any] in
            var entry: [String: Any] = ["phase": value.phase.rawValue, "live": value.hasLiveEvidence,
                "started": value.liveTurnStarted]
            entry["thread"] = identifier(value.threadID); entry["turn"] = identifier(value.turnID)
            entry["changedAt"] = value.phaseChangedAt?.timeIntervalSince1970
            entry["observedAt"] = value.lastObserved?.timeIntervalSince1970
            return entry
        }
        if let status { row["status"] = ["connected": status.connected, "attached": status.attachedThreads,
            "notifications": status.notifications, "scans": status.fallbackScans,
            "loops": status.helperLoopIterations, "cpu": status.helperCpuSeconds] as [String: Any] }
        sink.write(row)
    }
    private final class Sink: @unchecked Sendable {
        let enabled = UserDefaults.standard.bool(forKey: "pacerLocalRuntimeTrace")
        private let lock = NSLock()
        private var handle: FileHandle?
        private var written = 0
        init() {
            guard enabled else { return }
            let fd = Darwin.open("/private/tmp/pacer-runtime-trace-\(getpid()).jsonl", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd >= 0 { handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
        }
        func write(_ row: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            guard let current = handle, var data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) else { return }
            data.append(10)
            guard written + data.count <= 1024 * 1024 else { try? current.close(); handle = nil; return }
            do { try current.write(contentsOf: data); written += data.count }
            catch { try? current.close(); handle = nil }
        }
    }
}
