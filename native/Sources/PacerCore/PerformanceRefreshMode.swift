import Foundation

/// Batches presentation only. Accounting precision and request timestamps do
/// not depend on this preference; lifecycle/attention events stay immediate.
public enum PerformanceRefreshMode: String, CaseIterable, Sendable {
    case efficient, balanced, responsive
    public var interval: TimeInterval {
        switch self { case .efficient: return 1; case .balanced: return 0.25; case .responsive: return 0.1 }
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: "performanceRefreshMode").flatMap(Self.init(rawValue:)) ?? .balanced
    }
    public func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "performanceRefreshMode") }
}
