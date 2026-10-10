import Foundation

/// Numeric metadata can enrich an existing turn without creating activity or extending retention.
public struct SessionPerformanceUpdate: Equatable, Sendable {
    public let id: String
    public let turnID: String
    public let response: ResponsePerformance?
    public let firstTokenLatency: TimeInterval?
    public let firstTokenReportedAt: Date?
    /// Numeric measurements may arrive after the source released a completed turn.
    /// They can enrich only an already observed matching session/turn.
    public init?(id: String, turnID: String, response: ResponsePerformance?, firstTokenLatency: TimeInterval?, firstTokenReportedAt: Date?) {
        guard !id.isEmpty, id.utf8.count <= 1024, !turnID.isEmpty, turnID.utf8.count <= 256,
              response == nil || response?.turnID == turnID,
              firstTokenLatency.map({ $0.isFinite && (0...3600).contains($0) }) ?? true,
              firstTokenReportedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              response != nil || firstTokenLatency != nil else { return nil }
        self.id = id; self.turnID = turnID; self.response = response
        self.firstTokenLatency = firstTokenLatency; self.firstTokenReportedAt = firstTokenReportedAt
    }
    public init?(_ activity: SessionActivity) {
        guard !activity.isInternalReview, let turn = activity.turnID,
              activity.responsePerformance != nil || activity.firstTokenLatency != nil else { return nil }
        id = activity.canonicalized().id; turnID = turn
        response = activity.responsePerformance; firstTokenLatency = activity.firstTokenLatency
        firstTokenReportedAt = activity.firstTokenReportedAt
    }
    public func apply(to activity: inout SessionActivity) { activity.applyPerformance(self) }
}
