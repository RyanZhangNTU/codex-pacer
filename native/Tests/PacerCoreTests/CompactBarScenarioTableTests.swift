import Foundation
import XCTest
@testable import PacerCore

final class CompactBarScenarioTableTests: XCTestCase {
    private typealias F = PresentationScenarioFixtures
    private struct Choice: Decodable {
        let providers: [String], clock: Bool, walletWithGauge: String, walletWithoutGauge: String
    }
    private struct Module: Decodable {
        let mask: Int, providers: [String], available: [String]
        let withoutBudget: [Choice], withBudget: [Choice]
    }
    private struct Layout: Decodable { let gauge: Bool, separateClock: Bool }
    private struct Metric: Decodable {
        let metric: CompactBarPresentation.Metric, selection: String
        let quota: [String: String], time: [String: String], ring: [String: Double], normalized: [String: String]
    }
    private struct Entry: Decodable { let provider: String, text: String }
    private struct State: Decodable {
        let provider: String, kind: String, age: Double, failed: Bool, selection: String
        let metric: CompactBarPresentation.Metric
        let entries: [Entry], ring: Double?, dimmed: Bool, time: String, weeklyOnly: Bool, normalized: String
    }
    private struct Live: Decodable { let stage: Int, status: String, rate: String }
    private struct Table: Decodable {
        let modules: [Module], slots: [[CompactBarPresentation.RingChoice]], layouts: [Layout], metrics: [Metric], states: [State], live: [Live]
    }
    private func component(_ id: String, _ output: CompactBarPresentation.Output) throws -> CompactBarPresentation.Component {
        try XCTUnwrap(output.components.first { $0.id == id })
    }

    func testAllModuleBudgetSlotLayoutMetricAndWindowCombinations() throws {
        let table = try F.table("compact", as: Table.self)
        XCTAssertEqual(table.modules.map(\.mask), Array(0..<8))
        var checked = 0
        for row in table.modules {
            let providers = try row.providers.map { try XCTUnwrap(AgentProvider(rawValue: $0)) }
            let sources = try providers.filter { $0 != .deepseek }.map {
                CompactBarContext.Source(provider: $0, snapshot: try F.demoQuota($0), failed: false)
            }
            for budget in [false, true] {
                let context = CompactBarContext(activities: DemoScenario.tasks(stage: .thinking, at: F.now), requests: [], completions: [],
                    sources: sources, wallet: providers.contains(.deepseek) ? .init(F.demoWallet(budget: budget), preferred: .day) : nil, now: F.now)
                let choices = budget ? row.withBudget : row.withoutBudget
                for (slot, expected) in zip(table.slots, choices) {
                    for layoutRow in table.layouts {
                        var layout = CompactIslandLayout.standard
                        if !layoutRow.gauge { layout.hide(.quotaGauge) }
                        if layoutRow.separateClock { layout.move(.priceClock, to: .trailing) }
                        for metric in table.metrics {
                            let label = "mask=\(row.mask), budget=\(budget), slots=\(slot), gauge=\(layoutRow.gauge), clock=\(layoutRow.separateClock), \(metric.metric)/\(metric.selection)"
                            let output = try XCTUnwrap(CompactBarPresentation.project(.init(providers: providers,
                                options: .init(metric: metric.metric, codexWindow: metric.selection, claudeWindow: metric.selection, rings: slot),
                                context: context), layout: layout))
                            XCTAssertEqual(output.rings.map(\.provider.rawValue), expected.providers, label)
                            XCTAssertEqual(output.gaugeClock, expected.clock && !layoutRow.separateClock, label)
                            for ring in output.rings {
                                F.equal(ring.remaining, metric.ring[ring.provider.rawValue], label)
                                XCTAssertFalse(ring.dimmed, label)
                            }
                            let entries = try component("quota", output).entries
                            XCTAssertEqual(entries.map(\.provider.rawValue), row.providers, label)
                            let wallet = layoutRow.gauge ? expected.walletWithGauge : expected.walletWithoutGauge
                            for entry in entries {
                                let expectedText: String
                                switch entry.provider {
                                case .deepseek: expectedText = wallet
                                case .codex, .claude: expectedText = try XCTUnwrap(metric.quota[entry.provider.rawValue])
                                }
                                XCTAssertEqual(entry.text, expectedText, label)
                                let strip = entry.provider == .deepseek || row.providers.contains("deepseek")
                                    ? expectedText : String(expectedText.dropLast())
                                XCTAssertEqual(entry.stripText, strip, label)
                                XCTAssertFalse(entry.dimmed, label)
                            }
                            let times = try component("timeRemaining", output).entries
                            XCTAssertEqual(times.map(\.provider.rawValue), row.providers.filter { $0 != "deepseek" }, label)
                            for entry in times { XCTAssertEqual(entry.text, metric.time[entry.provider.rawValue], label) }
                            for window in output.windows {
                                XCTAssertEqual(window.weeklyOnly, window.provider == .codex, label)
                                XCTAssertEqual(window.selection, metric.normalized[window.provider.rawValue], label)
                            }
                            XCTAssertEqual(Set(output.components.filter(\.available).map(\.id)), Set(row.available), label)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 1440)
    }

    func testFailedStaleExpiredWeeklyOnlyAndLegacyWindowIDs() throws {
        let table = try F.table("compact", as: Table.self)
        XCTAssertEqual(table.states.count, 480)
        let otherClaude = try F.demoQuota(.claude)
        for row in table.states {
            let provider = try XCTUnwrap(AgentProvider(rawValue: row.provider))
            let five = QuotaWindow(id: "five", usedPercent: 80, durationMinutes: 300,
                resetsAt: F.now.addingTimeInterval(row.kind == "expired" ? 0 : row.kind == "past" ? -1 : 9000))
            let week = QuotaWindow(id: "week", usedPercent: 25, durationMinutes: 10080,
                resetsAt: F.now.addingTimeInterval(row.kind == "expired" ? 0 : row.kind == "past" ? -1 : 300000))
            let inputs: [String: [QuotaWindow]] = ["none": [], "five": [five], "week": [week], "both": [five, week],
                "expired": [five, week], "past": [five, week]]
            let own = F.snapshot(provider, windows: try XCTUnwrap(inputs[row.kind]), age: row.age)
            let priorCodex = F.snapshot(.codex, windows: [
                .init(id: "five", usedPercent: 80, durationMinutes: 300, resetsAt: F.now.addingTimeInterval(9000)),
                .init(id: "week", usedPercent: 25, durationMinutes: 10080, resetsAt: F.now.addingTimeInterval(300000))], age: 301)
            let sources: [CompactBarContext.Source] = [
                .init(provider: .codex, snapshot: provider == .codex ? own : priorCodex, failed: provider == .codex ? row.failed : true),
                .init(provider: .claude, snapshot: provider == .claude ? own : otherClaude, failed: provider == .claude && row.failed)]
            let output = try XCTUnwrap(CompactBarPresentation.project(.init(providers: [.codex, .claude],
                options: .init(metric: row.metric, codexWindow: provider == .codex ? row.selection : "week",
                    claudeWindow: provider == .claude ? row.selection : "auto"),
                context: .init(activities: [], requests: [], completions: [], sources: sources, now: F.now))))
            let label = "\(row.provider)/\(row.kind)/\(row.age)/failed=\(row.failed)/\(row.selection)/\(row.metric)"
            let entries = try component("quota", output).entries
            XCTAssertEqual(entries.map(\.provider.rawValue), row.entries.map(\.provider), label)
            XCTAssertEqual(entries.map(\.text), row.entries.map(\.text), label)
            XCTAssertEqual(entries.map(\.stripText), row.entries.map { $0.text == "—" ? "—" : String($0.text.dropLast()) }, label)
            let ring = try XCTUnwrap(output.rings.first { $0.provider == provider })
            F.equal(ring.remaining, row.ring, label); XCTAssertEqual(ring.dimmed, row.dimmed, label)
            let window = try XCTUnwrap(output.windows.first { $0.provider == provider })
            XCTAssertEqual(window.weeklyOnly, row.weeklyOnly, label); XCTAssertEqual(window.selection, row.normalized, label)
            XCTAssertEqual(try component("timeRemaining", output).entries.first { $0.provider == provider }?.text, row.time, label)
        }
    }

    func testAllDemoStagesAttentionAttachmentAndStripStates() throws {
        let table = try F.table("compact", as: Table.self)
        let layout = CompactIslandLayout(leading: [.activity, .status, .tps, .firstOutput])
        var checked = 0
        for row in table.live {
            let activities = DemoScenario.tasks(stage: try XCTUnwrap(DemoTaskStage(rawValue: row.stage)), at: F.now)
            for attention in [false, true] {
                let requests: [PendingAttentionRequest] = attention ? [.init(id: "approval", threadID: "00000000-0000-4000-8000-000000000001",
                    sourceHostID: nil, sourceName: nil, kind: .approval, detectedAt: F.now)] : []
                let context = CompactBarContext(activities: activities, requests: requests, completions: [], sources: [], now: F.now)
                for attached in [false, true] {
                    for strip in [false, true] {
                        let output = try XCTUnwrap(CompactBarPresentation.project(.init(language: "en", providers: [.codex],
                            context: context, attached: attached, strip: strip), layout: layout))
                        XCTAssertEqual(try component("status", output).text, L10n.text(attention ? "attention.approval" : row.status, language: .english))
                        XCTAssertEqual(try component("tps", output).text, row.rate)
                        XCTAssertEqual(try component("tps", output).visible, !attached || !attention || strip)
                        XCTAssertEqual((output.leading + output.trailing).contains("status"), !strip)
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 32)
    }
}
