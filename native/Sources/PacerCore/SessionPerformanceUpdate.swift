import Foundation

/// Numeric metadata can enrich an existing turn without creating activity or extending retention.
public struct SessionPerformanceUpdate: Equatable, Sendable {
    public let id: String
    public let turnID: String
    public let response: ResponsePerformance?
    public let firstTokenLatency: TimeInterval?
    init?(_ activity: SessionActivity) {
        guard !activity.isInternalReview, let turn = activity.turnID,
              activity.responsePerformance != nil || activity.firstTokenLatency != nil else { return nil }
        id = activity.canonicalized().id; turnID = turn
        response = activity.responsePerformance; firstTokenLatency = activity.firstTokenLatency
    }
    func apply(to activity: inout SessionActivity) { activity.applyPerformance(self) }
}
