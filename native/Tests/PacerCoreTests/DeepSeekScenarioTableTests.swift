import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekScenarioTableTests: XCTestCase {
    private typealias F = PresentationScenarioFixtures
    private struct Age: Decodable { let age: Double, freshness: F.Text }
    private struct Amount: Decodable {
        let total: Double, amount: String, whole: String, cents: String, state: String, balance: String, subtitle: String, segment: String
    }
    private struct DialTable: Decodable { let ages: [Age], amounts: [Amount] }
    func testEveryOriginalDialAgeAndAmountPairHasFixedMoneyFreshnessAndTones() throws {
        let table = try F.table("deepseek-dial", as: DialTable.self)
        XCTAssertEqual(table.ages.map(\.age), [0, 30, 301, 601, 3600])
        XCTAssertEqual(table.amounts.map(\.total), [0, 2, 86.4, 1250])
        var checked = 0
        for age in table.ages {
            for amount in table.amounts {
                let wallet = F.demoWallet(budget: false, total: amount.total, age: age.age)
                let value = DeepSeekDialPresentation(wallet: wallet, at: F.now)
                let label = "age=\(age.age), total=\(amount.total)"
                XCTAssertEqual(DeepSeekDialPresentation.amount(amount.total), amount.amount, label)
                XCTAssertEqual(value.balanceWhole, amount.whole, label); XCTAssertEqual(value.balanceCents, amount.cents, label)
                XCTAssertEqual(value.freshness, age.freshness.render(), label)
                XCTAssertEqual(String(describing: wallet.state), age.age > 600 ? "stale" : amount.state, label)
                XCTAssertEqual(value.dimmedFace, age.age > 600, label); XCTAssertEqual(value.staleCaption, age.age > 600, label)
                XCTAssertEqual(value.balanceTone.rawValue, age.age > 600 ? "secondary" : amount.balance, label)
                XCTAssertEqual(value.subtitleTone.rawValue, age.age > 600 ? "tertiary" : amount.subtitle, label)
                XCTAssertEqual(value.segmentTone.rawValue, age.age > 600 ? "staleSegment" : amount.segment, label)
                if age.age > 600 { XCTAssertEqual(value.subtitle, age.freshness.render(), label) }
                else if amount.total == 0 { XCTAssertEqual(value.subtitle, L10n.text("deepseek.wallet.exhausted"), label) }
                XCTAssertTrue(value.help.contains(age.freshness.render()), label)
                XCTAssertNil(value.connectTitle, label)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 20)
    }

    private struct Mode: Decodable {
        let detected: String?, source: DeepSeekBalanceSelection, effective: String?, keyEditor: Bool, showDetection: Bool
        let title: String, detectedKey: String
        let action: DeepSeekConnectionPresentation.Action?, rejectedAction: DeepSeekConnectionPresentation.Action
    }
    private struct ConnectionTable: Decodable { let modes: [Mode], ages: [Age] }
    func testEveryProfileSourceAndAgePairKeepsKnownBalancesAndRejectsInvalidConnections() throws {
        let table = try F.table("deepseek-connection", as: ConnectionTable.self)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-connection-table-" + UUID().uuidString)
        let profile = home.appendingPathComponent("profiles/desktop/cordis.patch.yml")
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let profiles: [String: String] = ["account": "deepseek-account", "apiKey": "deepseek-official"]
        var checked = 0
        for mode in table.modes {
            if let detected = mode.detected {
                try Data("provider: \(try XCTUnwrap(profiles[detected]))\n".utf8).write(to: profile)
            } else if FileManager.default.fileExists(atPath: profile.path) { try FileManager.default.removeItem(at: profile) }
            let detected = DeepSeekAuthMode.detect(home: home)
            XCTAssertEqual(detected?.rawValue, mode.detected)
            XCTAssertEqual(mode.source.mode(detected: detected)?.rawValue, mode.effective)
            for age in table.ages {
                let balance = DeepSeekBalance(total: 86.4, capturedAt: F.now.addingTimeInterval(-age.age), source: .apiKey)
                let value = DeepSeekConnectionPresentation(source: mode.source, detected: detected, balance: balance,
                    error: .connectionFailed, refreshing: true, now: F.now)
                XCTAssertTrue(value.connected); XCTAssertEqual(value.text, L10n.text("deepseek.connected", age.freshness.render()))
                XCTAssertEqual(value.color, .green); XCTAssertEqual(value.title, L10n.text(mode.title))
                XCTAssertEqual(value.keyEditor, mode.keyEditor); XCTAssertEqual(value.showDetection, mode.showDetection)
                XCTAssertEqual(value.action, mode.action)
                let found = L10n.text(mode.detectedKey)
                XCTAssertEqual(value.detectedText, mode.source == .automatic ? found : L10n.text("deepseek.detected.overridden", found))
                checked += 1
            }
            let rejected = DeepSeekConnectionPresentation(source: mode.source, detected: detected,
                balance: .init(total: 86.4, capturedAt: F.now.addingTimeInterval(-601), source: .apiKey), error: .invalidKey, refreshing: false, now: F.now)
            XCTAssertFalse(rejected.connected); XCTAssertEqual(rejected.color, .orange); XCTAssertEqual(rejected.action, mode.rejectedAction)
        }
        XCTAssertEqual(checked, 54)
    }
}
