import XCTest
@testable import PacerCore

final class DeepSeekConnectionPresentationTests: XCTestCase {
    func testDialStatusKeepsConnectionRecoverySeparateFromTransientReadErrors() throws {
        for refreshing in [false, true] {
            XCTAssertNil(DeepSeekBalanceStatusPresentation(error: nil, refreshing: refreshing))
            for error in [DeepSeekBalanceError.signedOut, .missingKey, .invalidKey, .challenge, .unsupportedCurrency, .invalidReply, .connectionFailed, .unavailable] {
                let status = try XCTUnwrap(DeepSeekBalanceStatusPresentation(error: error, refreshing: refreshing))
                XCTAssertEqual(status.message, error.errorDescription)
                if [.signedOut, .missingKey, .invalidKey, .challenge].contains(error) {
                    XCTAssertEqual(status.tone, .secondary); XCTAssertTrue(status.actions.isEmpty)
                } else {
                    XCTAssertEqual(status.tone, .attention); XCTAssertEqual(status.actions.map(\.kind), [.retry, .settings])
                    XCTAssertEqual(status.actions[0].enabled, !refreshing); XCTAssertTrue(status.actions[1].enabled)
                    XCTAssertEqual(status.actions[0].title, L10n.text(refreshing ? "common.retrying" : "common.retry"))
                }
                let restored = try JSONDecoder().decode(DeepSeekBalanceStatusPresentation.self, from: JSONEncoder().encode(status))
                XCTAssertEqual(restored, status)
            }
        }
    }
    func testSourceChoicesAndKnownBalancesRetainTheOriginalConnectionSemantics() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for source in DeepSeekBalanceSelection.allCases {
            for detected in [nil, .account, .apiKey] as [DeepSeekAuthMode?] {
                for age in [0.0, 10, 60, 601] {
                    let balance = DeepSeekBalance(total: 86.4, capturedAt: now.addingTimeInterval(-age), source: .apiKey)
                    let value = DeepSeekConnectionPresentation(source: source, detected: detected, balance: balance,
                        error: .connectionFailed, refreshing: true, now: now)
                    XCTAssertTrue(value.connected)
                    XCTAssertEqual(value.color, "green", "The last known balance takes precedence over a transient read failure")
                    XCTAssertEqual(value.keyEditor, source.mode(detected: detected) == .apiKey)
                    XCTAssertEqual(value.showDetection, source != .automatic)
                    XCTAssertEqual(value.action, value.keyEditor ? "refresh" : nil)
                }
            }
        }
    }
    func testMissingOrRejectedKeysAndAccountConnectionNeverClaimAKnownBalance() throws {
        let now = Date()
        for error in [DeepSeekBalanceError.missingKey, .invalidKey, .signedOut, .challenge] {
            let value = DeepSeekConnectionPresentation(source: .apiKey, detected: .account,
                balance: DeepSeekBalance(total: 10, capturedAt: now, source: .apiKey), error: error, refreshing: false, now: now)
            XCTAssertFalse(value.connected); XCTAssertEqual(value.color, "orange"); XCTAssertEqual(value.action, "refresh")
        }
        let checking = DeepSeekConnectionPresentation(source: .web, detected: nil, balance: nil, error: nil, refreshing: true, now: now)
        XCTAssertFalse(checking.connected); XCTAssertEqual(checking.color, "secondary"); XCTAssertEqual(checking.action, "signIn")
        let idle = DeepSeekConnectionPresentation(source: .automatic, detected: nil, balance: nil, error: nil, refreshing: false, now: now)
        XCTAssertTrue(idle.showDetection); XCTAssertFalse(idle.keyEditor)
        let text = String(decoding: try JSONEncoder().encode(idle), as: UTF8.self)
        XCTAssertFalse(text.contains("apiKey=")); XCTAssertFalse(text.contains("accountId"))
    }
}
