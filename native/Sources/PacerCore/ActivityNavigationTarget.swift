import Foundation

public enum ActivityNavigationTarget {
    public static func resolve(_ activity: SessionActivity, activities: [SessionActivity], inbox: CompletionInbox, remoteSourceIDs: Set<String> = []) -> SessionActivity? {
        guard activity.provider == .claude || activity.launchedByEmbeddingApp, let parent = activity.parentThreadID else { return activity }
        guard !activity.isInternalReview, activity.turnID != nil, activity.turnStartedAt != nil,
              activity.provider != .claude || (activity.sourceHostID.map({ host in remoteSourceIDs.contains(host) }) ?? true) else { return nil }
        let source = inbox.sourceToken(for: activity)
        var parentSession = parent, seen: Set<String> = [activity.canonicalized().id]
        for _ in 0..<64 {
            let id = activity.provider.activityID(sessionID: parentSession, sourceHostID: activity.sourceHostID)
            guard seen.insert(id).inserted else { return nil }
            if let observed = activities.first(where: {
                $0.canonicalized().id == id && $0.provider == activity.provider && $0.sourceHostID == activity.sourceHostID
            }) {
                guard !observed.isInternalReview, inbox.sourceToken(for: observed) == source else { return nil }
                if let ancestor = observed.parentThreadID {
                    guard observed.turnID != nil, observed.turnStartedAt != nil else { return nil }
                    parentSession = ancestor
                    continue
                }
                return observed.threadID.flatMap(UUID.init(uuidString:)) == nil ? nil : observed
            }
            guard let uuid = UUID(uuidString: parentSession) else { return nil }
            let session = uuid.uuidString.lowercased()
            // An observed parent UUID is routing evidence; a child's directory
            // does not establish the parent's directory or continuation ID.
            var target = SessionActivity(id: activity.provider.activityID(sessionID: session, sourceHostID: activity.sourceHostID),
                project: activity.project, sourceHost: activity.sourceHost, sourceHostID: activity.sourceHostID, provider: activity.provider, sessionID: session)
            if let origin = activity.codexOrigin { target.setCodexOrigin(origin) }
            return target
        }
        return nil
    }
}
