import Foundation

/// Display metadata can arrive after the turn and its subscription are gone.
/// It may update an existing card, but cannot create or change task activity.
public struct SessionNameUpdate: Equatable, Sendable {
    public let id: String
    public let title: String?

    init?(_ activity: SessionActivity) {
        guard !activity.isInternalReview,
              activity.title != nil || activity.titleWasExplicitlyCleared else { return nil }
        id = activity.canonicalized().id
        title = activity.title
    }

    func apply(to activity: inout SessionActivity) {
        guard activity.canonicalized().id == id else { return }
        activity.updateName(title)
    }
}
