import Foundation
import XCTest
@testable import PacerCore

final class CompactWarningPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(_ remaining: Double, stale: Bool = false, expired: Bool = false) -> QuotaSnapshot {
        .init(buckets: [.init(id: "codex", name: nil, plan: nil, windows: [
            .init(id: "5h", usedPercent: 100 - remaining, durationMinutes: 300, resetsAt: now.addingTimeInterval(expired ? -1 : 3600)),
            .init(id: "7d", usedPercent: 50, durationMinutes: 10080, resetsAt: now.addingTimeInterval(expired ? -1 : 86400))
        ], credits: nil)], capturedAt: now.addingTimeInterval(stale ? -301 : 0), resetCredits: nil)
    }
    func testFiveHourWarningUsesFreshProviderWindowAndStrictTwentyPercentBoundary() {
        func items(_ remaining: Double, stale: Bool = false, expired: Bool = false, failed: Bool = false) -> [CompactWarningPresentation.Item] {
            CompactWarningPresentation.items(enabled: [.codex], warnings: [.fiveHour, .quotaDelay], snapshots: [.codex: snapshot(remaining, stale: stale, expired: expired)],
                failed: failed ? [.codex] : [], now: now)
        }
        XCTAssertTrue(items(20).isEmpty)
        XCTAssertEqual(items(19.9).map(\.kind), [.fiveHour]); XCTAssertEqual(items(19.9).first?.solid, false)
        XCTAssertEqual(items(0).first?.solid, true)
        XCTAssertEqual(items(1, stale: true).map(\.kind), [.quotaDelay])
        XCTAssertEqual(items(1, expired: true).map(\.kind), [.quotaDelay])
        XCTAssertEqual(items(1, failed: true).map(\.kind), [.quotaDelay])
        XCTAssertTrue(CompactWarningPresentation.items(enabled: [.codex], warnings: [], snapshots: [.codex: snapshot(1, stale: true)], now: now).isEmpty)
    }
    func testWarningOrderAndWalletExhaustionCannotBeHiddenByItsLowBalanceSwitch() throws {
        let wallet = DeepSeekWallet(balance: .init(total: 0, capturedAt: now, source: .web), connected: true, ledger: .init(), now: now)
        let alert = try XCTUnwrap(DeepSeekAlertPresentation(wallet: wallet, lowBalance: false, spike: false, budget: false))
        let items = CompactWarningPresentation.items(enabled: [.codex, .deepseek], warnings: [.fiveHour, .ssh],
            snapshots: [.codex: snapshot(12)], sshIssue: true, wallet: alert, now: now)
        // Marks that need the user lead; the rest keep their provider order.
        XCTAssertEqual(items.map(\.kind), [.exhausted, .fiveHour, .ssh])
        XCTAssertEqual(items.first?.provider, "deepseek"); XCTAssertEqual(items.first?.label, "¥"); XCTAssertEqual(items.first?.solid, true)
        XCTAssertFalse(items.first?.help.isEmpty ?? true)
        // Every mark is text in the one capsule family.
        XCTAssertEqual(items.first { $0.kind == .ssh }?.label, "SSH"); XCTAssertNil(items.first { $0.kind == .ssh }?.symbol)
        let shown = CompactWarningPresentation.visible(items, limit: 2)
        XCTAssertEqual(shown.shown.map(\.kind), [.exhausted, .fiveHour]); XCTAssertEqual(shown.hidden, 1)
        XCTAssertEqual(CompactWarningPresentation.visible(items, limit: 0).hidden, 0)
        XCTAssertEqual(CompactWarningPresentation.visible(items, limit: 3).shown.count, 3)
    }
    func testWalletProjectionFollowsTheOriginalSingleAlertPriority() {
        var ledger = DeepSeekSpendLedger(); ledger.record(id: "synthetic", at: now.addingTimeInterval(-30), cost: 11)
        let wallet = DeepSeekWallet(balance: .init(total: 9, capturedAt: now, source: .web), connected: true, ledger: ledger,
            now: now, budgets: .init(daily: 10, weekly: 50), spikeLimit: 5)
        XCTAssertEqual(DeepSeekAlertPresentation(wallet: wallet, lowBalance: true, spike: true, budget: true)?.kind, .spike)
        XCTAssertEqual(DeepSeekAlertPresentation(wallet: wallet, lowBalance: true, spike: false, budget: true)?.kind, .overBudget)
        XCTAssertEqual(DeepSeekAlertPresentation(wallet: wallet, lowBalance: true, spike: false, budget: false)?.kind, .lowBalance)
        XCTAssertNil(DeepSeekAlertPresentation(wallet: wallet, lowBalance: false, spike: false, budget: false))
    }
}
