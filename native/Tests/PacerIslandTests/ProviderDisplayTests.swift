import XCTest
import PacerCore
@testable import PacerIsland

@MainActor
final class ProviderDisplayTests: XCTestCase {
    private struct Fixture {
        let model: IslandModel
        let defaults: UserDefaults
        let domain: String
    }

    private final class Suspension<Value> {
        private var continuation: CheckedContinuation<Value, Never>?
        private let started: () -> Void
        init(started: @escaping () -> Void) { self.started = started }
        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started()
            }
        }
        func resume(_ value: Value) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: value)
        }
    }

    private func fixture() throws -> Fixture {
        let domain = "com.codexpacer.provider-display-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "completionReminder")
        defaults.set(true, forKey: "inputReminder")
        defaults.set(true, forKey: "monitorSSH")
        defaults.set(0, forKey: "completedRetentionMinutes")
        let model = IslandModel(demo: true, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: true, claudeInstalled: true))
        model.activities = []
        model.selectProvider(.codex); model.quota = nil; model.history = QuotaCycleHistory()
        model.selectProvider(.claude); model.quota = nil; model.history = QuotaCycleHistory()
        model.selectProvider(.codex)
        return Fixture(model: model, defaults: defaults, domain: domain)
    }

    private func quota(_ provider: AgentProvider, used: Double, at now: Date) throws -> QuotaSnapshot {
        let data = try JSONSerialization.data(withJSONObject: ["rateLimits": [
            "limitId": provider.rawValue,
            "primary": ["usedPercent": used, "windowDurationMins": 300,
                "resetsAt": now.addingTimeInterval(9_000).timeIntervalSince1970],
            "secondary": ["usedPercent": used + 5, "windowDurationMins": 10_080,
                "resetsAt": now.addingTimeInterval(302_400).timeIntervalSince1970]
        ]])
        var snapshot = try QuotaSnapshot.decode(data, capturedAt: now)
        snapshot.accountScope = "synthetic-" + provider.rawValue
        return snapshot
    }

    private func activity(_ provider: AgentProvider, session: String, at now: Date, tokens: Int = 100,
                          completed: Bool = false, hostID: String? = nil) -> SessionActivity {
        var value = SessionActivity(id: provider.activityID(sessionID: session, sourceHostID: hostID), project: "Synthetic task",
            sourceHost: hostID == nil ? nil : "Synthetic host", sourceHostID: hostID,
            phaseAwareRate: true, provider: provider, sessionID: session)
        let turn = "synthetic-turn"
        value.applyRuntime(["method": "turn/started", "threadId": session, "turnId": turn,
            "at": now.addingTimeInterval(-10).timeIntervalSince1970])
        if provider == .claude {
            // Claude supplies service request duration and TTFT without an
            // observed text delta. Exercise the same numeric update as OTLP.
            if let sample = ResponsePerformance(responseID: "synthetic-request", turnID: turn, outputTokens: tokens,
                startedAt: now.addingTimeInterval(-10), completedAt: now.addingTimeInterval(-5), source: .requestUsage),
               let update = SessionPerformanceUpdate(id: value.canonicalized().id, turnID: turn, response: sample,
                firstTokenLatency: 1, firstTokenReportedAt: now.addingTimeInterval(-9)) {
                update.apply(to: &value)
            }
        } else {
            value.applyRuntime(["method": "item/agentMessage/delta", "threadId": session, "turnId": turn,
                "hasText": true, "at": now.addingTimeInterval(-5).timeIntervalSince1970])
            // Accounting arrives after the last generated item. Its receipt
            // must not extend the five-second model response window.
            value.applyRequestUsage(responseID: "synthetic-request", turnID: turn, outputTokens: tokens,
                at: now.addingTimeInterval(-4))
        }
        if completed {
            value.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": turn,
                "status": "completed", "at": now.addingTimeInterval(-1).timeIntervalSince1970])
        }
        return value.canonicalized()
    }

    private var connected: RuntimeStreamStatus {
        var value = RuntimeStreamStatus(); value.connected = true
        return value
    }

    func testNewSignInDropsOldOrganizationWhileRetryKeepsExplicitChoice() async throws {
        let fixture = try fixture(), model = fixture.model
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let organization = "c211bf81-dc2a-4a19-b75d-9e03e47490e7"
        model.selectProvider(.claude)
        model.retryClaudeWebConnection(organizationID: organization)
        await Task.yield()
        model.retryQuotaConnection()
        XCTAssertEqual(fixture.defaults.string(forKey: "claudeWebOrganizationID"), organization)
        model.retryClaudeWebConnection(afterSignIn: true)
        XCTAssertNil(fixture.defaults.string(forKey: "claudeWebOrganizationID"))
        XCTAssertEqual(model.enabledProviders, [.codex, .claude])
        await model.shutdown()
    }

    func testClaudeConnectionActionsDistinguishSignInAndWorkspaceSelection() async throws {
        let domain = "com.codexpacer.provider-connection-actions-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("/private/tmp/pacer-connection-actions-" + UUID().uuidString, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        defaults.set(false, forKey: "completionReminder")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        let choices = [ClaudeWebOrganization(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name: "Synthetic workspace")]
        var reads = ClaudeQuotaReadDependencies()
        reads.passive = { _ in nil }
        reads.webSession = { ClaudeWebSession(cookieHeader: "sessionKey=fixture-cookie", sessionHash: String(repeating: "a", count: 64)) }
        reads.web = { _ in throw ClaudeQuotaError.organizationSelectionRequired }
        reads.organizations = { _ in choices }
        let model = IslandModel(defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false), claudeQuotaReads: reads)
        var logins = 0, selections = 0
        model.onClaudeLogin = { logins += 1 }
        model.onClaudeOrganizationSelection = { candidates in
            XCTAssertEqual(candidates, choices)
            selections += 1
        }
        XCTAssertFalse(model.claudeNeedsOrganizationSelection)
        XCTAssertEqual(model.claudeConnectionActionTitleKey, "claude.quota.connect")
        XCTAssertEqual(model.claudeConnectionActionHelpKey, "claude.quota.connect_help")
        model.chooseClaudeOrganization()
        XCTAssertEqual(selections, 0); XCTAssertEqual(logins, 0)
        model.signInClaudeQuota(); model.connectClaudeQuota()
        XCTAssertEqual(logins, 2); XCTAssertEqual(selections, 0)

        model.selectProvider(.claude); model.retryQuotaConnection()
        await model.waitForClaudeQuotaRefresh()
        XCTAssertTrue(model.claudeNeedsOrganizationSelection)
        XCTAssertEqual(model.claudeConnectionActionTitleKey, "claude.quota.choose_workspace")
        XCTAssertEqual(model.claudeConnectionActionHelpKey, "claude.quota.choose_workspace_help")
        model.signInClaudeQuota()
        XCTAssertEqual(logins, 3); XCTAssertEqual(selections, 0, "Switching accounts must still open login when workspace candidates exist")
        model.chooseClaudeOrganization(); model.connectClaudeQuota()
        XCTAssertEqual(selections, 2); XCTAssertEqual(logins, 3, "Workspace selection must not send the user back through login")

        ProviderModules(codexMode: .disabled, claudeMode: .disabled).save(to: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(model.claudeNeedsOrganizationSelection)
        model.chooseClaudeOrganization()
        XCTAssertEqual(selections, 2)
        XCTAssertEqual(model.claudeConnectionActionTitleKey, "claude.quota.connect")
        await model.shutdown()
    }

    func testVerifiedLocalMirrorRemovalPreservesRealRemoteAndOtherProviderEndings() async throws {
        let fixture = try fixture(), model = fixture.model, now = Date()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let session = "019a0000-0000-7000-8000-000000000025"
        let mirror = activity(.claude, session: session, at: now, completed: true)
        let remote = activity(.claude, session: session, at: now, completed: true, hostID: "remote-ssh-discovered:synthetic")
        let codex = activity(.codex, session: session, at: now, completed: true)
        model.receiveRemoteUpdate([codex], statuses: ["local": connected], unavailable: [], requests: [], names: [])
        model.receiveClaudeUpdate([mirror, remote], statuses: [:], requests: [])
        XCTAssertTrue(model.isUnreadCompletion(mirror))
        model.receiveClaudeUpdate([mirror, remote], statuses: [:], requests: [],
            excludedLocalIDs: [mirror.id, remote.id, codex.id])
        XCTAssertFalse(model.activities.contains { $0.id == mirror.id })
        XCTAssertFalse(model.isUnreadCompletion(mirror))
        XCTAssertTrue(model.isUnreadCompletion(remote))
        XCTAssertTrue(model.isUnreadCompletion(codex))
        XCTAssertEqual(Set(model.pendingCompletions.map(\.id)), [remote.id, codex.id])
        await model.shutdown()
    }

    func testQuotaTabKeepsProviderWindowsHistoryAndErrorsIndependent() async throws {
        let fixture = try fixture(), model = fixture.model, now = Date()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        model.now = now
        let codex = try quota(.codex, used: 20, at: now), claude = try quota(.claude, used: 60, at: now)
        fixture.defaults.set("codex/primary", forKey: "quotaWindowID")
        fixture.defaults.set("claude/secondary", forKey: "claudeQuotaWindowID")
        model.quota = codex; model.history.record(codex)
        model.errorMessage = "Synthetic Codex error"; model.historyWarning = "Synthetic Codex history warning"
        let codexHistory = model.history
        model.selectProvider(.claude)
        XCTAssertNil(model.quota)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.history.cycles.isEmpty)
        model.quota = claude; model.history.record(claude)
        model.errorMessage = "Synthetic Claude error"; model.historyWarning = "Synthetic Claude history warning"
        let claudeHistory = model.history
        XCTAssertEqual(model.selectedWindow?.id, "claude/secondary")
        XCTAssertEqual(fixture.defaults.string(forKey: "selectedQuotaProvider"), "claude")

        model.selectProvider(.codex)
        XCTAssertEqual(model.quota, codex)
        XCTAssertEqual(model.selectedWindow?.id, "codex/primary")
        XCTAssertEqual(model.history, codexHistory)
        XCTAssertEqual(model.errorMessage, "Synthetic Codex error")
        XCTAssertEqual(model.historyWarning, "Synthetic Codex history warning")
        XCTAssertEqual(model.providerQuota(.claude), claude)
        XCTAssertEqual(model.providerQuotaError(.claude), "Synthetic Claude error")
        model.selectProvider(.claude)
        XCTAssertEqual(model.history, claudeHistory)
        XCTAssertEqual(model.historyWarning, "Synthetic Claude history warning")
        model.quota = nil; model.errorMessage = nil
        XCTAssertEqual(model.providerQuota(.codex), codex, "Clearing an unavailable provider cannot clear another provider's quota")
        XCTAssertEqual(model.providerQuotaError(.codex), "Synthetic Codex error")
        await model.shutdown()
    }

    func testQuotaTabsKeepMixedTasksAndAggregatedThroughputForMatchingSessionIDs() async throws {
        let fixture = try fixture(), model = fixture.model, now = Date()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let session = "019a0000-0000-7000-8000-000000000021"
        let codex = activity(.codex, session: session, at: now, tokens: 100)
        let claude = activity(.claude, session: session, at: now, tokens: 50)
        XCTAssertEqual(try XCTUnwrap(codex.responsePerformance).duration, 5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(claude.responsePerformance).duration, 5, accuracy: 0.000_001)
        XCTAssertEqual(codex.responsePerformance?.source, .requestUsage)
        XCTAssertEqual(claude.responsePerformance?.source, .requestUsage)
        model.receiveRemoteUpdate([codex], statuses: ["local": connected], unavailable: [], requests: [], names: [])
        model.receiveClaudeUpdate([claude], statuses: ["local": connected], requests: [])
        let ids = Set([codex.id, claude.id])
        XCTAssertEqual(Set(model.visibleActivities.map(\.id)), ids)
        XCTAssertEqual(model.taskGroups.count, 2, "Matching host/session identifiers from different providers cannot merge")
        XCTAssertEqual(try XCTUnwrap(model.rate), 30, accuracy: 0.000_001)
        for provider in [AgentProvider.claude, .codex] {
            model.selectProvider(provider)
            XCTAssertEqual(Set(model.visibleActivities.map(\.id)), ids, "The quota tab must not filter the task region")
            XCTAssertEqual(model.running.count, 2)
            XCTAssertEqual(try XCTUnwrap(model.rate), 30, accuracy: 0.000_001)
        }
        await model.shutdown()
    }

    func testRepeatedTaskPresentationReusesGroupingButExactClockStillChangesFreshness() async throws {
        let fixture = try fixture(), model = fixture.model
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = "019a0000-0000-7000-8000-000000000028"
        let running = activity(.codex, session: session, at: now, tokens: 100)
        model.now = now; model.activities = [running]
        let before = model.taskGroupingComputations
        XCTAssertEqual(model.running.count, 1)
        XCTAssertEqual(model.rate, 20)
        let grouped = model.taskGroupingComputations
        XCTAssertEqual(grouped, before + 1)
        for _ in 0..<10 {
            _ = model.headerStatus; _ = model.headerActivity(); _ = model.visibleActivities
            _ = model.rate; _ = model.rateIsFresh; _ = model.taskGroup(for: running)
        }
        XCTAssertEqual(model.taskGroupingComputations, grouped,
            "One activity snapshot must not rebuild its grouping for every displayed component")
        model.now = now.addingTimeInterval(9.999)
        XCTAssertTrue(model.rateIsFresh)
        model.now = now.addingTimeInterval(10.001)
        XCTAssertFalse(model.rateIsFresh)
        XCTAssertEqual(model.rate, 20, "A stale measurement remains numeric after the exact freshness boundary")
        XCTAssertEqual(model.running.count, 1)
        model.selectProvider(.claude)
        XCTAssertEqual(model.taskGroupingComputations, grouped, "Quota selection and the clock do not change task ownership")
        model.activities = [activity(.codex, session: session, at: now, completed: true)]
        XCTAssertTrue(model.running.isEmpty)
        XCTAssertNil(model.rate)
        XCTAssertEqual(model.taskGroups.first?.primary.phase, .completed)
        XCTAssertEqual(model.taskGroupingComputations, grouped + 1, "A real lifecycle change invalidates grouped state")
        await model.shutdown()
    }

    func testClaudeOpenAcknowledgesActualConversationAndKeepsTerminalOrFailureUnread() async throws {
        for outcome in [ActivityOpenOutcome.dispatchedTerminal, .openedConversation, .failed("Synthetic open failure")] {
            let acknowledges: Bool
            if case .openedConversation = outcome { acknowledges = true } else { acknowledges = false }
            let domain = "com.codexpacer.provider-terminal-tests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
            defaults.set(0, forKey: "completedRetentionMinutes")
            // Receive synthetic lifecycle with reminders disabled, so this
            // non-demo fixture cannot deliver an actual system notification.
            defaults.set(false, forKey: "completionReminder")
            let model = IslandModel(defaults: defaults,
                installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
            let completed = activity(.claude, session: "019a0000-0000-7000-8000-000000000023", at: Date(),
                completed: true, hostID: "remote-ssh-discovered:synthetic")
            model.receiveClaudeUpdate([completed], statuses: [:], requests: [])
            defaults.set(true, forKey: "completionReminder")
            XCTAssertTrue(model.canOpen(completed))
            XCTAssertTrue(model.isUnreadCompletion(completed))
            let dispatched = expectation(description: "Navigation dispatch callback"), processed = expectation(description: "Open result processed")
            model.onOpenActivity = { requested in
                XCTAssertEqual(requested.id, completed.id)
                dispatched.fulfill()
                return outcome
            }
            model.onStatusChange = { processed.fulfill() }
            model.open(completed)
            await fulfillment(of: [dispatched, processed], timeout: 2)
            XCTAssertEqual(model.activities.contains { $0.id == completed.id && $0.turnID == completed.turnID }, !acknowledges)
            XCTAssertEqual(model.isUnreadCompletion(completed), !acknowledges, "Only the actual conversation-open result acknowledges the chat")
            XCTAssertEqual(model.pendingCompletions.map(\.id), acknowledges ? [] : [completed.id])
            if case .failed(let message) = outcome { XCTAssertEqual(model.navigationError, message) }
            else { XCTAssertNil(model.navigationError) }
            await model.shutdown()
        }
    }

    func testQueuedClaudeOpenDoesNotUseAReplacedProfile() async throws {
        let fixture = try fixture(), model = fixture.model, now = Date()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let completed = activity(.claude, session: "019a0000-0000-7000-8000-000000000027", at: now, completed: true)
        model.receiveClaudeUpdate([completed], statuses: ["local": connected], requests: [])
        var launches = 0
        model.onOpenActivity = { _ in launches += 1; return .openedConversation }
        model.open(completed)
        fixture.defaults.set("/private/tmp/pacer-replaced-profile-" + UUID().uuidString, forKey: "claudeHome")
        model.applySettings(sourceChanged: false)
        await Task.yield()
        XCTAssertEqual(launches, 0)
        XCTAssertNil(model.navigationError)
        await model.shutdown()
    }

    func testSourceResetDuringSuspendedClaudeReadsCannotUseOrPublishTheOldClient() async throws {
        enum ReadBoundary: CaseIterable, Equatable { case passive, cookie, quota }
        for changesHome in [false, true] {
            for boundary in ReadBoundary.allCases {
                let domain = "com.codexpacer.provider-source-race-tests." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-quota-race-" + UUID().uuidString)
                defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defaults.set(root.appendingPathComponent("old-home").path, forKey: "claudeHome")
                defaults.set(false, forKey: "monitorSSH")
                defaults.set(false, forKey: "completionReminder")
                ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
                let started = expectation(description: "Suspended \(boundary), home change \(changesHome)")
                let passive = Suspension<QuotaSnapshot?>(started: { started.fulfill() })
                let cookie = Suspension<ClaudeWebSession?>(started: { started.fulfill() })
                let quotaResult = Suspension<QuotaSnapshot>(started: { started.fulfill() })
                var reads = ClaudeQuotaReadDependencies(), passiveCalls = 0, cookieCalls = 0, compatibilityCalls = 0, webCalls = 0
                var snapshot = try quota(.claude, used: 20, at: Date())
                snapshot.accountScope = nil // A synthetic sample must never persist into the real history store.
                reads.passive = { _ in
                    passiveCalls += 1
                    if boundary == .passive && passiveCalls == 1 { return await passive.wait() }
                    return nil
                }
                reads.webSession = {
                    cookieCalls += 1
                    if boundary == .cookie && cookieCalls == 1 { return await cookie.wait() }
                    return nil
                }
                reads.compatibility = { _ in
                    compatibilityCalls += 1
                    if boundary == .quota && compatibilityCalls == 1 { return await quotaResult.wait() }
                    throw ClaudeQuotaError.unavailable
                }
                reads.web = { _ in webCalls += 1; return snapshot }
                let model = IslandModel(defaults: defaults,
                    installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false), claudeQuotaReads: reads)
                model.selectProvider(.claude); model.retryQuotaConnection()
                await fulfillment(of: [started], timeout: 2)
                // This waiter captures the actual old owned task before Save replaces it.
                let oldReadFinished = Task { await model.waitForClaudeQuotaRefresh() }
                await Task.yield()
                if changesHome { defaults.set(root.appendingPathComponent("new-home").path, forKey: "claudeHome") }
                else { ProviderModules(codexMode: .disabled, claudeMode: .disabled).save(to: defaults) }
                model.applySettings(sourceChanged: false)
                switch boundary {
                case .passive: passive.resume(nil)
                case .cookie: cookie.resume(ClaudeWebSession(cookieHeader: "sessionKey=synthetic-cookie", sessionHash: String(repeating: "a", count: 64)))
                case .quota: quotaResult.resume(snapshot)
                }
                await oldReadFinished.value
                XCTAssertNil(model.providerQuota(.claude), "A result from the replaced source must never publish")
                XCTAssertEqual(webCalls, 0, "A canceled cookie read must not create/use a stale-home web client")
                if boundary != .quota && !changesHome { XCTAssertEqual(compatibilityCalls, 0) }
                await model.shutdown()
            }
        }
    }

    func testCodexHomeEditResetsClaudeOnlyWhenItsSSHDiscoveryUsesThatHome() async throws {
        for monitorsSSH in [false, true] {
            let fixture = try fixture(), model = fixture.model, now = Date()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
            fixture.defaults.set(monitorsSSH, forKey: "monitorSSH")
            model.applySettings(sourceChanged: false)
            let completion = activity(.claude, session: "019a0000-0000-7000-8000-000000000026", at: now, completed: true)
            model.receiveClaudeUpdate([completion], statuses: ["local": connected], requests: [])
            model.selectProvider(.claude)
            let snapshot = try quota(.claude, used: 25, at: now)
            model.quota = snapshot; model.history.record(snapshot)
            let history = model.history
            XCTAssertTrue(model.isUnreadCompletion(completion))
            fixture.defaults.set("/private/tmp/pacer-synthetic-codex-home-" + UUID().uuidString, forKey: "codexHome")
            model.applySettings(sourceChanged: true)
            if monitorsSSH {
                XCTAssertNil(model.providerQuota(.claude))
                XCTAssertTrue(model.pendingCompletions.isEmpty)
            } else {
                XCTAssertEqual(model.providerQuota(.claude), snapshot)
                XCTAssertEqual(model.history, history)
                XCTAssertTrue(model.isUnreadCompletion(completion))
                XCTAssertEqual(model.pendingCompletions.map(\.id), [completion.id])
            }
            await model.shutdown()
        }
    }

    func testDisablingEitherModulePreservesOtherQuotaAndUnreadCompletion() async throws {
        for disabled in AgentProvider.allCases {
            let fixture = try fixture(), model = fixture.model, now = Date()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
            let session = "019a0000-0000-7000-8000-000000000022"
            let codex = activity(.codex, session: session, at: now, completed: true)
            let claude = activity(.claude, session: session, at: now, completed: true)
            model.receiveRemoteUpdate([codex], statuses: ["local": connected], unavailable: [], requests: [], names: [])
            model.receiveClaudeUpdate([claude], statuses: ["local": connected], requests: [])
            for provider in AgentProvider.allCases {
                model.selectProvider(provider)
                let snapshot = try quota(provider, used: 30, at: now)
                model.quota = snapshot; model.history.record(snapshot)
                model.errorMessage = "Synthetic " + provider.rawValue + " error"
            }
            let kept: AgentProvider = disabled == .codex ? .claude : .codex
            let completion = kept == .codex ? codex : claude
            model.selectProvider(kept)
            let keptQuota = model.quota, keptHistory = model.history, keptError = model.errorMessage
            XCTAssertTrue(model.isUnreadCompletion(completion))
            XCTAssertEqual(model.pendingCompletions.count, 2)
            model.selectProvider(disabled)
            var modules = ProviderModules.load(from: fixture.defaults)
            modules.setMode(.disabled, for: disabled); modules.save(to: fixture.defaults)
            model.applySettings(sourceChanged: false)
            await Task.yield()
            XCTAssertEqual(model.enabledProviders, [kept])
            XCTAssertEqual(model.selectedProvider, kept)
            XCTAssertNil(model.providerQuota(disabled))
            XCTAssertEqual(model.quota, keptQuota)
            XCTAssertEqual(model.history, keptHistory)
            XCTAssertEqual(model.errorMessage, keptError)
            XCTAssertEqual(Set(model.visibleActivities.map(\.id)), Set([completion.id]))
            XCTAssertTrue(model.isUnreadCompletion(completion), "Disabling another module cannot acknowledge this completion")
            XCTAssertEqual(model.pendingCompletions.map(\.id), [completion.id])
            await model.shutdown()
        }
    }

    func testDisablingBothModulesLeavesNoQuotaOrTaskComponentsAndRejectsTabSelection() async throws {
        let fixture = try fixture(), model = fixture.model
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        ProviderModules(codexMode: .disabled, claudeMode: .disabled).save(to: fixture.defaults)
        model.applySettings(sourceChanged: false)
        await Task.yield()
        XCTAssertTrue(model.enabledProviders.isEmpty)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertTrue(model.visibleActivities.isEmpty)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertNil(model.quota)
        XCTAssertFalse(model.isModuleEnabled(.codex)); XCTAssertFalse(model.isModuleEnabled(.claude))
        let before = model.selectedProvider
        model.selectProvider(.claude)
        XCTAssertEqual(model.selectedProvider, before)
        for component in [CompactIslandLayout.Component.codexQuota, .claudeQuota, .quotaLabel, .timeRemaining, .lowQuotaWarning, .quotaDelayWarning] {
            XCTAssertFalse(CompactIslandComponent.isVisible(component, model: model))
        }
        await model.shutdown()
    }

    func testCompactQuotaAndSourceWarningsIncludeTheUnselectedProvider() async throws {
        let fixture = try fixture(), model = fixture.model, now = Date()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        model.now = now
        model.quota = try quota(.codex, used: 30, at: now)
        model.selectProvider(.claude); model.quota = try quota(.claude, used: 90, at: now)
        model.selectProvider(.codex)
        XCTAssertTrue(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model), "Claude's low quota is visible while Codex is selected")
        model.selectProvider(.claude); model.errorMessage = "Synthetic unavailable usage"
        model.selectProvider(.codex)
        XCTAssertFalse(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model), "Unavailable usage cannot create a live low-quota warning")
        XCTAssertTrue(CompactIslandComponent.isVisible(.quotaDelayWarning, model: model))
        model.quota = try quota(.codex, used: 95, at: now)
        XCTAssertTrue(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model))
        XCTAssertTrue(CompactIslandComponent.isVisible(.quotaDelayWarning, model: model), "Warnings from different providers remain additive")

        let host = "remote-ssh-discovered:synthetic"
        model.receiveRemoteUpdate([], statuses: ["local": connected, host: connected], unavailable: [], requests: [], names: [])
        model.receiveClaudeUpdate([], statuses: ["local": connected, host: RuntimeStreamStatus()], requests: [])
        XCTAssertTrue(CompactIslandComponent.isVisible(.sshWarning, model: model), "Healthy Codex SSH cannot conceal disconnected Claude SSH")
        var missing = RuntimeStreamStatus(); missing.sourceAvailable = false
        model.receiveClaudeUpdate([], statuses: ["local": connected, host: missing], requests: [])
        XCTAssertFalse(CompactIslandComponent.isVisible(.sshWarning, model: model), "A paused missing Claude source is not an SSH failure")
        model.receiveClaudeUpdate([], statuses: ["local": connected, host: RuntimeStreamStatus()], requests: [])
        fixture.defaults.set(false, forKey: "monitorSSH")
        XCTAssertFalse(CompactIslandComponent.isVisible(.sshWarning, model: model))
        fixture.defaults.set(true, forKey: "monitorSSH")
        XCTAssertTrue(CompactIslandComponent.isVisible(.sshWarning, model: model), "Disabling the preference does not erase the diagnostic state")
        var modules = ProviderModules.load(from: fixture.defaults)
        modules.claudeMode = .disabled; modules.save(to: fixture.defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(CompactIslandComponent.isVisible(.sshWarning, model: model), "A disabled module cannot leave a connection warning")
        await model.shutdown()
    }
}
