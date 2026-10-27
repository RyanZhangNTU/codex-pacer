import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class DeepSeekIslandTests: XCTestCase {
    private func defaults(_ modules: ProviderModules) throws -> (UserDefaults, String) {
        let domain = "com.codexpacer.deepseek-island-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "monitorSSH")
        defaults.set(0, forKey: "completedRetentionMinutes")
        defaults.set("/private/tmp/pacer-deepseek-tests-" + UUID().uuidString, forKey: "deepseekHome")
        modules.save(to: defaults)
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        return (defaults, domain)
    }
    private func ended(_ provider: AgentProvider, session: String, cost: Double? = nil) -> SessionActivity {
        let at = Date().addingTimeInterval(-5)
        var activity = SessionActivity(id: provider.activityID(sessionID: session, sourceHostID: nil), provider: provider)
        activity.applyRuntime(["method": "turn/started", "threadId": session, "turnId": "1.4", "at": at.timeIntervalSince1970])
        if let cost { activity.setTurnCost(cost, turnID: "1.4") }
        activity.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": "1.4", "status": "completed",
            "at": at.timeIntervalSince1970 + 2])
        return activity
    }

    func testTurnCostFollowsItsSettingAndDisablingDeepSeekKeepsTheOtherModule() async throws {
        let (defaults, _) = try defaults(ProviderModules(codexMode: .enabled, claudeMode: .disabled, deepseekMode: .enabled))
        let model = IslandModel(demo: true, defaults: defaults, installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        model.activities = []
        let session = "019a0000-0000-7000-8000-000000000a01"
        let codex = ended(.codex, session: session, cost: 0.5), deepseek = ended(.deepseek, session: session, cost: 0.42)
        XCTAssertNil(codex.turnCost, "Only DeepSeek turns carry an estimate")
        model.receiveRemoteUpdate([codex], statuses: [:], unavailable: [], requests: [], names: [])
        model.receiveDeepSeekUpdate([deepseek], statuses: ["local": RuntimeStreamStatus()], requests: [])
        XCTAssertEqual(model.enabledProviders, [.codex, .deepseek])
        XCTAssertEqual(Set(model.visibleActivities.map(\.id)), [codex.id, deepseek.id])
        let row = try XCTUnwrap(model.visibleActivities.first { $0.provider == .deepseek })
        XCTAssertEqual(model.displayedTurnCost(row) ?? 0, 0.42, accuracy: 0.0001, "An ended turn keeps its final estimate")
        XCTAssertNil(model.displayedTurnCost(codex))
        defaults.set(false, forKey: IslandModel.deepseekTurnCostKey)
        XCTAssertNil(model.displayedTurnCost(row))
        XCTAssertTrue(model.isUnreadCompletion(codex))

        var modules = ProviderModules.load(from: defaults)
        modules.setMode(.disabled, for: .deepseek); modules.save(to: defaults)
        model.applySettings(sourceChanged: false)
        await Task.yield()
        XCTAssertEqual(model.enabledProviders, [.codex])
        XCTAssertEqual(model.visibleActivities.map(\.id), [codex.id])
        XCTAssertTrue(model.isUnreadCompletion(codex), "Disabling DeepSeek cannot acknowledge another module's completion")
        XCTAssertEqual(QuotaDashboardLayout.slots(providers: [.deepseek, .codex]).map(\.provider), [.codex, .deepseek])
        await model.shutdown()
    }

    func testBalanceReadsFollowTheChosenSourceAndStopAskingAfterARejectedKey() async throws {
        let (defaults, _) = try defaults(ProviderModules(codexMode: .disabled, claudeMode: .disabled, deepseekMode: .enabled))
        defaults.set(DeepSeekBalanceSource.apiKey.rawValue, forKey: DeepSeekBalanceSource.defaultsKey)
        let model = IslandModel(defaults: defaults, installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        var key: String? = nil, apiReads = 0, webReads = 0
        var reply: Result<Double, DeepSeekBalanceError> = .success(8.4)
        model.deepseekBalanceReads.apiKey = { key }
        model.deepseekBalanceReads.api = { sent in
            apiReads += 1
            XCTAssertEqual(sent, key)
            return DeepSeekBalance(total: try reply.get(), capturedAt: Date(), source: .apiKey)
        }
        model.deepseekBalanceReads.web = {
            webReads += 1
            return DeepSeekBalance(total: 120, alertBound: 150, capturedAt: Date(), source: .web)
        }
        func settle() async {
            for _ in 0..<200 where model.deepseekRefreshing { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        model.refreshDeepSeekBalance(force: true)
        XCTAssertEqual(model.deepseekBalanceError, .missingKey, "No key means asking for one, without a request")
        XCTAssertTrue(model.deepseekConnectionNeeded)
        XCTAssertEqual(apiReads, 0)

        key = "sk-0123456789abcdef0123"
        model.refreshDeepSeekBalance(force: true); await settle()
        XCTAssertEqual(apiReads, 1)
        XCTAssertEqual(model.deepseekBalance?.total, 8.4)
        XCTAssertNil(model.deepseekBalanceError)
        XCTAssertEqual(model.deepseekWallet.state, .low)
        XCTAssertEqual(model.compactStripWalletText, "¥8.4")

        reply = .failure(.invalidKey)
        model.refreshDeepSeekBalance(force: true); await settle()
        XCTAssertEqual(model.deepseekBalanceError, .invalidKey)
        XCTAssertNil(model.deepseekBalance, "A rejected key clears the old balance")
        model.refreshDeepSeekBalance(); await settle()
        XCTAssertEqual(apiReads, 2, "A periodic refresh does not retry a key that needs replacing")

        reply = .failure(.connectionFailed)
        model.refreshDeepSeekBalance(force: true); await settle()
        XCTAssertEqual(model.deepseekBalanceError, .connectionFailed)
        XCTAssertFalse(model.deepseekConnectionNeeded)

        defaults.set(DeepSeekBalanceSource.web.rawValue, forKey: DeepSeekBalanceSource.defaultsKey)
        model.applySettings(sourceChanged: false); await settle()
        XCTAssertEqual(webReads, 1, "A new source reads the wallet again at once")
        XCTAssertEqual(model.deepseekBalance?.source, .web)
        XCTAssertEqual(model.deepseekWallet.state, .low, "The platform's alert line decides low")
        await model.shutdown()
    }

    func testBalanceNoticesFireOnceEachTimeTheLineIsCrossed() {
        let now = Date()
        func wallet(_ total: Double) -> DeepSeekWallet {
            DeepSeekWallet(balance: DeepSeekBalance(total: total, capturedAt: now, source: .web), connected: true,
                ledger: DeepSeekSpendLedger(), now: now, lowThreshold: 10)
        }
        var attention = DeepSeekBalanceAttention()
        XCTAssertTrue(attention.notices(wallet(50)).isEmpty)
        XCTAssertEqual(attention.notices(wallet(8)).map(\.id), ["deepseek:balance:low"])
        XCTAssertTrue(attention.notices(wallet(7)).isEmpty, "Staying low does not repeat")
        XCTAssertEqual(attention.notices(wallet(0)).map(\.id), ["deepseek:balance:exhausted"])
        XCTAssertTrue(attention.notices(wallet(5)).isEmpty, "A small top-up after running out is not a new low warning")
        XCTAssertTrue(attention.notices(wallet(80)).isEmpty)
        let again = attention.notices(wallet(9))
        XCTAssertEqual(again.map(\.id), ["deepseek:balance:low"], "Crossing again after recovering warns again")
        XCTAssertEqual(again.first?.kind, .lowQuota, "Balance notices stay readable when project names are hidden")
    }
}
