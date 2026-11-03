import Foundation

/// Native quota polling: 30 seconds expanded, 120 collapsed, doubling failures
/// with the Mac failure counter capped at four.
public enum ProviderQuotaRefreshPolicy {
    public static func interval(expanded: Bool, failures: Int) -> TimeInterval {
        min(600, (expanded ? 30.0 : 120.0) * pow(2, Double(min(4, max(0, failures)))))
    }
    public static func isDue(lastAttempt: Date?, expanded: Bool, failures: Int, now: Date,
                             force: Bool = false, expansion: Bool = false) -> Bool {
        let elapsed = lastAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        return force || (expansion && elapsed > 30) || elapsed >= interval(expanded: expanded, failures: failures)
    }
}
