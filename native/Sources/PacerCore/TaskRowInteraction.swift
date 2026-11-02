import Foundation

/// Shared timing and samples for the task row's ease-out hover.
public enum TaskRowInteraction {
    public static let hoverDuration: Double = 0.12
    public static let navigationErrorDuration: Double = 30
    public static func hoverProgress(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        if fraction <= 0 { return 0 }; if fraction >= 1 { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<36 {
            let t = (low + high) / 2, x = 1.74 * t * t - 0.74 * t * t * t
            if x < fraction { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * t * t - 2 * t * t * t
    }
}
