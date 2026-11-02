import Foundation
import CryptoKit

/// Explicit local troubleshooting only. Disabled by default, bounded to 1 MiB,
/// and excludes display text, paths, requests, token values and raw identifiers.
public enum RuntimeDiagnostics {
    private static func identifier(_ value: String?) -> String? {
        value.map { SHA256.hash(data: Data($0.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }
    }
    public static func data(_ stage: String, source: String, frame: [String: Any]? = nil,
                              activities: [SessionActivity] = [], status: RuntimeStreamStatus? = nil) -> Data? {
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
            entry["rate"] = value.displayedOutputEstimate(at: Date())?.value
            entry["firstOutput"] = value.firstTokenLatency
            entry["changedAt"] = value.phaseChangedAt?.timeIntervalSince1970
            entry["observedAt"] = value.lastObserved?.timeIntervalSince1970
            return entry
        }
        if let status { row["status"] = ["connected": status.connected, "attached": status.attachedThreads,
            "notifications": status.notifications, "scans": status.fallbackScans,
            "loops": status.helperLoopIterations, "cpu": status.helperCpuSeconds] as [String: Any] }
        guard var bytes = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) else { return nil }
        bytes.append(10); return bytes
    }
}

public struct RuntimeDiagnosticObserver: Sendable {
    private let isEnabled: @Sendable () -> Bool
    public var enabled: Bool { isEnabled() }
    private let write: @Sendable (Data) -> Void
    public init(enabled: Bool = false, write: @escaping @Sendable (Data) -> Void = { _ in }) {
        isEnabled = { enabled }; self.write = write
    }
    public init(enabled: @escaping @Sendable () -> Bool, write: @escaping @Sendable (Data) -> Void) {
        isEnabled = enabled; self.write = write
    }
    public func record(_ stage: String, source: String, frame: [String: Any]? = nil,
                       activities: [SessionActivity] = [], status: RuntimeStreamStatus? = nil) {
        guard enabled, let bytes = RuntimeDiagnostics.data(stage, source: source, frame: frame, activities: activities, status: status) else { return }
        write(bytes)
    }
}
