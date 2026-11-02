import Foundation
import XCTest
@testable import PacerCore

final class QuotaDashboardScenarioTableTests: XCTestCase {
    private typealias F = PresentationScenarioFixtures
    private typealias P = QuotaDashboardPresentation
    private struct ReadingRow: Decodable {
        let name: String, provider: String, bucket: String?, windows: [F.Window], age: Double, failed: Bool, period: String
        let availability: String, window: String?, remaining: Double?, time: Double?, pace: Double?
        let verdict: P.Verdict?
        let pressing: Bool, value: String, timeText: String, reset: Double?
        let freshness: F.Text, countdown: F.Text, projection: F.Text?, inline: F.Text?, warns: Bool, helpTokens: [String]
    }
    func testEveryReadingCandidatePeriodProviderAndFailureHasFixedExpectedFields() throws {
        let rows = try F.table("quota-readings", as: [ReadingRow].self)
        XCTAssertEqual(rows.count, 88)
        for row in rows {
            let provider = try XCTUnwrap(AgentProvider(rawValue: row.provider))
            let period = try XCTUnwrap(P.Period(rawValue: row.period))
            let snapshot = row.name == "unread" ? nil : F.snapshot(provider, windows: row.windows.map(\.value), age: row.age, bucket: row.bucket)
            let source = provider == .codex && snapshot != nil ? L10n.text("quota.source_codex") : nil
            let reading = P.Reading(provider: provider, period: period, snapshot: snapshot, failed: row.failed,
                sourceText: source, now: F.now)
            let label = "\(row.provider)/\(row.name)/\(row.period)/failed=\(row.failed)"
            XCTAssertEqual(reading.availability.rawValue, row.availability, label)
            XCTAssertEqual(reading.windowID, row.window, label); XCTAssertEqual(reading.bucketName, row.bucket, label)
            F.equal(reading.remainingPercent, row.remaining, label); F.equal(reading.remainingTimePercent, row.time, label)
            F.equal(reading.pacePercent, row.pace, label)
            XCTAssertEqual(reading.valueText, row.value, label); XCTAssertEqual(reading.timeText, row.timeText, label)
            XCTAssertEqual(reading.verdict, row.verdict, label); XCTAssertEqual(reading.pressing, row.pressing, label)
            XCTAssertEqual(reading.paceText, row.pace.map { "\(Int($0.rounded()))%" } ?? "—", label)
            XCTAssertEqual(reading.countdown, row.countdown.render(), label)
            XCTAssertEqual(reading.freshnessText, row.freshness.render(), label); XCTAssertEqual(reading.sourceText, source, label)
            let reset = row.reset.map { L10n.text("quota.reset_date", L10n.date(F.now.addingTimeInterval($0))) } ?? L10n.text("quota.reset_unknown")
            let moment = row.reset.map { L10n.moment(F.now.addingTimeInterval($0), relativeTo: F.now) }
            XCTAssertEqual(reading.resetDate, reset, label); XCTAssertEqual(reading.resetMoment, moment, label)
            XCTAssertEqual(reading.resetAtText, moment.map { L10n.text("dashboard.reset_at", $0) } ?? L10n.text("quota.reset_unknown"), label)
            let substitutions = ["@projectionDuration": L10n.text("dashboard.countdown_minutes", 6)]
            XCTAssertEqual(reading.projectionText, row.projection?.render(substitutions: substitutions), label)
            XCTAssertEqual(reading.projectionInline, row.inline?.render(substitutions: substitutions), label)
            XCTAssertEqual(reading.projectionWarns, row.warns, label); XCTAssertFalse(reading.projectionEarly, label)
            let periodName = row.period == "5h" ? L10n.text("quota.hours", 5) : L10n.text("quota.days", 7)
            let verdict = row.verdict?.label
            let tokens = ["rings": L10n.text("dashboard.rings_help"), "bucket": row.bucket ?? "",
                "missing": L10n.text("dashboard.period_unavailable", periodName),
                "time": L10n.text("dashboard.time_remaining", row.timeText), "reset": reset,
                "verdict": verdict ?? "", "freshness": row.freshness.render()]
            XCTAssertEqual(reading.splitHelp, try row.helpTokens.map { try XCTUnwrap(tokens[$0]) }.joined(separator: "\n"), label)
            let name = (row.provider == "codex" ? "Codex" : "Claude") + (row.bucket.map { " " + $0 } ?? "")
            let summary = ([reset] + [verdict].compactMap { $0 } + [row.freshness.render()]).joined(separator: ". ")
            XCTAssertEqual(reading.accessibilityLabel, L10n.text("dashboard.rings_accessibility", name, periodName,
                row.remaining == nil ? L10n.text("common.unknown") : row.value + "%",
                row.time == nil ? L10n.text("common.unknown") : row.timeText, summary), label)
            if row.availability == "proOnly" {
                XCTAssertEqual(reading.classicAccessibilityLabel, name + ", " + periodName + ". " + L10n.text("dashboard.pro_help"), label)
            } else { XCTAssertEqual(reading.classicAccessibilityLabel, reading.accessibilityLabel, label) }
        }
    }

    private struct Module: Decodable {
        let providers: [AgentProvider], split: [AgentProvider], classicProviders: [AgentProvider], classicPeriods: [String], identifies: Bool
    }
    private struct Policy: Decodable { let mask: Int, bucket: String, providers: [AgentProvider], style: P.Style, legacy: Bool }
    private struct LayoutTable: Decodable { let modules: [Module], policies: [Policy] }
    func testEveryModuleCombinationPreservesBothSlotLayoutsAndDuplicateInputs() throws {
        let table = try F.table("quota-layout", as: LayoutTable.self)
        XCTAssertEqual(table.modules.count, 8)
        for row in table.modules {
            let inputs = Array(row.providers.reversed()) + row.providers
            let classic = P.slots(providers: inputs, style: .classic)
            XCTAssertEqual(classic.map(\.provider), row.classicProviders)
            XCTAssertEqual(classic.map { $0.period.rawValue }, row.classicPeriods)
            XCTAssertEqual(classic.map(\.identifiesProvider), Array(repeating: row.identifies, count: row.classicProviders.count))
            XCTAssertEqual(classic.map(\.title), row.identifies ? row.classicProviders.map(\.displayName) : row.classicPeriods)
            XCTAssertEqual(P.slots(providers: inputs, style: .split).map(\.provider), row.split)
        }
    }
    func testAll512LegacyPolicyCombinationsUseTheFixedTruthTable() throws {
        let table = try F.table("quota-layout", as: LayoutTable.self)
        XCTAssertEqual(table.policies.count, 512)
        XCTAssertEqual(Set(table.policies.map { "\($0.mask)/\($0.bucket)/\($0.providers.map(\.rawValue).joined(separator: ","))/\($0.style.rawValue)" }).count, 512)
        let windows: [QuotaWindow] = [
            .init(id: "five", usedPercent: 20, durationMinutes: 300, resetsAt: F.now.addingTimeInterval(9000)),
            .init(id: "week", usedPercent: 30, durationMinutes: 10080, resetsAt: F.now.addingTimeInterval(300000)),
            .init(id: "custom", usedPercent: 40, durationMinutes: 480, resetsAt: nil),
            .init(id: "untyped", usedPercent: 50, durationMinutes: nil, resetsAt: nil)]
        for row in table.policies {
            let selected = windows.enumerated().filter { row.mask & (1 << $0.offset) != 0 }.map(\.element)
            let snapshot = F.snapshot(.codex, windows: selected, bucket: row.bucket)
            XCTAssertEqual(P.usesLegacyCodexDisplay(providers: row.providers, snapshot: snapshot, style: row.style), row.legacy,
                "mask=\(row.mask), \(row.bucket), \(row.providers), \(row.style)")
        }
        for style in P.Style.allCases { XCTAssertFalse(P.usesLegacyCodexDisplay(providers: [.codex], snapshot: nil, style: style)) }
    }

    private struct LegacyRow: Decodable {
        let weekly: Bool, expired: Bool, age: Double, selection: String?, failed: Bool, fresh: Bool
        let freshness: F.Text, remaining: [Double], pace: [Double?]
    }
    func testAllLegacyFreshnessSelectionsRetainTheirOwnWindowValues() throws {
        let rows = try F.table("legacy-freshness", as: [LegacyRow].self)
        XCTAssertEqual(rows.count, 64)
        for row in rows {
            var windows: [QuotaWindow] = [.init(id: "eight", usedPercent: 70, durationMinutes: 480,
                resetsAt: F.now.addingTimeInterval(row.expired ? 0 : 14400))]
            if row.weekly { windows.append(.init(id: "week", usedPercent: 20, durationMinutes: 10080, resetsAt: F.now.addingTimeInterval(302400))) }
            let value = P.Legacy(snapshot: F.snapshot(.codex, windows: windows, age: row.age), failed: row.failed,
                selectedWindowID: row.selection, now: F.now)
            let label = "weekly=\(row.weekly), expired=\(row.expired), age=\(row.age), selection=\(row.selection ?? "nil"), failed=\(row.failed)"
            XCTAssertEqual(value.fresh, row.fresh, label); XCTAssertEqual(value.freshnessText, row.freshness.render(), label)
            XCTAssertEqual(value.help, [L10n.text("quota.source_codex"), row.freshness.render()].joined(separator: "\n"), label)
            XCTAssertEqual(value.buckets.flatMap(\.windows).compactMap(\.remainingPercent), row.remaining, label)
            for (actual, expected) in zip(value.buckets.flatMap(\.windows), row.pace) { F.equal(actual.pacePercent, expected, label) }
        }
    }

    func testConnectionStatesForUnreadEmptyAndCustomWindowsWithBothFailureAndRefreshStates() throws {
        let custom = F.snapshot(.codex, windows: [.init(id: "custom", usedPercent: nil, durationMinutes: 480, resetsAt: nil)], bucket: "scoped")
        let empty = QuotaSnapshot(buckets: [], capturedAt: F.now, accountScope: nil, resetCredits: nil)
        let states: [(QuotaSnapshot?, QuotaConnectionPresentation.State)] = [(nil, .unavailable), (empty, .unavailable), (custom, .hidden)]
        for provider in [AgentProvider.codex, .claude] {
            for (snapshot, state) in states {
                for failed in [false, true] {
                    for refreshing in [false, true] {
                        let value = QuotaConnectionPresentation(provider: provider, snapshot: snapshot, error: failed ? "Synthetic failure" : nil, refreshing: refreshing)
                        if failed {
                            XCTAssertEqual(value.state, .error); XCTAssertEqual(value.message, "Synthetic failure")
                            XCTAssertEqual(value.actions.map(\.kind), [.retry, .settings]); XCTAssertEqual(value.actions[0].enabled, !refreshing)
                        } else if state == .hidden {
                            XCTAssertEqual(value.state, .hidden); XCTAssertNil(value.message); XCTAssertTrue(value.actions.isEmpty)
                        } else {
                            XCTAssertEqual(value.state, refreshing ? .loading : .unavailable)
                            XCTAssertEqual(value.message, refreshing ? L10n.text("quota.loading") : L10n.text("dashboard.provider_unavailable", provider.displayName))
                            XCTAssertEqual(value.actions.map(\.kind), [.settings])
                        }
                    }
                }
            }
        }
    }
}
