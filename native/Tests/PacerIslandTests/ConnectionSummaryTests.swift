import XCTest
@testable import PacerCore
@testable import PacerIsland

final class ConnectionSummaryTests: XCTestCase {
    private let prefix = ConnectionSource.sshPrefix
    private func status(_ connected: Bool, sessions: Int = 0, available: Bool? = nil) -> RuntimeStreamStatus {
        var value = RuntimeStreamStatus()
        value.connected = connected; value.attachedThreads = sessions; value.sourceAvailable = available
        return value
    }
    private func summary(_ statuses: [AgentProvider: [String: RuntimeStreamStatus]], aliases: [String] = [],
                         configured: Set<String> = [], configuring: Set<String> = [], failed: Set<String> = [],
                         unavailable: [String] = [], enabled: [AgentProvider] = AgentProvider.allCases) -> ConnectionSummary {
        ConnectionSummary(enabledProviders: enabled,
            sources: ConnectionSource.sources(statuses: statuses, unavailableSSH: unavailable, names: [:]),
            hosts: SSHHost.hosts(codex: enabled.contains(.codex) ? statuses[.codex] ?? [:] : nil, unavailableCodex: unavailable,
                claude: enabled.contains(.claude) ? statuses[.claude] ?? [:] : nil, claudeAliases: aliases,
                configured: configured, configuring: configuring, failed: failed))
    }

    func testUnpublishedAndConfiguringTargetsPreventAllConnectedSummary() {
        var statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [
            .codex: ["local": status(true, sessions: 2)], .claude: ["local": status(true, sessions: 1)]]
        let waiting = summary(statuses, aliases: ["new-host"])
        XCTAssertEqual(waiting.state, .connecting(1), "A configured target without a stream status still counts")
        XCTAssertEqual(waiting.sources, 3)
        XCTAssertEqual(waiting.sessions, 3)
        statuses[.claude]?[prefix + "new-host"] = status(true, sessions: 8, available: true)
        for configuring: Set<String> in [[], ["new-host"]] {
            let pending = summary(statuses, aliases: ["new-host"], configuring: configuring)
            XCTAssertEqual(pending.state, .connecting(1), "A connected collector is not ready while its hooks are being configured")
            XCTAssertEqual(pending.sources, 3, "The host row and stream describe the same source")
            XCTAssertEqual(pending.sessions, 3, "Use the same effective state and session count as the host row")
        }
        let ready = summary(statuses, aliases: ["new-host"], configured: ["new-host"])
        XCTAssertEqual(ready.state, .connected)
        XCTAssertEqual(ready.sources, 3)
        XCTAssertEqual(ready.sessions, 11)
    }

    func testPausedSourcesAndMissingLocalProviderCannotAppearConnected() {
        let statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [
            .codex: ["local": status(true, sessions: 2)],
            .claude: ["local": status(true), prefix + "no-claude": status(false, sessions: 8, available: false)]]
        let paused = summary(statuses, aliases: ["no-claude"])
        XCTAssertEqual(paused.state, .paused(1), "A reachable host without Claude is paused, not a failure or success")
        XCTAssertEqual(paused.sessions, 2)
        let missing = summary([.codex: ["local": status(true)]])
        XCTAssertEqual(missing.state, .connecting(1), "A missing enabled local provider must be included")
        XCTAssertEqual(missing.sources, 2)
        XCTAssertEqual(summary([:]).state, .checking)
        let disabled = summary(statuses, aliases: ["no-claude"], enabled: [])
        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertEqual(disabled.sources, 0)
        XCTAssertEqual(disabled.sessions, 0)
    }

    func testSummaryDeduplicatesFailuresPerProviderAndHostAndKeepsUnpublishedFailures() {
        let statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [
            .codex: ["local": status(true, sessions: 2), prefix + "shared": status(false)],
            .claude: ["local": status(true), prefix + "shared": status(false)]]
        let result = summary(statuses, aliases: ["shared", "setup-only"], failed: ["shared", "setup-only"], unavailable: ["shared"])
        XCTAssertEqual(result.state, .retrying(3), "Duplicate status, unavailable and setup records count once per provider/host")
        XCTAssertEqual(result.sources, 5)
        XCTAssertEqual(result.sessions, 2)
        let retry = summary(statuses, aliases: ["shared", "setup-only"], configuring: ["setup-only"], failed: ["setup-only"], unavailable: ["shared"])
        XCTAssertEqual(retry.state, .retrying(2), "A setup retry in flight replaces its earlier failure")
        let claudeOnly = summary(statuses, aliases: ["shared"], enabled: [.claude])
        XCTAssertEqual(claudeOnly.state, .retrying(1))
        XCTAssertEqual(claudeOnly.sources, 2, "Disabled providers do not contribute sources")
    }

    func testIdleRemoteControlIsNeutralAndCannotHideOtherFailures() throws {
        let control = ConnectionSource.controlPrefix + "fixture"
        var idle = status(false)
        idle.waitingForSession = true
        var statuses: [AgentProvider: [String: RuntimeStreamStatus]] = [
            .codex: ["local": status(true, sessions: 2), control: idle], .claude: ["local": status(true)]]
        let sources = ConnectionSource.sources(statuses: statuses, unavailableSSH: [], names: [:])
        XCTAssertEqual(try XCTUnwrap(sources.first { $0.key == control }).state, .idle)
        let waiting = summary(statuses)
        XCTAssertEqual(waiting.state, .idle)
        XCTAssertEqual(waiting.sources, 3)
        XCTAssertEqual(waiting.sessions, 2)

        statuses[.codex]?[prefix + "failed"] = status(false)
        XCTAssertEqual(summary(statuses).state, .retrying(1), "An idle Remote Control host cannot hide an SSH failure")
        statuses[.codex]?.removeValue(forKey: prefix + "failed")
        statuses[.codex]?[control] = status(false)
        XCTAssertEqual(summary(statuses).state, .retrying(1), "Actual Remote Control failure still offers Retry")
        statuses[.codex]?[control] = status(true, sessions: 1)
        XCTAssertEqual(summary(statuses).state, .connected)
        XCTAssertEqual(summary(statuses).sessions, 3)
    }
    func testDeviceNamesSurviveZeroSessionsAndOfflineIsNotAConnectionFailure() throws {
        var work = status(true, sessions: 1), notebook = status(false)
        work.sourceName = "Workstation"; work.remoteHostOnline = true
        notebook.sourceName = "Notebook"; notebook.remoteHostOnline = false
        let rows = ConnectionSource.sources(statuses: [.codex: ["local": status(true),
            ConnectionSource.controlPrefix + "work": work, ConnectionSource.controlPrefix + "notebook": notebook]], unavailableSSH: [], names: [:])
        let offline = try XCTUnwrap(rows.first { $0.name == "Notebook" })
        XCTAssertEqual(offline.state, .offline)
        XCTAssertFalse(notebook.hasConnectionFailure)
        let result = ConnectionSummary(enabledProviders: [.codex], sources: rows, hosts: [])
        XCTAssertEqual(result.sources, 3)
        XCTAssertEqual(result.sessions, 1)
        XCTAssertEqual(result.state, .offline(1), "An offline device must not imply that the running source is waiting for a session")
    }
}
