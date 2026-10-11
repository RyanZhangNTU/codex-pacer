import Foundation

/// The collapsed bar follows one of two windows from the provider's own
/// service bucket: 5 hours when the service reports one, otherwise 7 days.
/// Earlier releases stored "auto" (7 days) or a service window id; those read
/// as the matching period and stay stored until Settings saves a new choice.
public enum QuotaWindowSelection: String, CaseIterable, Sendable {
    case fiveHour = "5h", weekly = "7d"

    public init(saved: String?, snapshot: QuotaSnapshot?) {
        switch saved {
        case Self.fiveHour.rawValue: self = .fiveHour
        case nil, "auto", Self.weekly.rawValue: self = .weekly
        case let id?: self = snapshot?.windows.first { $0.id == id }?.durationMinutes == 300 ? .fiveHour : .weekly
        }
    }
}
