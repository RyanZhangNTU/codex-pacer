import Foundation
import XCTest
@testable import PacerCore

final class ExpandedPanelTests: XCTestCase {
    private typealias Layout = ExpandedPanelLayout
    private typealias Options = ExpandedPanelOptions
    private typealias P = ExpandedPanelPresentation
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let all: Set<AgentProvider> = [.codex, .claude, .deepseek]

    private func snapshot(_ provider: AgentProvider, fiveHour: Bool = true, weekly: Bool = true) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        if fiveHour { windows.append(.init(id: "5h", usedPercent: 20, durationMinutes: 300, resetsAt: now.addingTimeInterval(9000))) }
        if weekly { windows.append(.init(id: "7d", usedPercent: 60, durationMinutes: 10080, resetsAt: now.addingTimeInterval(200_000))) }
        return .init(buckets: [.init(id: provider.rawValue, name: nil, plan: nil, windows: windows, credits: nil)],
            capturedAt: now, resetCredits: nil)
    }

    private func sections(_ blocks: [Layout.Block], providers: Set<AgentProvider>? = nil, options: Options = .init(),
                          budgetDial: Bool = false) -> [P.Section] {
        P.sections(layout: Layout(blocks: blocks), providers: providers ?? all, options: options, budgetDial: budgetDial)
    }

    // MARK: Layout

    func testAutomaticLayoutMatchesThePanelBeforeBlocks() {
        XCTAssertEqual(Layout.automatic(providers: [.codex, .claude], deepseekDetailed: true).visibleBlocks(providers: [.codex, .claude]),
            [.tasks, .codex, .claude])
        XCTAssertEqual(Layout.automatic(providers: [.deepseek], deepseekDetailed: true).visibleBlocks(providers: [.deepseek]),
            [.tasks, .deepseek, .deepseekSpend, .deepseekWeek], "Detailed DeepSeek alone adds where the money went and the week")
        XCTAssertEqual(Layout.automatic(providers: [.deepseek], deepseekDetailed: false).visibleBlocks(providers: [.deepseek]),
            [.tasks, .deepseek], "Simple keeps the dial and what sits beside it")
        XCTAssertEqual(Layout.automatic(providers: [.codex, .deepseek], deepseekDetailed: true).visibleBlocks(providers: [.codex, .deepseek]),
            [.tasks, .codex, .deepseek], "Beside another service DeepSeek showed only its dial")
        XCTAssertEqual(Layout.resolved(saved: Layout(blocks: [.claude]), providers: all, deepseekDetailed: true).blocks, [.claude])
        // The automatic sections draw today's panel: tasks, then one quota row.
        let automatic = P.sections(layout: .automatic(providers: [.codex, .claude], deepseekDetailed: true), providers: [.codex, .claude],
            options: .init(), budgetDial: false)
        XCTAssertEqual(automatic, [P.Section(kind: .tasks, actions: true), P.Section(kind: .quota, providers: [.codex, .claude])])
        let solo = P.sections(layout: .automatic(providers: [.deepseek], deepseekDetailed: true), providers: [.deepseek],
            options: .init(), budgetDial: false)
        XCTAssertEqual(solo, [P.Section(kind: .tasks, actions: true), P.Section(kind: .quota, providers: [.deepseek], spendBeside: true),
            P.Section(kind: .deepseekWeek, providers: [.deepseek], joined: true)], "The day dial keeps the spend in its column")
    }

    func testLayoutDecodesOnlyItsOwnSchemaAndDropsUnknownOrRepeatedBlocks() throws {
        XCTAssertNil(Layout.decode(nil)); XCTAssertNil(Layout.decode("not json"))
        XCTAssertNil(Layout.decode(#"{"version":2,"blocks":["tasks"]}"#), "A newer layout reads as automatic")
        XCTAssertNil(Layout.decode(String(repeating: " ", count: Layout.byteLimit + 1)))
        let value = try XCTUnwrap(Layout.decode(#"{"version":1,"blocks":["claude","future","tasks","claude"]}"#))
        XCTAssertEqual(value.blocks, [.claude, .tasks])
        XCTAssertEqual(value.json, #"{"blocks":["claude","tasks"],"version":1}"#)
        XCTAssertEqual(Layout.decode(value.json), value)
        XCTAssertEqual(Layout.decode(#"{"version":1,"blocks":[]}"#)?.blocks, [], "An empty saved layout stays empty")
    }

    func testEditsKeepUsualOrderHiddenPlacesAndTheLastShownBlock() {
        var layout = Layout(blocks: [.claude, .tasks])
        layout.toggle(.codex, providers: all)
        XCTAssertEqual(layout.blocks, [.codex, .claude, .tasks], "A new block goes before the first block that usually follows it")
        layout.toggle(.deepseekWeek, providers: all); layout.toggle(.deepseek, providers: all)
        XCTAssertEqual(layout.blocks, [.codex, .claude, .tasks, .deepseek, .deepseekWeek])
        layout.toggle(.tasks, providers: all)
        XCTAssertEqual(layout.blocks, [.codex, .claude, .deepseek, .deepseekWeek])

        // Claude is off: its block keeps its place, and moving skips it.
        let providers: Set<AgentProvider> = [.codex, .deepseek]
        layout.shift(.deepseek, by: -1, providers: providers)
        XCTAssertEqual(layout.blocks, [.deepseek, .codex, .claude, .deepseekWeek])
        layout.shift(.deepseek, by: -5, providers: providers)
        XCTAssertEqual(layout.blocks, [.deepseek, .codex, .claude, .deepseekWeek], "The first shown block stays first")
        layout.move(.deepseekWeek, before: .claude)
        XCTAssertEqual(layout.blocks, [.deepseek, .codex, .deepseekWeek, .claude])
        layout.move(.deepseekWeek, before: nil)
        XCTAssertEqual(layout.blocks, [.deepseek, .codex, .claude, .deepseekWeek])

        var last = Layout(blocks: [.claude, .codex])
        XCTAssertTrue(last.isLastVisible(.codex, providers: [.codex]))
        last.toggle(.codex, providers: [.codex])
        XCTAssertEqual(last.blocks, [.claude, .codex], "The last block the services can show stays")
        last.toggle(.claude, providers: [.codex])
        XCTAssertEqual(last.blocks, [.codex], "A hidden block can always go")
    }

    // MARK: Options

    func testEveryOptionFallsBackOnItsOwnAndSavesSortedJSON() {
        let defaults = Options()
        XCTAssertEqual(Options.decode(nil), defaults); XCTAssertEqual(Options.decode("[]"), defaults)
        XCTAssertEqual(Options.decode(String(repeating: " ", count: Options.byteLimit + 1)), defaults)
        XCTAssertEqual(defaults.pageSize, 3); XCTAssertEqual(defaults.rowStyle, .twoLine)
        XCTAssertEqual(defaults.rowFields, Set(Options.RowField.allCases)); XCTAssertEqual(defaults.spendTasks, 2)
        XCTAssertEqual(defaults.headerActions, Set(Options.HeaderAction.allCases))
        let mixed = Options.decode(#"{"version":9,"pageSize":9,"rowStyle":"oneLine","rowFields":["rate","future"],"codexPeriods":"monthly","claudePeriods":"weekly","spendTasks":3,"weekLine":"no","headerActions":["pin"]}"#)
        XCTAssertEqual(mixed.pageSize, 3); XCTAssertEqual(mixed.rowStyle, .oneLine); XCTAssertEqual(mixed.rowFields, [.rate])
        XCTAssertEqual(mixed.codexPeriods, .both); XCTAssertEqual(mixed.claudePeriods, .weekly)
        XCTAssertEqual(mixed.spendTasks, 2); XCTAssertTrue(mixed.weekLine); XCTAssertEqual(mixed.headerActions, [.pin])
        XCTAssertEqual(Options.decode(#"{"rowFields":[]}"#).rowFields, [], "An empty choice stays empty")

        var chosen = defaults
        chosen.pageSize = 6; chosen.rowFields = [.model, .rate]; chosen.quotaArrange = .stack; chosen.headerActions = [.settings, .markRead]
        XCTAssertEqual(Options.decode(chosen.json), chosen)
        XCTAssertTrue(chosen.json.contains(#""rowFields":["rate","model"]"#), "Sets save in a fixed order")
        XCTAssertTrue(chosen.json.contains(#""headerActions":["markRead","settings"]"#))
        XCTAssertTrue(chosen.json.hasPrefix(#"{"claudePeriods":"both""#)); XCTAssertTrue(chosen.json.contains(#""version":1"#))
    }

    func testRowFieldsAndBudgetDialFollowTheirChoices() {
        var options = Options()
        XCTAssertTrue(options.shows(.model))
        options.rowStyle = .oneLine
        XCTAssertFalse(options.shows(.model), "One line keeps only the speed and the turn time")
        XCTAssertTrue(options.shows(.rate)); XCTAssertTrue(options.shows(.turnTime))
        options.rowFields.remove(.rate)
        XCTAssertFalse(options.shows(.rate))
        XCTAssertTrue(options.showsBudgetDial(hasBudget: true)); XCTAssertFalse(options.showsBudgetDial(hasBudget: false))
        options.deepseekDial = .day
        XCTAssertFalse(options.showsBudgetDial(hasBudget: true))
        options.setPeriods(.fiveHour, for: .claude); options.setPeriods(.weekly, for: .deepseek)
        XCTAssertEqual(options.periods(for: .claude), .fiveHour); XCTAssertEqual(options.periods(for: .deepseek), .both)
    }

    // MARK: Sections

    func testSectionsPairAdjacentQuotaInLayoutOrderAndGiveTheFirstTheActions() {
        XCTAssertEqual(sections([.claude, .codex, .tasks]),
            [P.Section(kind: .quota, providers: [.claude, .codex], actions: true), P.Section(kind: .tasks)])
        XCTAssertEqual(sections([.codex, .tasks, .claude]),
            [P.Section(kind: .quota, providers: [.codex], actions: true), P.Section(kind: .tasks), P.Section(kind: .quota, providers: [.claude])],
            "Blocks apart stay apart")
        var stack = Options(); stack.quotaArrange = .stack
        XCTAssertEqual(sections([.tasks, .codex, .claude, .deepseek], options: stack).map(\.providers), [[], [.codex], [.claude], [.deepseek]])
        XCTAssertEqual(sections([.tasks, .codex, .claude], providers: [.claude]),
            [P.Section(kind: .tasks, actions: true), P.Section(kind: .quota, providers: [.claude])], "A disabled service's block is skipped")
        XCTAssertEqual(sections([.codex], providers: [.claude]), [P.Section(kind: .tasks, actions: true)],
            "With nothing to show the task list keeps the actions")
    }

    func testDeepSeekSpendAndWeekJoinTheirDialOrStandApart() {
        XCTAssertEqual(sections([.deepseek, .deepseekSpend, .deepseekWeek], budgetDial: true),
            [P.Section(kind: .quota, providers: [.deepseek], actions: true),
             P.Section(kind: .deepseekSpend, providers: [.deepseek], joined: true),
             P.Section(kind: .deepseekWeek, providers: [.deepseek], joined: true)], "The budget dial's column has no room for the spend")
        XCTAssertEqual(sections([.codex, .deepseek, .deepseekSpend]),
            [P.Section(kind: .quota, providers: [.codex, .deepseek], actions: true),
             P.Section(kind: .deepseekSpend, providers: [.deepseek], joined: true)], "Only a lone dial takes the spend into its column")
        XCTAssertEqual(sections([.deepseekWeek, .tasks, .codex, .deepseekSpend]),
            [P.Section(kind: .deepseekWeek, providers: [.deepseek], actions: true), P.Section(kind: .tasks),
             P.Section(kind: .quota, providers: [.codex]), P.Section(kind: .deepseekSpend, providers: [.deepseek])])
        let first = sections([.deepseekWeek, .tasks])[0]
        XCTAssertTrue(first.showsHeader, "A first chart carries the actions under a header")
        XCTAssertFalse(sections([.tasks, .deepseekWeek])[1].showsHeader, "Otherwise it keeps its own title")
        XCTAssertEqual(sections([.deepseek, .deepseekWeek, .deepseekSpend]).map(\.kind), [.quota, .deepseekWeek, .deepseekSpend],
            "The spend joins the dial only right after it")
    }

    func testHeadersNameTheSectionAndItsLoneService() {
        func header(_ providers: [AgentProvider], budget: Bool = false) -> P.Header {
            P.header(P.Section(kind: .quota, providers: providers), budgetDial: budget)
        }
        XCTAssertEqual(header([.codex, .claude]).title, L10n.text("layout.group.quota")); XCTAssertNil(header([.codex, .claude]).detail)
        XCTAssertEqual(header([.claude]).detail, "Claude"); XCTAssertEqual(header([.claude]).provider, .claude)
        XCTAssertEqual(header([.codex, .deepseek]).title, L10n.text("layout.group.quota_balance"))
        XCTAssertEqual(header([.deepseek]).title, L10n.text("layout.group.balance"))
        XCTAssertEqual(header([.deepseek], budget: true).title, L10n.text("layout.group.budget"))
        XCTAssertEqual(P.header(P.Section(kind: .tasks), budgetDial: false).title, L10n.text("layout.group.tasks"))
        XCTAssertEqual(P.header(P.Section(kind: .deepseekWeek), budgetDial: false).title, L10n.text("deepseek.week_title"))
    }

    // MARK: Quota drawing

    func testGaugeFollowsTheChosenWindows() {
        let both = snapshot(.codex), weekly = snapshot(.codex, fiveHour: false), five = snapshot(.codex, weekly: false)
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: both, periods: .both), .init(provider: .codex, period: .weekly, split: true))
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: weekly, periods: .both), .init(provider: .codex, period: .weekly, split: false))
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: both, periods: .weekly), .init(provider: .codex, period: .weekly, split: false))
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: both, periods: .fiveHour), .init(provider: .codex, period: .fiveHour, split: false))
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: weekly, periods: .fiveHour).period, .weekly,
            "An account without 5 hours keeps its week")
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: five, periods: .fiveHour).period, .fiveHour)
        XCTAssertEqual(P.gauge(provider: .codex, snapshot: nil, periods: .fiveHour).period, .fiveHour)
    }

    func testQuotaLayoutKeepsBlockOrderDetailsAndClassicWindows() {
        let snapshots: [AgentProvider: QuotaSnapshot] = [.codex: snapshot(.codex), .claude: snapshot(.claude)]
        let ordered = QuotaDashboardPresentation.layout(providers: [.claude, .codex], snapshots: snapshots, style: .split, now: now,
            preservingOrder: true)
        XCTAssertEqual(ordered.slots.map(\.provider), [.claude, .codex])
        XCTAssertEqual(QuotaDashboardPresentation.layout(providers: [.claude, .codex], snapshots: snapshots, style: .split, now: now).slots.map(\.provider),
            [.codex, .claude], "Without a panel order the services keep their usual one")
        XCTAssertEqual(QuotaDashboardPresentation.layout(providers: [.claude], snapshots: snapshots, style: .split, now: now).kind, .splitSingle)
        XCTAssertEqual(QuotaDashboardPresentation.layout(providers: [.claude], snapshots: snapshots, style: .split, now: now, details: false).kind,
            .splitRings, "Without details a lone ring stands as in a row")
        let classicWeek = QuotaDashboardPresentation.layout(providers: [.claude], snapshots: snapshots, style: .classic, now: now,
            periods: { _ in .weekly })
        XCTAssertEqual(classicWeek.slots.map(\.period), [.weekly])
        XCTAssertEqual(QuotaDashboardPresentation.layout(providers: [.claude], snapshots: snapshots, style: .classic, now: now).slots.map(\.period),
            [.fiveHour, .weekly])
        let classicPair = QuotaDashboardPresentation.layout(providers: [.codex, .claude], snapshots: snapshots, style: .classic, now: now,
            periods: { $0 == .claude ? .fiveHour : .both })
        XCTAssertEqual(classicPair.slots.map(\.period), [.weekly, .fiveHour])
    }

    // MARK: DeepSeek

    func testSpendBarAndWeekFollowTheirChoices() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var ledger = DeepSeekSpendLedger()
        for (index, cost) in [6.0, 4, 3, 2, 1].enumerated() {
            ledger.record(id: "today-\(index)", at: now.addingTimeInterval(-Double(index + 1) * 60), cost: cost, task: "task-\(index)")
        }
        ledger.record(id: "old-one", at: now.addingTimeInterval(-86400), cost: 5)
        ledger.record(id: "old-two", at: now.addingTimeInterval(-172800), cost: 3)
        var history = DeepSeekBalanceHistory()
        history.record(total: 120, at: calendar.startOfDay(for: now).addingTimeInterval(1), source: "web", calendar: calendar)
        history.record(total: 100, at: now, source: "web", calendar: calendar)
        let wallet = DeepSeekWallet(balance: .init(total: 100, capturedAt: now, source: .web), connected: true, ledger: ledger, now: now,
            history: history, calendar: calendar)
        let standard = try XCTUnwrap(DeepSeekSoloPresentation(wallet: wallet, at: now).distribution)
        XCTAssertEqual(standard.parts.filter { !$0.elsewhere }.count, 3, "Two tasks and the rest, as before")
        XCTAssertTrue(standard.parts.last!.elsewhere)
        var options = ExpandedPanelOptions(); options.spendTasks = 4; options.spendElsewhere = false; options.weekLine = false
        let chosen = DeepSeekSoloPresentation(wallet: wallet, at: now, panel: options)
        let parts = try XCTUnwrap(chosen.distribution?.parts)
        XCTAssertEqual(parts.count, 5); XCTAssertFalse(parts.contains { $0.elsewhere })
        XCTAssertEqual(parts.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertEqual(parts.map(\.opacity), [0.9, 0.72, 0.56, 0.44, 0.32])
        XCTAssertEqual(P.distribution(wallet, options: options), chosen.distribution)
        let week = try XCTUnwrap(chosen.week)
        XCTAssertNil(week.lineText); XCTAssertNil(week.lineFraction)
        XCTAssertNotNil(DeepSeekSoloPresentation(wallet: wallet, at: now).week?.lineText)

        var onlyElsewhere = DeepSeekSpendLedger()
        onlyElsewhere.record(id: "old", at: now.addingTimeInterval(-86400), cost: 1)
        let quiet = DeepSeekWallet(balance: .init(total: 100, capturedAt: now, source: .web), connected: true, ledger: onlyElsewhere, now: now,
            history: history, calendar: calendar)
        XCTAssertNotNil(DeepSeekSoloPresentation(wallet: quiet, at: now).distribution)
        XCTAssertNil(DeepSeekSoloPresentation(wallet: quiet, at: now, panel: options).distribution,
            "Hiding spend elsewhere leaves nothing to draw on a day without local tasks")
    }

    // MARK: Settings page projection

    func testProjectionEditsSavesAndRestoresTheLayout() throws {
        let request = P.Request(providers: [.codex, .claude], language: "en")
        let automatic = try XCTUnwrap(P.project(request))
        XCTAssertNil(automatic.layoutJSON, "Nothing is saved until an edit")
        XCTAssertEqual(automatic.blocks, ["tasks", "codex", "claude", "deepseek"]); XCTAssertEqual(automatic.visible, ["tasks", "codex", "claude"])
        XCTAssertEqual(automatic.catalog.first { $0.id == "deepseek" }?.available, false)
        XCTAssertEqual(automatic.catalog.first { $0.id == "deepseekWeek" }?.placed, false)
        XCTAssertEqual(automatic.groups.map(\.id), ["tasks", "quota", "deepseek"])
        XCTAssertEqual(automatic.sections.first?.actions, true)

        var edit = request; edit.action = .init(kind: "shift", block: "tasks", offset: 1)
        let moved = try XCTUnwrap(P.project(edit))
        XCTAssertEqual(moved.visible, ["codex", "tasks", "claude"])
        XCTAssertEqual(moved.layoutJSON, #"{"blocks":["codex","tasks","claude","deepseek"],"version":1}"#)
        var removal = request; removal.layout = #"{"version":1,"blocks":["claude"]}"#; removal.action = .init(kind: "toggle", block: "claude")
        let kept = try XCTUnwrap(P.project(removal))
        XCTAssertEqual(kept.visible, ["claude"]); XCTAssertEqual(kept.catalog.first { $0.id == "claude" }?.locked, true)
        var restore = removal; restore.action = .init(kind: "restore")
        let restored = try XCTUnwrap(P.project(restore))
        XCTAssertNil(restored.layoutJSON); XCTAssertEqual(restored.visible, ["tasks", "codex", "claude"])

        var options = ExpandedPanelOptions(); options.quotaArrange = .stack
        var stacked = request; stacked.options = options.json
        XCTAssertEqual(try XCTUnwrap(P.project(stacked)).sections.count, 3)
        XCTAssertEqual(try XCTUnwrap(P.project(stacked)).options.quotaArrange, .stack)

        for invalid in [P.Action(kind: "toggle", block: "future"), P.Action(kind: "shift", block: "tasks"),
                        P.Action(kind: "shift", block: "tasks", offset: 11), P.Action(kind: "move", block: "tasks", before: "future"),
                        P.Action(kind: "explode", block: "tasks")] {
            var bad = request; bad.action = invalid
            XCTAssertNil(P.project(bad), invalid.kind)
        }
        var language = request; language.language = "fr"
        XCTAssertNil(P.project(language))
        var repeated = request; repeated.providers = [.codex, .codex]
        XCTAssertNil(P.project(repeated))
        var damaged = request; damaged.layout = "{"
        XCTAssertEqual(try XCTUnwrap(P.project(damaged)).visible, ["tasks", "codex", "claude"], "A damaged layout reads as automatic")
        let encoded = try JSONEncoder().encode(automatic)
        XCTAssertEqual(try JSONDecoder().decode(P.Output.self, from: encoded), automatic)
    }
}
