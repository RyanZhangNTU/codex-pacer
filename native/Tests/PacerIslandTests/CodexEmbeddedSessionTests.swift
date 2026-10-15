import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class CodexEmbeddedSessionTests: XCTestCase {
    private let session = "019a0000-0000-7000-8000-0000000000c1"
    private let child = "019a0000-0000-7000-8000-0000000000c2"
    private let catalog = "019a0000-0000-7000-8000-0000000000c3"
    private let official = "019a0000-0000-7000-8000-0000000000c4"

    func testRolloutFileIdentityUsesTheSameVisibilityKeyAsTheDisplayedRow() async throws {
        let (model, defaults, _) = try fixture()
        var value = SessionActivity(id: "rollout-2026-10-15T00-00-00-" + session + ".jsonl")
        value.applyRuntime(["method": "turn/started", "threadId": session, "turnId": "synthetic-turn",
            "at": Date().timeIntervalSince1970])
        value.setCodexOrigin(.init(embedded: true, ignored: false))
        model.receiveRemoteUpdate([value], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertEqual(model.activities.map(\.id), [value.canonicalized().id])
        defaults.set(false, forKey: IslandModel.showsEmbeddedCodexSessionsKey)
        model.applySettings(sourceChanged: false)
        XCTAssertTrue(model.activities.isEmpty)
        defaults.set(true, forKey: IslandModel.showsEmbeddedCodexSessionsKey)
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(model.activities.map(\.id), [value.canonicalized().id])
        await model.shutdown()
    }

    func testIgnoredFamiliesNeverReachCardsAttentionOrFirstOutputRegardlessOfVisibility() async throws {
        let (model, defaults, _) = try fixture()
        for show in [true, false] {
            defaults.set(show, forKey: IslandModel.showsEmbeddedCodexSessionsKey)
            var translation = activity(session, completed: true)
            translation.setCodexOrigin(.init(embedded: true, ignored: true))
            var descendant = activity(child, completed: true); descendant.updateParent(session)
            var lookup = activity(catalog, completed: true); lookup.setCodexOrigin(.init(embedded: true, ignored: true))
            let normal = activity(official)
            let requests = [translation, descendant, lookup].map {
                PendingAttentionRequest(id: "synthetic:" + $0.id, threadID: $0.threadID!, sourceHostID: nil,
                    sourceName: nil, kind: .approval, detectedAt: Date())
            }
            let metrics = try XCTUnwrap(SessionPerformanceUpdate(id: translation.id, turnID: "synthetic-turn", response: nil,
                firstTokenLatency: 0.5, firstTokenReportedAt: Date().addingTimeInterval(-1)))
            model.receiveRemoteUpdate([translation, descendant, lookup, normal], statuses: [:], unavailable: [], requests: requests,
                names: [], performance: [metrics])
            XCTAssertEqual(model.activities.map(\.id), [normal.id])
            XCTAssertTrue(model.pendingInputRequests.isEmpty); XCTAssertTrue(model.pendingCompletions.isEmpty)
            XCTAssertNil(model.latestFirstOutputLatency)
            XCTAssertEqual(model.running.map(\.id), [normal.id])
        }
        await model.shutdown()
    }

    func testUnknownHostReportsFailureAndNeverFallsBackToTheInstalledCodexApp() async throws {
        let (model, _, root) = try fixture(demo: true)
        var ended = activity(session, completed: true); ended.setCodexOrigin(.init(embedded: true, ignored: false))
        model.receiveRemoteUpdate([ended], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertTrue(model.canOpen(ended), "A missing host must report a visible error")
        model.navigationErrorDuration = 0.05
        model.onOpenActivity = { value in await CodexConversationOpener.open(value, home: root, recordedHost: nil) }
        model.open(ended)
        try await waitUntil { model.navigationError != nil }
        XCTAssertEqual(model.navigationError, L10n.text("activity.codex_host_missing"))
        XCTAssertTrue(model.isUnreadCompletion(ended))
        try await waitUntil { model.navigationError == nil }
        XCTAssertTrue(model.activities.contains { $0.id == ended.id })
        await model.shutdown()
    }

    func testOnlyLocalEmbeddedCodexUsesHostRoutingAndOfficialNavigationKeepsItsGuards() async throws {
        let (model, _, _) = try fixture()
        var embedded = activity(session); embedded.setCodexOrigin(.init(embedded: true, ignored: false))
        var descendant = activity(child); descendant.updateParent(session)
        let normal = activity(official)
        let ssh = activity(session, host: "remote-ssh-discovered:synthetic")
        model.receiveRemoteUpdate([embedded, descendant, normal, ssh], statuses: [:], unavailable: [], requests: [], names: [])
        let zotero = HostApplication(bundleIdentifier: "org.zotero.zotero", bundleURL: URL(fileURLWithPath: "/Applications/Zotero.app"), name: "Zotero")
        model.recordHostApplications([session: zotero], provider: .codex)
        let childRow = try XCTUnwrap(model.activities.first { $0.threadID == child })
        XCTAssertEqual(model.taskSourceName(embedded), "Zotero")
        XCTAssertEqual(model.hostApplication(for: childRow), zotero)
        XCTAssertTrue(model.canOpen(embedded))
        XCTAssertFalse(model.canOpen(normal), "Official local URLs retain the existing custom-home guard")
        XCTAssertTrue(model.canOpen(ssh)); XCTAssertNil(model.hostApplication(for: ssh))
        XCTAssertEqual(model.taskSourceName(ssh), "Synthetic SSH")
        await model.shutdown()
    }

    private func fixture(demo: Bool = false) throws -> (IslandModel, UserDefaults, URL) {
        let domain = "com.codexpacer.codex-embedded." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-codex-embedded-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "codexHome"); defaults.set(false, forKey: "monitorSSH")
        ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
        let model = IslandModel(demo: demo, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: root.appendingPathComponent("dismissals.json")))
        model.hostApplicationResolver = { _, _, _ in [:] }
        return (model, defaults, root)
    }
    private func activity(_ id: String, host: String? = nil, completed: Bool = false) -> SessionActivity {
        var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: id, sourceHostID: host), project: "Synthetic task",
            sourceHost: host == nil ? nil : "Synthetic SSH", sourceHostID: host, phaseAwareRate: true)
        value.setCodexOrigin(.init(embedded: false, ignored: false))
        value.applyRuntime(["method": "turn/started", "threadId": id, "turnId": "synthetic-turn", "at": Date().addingTimeInterval(-10).timeIntervalSince1970])
        if completed {
            value.applyRuntime(["method": "turn/completed", "threadId": id, "turnId": "synthetic-turn", "status": "completed",
                "at": Date().addingTimeInterval(-1).timeIntervalSince1970])
        }
        return value
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
