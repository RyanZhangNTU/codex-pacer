import Foundation

/// Native quota polling: 30 seconds expanded, 120 collapsed, doubling failures
/// with the Mac failure counter capped at four.
enum ProviderQuotaRefreshPolicy {
    static func interval(expanded: Bool, failures: Int) -> TimeInterval {
        min(600, (expanded ? 30.0 : 120.0) * pow(2, Double(min(4, max(0, failures)))))
    }
}
