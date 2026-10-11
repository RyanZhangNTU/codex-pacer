import XCTest
@testable import PacerCore

final class ProviderTests: XCTestCase {
    private let session = "019a0000-0000-7000-8000-000000000001"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func activity(_ provider: AgentProvider, sessionID: String? = nil, host: String? = nil) -> SessionActivity {
        SessionActivity(id: sessionID ?? session, sourceHostID: host, phaseAwareRate: true,
                        provider: provider, sessionID: sessionID ?? session).canonicalized()
    }
    private func event(_ value: inout SessionActivity, _ method: String, second: Double, fields: [String: Any] = [:], turn: String = "turn") {
        var event: [String: Any] = ["method": method, "threadId": value.threadID!, "turnId": turn,
                                    "at": start.addingTimeInterval(second).timeIntervalSince1970]
        event.merge(fields) { _, incoming in incoming }; value.applyRuntime(event)
    }
    private func ended(_ provider: AgentProvider) -> SessionActivity {
        var value = activity(provider)
        event(&value, "turn/started", second: 0)
        event(&value, "turn/completed", second: 5, fields: ["status": "completed"])
        return value
    }

    func testProviderQualifiedIdentityPreservesCodexAndSeparatesLocalAndSsh() {
        let host = "remote-ssh-discovered:gpu.example"
        XCTAssertEqual(activity(.codex).id, "local:" + session)
        XCTAssertEqual(activity(.claude).id, "claude:local:" + session)
        XCTAssertEqual(activity(.codex, host: host).id, host + ":" + session)
        XCTAssertEqual(activity(.claude, host: host).id, "claude:" + host + ":" + session)
        XCTAssertEqual(ActivitySourceMerger.merge(logged: [ended(.codex)], streamed: [ended(.claude)]).count, 2)
        XCTAssertNotNil(activity(.codex).threadURL)
        XCTAssertNil(activity(.claude).threadURL, "Unverified Claude routes must not become Codex deep links")
    }

    func testClaudeOpaqueAgentIdsGroupOnlyWithinTheirProviderAndHost() {
        let parent = activity(.claude)
        var child = activity(.claude, sessionID: "agent-ABC_01")
        event(&child, "metadata", second: 0, fields: ["parentThreadId": session])
        event(&child, "turn/started", second: 0)
        XCTAssertEqual(child.threadID, "agent-ABC_01")
        XCTAssertEqual(child.parentThreadID, session)
        let otherHost = activity(.claude, sessionID: "agent-ABC_01", host: "remote-ssh-discovered:fixture")
        let groups = ActivityTaskGroup.make([parent, child, activity(.codex), otherHost])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first(where: { $0.primary.id == parent.id })?.members.count, 2)
        XCTAssertNil(AgentProvider.codex.validatedSessionID("agent-ABC_01"))
        for invalid in ["../agent", "agent:id", "agent\ntext", String(repeating: "a", count: 257)] {
            XCTAssertNil(AgentProvider.claude.validatedSessionID(invalid))
        }
        XCTAssertNil(SessionActivity(id: session, provider: .claude, sessionID: "../agent").threadID)
    }

    func testMappedClaudeUsageKeepsToolTimingAndLateAccountingIndependentOfCompletion() {
        var value = activity(.claude)
        event(&value, "turn/started", second: 0)
        event(&value, "item/agentMessage/delta", second: 2, fields: ["hasText": true])
        event(&value, "item/agentMessage/delta", second: 5, fields: ["hasText": true])
        event(&value, "item/started", second: 5, fields: ["itemId": "tool", "itemType": "commandExecution"])
        value.applyRequestUsage(responseID: "response", turnID: "turn", outputTokens: 100, at: start.addingTimeInterval(6))
        XCTAssertEqual(value.responsePerformance?.tokensPerSecond, 20)
        XCTAssertEqual(value.firstTokenLatency, 2)
        event(&value, "item/completed", second: 15, fields: ["itemId": "tool", "itemType": "commandExecution"])
        event(&value, "turn/completed", second: 16, fields: ["status": "completed"])
        let changed = value.phaseChangedAt
        value.applyRequestUsage(responseID: "response", turnID: "turn", outputTokens: 200, at: start.addingTimeInterval(17))
        value.applyRequestUsage(responseID: "wrong", turnID: "another-turn", outputTokens: 1000, at: start.addingTimeInterval(17))
        XCTAssertEqual(value.responsePerformance?.outputTokens, 100, "Replayed accounting and another turn cannot replace the sample")
        XCTAssertEqual(value.phaseChangedAt, changed)
        XCTAssertEqual(value.phase, .completed)
        XCTAssertEqual(value.displayedOutputEstimate(at: start.addingTimeInterval(22))?.value, 20)
        XCTAssertFalse(value.displayedOutputEstimate(at: start.addingTimeInterval(22))!.isFresh)
    }

    func testCompletionAndAttentionStayIsolatedAcrossProvidersAndSelectiveDisable() {
        let codex = ended(.codex), claude = ended(.claude)
        var inbox = CompletionInbox()
        inbox.observe([codex, claude], at: start.addingTimeInterval(6), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.count, 2)
        inbox.dismiss(claude)
        inbox.remove(provider: .claude)
        XCTAssertTrue(inbox.isUnread(codex))
        inbox.observe([codex, claude], at: start.addingTimeInterval(7), retention: 1800)
        XCTAssertEqual(inbox.unreadActivities.count, 2, "Selective disable also clears only that provider's dismissed baseline")
        let request = PendingAttentionRequest(id: "claude:request", threadID: session, sourceHostID: nil,
            sourceName: nil, kind: .approval, detectedAt: start, provider: .claude)
        XCTAssertEqual(request.activity.provider, .claude)
        XCTAssertEqual(request.activity.id, claude.id)
        XCTAssertNotEqual(request.activity.id, codex.id)
    }

    func testAuthoritativeProviderMetricsEnrichOnlyMatchingObservedTurn() throws {
        var claude = ended(.claude), codex = ended(.codex)
        let response = try XCTUnwrap(ResponsePerformance(responseID: "measured", turnID: "turn", outputTokens: 300,
            startedAt: start, completedAt: start.addingTimeInterval(3), source: .requestUsage))
        let update = try XCTUnwrap(SessionPerformanceUpdate(id: claude.id, turnID: "turn", response: response,
            firstTokenLatency: 1, firstTokenReportedAt: start.addingTimeInterval(1)))
        let endedAt = claude.phaseChangedAt
        update.apply(to: &claude); update.apply(to: &codex)
        XCTAssertEqual(claude.responsePerformance?.tokensPerSecond, 100)
        XCTAssertEqual(claude.firstTokenLatency, 1)
        XCTAssertEqual(claude.phase, .completed)
        XCTAssertEqual(claude.phaseChangedAt, endedAt)
        XCTAssertNil(codex.responsePerformance)
        var unseen = activity(.claude)
        update.apply(to: &unseen)
        XCTAssertNil(unseen.responsePerformance)
        XCTAssertEqual(unseen.phase, .unknown)
        XCTAssertNil(SessionPerformanceUpdate(id: claude.id, turnID: "different", response: response,
            firstTokenLatency: nil, firstTokenReportedAt: nil))
    }

    func testObservedClaudeRequestRemainsEstimatedAndAuthoritativeSameRequestAlwaysWins() throws {
        var value = activity(.claude)
        event(&value, "turn/started", second: 0)
        func apply(_ id: String, _ tokens: Int, _ second: Double, _ source: ResponsePerformance.Source) throws {
            let response = try XCTUnwrap(ResponsePerformance(responseID: id, turnID: "turn", outputTokens: tokens,
                startedAt: start, completedAt: start.addingTimeInterval(second), source: source))
            let update = try XCTUnwrap(SessionPerformanceUpdate(id: value.id, turnID: "turn", response: response,
                firstTokenLatency: nil, firstTokenReportedAt: nil))
            update.apply(to: &value)
        }
        try apply("response-1", 200, 8, .observedRequest)
        XCTAssertEqual(value.displayedOutputEstimate(at: start.addingTimeInterval(9))?.value, 25)
        XCTAssertTrue(value.displayedRateIsEstimated(at: start.addingTimeInterval(9)))
        XCTAssertNil(value.firstTokenLatency, "Observed full-message timings cannot manufacture TTFT")
        try apply("response-1", 300, 3, .requestUsage)
        XCTAssertEqual(value.responsePerformance?.source, .requestUsage)
        XCTAssertEqual(value.displayedOutputEstimate(at: start.addingTimeInterval(9))?.value, 100)
        XCTAssertFalse(value.displayedRateIsEstimated(at: start.addingTimeInterval(9)))
        try apply("response-1", 200, 20, .observedRequest)
        XCTAssertEqual(value.displayedOutputEstimate(at: start.addingTimeInterval(21))?.value, 100)
        XCTAssertEqual(value.displayedOutputEstimate(at: start.addingTimeInterval(21))?.reportedAt, start.addingTimeInterval(3))
        // Different request identity defeats the older near-timestamp priority.
        try apply("response-2", 800, 4, .observedRequest)
        XCTAssertEqual(value.responsePerformance?.responseID, "response-2")
        XCTAssertEqual(value.displayedOutputEstimate(at: start.addingTimeInterval(5))?.value, 200)
        XCTAssertTrue(value.displayedRateIsEstimated(at: start.addingTimeInterval(5)))
        XCTAssertNil(value.firstTokenLatency)
    }

    func testClaudeNavigationRequiresKnownDesktopMetadataAndRejectsInjectedOrRemotePaths() throws {
        var local = activity(.claude)
        XCTAssertNil(local.threadURL)
        local.setClaudeNavigation(directory: URL(fileURLWithPath: "/private/tmp/project"), desktopSessionID: "local_" + session)
        let route = try XCTUnwrap(local.threadURL)
        XCTAssertEqual(route.scheme, "claude")
        XCTAssertEqual(route.host, "code")
        XCTAssertEqual(route.path, "/continue")
        XCTAssertEqual(URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "session", value: "local_" + session)])
        var refreshed = activity(.claude)
        refreshed.mergeDisplayMetadata(from: local)
        XCTAssertEqual(refreshed.threadURL, route)
        XCTAssertEqual(refreshed.navigationDirectory, local.navigationDirectory)
        for invalid in ["local_x&prompt=PRIVATE", "local_x\n", "local_", "local_arbitrary", "../session", session] {
            var malformed = activity(.claude)
            malformed.setClaudeNavigation(directory: URL(string: "https://example.invalid/project"), desktopSessionID: invalid)
            XCTAssertNil(malformed.threadURL)
            XCTAssertNil(malformed.navigationDirectory)
        }
        for invalidDirectory in [URL(fileURLWithPath: "/private/tmp/line\n"),
                                 URL(fileURLWithPath: "/" + String(repeating: "x", count: 4097)),
                                 URL(string: "file://other-host/private/tmp/project")!] {
            var malformed = activity(.claude)
            malformed.setClaudeNavigation(directory: invalidDirectory, desktopSessionID: nil)
            XCTAssertNil(malformed.navigationDirectory)
        }
        var remote = activity(.claude, host: "remote-ssh-discovered:fixture")
        remote.setClaudeNavigation(directory: URL(fileURLWithPath: "/private/tmp/project"), desktopSessionID: "local_" + session)
        XCTAssertNil(remote.threadURL)
        XCTAssertNil(remote.navigationDirectory)
        var codex = activity(.codex)
        codex.setClaudeNavigation(directory: URL(fileURLWithPath: "/private/tmp/project"), desktopSessionID: "local_" + session)
        XCTAssertEqual(codex.threadURL?.scheme, "codex")
        XCTAssertNil(codex.navigationDirectory)
    }

    func testHistoricalClaudeBaselineRetainsCardsWithoutReplayingCompletionReminders() {
        for host in [nil, "remote-ssh-discovered:fixture"] as [String?] {
            var historical = activity(.claude, host: host)
            var inbox = CompletionInbox(), attention = AttentionPolicy()
            // A bounded startup tail may publish its running chunk before the
            // later chunk supplies the historical Stop event.
            event(&historical, "turn/attached", second: 0)
            historical.suppressHistoricalCompletionNotifications()
            inbox.observe([historical], at: start.addingTimeInterval(1), retention: 1800)
            XCTAssertTrue(attention.activityNotices([historical], at: start.addingTimeInterval(1)).isEmpty)
            event(&historical, "turn/completed", second: 5, fields: ["status": "completed"])
            historical.suppressHistoricalCompletionNotifications()
            XCTAssertTrue(historical.isHistoricalCompletion)
            inbox.observe([historical], at: start.addingTimeInterval(6), retention: 1800)
            XCTAssertEqual(inbox.activities.count, 1)
            XCTAssertTrue(inbox.unreadActivities.isEmpty)
            XCTAssertTrue(attention.activityNotices([historical], at: start.addingTimeInterval(6)).isEmpty)
            event(&historical, "metadata", second: 6, fields: ["name": "Renamed"])
            historical.applyRequestUsage(responseID: "late", turnID: "turn", outputTokens: 100, at: start.addingTimeInterval(6))
            XCTAssertTrue(historical.isHistoricalCompletion, "Metadata and late metrics cannot promote history to a live ending")
            event(&historical, "turn/started", second: 7, turn: "next")
            XCTAssertFalse(historical.isHistoricalCompletion)
            event(&historical, "turn/completed", second: 8, fields: ["status": "completed"], turn: "next")
            inbox.observe([historical], at: start.addingTimeInterval(9), retention: 1800)
            XCTAssertEqual(inbox.unreadActivities.count, 1)
            XCTAssertEqual(attention.activityNotices([historical], at: start.addingTimeInterval(9)).count, 1)
        }
    }

    func testModuleOverridesPersistAndAutomaticDoesNotWriteOrOverrideChoices() throws {
        let name = "ProviderTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let onlyClaude = ProviderInstallationDetection(codexInstalled: false, claudeInstalled: true)
        var modules = ProviderModules.load(from: defaults)
        XCTAssertEqual(modules.enabledProviders(detection: onlyClaude), [.claude])
        XCTAssertNil(defaults.object(forKey: "providerModule.claude"), "Detection must not freeze automatic settings")
        modules.setMode(.enabled, for: .codex)
        modules.setMode(.disabled, for: .claude)
        modules.save(to: defaults)
        let restored = ProviderModules.load(from: defaults)
        XCTAssertEqual(restored.enabledProviders(detection: onlyClaude), [.codex])
        XCTAssertEqual(restored.mode(for: .claude), .disabled)
        XCTAssertEqual(restored.enabledProviders(detection: .init(codexInstalled: true, claudeInstalled: true)), [.codex])
    }

    func testInstallationDetectionUsesBoundedExecutableLocationsWithoutLaunching() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("provider-install-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let detected = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: [.codex: [], .claude: []], systemBinDirectories: [])
        XCTAssertEqual(detected, .init(codexInstalled: false, claudeInstalled: true))

        // Finder launches do not inherit shell PATH. Existing manager installs
        // must still enable the matching module automatically.
        try FileManager.default.removeItem(at: cli)
        for (relative, name) in [(".nvm/versions/node/v22.2.0/bin", "codex"), (".fnm/current/bin", "claude")] {
            let directory = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let managed = ProviderInstallationDetection.detect(userHome: home, environment: [:],
            applicationURLs: [.codex: [], .claude: []], systemBinDirectories: [])
        XCTAssertEqual(managed, .init(codexInstalled: true, claudeInstalled: true))
    }
}
