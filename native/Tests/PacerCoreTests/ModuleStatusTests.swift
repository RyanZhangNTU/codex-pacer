import XCTest
@testable import PacerCore

/// Every module page's Status card speaks one vocabulary: the same states,
/// tones and at most one action, whatever feeds them.
final class ModuleStatusTests: XCTestCase {
    func testCodexMonitoringFollowsItsCLIThenItsHooks() {
        let missing = ModuleMonitoring.codex(executableFound: false, executableIssue: "No codex", hooks: .running, sessions: 2, opensCodex: true)
        XCTAssertEqual(missing, .init(.notFound, detail: "No codex", action: .rescan), "A missing CLI comes first, with Rescan")
        XCTAssertEqual(ModuleMonitoring.codex(executableFound: nil, hooks: nil, sessions: 0, opensCodex: true).state, .checking)
        XCTAssertEqual(ModuleMonitoring.codex(executableFound: true, hooks: .notInstalled, sessions: 0, opensCodex: true).state, .settingUp)

        let approval = ModuleMonitoring.codex(executableFound: true, hooks: .needsApproval(count: 7), sessions: 0, opensCodex: true)
        XCTAssertEqual(approval.action, .openCodex); XCTAssertNil(approval.detail); XCTAssertTrue(approval.needsUser)
        let manual = ModuleMonitoring.codex(executableFound: true, hooks: .needsApproval(count: 7), sessions: 0, opensCodex: false)
        XCTAssertNil(manual.action, "Without Codex Desktop the row says what to do instead")
        XCTAssertEqual(manual.detail, L10n.text("whats_new.codex_setup.allow_manual"))

        let running = ModuleMonitoring.codex(executableFound: true, hooks: .running, sessions: 2, opensCodex: true)
        XCTAssertEqual(running.tone, .positive); XCTAssertNil(running.action)
        XCTAssertEqual(running.text, L10n.text("monitoring.on") + " · " + L10n.text("connections.sessions", 2))
        XCTAssertEqual(ModuleMonitoring.codex(executableFound: true, hooks: .running, sessions: 0, opensCodex: true).text, L10n.text("monitoring.on"),
                       "No sessions, no count")
        XCTAssertEqual(ModuleMonitoring.codex(executableFound: true, hooks: .notRunning, sessions: 0, opensCodex: true).action, .retry)
        XCTAssertEqual(ModuleMonitoring.codex(executableFound: true, hooks: .needsCodexUpdate, sessions: 0, opensCodex: true).state, .needsUpdate)
        XCTAssertEqual(ModuleMonitoring.codex(executableFound: true, hooks: .installFailed, sessions: 0, opensCodex: true), .init(.failed, action: .retry))
    }

    func testOtherModulesUseTheSameStates() {
        XCTAssertEqual(ModuleMonitoring.claude(.ready, sessions: 1, note: "Estimated"), .init(.on, sessions: 1, detail: "Estimated"))
        XCTAssertEqual(ModuleMonitoring.claude(.configuring, sessions: 0).state, .settingUp)
        XCTAssertEqual(ModuleMonitoring.claude(.failed, sessions: 0).action, .retry)
        XCTAssertEqual(ModuleMonitoring.claude(.missingHome, sessions: 0).tone, .neutral, "No Claude folder yet is no problem")

        XCTAssertEqual(ModuleMonitoring.harness(.ready, detected: true, sessions: 3).text, L10n.text("monitoring.on") + " · " + L10n.text("connections.sessions", 3))
        XCTAssertEqual(ModuleMonitoring.harness(.missing, detected: true, sessions: 0), .init(.waiting, detail: L10n.text("harness.missing"), action: .rescan))
        XCTAssertEqual(ModuleMonitoring.harness(.missing, detected: false, sessions: 0).tone, .attention, "An app not installed needs the user")
        XCTAssertEqual(ModuleMonitoring.harness(.incompatible, detected: true, sessions: 0).state, .unreadable)
        XCTAssertEqual(ModuleMonitoring.harness(nil, detected: true, sessions: 0).state, .checking, "Searching needs no button")
        XCTAssertEqual(ModuleMonitoring.harness(nil, detected: false, sessions: 0).action, .rescan)

        XCTAssertEqual(ModuleMonitoring.deepseek(found: true, sessions: 1).state, .on)
        XCTAssertEqual(ModuleMonitoring.deepseek(found: false, sessions: 0).state, .waiting)
        XCTAssertEqual(ModuleMonitoring.deepseek(found: nil, sessions: 0).tone, .neutral)
    }

    /// Remote counts other machines alone: each module's own tasks here show on its page.
    func testRemoteSummaryCountsHostsOnly() {
        var local = RuntimeStreamStatus(); local.connected = true; local.attachedThreads = 2
        var host = RuntimeStreamStatus(); host.connected = true; host.attachedThreads = 1; host.sourceName = "devbox"
        let alone = ConnectionPagePresentation(enabledProviders: [.codex, .claude], statuses: [.codex: ["local": local], .claude: ["local": local]], hostsOnly: true)
        XCTAssertEqual(alone.state, "noHosts"); XCTAssertEqual(alone.title, L10n.text("connections.summary.no_hosts"))
        XCTAssertTrue(alone.sources.isEmpty); XCTAssertEqual(alone.detail, "")
        let ssh = ConnectionSource.sshPrefix + "devbox"
        let page = ConnectionPagePresentation(enabledProviders: [.codex], statuses: [.codex: ["local": local, ssh: host]], hostsOnly: true)
        XCTAssertEqual(page.state, "connected"); XCTAssertEqual(page.sourceCount, 1, "The local source is not counted")
        XCTAssertEqual(ConnectionPagePresentation(enabledProviders: [.codex], statuses: [.codex: ["local": local]]).sourceCount, 1,
                       "Without hostsOnly the local source still counts, as before")
    }

    func testCodexAccountComesFromItsQuotaRead() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1900000000}}}}"#.utf8)
        let quota = try QuotaSnapshot.decode(data)
        XCTAssertEqual(CodexAccountState(quota: quota, error: nil), .signedIn(plan: "plus"))
        XCTAssertEqual(CodexAccountState(quota: quota, error: nil).text, L10n.text("claude.account.signed_in") + " · Plus")
        XCTAssertEqual(CodexAccountState(quota: nil, error: CodexClientError.notLoggedIn.errorDescription), .signedOut)
        XCTAssertEqual(CodexAccountState.signedOut.detail, L10n.text("codex.account.sign_in_hint"))
        XCTAssertEqual(CodexAccountState(quota: quota, error: "Timed out"), .unavailable, "Another failure leaves the reason to the Usage row")
        XCTAssertEqual(CodexAccountState(quota: nil, error: nil), .checking)
        XCTAssertEqual(CodexAccountState.planName("business_team"), "Business Team")
        XCTAssertNil(CodexAccountState.planName("<script>"))
    }
}
