import AppKit
import SwiftUI
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class ExpandedPanelDisplayTests: XCTestCase {
    @MainActor private final class WidthCapture { var value: CGFloat = 0 }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func model(_ modules: ProviderModules, configure: (UserDefaults) -> Void = { _ in }) throws -> (IslandModel, UserDefaults) {
        let domain = testDefaultsName("ExpandedPanelDisplayTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { removeTestDefaults(domain) }
        modules.save(to: defaults)
        for (key, path) in [("codexHome", "codex"), ("claudeHome", "claude"), ("deepseekHome", "deepseek")] {
            defaults.set("/synthetic/panel/" + path, forKey: key)
        }
        defaults.set(false, forKey: "monitorSSH"); defaults.set(false, forKey: "monitorRemoteControl")
        configure(defaults)
        let model = IslandModel(demo: false, defaults: defaults,
            installation: .init(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true))
        model.now = now
        model.activities = DemoScenario.tasks(stage: .thinking, at: now)
            + [DemoScenario.claudeTask(stage: .thinking, at: now), DemoScenario.deepseekTask(stage: .thinking, at: now)]
        return (model, defaults)
    }

    func testPanelFollowsTheSavedBlocksAndChoices() async throws {
        let (model, defaults) = try model(ProviderModules(codexMode: .enabled, claudeMode: .enabled, deepseekMode: .enabled))
        XCTAssertNil(model.savedPanelLayout)
        XCTAssertEqual(model.panelSections.map(\.kind), [.tasks, .quota], "Without a saved layout the panel looks as before blocks")
        XCTAssertEqual(model.panelSections.last?.providers, [.codex, .claude, .deepseek])
        XCTAssertEqual(model.visibleActivities.count, 4)
        XCTAssertEqual(model.taskPresentation.pagination.pageCount, 2, "Three tasks to a page by default")

        var layouts = 0
        model.onLayoutChange = { layouts += 1 }
        ExpandedPanelLayout(blocks: [.deepseek, .tasks, .codex]).save(to: defaults)
        var options = ExpandedPanelOptions()
        options.quotaArrange = .stack; options.pageSize = 4; options.deepseekDial = .day
        options.save(to: defaults)
        model.reloadPanelSettings()
        XCTAssertEqual(layouts, 1, "A change of blocks or choices resizes the panel once")
        model.reloadPanelSettings()
        XCTAssertEqual(layouts, 1, "Reading the same settings again changes nothing")
        let sections = model.panelSections
        XCTAssertEqual(sections.map(\.kind), [.quota, .tasks, .quota])
        XCTAssertEqual(sections.map(\.providers), [[.deepseek], [], [.codex]], "Claude was left out; the order is the saved one")
        XCTAssertEqual(sections.map(\.actions), [true, false, false], "The first block carries the buttons")
        XCTAssertEqual(model.taskPresentation.pagination.pageSize, 4)
        XCTAssertFalse(model.taskPresentation.pagination.isPaginated)

        defaults.set("budget", forKey: IslandModel.deepseekModeKey)
        defaults.set(15.0, forKey: IslandModel.deepseekDailyBudgetKey)
        XCTAssertFalse(model.deepseekShowsBudgetDial, "Today's dial was chosen over the budget")
        options.deepseekDial = .budget; options.save(to: defaults); model.reloadPanelSettings()
        XCTAssertTrue(model.deepseekShowsBudgetDial)
        XCTAssertEqual(ExpandedPanelPresentation.header(model.panelSections[0], budgetDial: model.deepseekShowsBudgetDial).title,
            L10n.text("layout.group.budget"))

        ExpandedPanelLayout.clear(from: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertNil(model.savedPanelLayout, "Applying settings rereads the blocks")
        XCTAssertEqual(model.panelSections.map(\.kind), [.tasks, .quota, .quota, .quota], "Each quota keeps its own row")
        await model.shutdown()
    }

    func testDeepSeekAloneKeepsItsFormerContentUntilBlocksAreSaved() async throws {
        let modules = ProviderModules(codexMode: .disabled, claudeMode: .disabled, deepseekMode: .enabled)
        let (detailed, _) = try model(modules)
        XCTAssertEqual(detailed.panelLayout.visibleBlocks(providers: [.deepseek]), [.tasks, .deepseek, .deepseekSpend, .deepseekWeek])
        let sections = detailed.panelSections
        XCTAssertEqual(sections.map(\.kind), [.tasks, .quota, .deepseekWeek])
        XCTAssertTrue(sections[1].spendBeside, "The day dial draws today's spend in its column, as before")
        XCTAssertTrue(sections[2].joined)
        await detailed.shutdown()

        let (simple, _) = try model(modules) { $0.set("simple", forKey: DeepSeekPanelStyle.defaultsKey) }
        XCTAssertEqual(simple.panelSections.map(\.kind), [.tasks, .quota], "Simple content leaves spend and week out")
        await simple.shutdown()
    }

    func testRowsAndHeaderMeasureOnlyWhatTheyShow() async throws {
        _ = NSApplication.shared
        let (model, _) = try model(ProviderModules(codexMode: .enabled, claudeMode: .enabled, deepseekMode: .enabled))
        let row = try XCTUnwrap(model.taskPresentation.rows.first)
        func measure<Content: View>(_ view: Content) async throws -> CGFloat {
            let capture = WidthCapture()
            let host = NSHostingView(rootView: view.onPreferenceChange(ExpandedContentIdealWidth.self) { width in
                DispatchQueue.main.async { capture.value = width }
            })
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 600, height: 60),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 60)
            host.layoutSubtreeIfNeeded()
            try await TestWait.until { capture.value > 0 }
            return capture.value
        }
        func rowView(_ options: ExpandedPanelOptions) -> some View {
            TaskRowView(presentation: row, group: nil, now: now, enabled: true, accent: .blue, options: options) {}
        }
        var bare = ExpandedPanelOptions(); bare.rowFields = []
        var oneLine = ExpandedPanelOptions(); oneLine.rowStyle = .oneLine
        let full = try await measure(rowView(ExpandedPanelOptions()))
        let hidden = try await measure(rowView(bare)), single = try await measure(rowView(oneLine))
        XCTAssertLessThanOrEqual(hidden, full, "Hidden readings stop widening the panel")
        XCTAssertLessThanOrEqual(single, full)
        XCTAssertEqual(TaskRowView.height(.oneLine), 38)
        XCTAssertEqual(TaskRowView.height(.twoLine), 54)

        func subagentWidth(_ description: String, type: String?, name: String? = nil) async throws -> CGFloat {
            var child = DemoScenario.subagentTasks(stage: .thinking, at: now)[1]
            if let name, let type {
                child.subagentDisplay = SubagentDisplay(spawn: ["agent_role": type, "agent_nickname": name, "agent_path": description], header: [:])
            } else {
                child.subagentDisplay = SubagentDisplay(claudeType: type, description: description)
            }
            let line = ActivityTaskRowPresentation.subagentLine(child, options: .init(), at: now)
            return try await measure(SubagentList(lines: [line], enabled: true, open: {}))
        }
        let short = try await subagentWidth("Trace", type: nil)
        let tagged = try await subagentWidth("Trace", type: "Explore")
        let long = try await subagentWidth(String(repeating: "Wide ", count: 24), type: "Explore")
        XCTAssertGreaterThan(tagged, short); XCTAssertGreaterThan(long, tagged)
        XCTAssertLessThanOrEqual(long - tagged, 220 - 48 + 1, "Only the title has the 220 pt probe cap")
        let wideTag = String(repeating: "W", count: 48)
        let plugin = try await subagentWidth("Trace", type: "pr-review-toolkit:silent-failure-hunter")
        XCTAssertEqual(plugin - short, 120 + 4, accuracy: 1)
        let both = try await subagentWidth("trace", type: wideTag, name: wideTag)
        XCTAssertEqual(both - short, 2 * (120 + 4), accuracy: 1, "Each truncated tag and its gap add to the title minimum")

        let withButtons = try await measure(TaskPagerView(model: model, actions: true).header)
        let alone = try await measure(TaskPagerView(model: model, actions: false).header)
        let controls = NSHostingView(rootView: IslandPanelControls(model: model).fixedSize()).fittingSize.width
        XCTAssertGreaterThanOrEqual(withButtons - alone, controls,
            "A task list below the first block keeps only its page controls")
        await model.shutdown()
    }

    func testOneAndTwoLineRowsReadTheDotsTheyDraw() throws {
        let tasks = DemoScenario.subagentTasks(stage: .thinking, at: now)
        let row = try XCTUnwrap(ActivityTaskPresentation(activities: tasks, requests: [], inbox: CompletionInbox(), at: now).rows.first)
        XCTAssertEqual(SubagentDotsView.color(.failed, provider: .codex), PacerPalette.danger)
        XCTAssertEqual(SubagentDotsView.color(.attention, provider: .claude), PacerPalette.attention)
        for style in [ExpandedPanelOptions.RowStyle.oneLine, .twoLine] {
            var options = ExpandedPanelOptions(); options.rowStyle = style
            var view = TaskRowView(presentation: row, group: nil, now: now, enabled: true, accent: .blue, options: options) {}
            XCTAssertTrue(view.showsSubagentDots); XCTAssertTrue(view.accessibilityText.contains(row.subagentDotsAccessibility))
            view.options.rowFields.remove(.subagents)
            XCTAssertFalse(view.showsSubagentDots); XCTAssertFalse(view.accessibilityText.contains(row.subagentDotsAccessibility))
        }
    }

    func testLineCompressesTitleBeforeDroppingModelThenTime() throws {
        // Distinct rendered heights identify which variant SwiftUI actually placed.
        for (width, height) in [(300, 21), (158, 21), (157, 22), (107, 23)] {
            let view = TaskLineLayout(measuring: false, hasModel: true, hasTime: true) { model, time in
                HStack(spacing: 0) {
                    Text(String(repeating: "long title ", count: 10)).lineLimit(1).frame(minWidth: 48, maxWidth: .infinity)
                    Color.blue.frame(width: 20) // speed
                    if time { Color.gray.frame(width: 40) }
                    if model { Color.green.frame(width: 50) }
                }
                .frame(height: model ? 21 : time ? 22 : 23)
            }
            .frame(width: CGFloat(width)).fixedSize(horizontal: false, vertical: true)
            XCTAssertEqual(try XCTUnwrap(ImageRenderer(content: view).cgImage).height, height, "width \(width)")
        }
    }

    func testTwoLineRowFitsTimeAndModelIndependently() throws {
        let id = "fixture-task"
        var task = SessionActivity(id: id, sourceHost: String(repeating: "W", count: 16), sourceHostID: "fixture",
                                   provider: .claude, sessionID: id)
        task.applyRuntime(["method": "turn/started", "threadId": id, "turnId": "turn", "at": now.timeIntervalSince1970 - 90])
        task.applyRuntime(["method": "metadata", "threadId": id, "model": "M", "at": now.timeIntervalSince1970])
        let row = ActivityTaskRowPresentation(activity: task, unread: false, at: now)
        func render(_ fields: Set<ExpandedPanelOptions.RowField>) throws -> Data {
            var options = ExpandedPanelOptions(); options.rowFields = fields
            let view = TaskRowView(presentation: row, group: nil, now: now, enabled: true, accent: .blue, options: options) {}
            let lines = view.textLines(measuring: false).frame(width: 110).fixedSize(horizontal: false, vertical: true)
            let image = try XCTUnwrap(ImageRenderer(content: lines).cgImage)
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        // A mandatory source wider than line two still leaves time on line one.
        let crowdedStatus = try render([.source, .turnTime, .model])
        XCTAssertEqual(crowdedStatus, try render([.source, .turnTime]))
        XCTAssertNotEqual(crowdedStatus, try render([.source]))
        // The rate placeholder crowds time off line one. The short model fits on line two.
        let crowdedRate = try render([.rate, .turnTime, .model])
        XCTAssertEqual(crowdedRate, try render([.rate, .model]))
        XCTAssertNotEqual(crowdedRate, try render([.rate]))
    }

    func testMinimumWidthOfAnEmptyLine() {
        let host = NSHostingView(rootView: MinimumLineWidth { EmptyView() })
        XCTAssertEqual(host.fittingSize, .zero)
        host.layoutSubtreeIfNeeded()
    }

    func testSettingsPageSavesOnlyRealEditsAndSketchesPairedQuotas() {
        var saved: ExpandedPanelLayout?
        var selection: ExpandedPanelSelection?
        func pane(_ providers: [AgentProvider], options: ExpandedPanelOptions = .init()) -> SettingsExpandedPanelPane {
            SettingsExpandedPanelPane(expandMode: .constant(.hover), savedLayout: Binding(get: { saved }, set: { saved = $0 }), options: .constant(options),
                selection: Binding(get: { selection }, set: { selection = $0 }), quotaStyle: .constant(.split),
                retention: .constant(30), showsAppButtons: .constant(true), providers: providers, deepseekDetailed: true,
                openGeneral: {}, openDeepSeek: {})
        }
        let none = pane([])
        XCTAssertEqual(none.selected, .block(.tasks))
        none.toggle(.tasks)
        XCTAssertNil(saved, "Removing the last block is refused and saves nothing")

        let all = pane([.codex, .claude, .deepseek])
        all.toggle(.claude)
        // Services that are off keep their hidden places, so turning one on later shows its block.
        XCTAssertEqual(saved?.blocks, [.tasks, .codex, .deepseek, .workbuddy, .workbuddyAI],
                       "The first edit saves the blocks as they then appeared")
        all.shift(.deepseek, by: -1)
        XCTAssertEqual(saved?.blocks, [.tasks, .deepseek, .codex, .workbuddy, .workbuddyAI])
        all.move(.tasks, before: nil)
        XCTAssertEqual(saved?.blocks, [.deepseek, .codex, .workbuddy, .workbuddyAI, .tasks])
        all.toggle(.claude)
        XCTAssertEqual(saved?.blocks, [.claude, .deepseek, .codex, .workbuddy, .workbuddyAI, .tasks],
                       "An added block goes before the first that usually follows it")

        XCTAssertEqual(SettingsExpandedPanelPane.rows([.tasks, .codex, .claude, .deepseekSpend, .deepseek], arrange: .pair),
                       [[.tasks], [.codex, .claude], [.deepseekSpend], [.deepseek]])
        XCTAssertEqual(SettingsExpandedPanelPane.rows([.codex, .claude], arrange: .stack), [[.codex], [.claude]])

        var choices = ExpandedPanelOptions()
        choices.pageSize = 5; choices.rowStyle = .oneLine; choices.setPeriods(.weekly, for: .claude)
        XCTAssertEqual(SettingsExpandedPanelPane.summary(.tasks, options: choices),
                       L10n.text("main.panel.page_size") + " 5 · " + L10n.text("main.panel.row_one"))
        XCTAssertEqual(SettingsExpandedPanelPane.summary(.claude, options: choices), L10n.text("main.panel.periods_weekly"),
                       "Each quota's outline line names its own periods")
        XCTAssertEqual(SettingsExpandedPanelPane.summary(.codex, options: choices), L10n.text("main.panel.periods_both"))

        saved = ExpandedPanelLayout(blocks: [.tasks, .codex])
        selection = .block(.claude)
        XCTAssertEqual(pane([.codex]).selected, .block(.tasks), "A block whose service is off and not placed is not described")
        selection = .actions
        XCTAssertEqual(pane([.codex]).selected, .actions)
    }

    func testExpandedPanelPageSitsAfterTheCollapsedBar() {
        XCTAssertEqual(SettingsPane.groups(services: [])[2], [.appearance, .collapsedBar, .expandedPanel, .notifications, .general])
        XCTAssertEqual(SettingsPane(stored: "expandedPanel"), .expandedPanel)
        XCTAssertFalse(SettingsPane.expandedPanel.searchTerms.isEmpty)
    }
}
