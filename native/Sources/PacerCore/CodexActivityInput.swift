import Foundation

/// Codex's local rollouts can overlap with Desktop and remote observations.
/// Resolve that overlap before publishing into the shared activity state.
struct CodexActivityInput: Sendable {
    var logged: [SessionActivity] = []
    var streamed: [SessionActivity] = []
    var streamedRequests: [PendingAttentionRequest] = []
    var loggedRequests: [PendingAttentionRequest] = []
    var excludedIDs: Set<String> = []
    var attentionThreads: Set<String> = []
    var connected = false
    var endings: [String: SessionActivity] = [:]

    var knownActivities: [SessionActivity] { logged + streamed + Array(endings.values) }

    func snapshot(inbox: CompletionInbox) -> HarnessActivity {
        let ready = endings.values.filter { inbox.isSourceVisible($0.sourceHostID) }
        let live = ready.isEmpty ? streamed : ActivitySourceMerger.merge(logged: ready, streamed: streamed)
        let activities = ActivitySourceMerger.merge(logged: logged, streamed: live)
        return .init(activities: activities, requests: requests)
    }

    mutating func releaseVisibleEndings(inbox: CompletionInbox) {
        endings = endings.filter { !inbox.isSourceVisible($0.value.sourceHostID) }
    }

    private var requests: [PendingAttentionRequest] {
        let liveInputs = Set(streamedRequests.filter { $0.sourceHostID == nil && $0.kind == .input }.map(\.threadID))
        let authoritative = attentionThreads.filter { thread in
            if streamedRequests.contains(where: { $0.threadID == thread }) { return true }
            guard connected, let live = streamed.first(where: { $0.sourceHostID == nil && $0.threadID == thread && $0.hasLiveEvidence }) else { return false }
            let logged = logged.first { $0.threadID == thread }
            return logged?.turnID == nil || logged?.turnID == live.turnID
        }
        let fallback = loggedRequests.filter { request in
            guard !liveInputs.contains(request.threadID), !authoritative.contains(request.threadID) else { return false }
            if let live = streamed.first(where: { $0.sourceHostID == nil && $0.threadID == request.threadID && $0.hasLiveEvidence }) {
                if let start = live.turnStartedAt, start > request.detectedAt { return false }
                if [.completed, .interrupted].contains(live.phase), (live.phaseChangedAt ?? .distantPast) >= request.detectedAt { return false }
            }
            return true
        }
        return streamedRequests + fallback
    }
}
