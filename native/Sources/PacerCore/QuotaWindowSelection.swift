import Foundation

public enum QuotaWindowSelection {
    /// Unavailable quota is not evidence that a saved service bucket disappeared.
    public static func validated(_ selection: String, snapshot: QuotaSnapshot?) -> String {
        guard selection != "auto", let windows = snapshot?.windows, !windows.isEmpty else { return selection }
        return windows.contains { $0.id == selection } ? selection : "auto"
    }
}
