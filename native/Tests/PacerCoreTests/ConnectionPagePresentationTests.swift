import Foundation
import XCTest
@testable import PacerCore

final class ConnectionPagePresentationTests: XCTestCase {
    private func status(_ connected: Bool = true, sessions: Int = 0, available: Bool? = true,
                        name: String? = nil, online: Bool? = nil, waiting: Bool = false) -> RuntimeStreamStatus {
        var value = RuntimeStreamStatus(); value.connected = connected; value.attachedThreads = sessions
        value.sourceAvailable = available; value.sourceName = name; value.remoteHostOnline = online; value.waitingForSession = waiting
        return value
    }
    func testProblemsComeFirstWhileTwoProvidersShareOneHostRowAndCountsAreDeduplicated() throws {
        let ssh = ConnectionSource.sshPrefix, wsl = ConnectionSource.wslPrefix + "fixture"
        let page = ConnectionPagePresentation(enabledProviders: [.codex, .claude], statuses: [
            .codex: ["local": status(sessions: 1), ssh + "shared": status(sessions: 2), wsl: status(sessions: 3, name: "Linux")],
            .claude: ["local": status(), ssh + "shared": status(sessions: 8), wsl: status(sessions: 4, name: "Linux")]],
            claudeAliases: ["shared"], failed: ["shared"], names: ["shared": "Build host"], canRetrySetup: true)
        XCTAssertEqual(page.state, "retrying"); XCTAssertTrue(page.retry)
        XCTAssertEqual(page.hosts.count, 2); XCTAssertEqual(page.hosts.first?.name, "Build host")
        XCTAssertEqual(page.hosts.first?.modules.map(\.provider), ["codex", "claude"])
        XCTAssertEqual(page.hosts.first?.modules.last?.state, "setupFailed"); XCTAssertTrue(page.hosts.first?.modules.last?.retrySetup == true)
        XCTAssertEqual(page.sourceCount, 6); XCTAssertEqual(page.sessionCount, 10, "Pending Claude hooks must not add their eight sessions")
        XCTAssertEqual(page.hosts.last?.modules.map(\.sessions), [3, 4])
        XCTAssertEqual(page.sources.count, 2, "Host sources must not repeat as individual source rows")
        let encoded = try JSONEncoder().encode(page), roundTrip = try JSONDecoder().decode(ConnectionPagePresentation.self, from: encoded)
        XCTAssertEqual(roundTrip, page)
    }
    func testOfflineWaitingAndPausedSourcesRemainDistinctAndOptionalCloudDoesNotFailSummary() {
        let prefix = ConnectionSource.controlPrefix
        let page = ConnectionPagePresentation(enabledProviders: [.codex, .claude], statuses: [
            .codex: ["local": status(), prefix + "offline": status(false, name: "Notebook", online: false),
                prefix + "idle": status(false, available: nil, name: "Desktop", online: true, waiting: true)],
            .claude: ["local": status(), ClaudeCloudProjectState.sourceID: status(false, available: false)]])
        XCTAssertEqual(page.state, "offline"); XCTAssertFalse(page.retry)
        XCTAssertEqual(page.sources.first { $0.kind == L10n.text("connections.kind.remote_control") }?.name, "Notebook")
        XCTAssertEqual(page.sources.first { $0.name == "Notebook" }?.module.state, "offline")
        XCTAssertEqual(page.sources.first { $0.name == "Desktop" }?.module.state, "idle")
        XCTAssertEqual(page.sources.first { $0.key == ClaudeCloudProjectState.sourceID }?.module.label, L10n.text("connections.state.cloud_signed_out"))
        XCTAssertEqual(page.sourceCount, 4, "Optional signed-out Cloud Projects do not count as a broken source")
    }
    func testWSLSetupFailureAndQuotaCapabilityUseOnlyTheSameSourceProvider() {
        let wsl = ConnectionSource.wslPrefix + "fixture"
        let statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [.codex: ["local": status(), wsl: status(sessions: 2, name: "Linux")],
            .claude: ["local": status(), wsl: status(sessions: 3, name: "Linux")]]
        let failed = ConnectionPagePresentation(enabledProviders: [.codex, .claude], statuses: statuses,
            setup: [wsl: .failed], canRetrySetup: true, quotaSources: ["codex:" + wsl])
        XCTAssertEqual(failed.state, "retrying"); XCTAssertEqual(failed.sourceCount, 4); XCTAssertEqual(failed.sessionCount, 2)
        XCTAssertTrue(failed.hosts.first?.modules.first?.readsQuota == true); XCTAssertFalse(failed.hosts.first?.modules.last?.readsQuota == true)
        XCTAssertTrue(failed.hosts.first?.modules.last?.retrySetup == true)
        let configuring = ConnectionPagePresentation(enabledProviders: [.codex, .claude], statuses: statuses, setup: [wsl: .configuring], canRetrySetup: true)
        XCTAssertEqual(configuring.state, "connecting"); XCTAssertFalse(configuring.hosts.first?.modules.last?.retrySetup == true)
        let disabled = ConnectionPagePresentation(enabledProviders: [.codex], statuses: statuses, setup: [wsl: .failed], canRetrySetup: true)
        XCTAssertEqual(disabled.state, "connected"); XCTAssertEqual(disabled.hosts.first?.modules.count, 1)
        XCTAssertEqual(disabled.sessionCount, 2, "A hidden provider cannot contribute a failure or its session count")
    }
    func testCheckingAndDisabledStatesAndAllLanguagesKeepReadableLabels() {
        XCTAssertEqual(ConnectionPagePresentation(enabledProviders: [.codex], statuses: [:]).state, "checking")
        XCTAssertEqual(ConnectionPagePresentation(enabledProviders: [], statuses: [:]).state, "disabled")
        let page = ConnectionPagePresentation(enabledProviders: [.codex], statuses: [.codex: ["local": status(sessions: 1)]])
        XCTAssertEqual(page.title, L10n.text("connections.summary.ok")); XCTAssertFalse(page.detail.contains("%@"))
        XCTAssertFalse(page.sources.first?.module.sessionsText.isEmpty == true)
        for language in [AppLanguage.english, .simplifiedChinese] {
            XCTAssertNotEqual(L10n.text("connections.summary.ok", language: language), "connections.summary.ok")
            XCTAssertFalse(L10n.text("connections.sessions_one", 1, language: language).contains("%ld"))
        }
    }
}
