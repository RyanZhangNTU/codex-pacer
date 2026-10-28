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
                ledger: DeepSeekSpendLedger(), now: now)
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

    func testSpikeAndBudgetNoticesTakeABaselineThenFireOncePerCrossing() {
        let now = Date()
        var ledger = DeepSeekSpendLedger()
        func wallet(_ spent: Double, recent: Bool = false) -> DeepSeekWallet {
            ledger = DeepSeekSpendLedger()
            ledger.record(id: "early", at: Calendar.current.startOfDay(for: now).addingTimeInterval(1), cost: spent)
            if recent { ledger.record(id: "recent", at: now.addingTimeInterval(-60), cost: 6) }
            return DeepSeekWallet(balance: DeepSeekBalance(total: 80, capturedAt: now, source: .web), connected: true,
                ledger: ledger, now: now, budgets: DeepSeekBudgets(daily: 10), spikeLimit: 5)
        }
        var attention = DeepSeekBalanceAttention()
        func ids(_ wallet: DeepSeekWallet, snoozed: Date = .distantPast) -> [String] {
            attention.spendNotices(wallet, spike: true, budget: true, snoozedUntil: snoozed, now: now).map { $0.id.components(separatedBy: ":").prefix(2).joined(separator: ":") }
        }
        XCTAssertTrue(ids(wallet(9)).isEmpty, "A relaunch already past a line does not notify again")
        XCTAssertEqual(ids(wallet(11)), ["deepseek:budget"], "Exceeding is a new crossing")
        XCTAssertTrue(ids(wallet(12)).isEmpty)
        XCTAssertEqual(ids(wallet(1, recent: true)), ["deepseek:spike"])
        XCTAssertTrue(ids(wallet(1, recent: true)).isEmpty, "A spike that continues does not repeat")
        XCTAssertTrue(ids(wallet(1)).isEmpty)
        XCTAssertTrue(ids(wallet(1, recent: true), snoozed: now.addingTimeInterval(60)).isEmpty, "Not for an hour quiets a new spike")
        let spike = attention.spendNotices(wallet(1), spike: true, budget: true, snoozedUntil: .distantPast, now: now)
        XCTAssertTrue(spike.isEmpty)
        let notice = attention.spendNotices(wallet(1, recent: true), spike: true, budget: true, snoozedUntil: .distantPast, now: now).first
        XCTAssertEqual(notice?.category, DeepSeekBalanceAttention.spikeCategory, "A spike offers Open Harness and Not for an Hour")
    }

    func testRingsFollowTheModulesAndDeepSeekJoinsOnlyWithABudget() async throws {
        let (defaults, _) = try defaults(ProviderModules(codexMode: .enabled, claudeMode: .disabled, deepseekMode: .enabled))
        let model = IslandModel(demo: true, defaults: defaults, installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        model.deepseekUsage = DeepSeekLocalUsage(); model.deepseekHistory = DeepSeekBalanceHistory()
        XCTAssertEqual(model.compactRingProviders, [.codex], "Without a budget DeepSeek has no ring")
        XCTAssertEqual(model.compactQuotaText(.deepseek), "¥86", "Its value is then the balance")
        defaults.set(15.0, forKey: IslandModel.deepseekDailyBudgetKey)
        XCTAssertEqual(model.compactRingProviders, [.codex], "An amount alone does nothing in balance mode")
        XCTAssertFalse(model.deepseekShowsBudgetDial)
        defaults.set("budget", forKey: IslandModel.deepseekModeKey)
        XCTAssertEqual(model.compactRingProviders, [.codex, .deepseek], "DeepSeek takes the free inner ring")
        XCTAssertEqual(model.compactQuotaText(.deepseek), "¥15", "The value follows the ring: the budget left")
        XCTAssertTrue(model.deepseekShowsBudgetDial, "Budget mode shows the budget dial")
        defaults.set("deepseek", forKey: QuotaRingSlot.outer.defaultsKey)
        defaults.set("none", forKey: QuotaRingSlot.inner.defaultsKey)
        XCTAssertEqual(model.compactRingProviders, [.deepseek])
        defaults.set("claude", forKey: QuotaRingSlot.inner.defaultsKey)
        XCTAssertEqual(model.compactRingProviders, [.deepseek], "A disabled module's ring is skipped")
        XCTAssertFalse(model.compactGaugeShowsPriceClock)
        defaults.removeObject(forKey: QuotaRingSlot.outer.defaultsKey); defaults.removeObject(forKey: QuotaRingSlot.inner.defaultsKey)
        var modules = ProviderModules.load(from: defaults)
        modules.setMode(.disabled, for: .codex); modules.save(to: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(model.enabledProviders, [.deepseek])
        XCTAssertTrue(model.compactRingProviders.isEmpty, "DeepSeek alone keeps the price clock until a ring is chosen")
        XCTAssertTrue(model.compactGaugeShowsPriceClock)
        XCTAssertEqual(model.compactQuotaText(.deepseek), "¥86")
        await model.shutdown()
    }

    func testBudgetModeFillsInSuggestionsOnceAndKeepsAmountsWhenSwitchedOff() throws {
        let (defaults, _) = try defaults(ProviderModules(codexMode: .disabled, claudeMode: .disabled, deepseekMode: .enabled))
        var settings = DeepSeekBudgetSettings.load(from: defaults)
        XCTAssertFalse(settings.budgetMode, "Balance mode is the default")
        XCTAssertTrue(settings.isEmpty)
        let suggestion = DeepSeekBudgets(daily: 20, weekly: 120)
        settings.setBudgetMode(true, suggestion: suggestion)
        XCTAssertEqual(settings.active, suggestion, "Switching to budgets fills in the suggestion")
        settings.daily = 30; settings.weekly = nil
        settings.setBudgetMode(false, suggestion: suggestion)
        XCTAssertTrue(settings.isEmpty, "Balance mode counts no budget")
        settings.save(to: defaults)
        settings = DeepSeekBudgetSettings.load(from: defaults)
        XCTAssertEqual(settings.daily, 30, "The amounts are kept for the next switch")
        settings.setBudgetMode(true, suggestion: suggestion)
        XCTAssertEqual(settings.active, DeepSeekBudgets(daily: 30), "An amount already chosen is not replaced, nor a cleared one refilled")
    }

    func testEmptyAmountsFollowTheRulesAndOnlyAChosenLowLineCarriesOver() throws {
        let (defaults, _) = try defaults(ProviderModules(codexMode: .disabled, claudeMode: .disabled, deepseekMode: .enabled))
        XCTAssertNil(IslandModel.deepseekLowLine(in: defaults))
        defaults.set(10.0, forKey: IslandModel.legacyDeepSeekLowBalanceKey)
        XCTAssertNil(IslandModel.deepseekLowLine(in: defaults), "4.0 stored its ¥10 default whenever Settings changed")
        defaults.set(1.0, forKey: IslandModel.legacyDeepSeekLowBalanceKey)
        XCTAssertEqual(IslandModel.deepseekLowLine(in: defaults), 1, "Another 4.0 amount was chosen and carries over")
        defaults.set(25.0, forKey: IslandModel.deepseekLowBalanceKey)
        XCTAssertEqual(IslandModel.deepseekLowLine(in: defaults), 25, "A line saved by this version wins")
        defaults.set(0.0, forKey: IslandModel.deepseekLowBalanceKey)
        XCTAssertNil(IslandModel.deepseekLowLine(in: defaults), "Zero follows the rules rather than turning the reminder off")
        XCTAssertEqual(DeepSeekPanelStyle.load(from: defaults), .detailed)
    }

    private func balanceModel(source: DeepSeekBalanceSource) throws -> (IslandModel, UserDefaults) {
        let (defaults, _) = try defaults(ProviderModules(codexMode: .disabled, claudeMode: .disabled, deepseekMode: .enabled))
        defaults.set(source.rawValue, forKey: DeepSeekBalanceSource.defaultsKey)
        let model = IslandModel(defaults: defaults, installation: .init(codexInstalled: false, claudeInstalled: false))
        model.deepseekBalanceReads.apiKey = { "synthetic-balance-test-key" }
        return (model, defaults)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "The controlled balance read did not start or settle")
    }

    func testSourceSwitchRejectsCancelledSuccessAndFailureBeforeAndAfterReplacement() async throws {
        for staleSucceeds in [true, false] {
            for staleReturnsFirst in [true, false] {
                let (model, defaults) = try balanceModel(source: .web)
                var web: CheckedContinuation<Result<DeepSeekBalance, DeepSeekBalanceError>, Never>?
                var api: CheckedContinuation<DeepSeekBalance, Never>?
                model.deepseekBalanceReads.web = { try await withCheckedContinuation { web = $0 }.get() }
                model.deepseekBalanceReads.api = { _ in await withCheckedContinuation { api = $0 } }
                model.refreshDeepSeekBalance(force: true)
                await waitUntil { web != nil }
                let obsolete = try XCTUnwrap(model.deepseekBalanceTask)
                defaults.set(DeepSeekBalanceSource.apiKey.rawValue, forKey: DeepSeekBalanceSource.defaultsKey)
                model.applySettings(sourceChanged: false)
                await waitUntil { api != nil }
                let replacement = try XCTUnwrap(model.deepseekBalanceTask)
                let stale: Result<DeepSeekBalance, DeepSeekBalanceError> = staleSucceeds
                    ? .success(.init(total: 1, capturedAt: Date(), source: .web)) : .failure(.signedOut)
                let fresh = DeepSeekBalance(total: 80, capturedAt: Date(), source: .apiKey)
                if staleReturnsFirst {
                    try XCTUnwrap(web).resume(returning: stale); await obsolete.value
                    XCTAssertTrue(model.deepseekRefreshing, "An obsolete read cannot release its replacement's slot")
                    XCTAssertNotNil(model.deepseekBalanceTask)
                    XCTAssertNil(model.deepseekBalance)
                    XCTAssertNil(model.deepseekBalanceError)
                    try XCTUnwrap(api).resume(returning: fresh); await replacement.value
                } else {
                    try XCTUnwrap(api).resume(returning: fresh); await replacement.value
                    try XCTUnwrap(web).resume(returning: stale); await obsolete.value
                }
                XCTAssertEqual(model.deepseekBalance, fresh)
                XCTAssertNil(model.deepseekBalanceError)
                XCTAssertFalse(model.deepseekRefreshing)
                XCTAssertEqual(model.deepseekFailureCount, 0)
                await model.shutdown()
            }
        }
    }

    func testAutomaticBillingChangeClearsOldConnectionErrorInBothDirections() async throws {
        for startsWithAccount in [true, false] {
            let (model, _) = try balanceModel(source: .automatic)
            var webReads = 0, apiReads = 0
            model.deepseekBalanceReads.web = {
                webReads += 1
                if startsWithAccount { throw DeepSeekBalanceError.signedOut }
                return .init(total: 120, capturedAt: Date(), source: .web)
            }
            model.deepseekBalanceReads.api = { _ in
                apiReads += 1
                if !startsWithAccount { throw DeepSeekBalanceError.invalidKey }
                return .init(total: 80, capturedAt: Date(), source: .apiKey)
            }
            let first = startsWithAccount ? "deepseek-account" : "deepseek-official"
            let second = startsWithAccount ? "deepseek-official" : "deepseek-account"
            model.receiveDeepSeekUpdate([], statuses: [:], requests: [], usage: .init(provider: first))
            model.refreshDeepSeekBalance(force: true)
            await model.deepseekBalanceTask?.value
            XCTAssertEqual(model.deepseekBalanceError, startsWithAccount ? .signedOut : .invalidKey)
            model.receiveDeepSeekUpdate([], statuses: [:], requests: [], usage: .init(provider: second))
            await waitUntil { model.deepseekBalance != nil }
            XCTAssertEqual(webReads, 1)
            XCTAssertEqual(apiReads, 1)
            XCTAssertEqual(model.deepseekBalance?.source, startsWithAccount ? .apiKey : .web)
            XCTAssertNil(model.deepseekBalanceError)
            XCTAssertEqual(model.deepseekFailureCount, 0)
            await model.shutdown()
        }
    }

    func testProfileChangeDuringSuspendedReadImmediatelyUsesItsNewBillingSource() async throws {
        let (model, defaults) = try balanceModel(source: .automatic)
        let home = URL(fileURLWithPath: try XCTUnwrap(defaults.string(forKey: "deepseekHome")))
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profiles/desktop/cordis.patch.yml")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "provider: deepseek-account\n".write(to: profile, atomically: true, encoding: .utf8)
        var web: CheckedContinuation<DeepSeekBalance, Never>?, apiReads = 0
        model.deepseekBalanceReads.web = { await withCheckedContinuation { web = $0 } }
        model.deepseekBalanceReads.api = { _ in
            apiReads += 1
            return .init(total: 80, capturedAt: Date(), source: .apiKey)
        }
        model.refreshDeepSeekBalance(force: true)
        await waitUntil { web != nil }
        let obsolete = try XCTUnwrap(model.deepseekBalanceTask)
        try "provider: deepseek-official\n".write(to: profile, atomically: true, encoding: .utf8)
        try XCTUnwrap(web).resume(returning: .init(total: 1, capturedAt: Date(), source: .web))
        await obsolete.value
        await waitUntil { model.deepseekBalance?.source == .apiKey }
        XCTAssertEqual(apiReads, 1)
        XCTAssertEqual(model.deepseekBalance?.total, 80)
        XCTAssertNil(model.deepseekBalanceError)
        await model.shutdown()
    }
}
