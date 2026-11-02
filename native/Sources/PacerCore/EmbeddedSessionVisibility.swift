import Foundation

/// A session and its descendants stay on the same side of the embedded-app
/// preference. Provider- and host-qualified IDs prevent unrelated families
/// with the same session UUID from hiding each other.
public enum EmbeddedSessionVisibility {
    public static func embeddedActivityIDs(_ values: [SessionActivity]) -> Set<String> {
        var hidden = Set(values.filter(\.launchedByEmbeddingApp).map(\.id))
        var grew = !hidden.isEmpty
        while grew {
            grew = false
            for value in values where !hidden.contains(value.id) {
                guard let parent = value.parentThreadID,
                      hidden.contains(value.provider.activityID(sessionID: parent, sourceHostID: value.sourceHostID)) else { continue }
                hidden.insert(value.id); grew = true
            }
        }
        return hidden
    }
}
