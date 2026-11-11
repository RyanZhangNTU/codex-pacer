import Foundation
import XCTest
@testable import PacerCore

final class CompactComponentOptionsTests: XCTestCase {
    private typealias P = CompactBarPresentation
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ provider: AgentProvider, weeklyUsed: Double, weeklyReset: TimeInterval,
                          fiveHourUsed: Double? = nil, stale: Bool = false) -> QuotaSnapshot {
        var windows = [QuotaWindow(id: "7d", usedPercent: weeklyUsed, durationMinutes: 10080, resetsAt: now.addingTimeInterval(weeklyReset))]
        if let fiveHourUsed { windows.insert(.init(id: "5h", usedPercent: fiveHourUsed, durationMinutes: 300, resetsAt: now.addingTimeInterval(9000)), at: 0) }
        return .init(buckets: [.init(id: provider.rawValue, name: nil, plan: nil, windows: windows, credits: nil)],
            capturedAt: now.addingTimeInterval(stale ? -601 : 0), resetCredits: nil)
    }
    /// Codex: 30% left with a quarter of the week to go (pace 120, ahead).
    /// Claude: 10% left with half the week to go (pace 20, fast and low).
    private func quotaContext(claudeUsed: Double = 90) -> CompactBarContext {
        .init(activities: [], requests: [], completions: [], sources: [
            .init(provider: .codex, snapshot: snapshot(.codex, weeklyUsed: 70, weeklyReset: 151_200, fiveHourUsed: 20), failed: false),
            .init(provider: .claude, snapshot: snapshot(.claude, weeklyUsed: claudeUsed, weeklyReset: 302_400), failed: false)
        ], now: now)
    }
    private func project(_ options: CompactComponentOptions = .init(), metric: P.Metric = .remaining, context: CompactBarContext? = nil,
                         layout: CompactIslandLayout? = nil, strip: Bool = false, size: String? = nil) throws -> P.Output {
        var request = P.Request(language: "en", providers: [.codex, .claude], context: context ?? quotaContext(), strip: strip,
            componentOptions: options.json, size: size)
        request.options.metric = metric
        if let layout { request.layout = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self) }
        return try XCTUnwrap(P.project(request))
    }
    private func component(_ id: String, in value: P.Output) throws -> P.Component {
        try XCTUnwrap(value.components.first { $0.id == id })
    }

    func testEveryChoiceFallsBackOnItsOwnAndSavesSortedJSON() throws {
        let defaults = CompactComponentOptions()
        XCTAssertEqual(CompactComponentOptions.decode(nil), defaults)
        XCTAssertEqual(CompactComponentOptions.decode("not json"), defaults)
        XCTAssertEqual(CompactComponentOptions.decode(String(repeating: " ", count: CompactComponentOptions.byteLimit + 1)), defaults)
        let mixed = CompactComponentOptions.decode(#"{"version":7,"multiRing":"future","statusShow":"count","warningLimit":99,"paceTick":"yes","ringLayout":"split"}"#)
        XCTAssertEqual(mixed.multiRing, .service); XCTAssertEqual(mixed.statusShow, .count)
        XCTAssertEqual(mixed.warningLimit, 2); XCTAssertTrue(mixed.paceTick); XCTAssertEqual(mixed.ringLayout, .split)
        XCTAssertEqual(CompactComponentOptions.decode(#"{"warningLimit":0}"#).warningLimit, 0)
        XCTAssertTrue(defaults.ringDim, "The ring the alternating value is not naming dims by default")
        var chosen = defaults; chosen.multiRing = .segments; chosen.ringDim = false; chosen.warningStyle = .dot
        XCTAssertEqual(CompactComponentOptions.decode(chosen.json), chosen)
        XCTAssertTrue(chosen.json.hasPrefix(#"{"clockShow":"always","endMark":true"#))
        XCTAssertTrue(chosen.json.contains(#""version":1"#))
    }

    func testOptionsAndSizeAreOptionalOnTheWireAndOnlyOversizedTextRejects() throws {
        let value = try project(size: "large")
        XCTAssertEqual(value.metrics?.height, 42); XCTAssertEqual(value.metrics?.badge, 26); XCTAssertEqual(value.componentOptions, .init())
        XCTAssertEqual(try project(size: "huge").metrics, .standard)
        XCTAssertEqual(CompactBarMetrics.standard.height, 36); XCTAssertEqual(CompactBarMetrics.standard.value, 13)
        XCTAssertEqual(CompactBarSize.small.metrics.value, 11.5); XCTAssertEqual(CompactBarSize.extraLarge.metrics.stripWidth, 43)
        var request = P.Request(language: "en", providers: [.codex])
        let legacy = try XCTUnwrap(P.project(request))
        XCTAssertEqual(legacy.metrics, .standard); XCTAssertEqual(legacy.singleTaskPercent, false)
        request.componentOptions = String(repeating: "x", count: CompactComponentOptions.byteLimit + 1)
        XCTAssertNil(P.project(request))
        request.componentOptions = "{}"; request.size = String(repeating: "x", count: 65)
        XCTAssertNil(P.project(request))
        request.size = nil; request.options.singleTask = .percent
        XCTAssertEqual(P.project(request)?.singleTaskPercent, true)
        XCTAssertEqual(P.project(request)?.singleTaskCount, false)
    }

    func testQuotaValuesRotatePairOrShowTheLowestAndPaceStaysAPercent() throws {
        let layout = CompactIslandLayout(leading: [.quota], trailing: [])
        let rotating = try component("quota", in: project(layout: layout))
        XCTAssertEqual(rotating.entries.map(\.text), ["30%", "10%"])
        XCTAssertEqual(rotating.entries.map(\.low), [nil, true])
        var options = CompactComponentOptions(); options.quotaMultiple = .lowest
        XCTAssertEqual(try component("quota", in: project(options, layout: layout)).entries.map(\.provider), [.claude])
        options.lowColor = false
        XCTAssertEqual(try component("quota", in: project(options, layout: layout)).entries.first?.low, nil)
        // An old saved verdict choice is ignored: pace is always a percent.
        let legacy = CompactComponentOptions.decode(#"{"paceStyle":"verdict","quotaMultiple":"pair"}"#)
        XCTAssertEqual(legacy.quotaMultiple, .pair); XCTAssertFalse(legacy.json.contains("paceStyle"))
        XCTAssertEqual(try component("quota", in: project(metric: .pace, layout: layout, strip: true)).entries.map(\.stripText), ["120", "20"])
        let percent = try component("quota", in: project(metric: .pace, layout: layout))
        XCTAssertEqual(percent.entries.map(\.text), ["120%", "20%"]); XCTAssertEqual(percent.stripUnit, "%")
        // A pace has no low color: only remaining quota runs low.
        XCTAssertEqual(percent.entries.compactMap(\.low), [])
    }

    func testTimeLeftCanCountDownAndRingsCarryPaceLowAndExhaustedStates() throws {
        let layout = CompactIslandLayout(leading: [.quotaGauge], trailing: [.timeRemaining])
        var options = CompactComponentOptions(); options.timeStyle = .countdown
        let countdown = try component("timeRemaining", in: project(options, layout: layout))
        XCTAssertEqual(countdown.entries.first?.text, "1d18h"); XCTAssertEqual(countdown.entries.first?.stripText, "42h")
        XCTAssertNil(countdown.stripUnit)
        XCTAssertEqual(try component("timeRemaining", in: project(layout: layout)).entries.first?.text, "25%")
        let rings = try project(layout: layout).rings
        XCTAssertEqual(rings.map(\.provider), [.codex, .claude])
        XCTAssertEqual(try XCTUnwrap(rings[0].time), 0.25, accuracy: 0.0001); XCTAssertEqual(try XCTUnwrap(rings[1].time), 0.5, accuracy: 0.0001)
        XCTAssertEqual(rings.map(\.low), [nil, true]); XCTAssertEqual(rings.map(\.exhausted), [nil, nil])
        let empty = try project(context: quotaContext(claudeUsed: 100), layout: layout).rings[1]
        XCTAssertEqual(empty.exhausted, true); XCTAssertNil(empty.low)
        options = .init(); options.paceTick = false; options.lowColor = false
        XCTAssertEqual(try project(options, layout: layout).rings.compactMap(\.time), [])
        XCTAssertEqual(try project(options, layout: layout).rings.compactMap(\.low), [])
        options = .init(); options.ringLayout = .split
        let split = try project(options, layout: layout).rings
        XCTAssertEqual(split.map(\.provider), [.codex, .codex]); XCTAssertEqual(split.map(\.window), ["5h", "7d"])
        XCTAssertEqual(split.map(\.remaining), [80, 30])
    }

    func testStatusRateFirstOutputAndClockFollowTheirChoices() throws {
        let tasks = DemoScenario.tasks(stage: .responding, at: now)
        let pending = PendingAttentionRequest(id: "approval", threadID: "00000000-0000-4000-8000-000000000001", sourceHostID: nil,
            sourceName: nil, kind: .approval, detectedAt: now)
        let input = CompactBarContext(activities: tasks, requests: [pending], completions: [], sources: [], firstOutput: 1.25,
            firstOutputs: [3, 1, 2], now: now)
        let rate = try XCTUnwrap(input.rate), measured = try XCTUnwrap(input.measuredTasks)
        XCTAssertGreaterThan(measured, 0)
        let layout = CompactIslandLayout(leading: [.activity, .status, .tps, .firstOutput])
        var options = CompactComponentOptions()
        var value = try project(options, context: input, layout: layout)
        let urgent = try component("status", in: value)
        XCTAssertEqual(urgent.tone, "attention"); XCTAssertEqual(urgent.maxWidth, 108)
        XCTAssertEqual(try component("tps", in: value).text, String(format: "%.0f", rate))
        XCTAssertEqual(try component("firstOutput", in: value).text, "1.25")
        options.statusShow = .stage; options.statusWidth = .long; options.rateMeasure = .average; options.firstOutput = .median
        value = try project(options, context: input, layout: layout, size: "small")
        let stage = try component("status", in: value)
        XCTAssertNil(stage.tone); XCTAssertNotEqual(stage.text, urgent.text); XCTAssertEqual(stage.maxWidth, (160 * 32.0 / 36).rounded())
        let average = try component("tps", in: value)
        XCTAssertEqual(average.text, String(format: "%.0f", rate / Double(measured))); XCTAssertEqual(average.accessibility, (average.text ?? "") + " t/s")
        XCTAssertEqual(try component("firstOutput", in: value).text, "2.00")
        options = .init(); options.statusShow = .count
        let counted = try component("status", in: project(options, context: input, layout: layout))
        if input.activeCount > 1 { XCTAssertTrue(counted.text?.hasSuffix(" · " + (urgent.text ?? "")) == true) }
        else { XCTAssertEqual(counted.text, urgent.text) }

        let wallet = DeepSeekWallet(balance: .init(total: 5, capturedAt: now, source: .web), connected: true, ledger: .init(), now: now)
        let deepseek = CompactBarContext(activities: [], requests: [], completions: [], sources: [],
            wallet: .init(wallet, preferred: .day), now: now)
        var request = P.Request(language: "en", providers: [.deepseek], context: deepseek)
        request.layout = String(decoding: try JSONEncoder().encode(CompactIslandLayout(leading: [], trailing: [.priceClock])), as: UTF8.self)
        XCTAssertEqual(try component("priceClock", in: XCTUnwrap(P.project(request))).visible, true)
        options = .init(); options.clockShow = .peak; request.componentOptions = options.json
        XCTAssertEqual(try component("priceClock", in: XCTUnwrap(P.project(request))).visible, wallet.peakNow)
    }

    func testBadgeAveragesAndSegmentsOnlyRunningTasksThatReportAnEstimate() {
        typealias Share = HeaderActivity.TaskShare
        func header(_ tasks: [Share]) -> HeaderActivity { .init(core: .count(tasks.count), activeCount: tasks.count, orbit: [:], tasks: tasks) }
        let mixed = header([.init(provider: .codex, fraction: 0.72), .init(provider: .claude, fraction: 0.4), .init(provider: .claude, fraction: nil)])
        XCTAssertEqual(mixed.reportedCount, 2); XCTAssertEqual(try XCTUnwrap(mixed.averageProgress), 0.56, accuracy: 0.0001)
        XCTAssertNil(mixed.averageProvider); XCTAssertTrue(mixed.showsSegments); XCTAssertFalse(mixed.averageStale)
        let one = header([.init(provider: .claude, fraction: 0.2, stale: true), .init(provider: .claude, fraction: 0.6, stale: true)])
        XCTAssertEqual(one.averageProvider, .claude); XCTAssertTrue(one.averageStale)
        let none = header([.init(provider: .codex, fraction: nil), .init(provider: .claude, fraction: nil)])
        XCTAssertNil(none.averageProgress); XCTAssertFalse(none.showsSegments); XCTAssertFalse(none.averageStale)
        let many = header((0..<5).map { _ in Share(provider: .codex, fraction: 0.5) })
        XCTAssertFalse(many.showsSegments); XCTAssertEqual(many.averageProgress, 0.5)
        XCTAssertEqual(header((0..<20).map { _ in Share(provider: .codex, fraction: 2) }).tasks.count, HeaderActivity.taskLimit)
        // The rings list at most `taskLimit` tasks, but the average counts every running one.
        let crowd = header((0..<12).map { _ in Share(provider: .codex, fraction: 0) } + [Share(provider: .claude, fraction: 0.65)])
        XCTAssertEqual(crowd.tasks.count, HeaderActivity.taskLimit); XCTAssertEqual(crowd.reportedCount, 13)
        XCTAssertEqual(try XCTUnwrap(crowd.averageProgress), 0.05, accuracy: 0.0001)
        XCTAssertNil(crowd.averageProvider, "A mix behind the average draws neutral")
        XCTAssertEqual(Share(provider: .codex, fraction: 2).fraction, 1)

        // Which ring several tasks draw: a task without an estimate never moves
        // the average and breathes as a segment; with no estimate at all the
        // ring shows the services; more than four segments use the average.
        let partly = header([.init(provider: .codex, fraction: 0.6), .init(provider: .claude, fraction: nil), .init(provider: .claude, fraction: nil)])
        XCTAssertEqual(partly.multiTaskRing(.average), .average); XCTAssertEqual(partly.averageProgress, 0.6)
        XCTAssertEqual(partly.averageProvider, .codex, "Only the tasks with an estimate color the average")
        XCTAssertEqual(partly.multiTaskRing(.segments), .segments); XCTAssertEqual(partly.tasks.map(\.fraction), [0.6, nil, nil])
        XCTAssertEqual(partly.multiTaskRing(.service), .services)
        for choice in CompactComponentOptions.MultiRing.allCases {
            XCTAssertEqual(none.multiTaskRing(choice), .services, "\(choice) without any estimate shows the services")
        }
        let crowded = header([Share(provider: .codex, fraction: 0.3)] + (0..<4).map { _ in Share(provider: .claude, fraction: nil) })
        XCTAssertEqual(crowded.multiTaskRing(.segments), .average); XCTAssertEqual(crowded.averageProgress, 0.3)
        XCTAssertEqual(header([.init(provider: .codex, fraction: 0.6)]).multiTaskRing(.segments), nil, "One task keeps its own ring")
        var asking = partly; asking.attention = .approval
        XCTAssertNil(asking.multiTaskRing(.average), "A request keeps the amber disc")
    }

    func testFirstOutputHistoryKeepsOnlyItsRecentValues() {
        var history = CompactFirstOutputHistory()
        history.record(1, measuredAt: now); history.record(1, measuredAt: now); history.record(4000, measuredAt: now.addingTimeInterval(1))
        XCTAssertEqual(history.values, [1])
        for (index, value) in [5.0, 3, 9, 7, 2, 8].enumerated() { history.record(value, measuredAt: now.addingTimeInterval(Double(index + 2))) }
        XCTAssertEqual(history.values, [3, 9, 7, 2, 8]); XCTAssertEqual(history.median, 7)
        XCTAssertEqual(CompactFirstOutputHistory.median([4, 1, 3, 2]), 2.5); XCTAssertNil(CompactFirstOutputHistory.median([]))
        // Measurements that arrive after a newer one still count, in the order they were taken.
        var late = CompactFirstOutputHistory()
        late.record(9, measuredAt: now.addingTimeInterval(10)); late.record(1, measuredAt: now.addingTimeInterval(1))
        late.record(2, measuredAt: now.addingTimeInterval(2)); late.record(2, measuredAt: now.addingTimeInterval(2))
        XCTAssertEqual(late.values, [1, 2, 9]); XCTAssertEqual(late.median, 2)
        for offset in 11...13 { late.record(5, measuredAt: now.addingTimeInterval(Double(offset))) }
        late.record(0.5, measuredAt: now)
        XCTAssertEqual(late.values, [2, 9, 5, 5, 5], "One older than the five kept is not recent")
        var state = ActivityApplicationState()
        for (seconds, offset) in [(9.0, 10.0), (1, 1), (2, 2)] {
            state.rememberFirstOutput(seconds, reportedAt: now.addingTimeInterval(offset), at: now.addingTimeInterval(60))
        }
        XCTAssertEqual(state.latestFirstOutput?.seconds, 9, "The latest stays the newest measurement")
        XCTAssertEqual(state.firstOutputHistory.median, 2)
        let idle = CompactBarContext(activities: [], requests: [], completions: [], sources: [], firstOutputs: [1, 2, 3, 4, 5, 6], now: now)
        XCTAssertEqual(idle.firstOutputs, [2, 3, 4, 5, 6]); XCTAssertNil(idle.measuredTasks)
    }

    func testCompactCountdownsStayShortInBothForms() {
        XCTAssertEqual(CompactDuration.short(30), "<1m"); XCTAssertEqual(CompactDuration.short(45 * 60), "45m")
        XCTAssertEqual(CompactDuration.short(5400), "1.5h"); XCTAssertEqual(CompactDuration.short(7200), "2h")
        XCTAssertEqual(CompactDuration.short(46 * 3600), "46h"); XCTAssertEqual(CompactDuration.short(150 * 3600), "6d")
        XCTAssertEqual(CompactDuration.compact(5400, language: .english), "1h30m")
        XCTAssertEqual(CompactDuration.compact(5400, language: .simplifiedChinese), "1时30分")
        XCTAssertEqual(CompactDuration.compact(90_000, language: .english), "1d1h")
    }
}
