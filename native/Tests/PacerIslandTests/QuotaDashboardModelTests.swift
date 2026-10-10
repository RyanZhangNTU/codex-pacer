import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class QuotaDashboardModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture(_ initialPeriod: String? = nil) throws -> (IslandModel, UserDefaults) {
        let domain = "com.codexpacer.dashboard-model-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        ProviderModules(codexMode: .enabled, claudeMode: .enabled).save(to: defaults)
        if let initialPeriod { defaults.set(initialPeriod, forKey: "quotaDashboardPeriod") }
        let clock = now
        let model = IslandModel(demo: true, demoClock: { clock }, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        for provider in AgentProvider.allCases { model.selectProvider(provider); model.quota = nil }
        model.selectProvider(.codex)
        return (model, defaults)
    }
    private func window(_ id: String, minutes: Int?, used: Double? = 20, reset: Date? = nil) -> QuotaWindow {
        QuotaWindow(id: id, usedPercent: used, durationMinutes: minutes,
            resetsAt: reset ?? minutes.map { now.addingTimeInterval(Double($0) * 30) })
    }
    private func bucket(_ id: String, _ windows: [QuotaWindow]) -> QuotaBucket {
        QuotaBucket(id: id, name: id, plan: nil, windows: windows, credits: nil)
    }
    private func publish(_ snapshot: QuotaSnapshot?, for provider: AgentProvider, to model: IslandModel) {
        model.selectProvider(provider); model.quota = snapshot
    }
    private func snapshot(_ buckets: [QuotaBucket], at: Date? = nil) -> QuotaSnapshot {
        QuotaSnapshot(buckets: buckets, capturedAt: at ?? now, accountScope: "synthetic-scope", resetCredits: nil)
    }

    func testExactPeriodsUseOneSelectedServiceBucketAndIndependentProviderValues() throws {
        let (model, defaults) = try fixture()
        publish(snapshot([bucket("codex", [window("codex/five", minutes: 300), window("codex/week", minutes: 10080)]),
                          bucket("codex-review", [window("codex-review/week", minutes: 10080, used: 65), window("codex-review/eight", minutes: 480)])]), for: .codex, to: model)
        publish(snapshot([bucket("claude", [window("claude/five", minutes: 300, used: 40), window("claude/week", minutes: 10080)]),
                          bucket("claude/opus", [window("claude/opus/week", minutes: 10080)])]), for: .claude, to: model)
        defaults.set("codex-review/week", forKey: "quotaWindowID")
        XCTAssertNil(model.providerWindow(.codex, period: .fiveHour), "A selected service bucket cannot borrow another bucket's five-hour window")
        XCTAssertEqual(model.providerWindow(.codex, period: .weekly)?.id, "codex-review/week")
        XCTAssertEqual(model.dashboardQuota(provider: .codex, period: .fiveHour).availability, .missingPeriod)
        XCTAssertEqual(model.dashboardQuota(provider: .codex, period: .weekly).bucketName, "codex-review")
        XCTAssertEqual(model.providerWindow(.claude, period: .fiveHour)?.id, "claude/five")
        XCTAssertEqual(model.dashboardQuota(provider: .claude, period: .fiveHour).remainingQuotaPercent, 60)
        defaults.set("claude/opus/week", forKey: "claudeQuotaWindowID")
        XCTAssertEqual(model.dashboardQuota(provider: .claude, period: .fiveHour).availability, .missingPeriod, "Model-scoped weekly limits never imply an account plan")
        XCTAssertEqual(model.providerWindow(.claude, period: .weekly)?.id, "claude/opus/week")
        defaults.set("auto", forKey: "quotaWindowID")
        XCTAssertEqual(model.providerWindow(.codex, period: .fiveHour)?.id, "codex/five")
        XCTAssertEqual(model.dashboardQuota(provider: .codex, period: .fiveHour).remainingQuotaPercent, 80)
        XCTAssertNil(model.dashboardQuota(provider: .codex, period: .fiveHour).bucketName)
        XCTAssertEqual(model.selectedProvider, .claude, "Provider presentation reads do not change quota selection")
    }

    func testWeeklyOnlyProRequiresActualPrimaryBucketFreshUsageAndKnownFutureReset() throws {
        let (model, _) = try fixture()
        for provider in AgentProvider.allCases {
            let weekly = window(provider.rawValue + "/week", minutes: 10080)
            publish(snapshot([bucket(provider.rawValue, [weekly])]), for: provider, to: model)
            XCTAssertEqual(model.dashboardQuota(provider: provider, period: .fiveHour).availability, .proOnly)
            for candidate in [snapshot([]),
                snapshot([bucket(provider.rawValue, [window("unknown-usage", minutes: 10080, used: nil)])]),
                snapshot([bucket(provider.rawValue, [QuotaWindow(id: "unknown-reset", usedPercent: 20, durationMinutes: 10080, resetsAt: nil)])]),
                snapshot([bucket(provider.rawValue, [window("expired", minutes: 10080, reset: now)])]),
                snapshot([bucket(provider.rawValue, [weekly, window("untyped", minutes: nil)])]),
                snapshot([bucket(provider.rawValue + "/scoped", [weekly])])] {
                publish(candidate, for: provider, to: model)
                XCTAssertNotEqual(model.dashboardQuota(provider: provider, period: .fiveHour).availability, .proOnly)
            }
            publish(nil, for: provider, to: model)
            XCTAssertEqual(model.dashboardQuota(provider: provider, period: .fiveHour).availability, .unavailable)
            publish(snapshot([bucket(provider.rawValue, [weekly])], at: now.addingTimeInterval(-301)), for: provider, to: model)
            XCTAssertEqual(model.dashboardQuota(provider: provider, period: .fiveHour).availability, .stale)
            publish(snapshot([bucket(provider.rawValue, [weekly])]), for: provider, to: model)
            model.errorMessage = "Synthetic service failure"
            XCTAssertEqual(model.dashboardQuota(provider: provider, period: .fiveHour).availability, .stale)
            model.errorMessage = nil
        }
    }

    func testRemainingRingsPreserveUnknownFieldsBoundsAndExpiredStaleData() throws {
        let (model, _) = try fixture()
        let five = window("codex/five", minutes: 300, reset: now.addingTimeInterval(9000))
        publish(snapshot([bucket("codex", [five])]), for: .codex, to: model)
        var data = model.dashboardQuota(provider: .codex, period: .fiveHour)
        XCTAssertEqual(data.remainingQuotaPercent, 80); XCTAssertEqual(data.remainingTimePercent, 50)
        XCTAssertEqual(data.availability, .available)
        for (used, expected) in [(-20.0, 100.0), (130.0, 0.0)] {
            publish(snapshot([bucket("codex", [window("codex/five", minutes: 300, used: used, reset: now.addingTimeInterval(36000))])]), for: .codex, to: model)
            data = model.dashboardQuota(provider: .codex, period: .fiveHour)
            XCTAssertEqual(data.remainingQuotaPercent, expected); XCTAssertEqual(data.remainingTimePercent, 100)
        }
        publish(snapshot([bucket("codex", [QuotaWindow(id: "codex/five", usedPercent: .nan, durationMinutes: 300, resetsAt: nil)])]), for: .codex, to: model)
        data = model.dashboardQuota(provider: .codex, period: .fiveHour)
        XCTAssertNil(data.remainingQuotaPercent); XCTAssertNil(data.remainingTimePercent)
        XCTAssertEqual(data.availability, .available, "Unknown components stay unmeasured rather than inferring PRO")
        publish(snapshot([bucket("codex", [window("codex/five", minutes: 300, reset: now)])]), for: .codex, to: model)
        data = model.dashboardQuota(provider: .codex, period: .fiveHour)
        XCTAssertEqual(data.availability, .stale); XCTAssertEqual(data.remainingQuotaPercent, 80)
        XCTAssertNil(data.remainingTimePercent)
        XCTAssertEqual(data.freshnessText, L10n.text("quota.expired"))
    }

    func testSharedPeriodPersistsOnlyExactChoicesWithoutChangingCollapsedWindowOrProvider() throws {
        let (model, defaults) = try fixture("unrecognized")
        XCTAssertEqual(model.dashboardPeriod, .weekly)
        XCTAssertEqual(defaults.string(forKey: "quotaDashboardPeriod"), "unrecognized", "Loading a malformed preference is read-only")
        defaults.set("codex/custom", forKey: "quotaWindowID")
        defaults.set("claude/custom", forKey: "claudeQuotaWindowID")
        let provider = model.selectedProvider
        model.selectDashboardPeriod(.fiveHour)
        XCTAssertEqual(defaults.string(forKey: "quotaDashboardPeriod"), "5h")
        let rebuilt = IslandModel(demo: true, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false))
        XCTAssertEqual(rebuilt.dashboardPeriod, .fiveHour)
        rebuilt.selectDashboardPeriod(.weekly)
        XCTAssertEqual(defaults.string(forKey: "quotaDashboardPeriod"), "7d")
        XCTAssertEqual(model.selectedProvider, provider)
        XCTAssertEqual(defaults.string(forKey: "quotaWindowID"), "codex/custom")
        XCTAssertEqual(defaults.string(forKey: "claudeQuotaWindowID"), "claude/custom")
    }

    func testDashboardFallbackHeightIgnoresMovedWindowDetailsAndKeepsMeasuredGeometry() throws {
        let (model, defaults) = try fixture()
        publish(snapshot([bucket("codex", [window("codex/week", minutes: 10080)])]), for: .codex, to: model)
        let before = model.panelContentHeight
        publish(snapshot([bucket("codex", (0..<12).map { window("codex/\($0)", minutes: 480) })]), for: .codex, to: model)
        XCTAssertEqual(model.panelContentHeight, before, "Details moved to Settings cannot enlarge the two-ring dashboard fallback")
        ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertGreaterThan(model.panelContentHeight, before, "The Codex-only legacy exception reserves room for its actual bars")
        XCTAssertLessThanOrEqual(model.panelContentHeight, 640, "Many legacy service windows remain bounded by the existing panel limit")
        model.updateMeasuredContentHeight(511.2)
        XCTAssertEqual(model.panelContentHeight, 512)
        publish(snapshot([bucket("codex", [])]), for: .codex, to: model)
        XCTAssertEqual(model.panelContentHeight, 512, "The existing real content measurement still takes precedence")
    }

    func testSettingsHistoryWarningsFreshnessAndServiceDetailsStayProviderIndependent() throws {
        let (model, defaults) = try fixture()
        let credit = CreditBalance(hasCredits: true, unlimited: false, balance: "12.50")
        let reset = QuotaResetSummary(availableCount: 2, credits: [QuotaResetCredit(id: "synthetic-credit", status: "available", expiresAt: now.addingTimeInterval(86400), grantedAt: now)])
        let codex = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: nil, plan: nil,
            windows: [window("codex/week", minutes: 10080), window("codex/eight", minutes: 480)], credits: credit),
            bucket("codex/review", [window("codex/review/week", minutes: 10080, used: 50)])],
            capturedAt: now.addingTimeInterval(-400), accountScope: "synthetic-codex", resetCredits: reset)
        let claude = QuotaSnapshot(buckets: [bucket("claude", [window("claude/week", minutes: 10080, used: 40)])],
            capturedAt: now, accountScope: "synthetic-claude", resetCredits: nil)
        for (provider, value, warning) in [(AgentProvider.codex, codex, "Synthetic Codex warning"), (.claude, claude, "Synthetic Claude warning")] {
            publish(value, for: provider, to: model)
            var history = QuotaCycleHistory(); history.record(value)
            model.history = history; model.historyWarning = warning
        }
        defaults.set("codex/review/week", forKey: "quotaWindowID")
        XCTAssertEqual(model.providerCurrentCycle(.codex)?.id, "codex/review/week")
        XCTAssertEqual(model.providerCurrentCycle(.claude)?.id, "claude/week")
        XCTAssertEqual(model.providerHistoryWarning(.codex), "Synthetic Codex warning")
        XCTAssertEqual(model.providerHistoryWarning(.claude), "Synthetic Claude warning")
        XCTAssertTrue(model.providerQuotaIsStale(.codex, period: .weekly)); XCTAssertFalse(model.providerQuotaIsStale(.claude, period: .weekly))
        XCTAssertNotEqual(model.providerFreshnessText(.codex, period: .weekly), model.providerFreshnessText(.claude, period: .weekly))
        XCTAssertEqual(model.providerQuota(.codex)?.credits, credit)
        XCTAssertEqual(model.providerQuota(.codex)?.resetCredits, reset)
        XCTAssertEqual(model.providerQuota(.codex)?.windows.first(where: { $0.id == "codex/eight" })?.durationMinutes, 480)
        XCTAssertEqual(model.providerSourceText(.codex), L10n.text("quota.source_codex"))
        XCTAssertNil(model.providerSourceText(.claude), "A synthetic snapshot without source provenance cannot invent it")
        XCTAssertEqual(model.selectedProvider, .claude)
    }
}
