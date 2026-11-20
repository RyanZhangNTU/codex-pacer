import Foundation
import PacerCore
import PacerMacSupport

struct IslandPinnedCatalog: Equatable {
    var entries: [CodexPinnedThreads.Entry] = []
    var available = false
    var hidden: Set<String> = []
    var origins: [String: CodexSessionOrigin] = [:]
}

extension IslandModel {
    static let pinnedChatsKey = "showPinnedConversations"

    var showsPinnedChats: Bool { pinProfile != nil && viewingPinnedChats }
    var savedChatGroups: [PinnedConversationGroups.Group] {
        pinProfile.flatMap { chatGroups.profiles[$0] } ?? []
    }

    /// Changes the read scope immediately. A result from a previous home or an earlier opt-in cannot publish.
    @discardableResult func syncPinnedChats() -> Bool {
        let enabled = isModuleEnabled(.codex) && defaults.bool(forKey: Self.pinnedChatsKey)
        let profile = enabled ? (demo ? "" : CompletionDismissalStore.digest([home.path])) : nil
        guard profile != pinProfile else { return false }
        resetPinnedReader()
        if pinProfile == nil { viewingPinnedChats = true }
        pinProfile = profile
        if !demo && enabled {
            chatGroups = PinnedConversationGroups.read(defaults.string(forKey: "conversationGroups").map { Data($0.utf8) })
        }
        return true
    }

    func resetPinnedReader() {
        pinEpoch &+= 1
        pinWatcher?.stop()
        pinWatcher = nil
        pinsNeedRead = true
        let next = demo ? IslandPinnedCatalog(entries: CodexPinnedThreads.demoEntries, available: true) : IslandPinnedCatalog()
        if pinCatalog != next { pinCatalog = next }
    }

    func readPinnedCatalog(home: URL, epoch: UInt64) async -> [CodexPinnedThreads.Entry]? {
        guard pinProfile != nil, !demo, !sleeping, !stopped, epoch == pinEpoch else { return nil }
        let locations = await Task.detached(priority: .utility) {
            let db = CodexPinnedThreads.database(home: home)
            return (db, CodexPinnedThreads.watchURLs(home: home, database: db))
        }.value
        guard !Task.isCancelled, epoch == pinEpoch else { return nil }
        if pinWatcher == nil {
            pinWatcher = ActivityLogWatcher(files: MacFileSystem(), events: MacActivityFileEvents(),
                maximumDirectoryWatches: 1, fileExtensions: ["json", "sqlite", "sqlite-wal"]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.pinEpoch == epoch, self.pinProfile != nil, !self.sleeping, !self.stopped else { return }
                    self.pinsNeedRead = true
                    self.refreshActivity(metricsOnly: true)
                }
            }
        }
        pinWatcher?.update(locations.1, interval: 0.5)
        _ = await pinWatcher?.activeWatchCount()
        let result = await Task.detached(priority: .utility) { CodexPinnedThreads.read(home: home, database: locations.0) }.value
        guard !Task.isCancelled, epoch == pinEpoch else { return nil }
        return result
    }

    var pinnedChatRows: [CodexPinnedThreads.Row] {
        guard pinProfile != nil else { return [] }
        let visibility = ActivityVisibilityOptions(embeddedProviders: Set(AgentProvider.allCases.filter(showsEmbeddedSessions(for:))),
                                                  showsClaudeCloudProjects: showsClaudeCloudProjects)
        return CodexPinnedThreads.rows(pinCatalog.entries, activities: activities, requests: attentionRequests,
            excluding: pinCatalog.hidden.union(activityState.hiddenActivityIDs(visibility)), origins: pinCatalog.origins,
            showsEmbedded: showsEmbeddedSessions(for: .codex), inbox: completionInbox,
            options: taskPresentationOptions(for: activities), at: now)
    }

    func togglePinnedView() {
        guard pinProfile != nil, !pinInteraction else { return }
        viewingPinnedChats.toggle()
        onLayoutChange?()
    }

    func saveChatGroups(_ value: [PinnedConversationGroups.Group], profile: String) {
        guard showsPinnedChats, pinProfile == profile else { return }
        var next = chatGroups
        guard let data = next.save(value, profile: profile) else {
            showNavigationError(L10n.text("conversation_groups.save_failed"))
            return
        }
        if !demo { defaults.set(String(decoding: data, as: UTF8.self), forKey: "conversationGroups") }
        chatGroups = next
        onLayoutChange?()
    }
}
