import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class ClaudeSessionVisibilityTests: XCTestCase {
    private let parent = "019a0000-0000-7000-8000-0000000000d1"
    private let child = "retained-agent"
    private let remote = "remote-ssh-discovered:visibility-fixture"

    func testHidingAndShowingRetainedFamiliesSurvivesEitherOrderOfReaderEviction() async throws {
        for host in [nil, remote] as [String?] {
            for hideFirst in [false, true] {
                let (model, defaults, _) = try fixture()
                var ended = activity(parent, host: host, completed: true)
                ended.setClaudeLaunch(embedded: true)
                var descendant = activity(child, host: host, completed: true)
                descendant.updateParent(parent)
                // The same session on another host is independent.
                let other = activity(parent, host: host == nil ? remote : nil, completed: true)
                let requests = [ended, descendant, other].map {
                    PendingAttentionRequest(id: "question:" + $0.id, threadID: $0.threadID!, sourceHostID: $0.sourceHostID,
                        sourceName: nil, kind: .input, detectedAt: Date(), provider: .claude)
                }
                model.receiveClaudeUpdate([ended, descendant, other], statuses: [:], requests: requests)
                let application = ClaudeHostApplication(bundleIdentifier: "com.apple.Terminal",
                    bundleURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), name: "Terminal")
                if host == nil { model.recordClaudeHosts([parent: application]) }
                XCTAssertTrue(model.isUnreadCompletion(ended)); XCTAssertTrue(model.isUnreadCompletion(descendant))

                func hide() {
                    defaults.set(false, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
                    model.refilterClaudeSessions()
                }
                if hideFirst { hide() }
                model.receiveClaudeUpdate([], statuses: [:], requests: requests)
                if !hideFirst { hide() }
                XCTAssertEqual(Set(model.activities.map(\.id)), [other.id])
                XCTAssertEqual(model.pendingCompletions.map(\.id), [other.id])
                XCTAssertEqual(model.pendingInputRequests.map { $0.activity.id }, [other.id])

                defaults.set(true, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
                model.refilterClaudeSessions()
                XCTAssertEqual(Set(model.activities.map(\.id)), [ended.id, descendant.id, other.id])
                XCTAssertTrue(model.isUnreadCompletion(ended)); XCTAssertTrue(model.isUnreadCompletion(descendant))
                XCTAssertEqual(model.pendingInputRequests.count, 3)
                if host == nil { XCTAssertEqual(model.claudeHost(for: ended), application) }
                await model.shutdown()
            }
        }
    }

    func testHiddenCompletionIsRetainedAndOnlySuccessfulOpenDismissesIt() async throws {
        let (model, defaults, dismissals) = try fixture()
        defaults.set(false, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        var running = activity(parent)
        running.setClaudeLaunch(embedded: true)
        model.receiveClaudeUpdate([running], statuses: [:], requests: [])
        var ended = activity(parent, completed: true)
        ended.setClaudeLaunch(embedded: true)
        model.receiveClaudeUpdate([ended], statuses: [:], requests: [])
        model.receiveClaudeUpdate([], statuses: [:], requests: [])
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dismissals.path), "Hiding does not acknowledge an ending")

        defaults.set(true, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.refilterClaudeSessions()
        XCTAssertTrue(model.isUnreadCompletion(ended))
        XCTAssertEqual(model.activities.map(\.id), [ended.id])
        model.onOpenActivity = { _ in .openedConversation }
        model.open(ended)
        try await waitUntil { model.activities.isEmpty }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dismissals.path))
        defaults.set(false, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.refilterClaudeSessions()
        defaults.set(true, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.receiveClaudeUpdate([ended], statuses: [:], requests: [])
        XCTAssertTrue(model.activities.isEmpty, "Toggling visibility cannot undo a successful open")
        await model.shutdown()
    }

    func testHiddenRetainedCompletionStillExpires() async throws {
        let (model, defaults, dismissals) = try fixture()
        defaults.set(5, forKey: "completedRetentionMinutes")
        defaults.set(false, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        var ended = activity(parent, completed: true)
        ended.setClaudeLaunch(embedded: true)
        model.receiveClaudeUpdate([ended], statuses: [:], requests: [])
        model.receiveClaudeUpdate([], statuses: [:], requests: [])
        model.now = Date().addingTimeInterval(301)
        defaults.set(true, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.refilterClaudeSessions()
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dismissals.path))
        await model.shutdown()
    }

    func testCurrentCliResumeOverridesTheRetainedEmbeddedLaunch() async throws {
        let (model, defaults, _) = try fixture()
        var ended = activity(parent, completed: true)
        ended.setClaudeLaunch(embedded: true)
        model.receiveClaudeUpdate([ended], statuses: [:], requests: [])
        defaults.set(false, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.refilterClaudeSessions()
        var resumed = activity(parent)
        resumed.applyRuntime(["method": "turn/started", "threadId": parent, "turnId": "cli-resume",
            "at": Date().timeIntervalSince1970])
        model.receiveClaudeUpdate([resumed], statuses: [:], requests: [])
        XCTAssertEqual(model.running.map(\.id), [resumed.id])
        XCTAssertFalse(model.activities.first?.launchedByEmbeddingApp ?? true)
        await model.shutdown()
    }

    private func fixture() throws -> (IslandModel, UserDefaults, URL) {
        let domain = "com.codexpacer.visibility-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-visibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        defaults.set(root.appendingPathComponent("codex").path, forKey: "codexHome")
        defaults.set(root.appendingPathComponent("claude").path, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        let dismissals = root.appendingPathComponent("dismissals.json")
        let model = IslandModel(defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: dismissals))
        model.claudeHostResolver = { _, _ in [:] }
        return (model, defaults, dismissals)
    }

    private func activity(_ session: String, host: String? = nil, completed: Bool = false) -> SessionActivity {
        let now = Date()
        var value = SessionActivity(id: AgentProvider.claude.activityID(sessionID: session, sourceHostID: host),
            project: "Synthetic task", sourceHostID: host, phaseAwareRate: true, provider: .claude, sessionID: session)
        value.applyRuntime(["method": "turn/started", "threadId": session, "turnId": "synthetic-turn",
            "at": now.addingTimeInterval(-10).timeIntervalSince1970])
        if completed {
            value.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": "synthetic-turn",
                "status": "completed", "at": now.addingTimeInterval(-1).timeIntervalSince1970])
        }
        return value.canonicalized()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
