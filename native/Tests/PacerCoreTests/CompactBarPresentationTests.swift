import Foundation
import XCTest
@testable import PacerCore

final class CompactBarPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func quota(captured: Date? = nil) throws -> QuotaSnapshot {
        let wire: [String: Any] = ["rateLimitsByLimitId": [
            "codex": ["primary": ["usedPercent": 20, "windowDurationMins": 300, "resetsAt": now.addingTimeInterval(9000).timeIntervalSince1970],
                      "secondary": ["usedPercent": 70, "windowDurationMins": 10080, "resetsAt": now.addingTimeInterval(151200).timeIntervalSince1970]],
            "other": ["secondary": ["usedPercent": 1, "windowDurationMins": 10080, "resetsAt": now.addingTimeInterval(151200).timeIntervalSince1970]]
        ]]
        return try .decode(JSONSerialization.data(withJSONObject: wire), capturedAt: captured ?? now)
    }
    private func context(snapshot: QuotaSnapshot? = nil, failed: Bool = false) -> CompactBarContext {
        .init(activities: [], requests: [], completions: [], sources: [.init(provider: .codex, snapshot: snapshot, failed: failed)], now: now)
    }
    private func component(_ id: String, in value: CompactBarPresentation.Output) throws -> CompactBarPresentation.Component {
        try XCTUnwrap(value.components.first { $0.id == id })
    }
    func testTypedLayoutUsesTheSameVisibilityAndRingRulesWithoutSerializedInputs() throws {
        let snapshot = try quota()
        let layout = CompactIslandLayout(leading: [.quotaGauge, .quota], trailing: [.timeRemaining])
        let input = context(snapshot: snapshot)
        let typed = CompactBarPresentation.Request(providers: [.codex], context: input)
        let serialized = CompactBarPresentation.Request(layout: String(decoding: try JSONEncoder().encode(layout), as: UTF8.self),
            providers: [.codex], context: input)
        XCTAssertEqual(CompactBarPresentation.project(typed, layout: layout), CompactBarPresentation.project(serialized))
    }
    func testMigrationAndKeyboardCommandsKeepUnavailableComponentsInTheirSavedLane() throws {
        let legacy = #"{"version":6,"leading":["quotaGauge","firstOutput","tps"],"trailing":["sshWarning"]}"#
        var request = CompactBarPresentation.Request(layout: legacy, language: "en", providers: [])
        let initial = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(initial.editorLeading, ["firstOutput", "tps"])
        XCTAssertEqual(initial.warnings, ["ssh", "lowBalance", "spendSpike", "budget"])
        request.action = .init(kind: "shift", component: "tps", offset: -1)
        let moved = try XCTUnwrap(CompactBarPresentation.project(request))
        let saved = try JSONDecoder().decode(CompactIslandLayout.self, from: Data(moved.layoutJSON.utf8))
        XCTAssertEqual(saved.leading, [.quotaGauge, .tps, .firstOutput])
        request.layout = moved.layoutJSON; request.providers = [.codex]; request.action = nil
        XCTAssertEqual(CompactBarPresentation.project(request)?.editorLeading, ["quotaGauge", "tps", "firstOutput"])
        request.action = .init(kind: "move", component: "tps", lane: "trailing", before: "warnings")
        XCTAssertEqual(CompactBarPresentation.project(request)?.editorTrailing, ["tps", "warnings"])
    }
    func testWarningSwitchRestoresTheMissingSlotWithOnlyTheChosenKind() throws {
        let hidden = CompactIslandLayout(leading: [.activity], trailing: [.quota])
        var request = CompactBarPresentation.Request(layout: String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self),
            warnings: ["fiveHour", "ssh"], language: "en", providers: [.codex])
        request.action = .init(kind: "warning", component: "quotaDelay")
        let shown = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(shown.editorTrailing, ["warnings", "quota"]); XCTAssertEqual(shown.warnings, ["quotaDelay"])
        request.layout = shown.layoutJSON; request.warnings = shown.warnings; request.action = .init(kind: "warningOff", component: "quotaDelay")
        let off = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertTrue(off.warnings.isEmpty); XCTAssertEqual(off.editorTrailing, ["warnings", "quota"])
        request.action = .init(kind: "restore")
        XCTAssertEqual(CompactBarPresentation.project(request)?.warnings, CompactIslandLayout.Warning.allCases.map(\.rawValue))
    }
    func testSelectedWindowAndMetricUseTheProvidersOwnBucketAndRetainFailedReadings() throws {
        let snapshot = try quota()
        var request = CompactBarPresentation.Request(language: "en", providers: [.codex], context: context(snapshot: snapshot))
        var value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(try component("quota", in: value).entries.first?.text, "30%")
        XCTAssertEqual(value.rings.first?.remaining, 30)
        request.options.metric = "pace"
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(try component("quota", in: value).entries.first?.text, "120%")
        XCTAssertEqual(try component("timeRemaining", in: value).entries.first?.text, "25%")
        XCTAssertTrue(try component("quotaGauge", in: value).accessibility.contains("30%"), "Ring help always describes remaining quota")
        let legacy = try XCTUnwrap(snapshot.windows.first { $0.durationMinutes == 300 }).id
        request.options.codexWindow = legacy
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(value.windows.first?.selection, "5h"); XCTAssertEqual(try component("quota", in: value).entries.first?.text, "160%")
        request.context = context(snapshot: snapshot, failed: true)
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(try component("quota", in: value).entries.first?.text, "—")
        XCTAssertNil(value.rings.first?.remaining, "The collapsed ring hides the value after a failed refresh")
        XCTAssertFalse(try XCTUnwrap(value.rings.first).dimmed)
        request.options.metric = "remaining"
        XCTAssertEqual(try component("quota", in: XCTUnwrap(CompactBarPresentation.project(request))).entries.first?.text, "80%")
        request.options.metric = "pace"; request.context = context(snapshot: try quota(captured: now.addingTimeInterval(-301)))
        XCTAssertEqual(try component("quota", in: XCTUnwrap(CompactBarPresentation.project(request))).entries.first?.text, "—")
        request.context = context(failed: true)
        XCTAssertNil(CompactBarPresentation.project(request)?.rings.first?.remaining, "A failure without a cached reading has no ring value")
    }
    func testWalletRingsRequireAnExplicitSlotWhenAloneAndHidingTheGaugeRestoresTheBalance() throws {
        let balance = DeepSeekBalance(total: 86.4, granted: nil, tokenEstimation: nil, capturedAt: now, source: .web)
        let wallet = DeepSeekWallet(balance: balance, connected: true, ledger: .init(), now: now, budgets: .init(daily: 20))
        let input = CompactBarContext(activities: [], requests: [], completions: [], sources: [], wallet: .init(wallet, preferred: .day), now: now)
        var request = CompactBarPresentation.Request(language: "en", providers: [.deepseek], context: input)
        var value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertTrue(value.gaugeClock); XCTAssertTrue(value.rings.isEmpty)
        XCTAssertEqual(try component("quota", in: value).entries.first?.text, input.wallet?.balance)
        request.options.rings = ["deepseek", "deepseek"]
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertFalse(value.gaugeClock); XCTAssertEqual(value.rings.count, 1)
        XCTAssertEqual(try component("quota", in: value).entries.first?.text, input.wallet?.budget)
        request.layout = value.layoutJSON; request.action = .init(kind: "hide", component: "quotaGauge")
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertEqual(try component("quota", in: value).entries.first?.text, input.wallet?.balance)
        request.layout = value.layoutJSON; request.action = .init(kind: "show", component: "priceClock"); request.options.rings = ["none", "none"]
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertFalse(value.gaugeClock); XCTAssertTrue(value.trailing.contains("priceClock"))
        XCTAssertFalse(try component("timeRemaining", in: value).available)
    }
    func testStatusRateAndFirstOutputHaveTheNativeVisibilityAndAccessibleValues() throws {
        let tasks = DemoScenario.tasks(stage: .responding, at: now)
        let pending = PendingAttentionRequest(id: "approval", threadID: "00000000-0000-4000-8000-000000000001", sourceHostID: nil,
            sourceName: nil, kind: .approval, detectedAt: now)
        let input = CompactBarContext(activities: tasks, requests: [pending], completions: [], sources: [], firstOutput: 1.25, now: now)
        XCTAssertNotNil(input.rate)
        let layout = CompactIslandLayout(leading: [.activity, .status, .tps, .firstOutput])
        var request = CompactBarPresentation.Request(layout: String(decoding: try JSONEncoder().encode(layout), as: UTF8.self),
            language: "en", providers: [.codex], context: input, attached: true)
        var value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertFalse(value.leading.contains("tps")); XCTAssertEqual(try component("firstOutput", in: value).text, "1.25 s")
        XCTAssertTrue(try component("firstOutput", in: value).accessibility.contains("1.25 s"))
        request.strip = true; request.attached = false
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertTrue(value.leading.contains("tps")); XCTAssertFalse(value.leading.contains("status"))
        XCTAssertEqual(try component("firstOutput", in: value).stripText, "1.2")
        request.strip = false; request.attached = true; request.language = "zh-Hans"
        value = try XCTUnwrap(CompactBarPresentation.project(request))
        XCTAssertTrue(value.leading.contains("tps")); XCTAssertNotEqual(try component("status", in: value).text, "Approval needed")
    }
    func testContextOmitsAccountCreditsAndTaskIdentityWithoutMutatingTheSource() throws {
        var snapshot = try XCTUnwrap(DemoScenario.quota(at: now).last)
        snapshot.accountScope = "PRIVATE-ACCOUNT"
        var task = try XCTUnwrap(DemoScenario.tasks(stage: .tool, at: now).first); task.project = "PRIVATE-PROJECT"
        let input = CompactBarContext(activities: [task], requests: [], completions: [], sources: [.init(provider: .codex, snapshot: snapshot, failed: false)], now: now)
        let text = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE-")); XCTAssertFalse(text.contains("demo-reset")); XCTAssertFalse(text.contains("accountScope"))
        XCTAssertNil(input.sources.first?.snapshot?.credits); XCTAssertNil(input.sources.first?.snapshot?.resetCredits)
        XCTAssertNotNil(snapshot.credits); XCTAssertNotNil(snapshot.resetCredits); XCTAssertEqual(snapshot.accountScope, "PRIVATE-ACCOUNT")
    }
    func testMalformedBoundedChoicesAreRejectedAndAnUnreadableSavedLayoutUsesDefaults() throws {
        var request = CompactBarPresentation.Request(layout: "broken saved JSON", language: "en", providers: [])
        XCTAssertEqual(CompactBarPresentation.project(request)?.editorLeading, ["activity", "tps"])
        request.options.rings = ["foreign", "none"]; XCTAssertNil(CompactBarPresentation.project(request))
        request.options = .init(); request.options.codexWindow = "bad\nwindow"; XCTAssertNil(CompactBarPresentation.project(request))
        request.options = .init(); request.action = .init(kind: "move", component: "activity", lane: "center"); XCTAssertNil(CompactBarPresentation.project(request))
        request.action = nil; request.layout = String(repeating: "x", count: 8193); XCTAssertNil(CompactBarPresentation.project(request))
        XCTAssertNil(CompactBarPresentation.project(Data("{}".utf8)))
        XCTAssertNil(CompactBarPresentation.project(Data(repeating: 32, count: 262145)))
    }
}
