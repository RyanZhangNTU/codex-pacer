import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class ClaudeHostTrackingTests: XCTestCase {
    private let zotero = ClaudeHostApplication(bundleIdentifier: "org.zotero.zotero",
        bundleURL: URL(fileURLWithPath: "/Applications/Zotero.app"), name: "Zotero")
    private let terminal = ClaudeHostApplication(bundleIdentifier: "com.apple.Terminal",
        bundleURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), name: "Terminal")
    private let desktop = ClaudeHostApplication(bundleIdentifier: ClaudeApplicationResolver.bundleIdentifier,
        bundleURL: URL(fileURLWithPath: "/Applications/Claude.app"), name: "Claude")

    private actor Scans {
        var requests: [Set<String>] = []
        func record(_ sessions: Set<String>) { requests.append(sessions) }
        func all() -> [Set<String>] { requests }
    }

    func testHostIsScannedOnceAfterEndingAndKeptOnlyWhileShown() async throws {
        let fixture = try fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let model = fixture.model, scans = Scans(), first = zotero, second = terminal
        let running = "019a0000-0000-7000-8000-0000000000a1", ended = "019a0000-0000-7000-8000-0000000000a2"
        let vanishing = "019a0000-0000-7000-8000-0000000000a3"
        model.claudeHostResolver = { sessions, _ in
            await scans.record(sessions)
            return [running: first, vanishing: second].filter { sessions.contains($0.key) }
        }
        model.receiveClaudeUpdate([activity(running), activity(ended, completed: true), activity(vanishing)], statuses: [:], requests: [])
        try await waitUntil { model.claudeHosts.count == 2 }
        var requests = await scans.all()
        XCTAssertEqual(requests, [[running, ended, vanishing]])
        XCTAssertEqual(model.taskSourceName(activity(running)), "Zotero")
        XCTAssertNil(model.taskSourceName(activity(ended)), "No live holder was seen for this ending")

        // Within two seconds nothing is rescanned; later only running sessions
        // are, so the latest live holder can replace a record.
        model.trackClaudeHosts(now: Date())
        model.trackClaudeHosts(now: Date().addingTimeInterval(3))
        try await waitUntil { await scans.all().count == 2 }
        requests = await scans.all()
        XCTAssertEqual(requests.last, [running, vanishing])

        // The record outlives the process while its completion card is shown;
        // a session that leaves the list takes its record with it.
        model.receiveClaudeUpdate([activity(running, completed: true), activity(ended, completed: true)], statuses: [:], requests: [])
        XCTAssertEqual(model.claudeHost(for: activity(running, completed: true)), zotero)
        try await waitUntil { model.claudeHosts[vanishing] == nil }
        XCTAssertEqual(Set(model.claudeHosts.keys), [running])
        await model.shutdown()
    }

    func testLabelsNameNonDesktopHostsAndSubagentsUseTheirSessionsHost() async throws {
        let fixture = try fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let model = fixture.model
        let parent = "019a0000-0000-7000-8000-0000000000b1", child = "019a0000-0000-7000-8000-0000000000b2"
        let inDesktop = "019a0000-0000-7000-8000-0000000000b3", remote = "019a0000-0000-7000-8000-0000000000b4"
        var subagent = activity(child)
        subagent.updateParent(parent)
        let ssh = activity(remote, hostID: "remote-ssh-discovered:synthetic")
        model.receiveClaudeUpdate([activity(parent), subagent, activity(inDesktop), ssh], statuses: [:], requests: [])
        model.recordClaudeHosts([parent.uppercased(): terminal, inDesktop: desktop, remote: zotero])
        XCTAssertEqual(model.taskSourceName(activity(parent)), "Terminal")
        XCTAssertEqual(model.claudeHost(for: subagent), terminal)
        XCTAssertEqual(model.taskSourceName(subagent), "Terminal")
        XCTAssertNil(model.taskSourceName(activity(inDesktop)), "Claude Desktop sessions carry no host label")
        XCTAssertEqual(model.claudeHost(for: activity(inDesktop)), desktop)
        XCTAssertEqual(model.taskSourceName(ssh), "Synthetic host", "SSH rows keep their host name")
        XCTAssertNil(model.claudeHost(for: ssh))
        await model.shutdown()
    }

    func testHidingEmbeddedSessionsTakesTheirSubagentsQuestionsAndEndingsAndShowingRestoresThem() async throws {
        let fixture = try fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let model = fixture.model
        let plugin = "019a0000-0000-7000-8000-0000000000c1", child = "019a0000-0000-7000-8000-0000000000c2"
        let terminal = "019a0000-0000-7000-8000-0000000000c3"
        var embedded = activity(plugin, completed: true); embedded.setClaudeLaunch(embedded: true)
        var subagent = activity(child); subagent.updateParent(plugin)
        let questions = [plugin, child, terminal].map {
            PendingAttentionRequest(id: "question-" + $0, threadID: $0, sourceHostID: nil, sourceName: nil, kind: .input, detectedAt: Date(), provider: .claude)
        }
        func update() { model.receiveClaudeUpdate([embedded, subagent, activity(terminal)], statuses: [:], requests: questions) }
        func shown() -> Set<String> { Set(model.activities.compactMap(\.threadID)) }
        XCTAssertTrue(model.showsEmbeddedClaudeSessions, "On unless turned off")
        update()
        XCTAssertEqual(shown(), [plugin, child, terminal])
        XCTAssertEqual(model.attentionRequests.count, 3)

        fixture.defaults.set(false, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.refilterClaudeSessions()
        XCTAssertEqual(shown(), [terminal])
        XCTAssertEqual(model.attentionRequests.map(\.threadID), [terminal])
        update()
        XCTAssertEqual(shown(), [terminal], "Later reads stay filtered")

        fixture.defaults.set(true, forKey: IslandModel.showsEmbeddedClaudeSessionsKey)
        model.refilterClaudeSessions()
        XCTAssertEqual(shown(), [plugin, child, terminal])
        XCTAssertEqual(model.attentionRequests.count, 3)
        await model.shutdown()
    }

    func testOpenFailureClearsItselfUnlessReplaced() async throws {
        let fixture = try fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let model = fixture.model
        XCTAssertEqual(model.navigationErrorDuration, 30)
        model.navigationErrorDuration = 0.2
        model.showNavigationError("first")
        XCTAssertEqual(model.navigationError, "first")
        try await Task.sleep(nanoseconds: 100_000_000)
        model.navigationErrorDuration = 0.4
        model.showNavigationError("second")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.navigationError, "second", "An older timer must not clear a newer failure")
        try await waitUntil { model.navigationError == nil }
        await model.shutdown()
    }

    func testLocalOpenPrefersTheStartingAppOverDesktopAndNeverFallsBackToTerminal() {
        let link = URL(string: "claude://code/continue?session=local_synthetic")!
        typealias Opener = ClaudeConversationOpener
        XCTAssertEqual(Opener.localDestination(host: zotero, desktop: link), .host(zotero))
        XCTAssertEqual(Opener.localDestination(host: zotero, desktop: nil), .host(zotero))
        XCTAssertEqual(Opener.localDestination(host: desktop, desktop: link), .desktop(link))
        XCTAssertEqual(Opener.localDestination(host: desktop, desktop: nil), .host(desktop))
        XCTAssertEqual(Opener.localDestination(host: nil, desktop: link), .desktop(link))
        XCTAssertEqual(Opener.localDestination(host: nil, desktop: nil), .missing)
    }

    private struct Fixture { let model: IslandModel; let defaults: UserDefaults; let domain: String }

    private func fixture() throws -> Fixture {
        let domain = "com.codexpacer.claude-host-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        // Own defaults leave system notifications off; no monitor is started.
        let model = IslandModel(defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        model.claudeHostResolver = { _, _ in [:] }
        return Fixture(model: model, defaults: defaults, domain: domain)
    }

    private func activity(_ session: String, completed: Bool = false, hostID: String? = nil) -> SessionActivity {
        let now = Date()
        var value = SessionActivity(id: AgentProvider.claude.activityID(sessionID: session, sourceHostID: hostID),
            project: "Synthetic task", sourceHost: hostID == nil ? nil : "Synthetic host", sourceHostID: hostID,
            phaseAwareRate: true, provider: .claude, sessionID: session)
        value.applyRuntime(["method": "turn/started", "threadId": session, "turnId": "synthetic-turn",
            "at": now.addingTimeInterval(-10).timeIntervalSince1970])
        if completed {
            value.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": "synthetic-turn",
                "status": "completed", "at": now.addingTimeInterval(-1).timeIntervalSince1970])
        }
        return value.canonicalized()
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
