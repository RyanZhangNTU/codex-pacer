import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekDialPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func wallet(total: Double?, age: Double = 0) -> DeepSeekWallet {
        let balance = total.map { DeepSeekBalance(total: $0, granted: nil, tokenEstimation: nil, capturedAt: now.addingTimeInterval(-age), source: .web) }
        return DeepSeekWallet(balance: balance, connected: total != nil, ledger: DeepSeekSpendLedger(), now: now)
    }
    func testFreshLowExhaustedAndStaleTonesMatchOriginalDialRules() {
        let normal = DeepSeekDialPresentation(wallet: wallet(total: 80), at: now)
        XCTAssertEqual(normal.balanceTone, .primary); XCTAssertEqual(normal.subtitleTone, .secondary); XCTAssertEqual(normal.segmentTone, .provider)
        XCTAssertFalse(normal.dimmedFace); XCTAssertNil(normal.connectTitle)
        let low = DeepSeekDialPresentation(wallet: wallet(total: 2), at: now)
        XCTAssertEqual(low.balanceTone, .attention); XCTAssertEqual(low.subtitleTone, .attention)
        let exhausted = DeepSeekDialPresentation(wallet: wallet(total: 0), at: now)
        XCTAssertEqual(exhausted.balanceTone, .danger); XCTAssertEqual(exhausted.segmentTone, .danger)
        XCTAssertEqual(exhausted.subtitle, L10n.text("deepseek.wallet.exhausted"))
        let stale = DeepSeekDialPresentation(wallet: wallet(total: 80, age: 3600), at: now)
        XCTAssertTrue(stale.dimmedFace); XCTAssertTrue(stale.staleCaption); XCTAssertEqual(stale.balanceTone, .secondary)
        XCTAssertEqual(stale.subtitleTone, .tertiary); XCTAssertEqual(stale.segmentTone, .staleSegment)
        XCTAssertEqual(stale.subtitle, L10n.text("quota.minutes_ago", 60))
    }
    func testDisconnectedAndReadingRemainUnknownAndDoNotInventBalance() throws {
        let raw = wallet(total: nil), disconnected = DeepSeekDialPresentation(wallet: raw, at: now)
        XCTAssertEqual(disconnected.connectTitle, L10n.text("deepseek.sign_in"))
        XCTAssertEqual(disconnected.freshness, L10n.text("quota.not_read")); XCTAssertFalse(disconnected.dimmedFace)
        let reading = DeepSeekDialPresentation(wallet: raw, at: now, refreshing: true)
        XCTAssertNil(reading.connectTitle); XCTAssertEqual(reading.subtitle, L10n.text("deepseek.reading"))
        XCTAssertEqual(DeepSeekDialPresentation(wallet: raw, at: now, apiKey: true).connectTitle, L10n.text("deepseek.paste_key_short"))
        let bytes = try JSONEncoder().encode(disconnected), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("\"accountScope\":")); XCTAssertFalse(text.contains("\"apiKey\":"))
        XCTAssertEqual(try JSONDecoder().decode(DeepSeekDialPresentation.self, from: bytes), disconnected)
    }
    func testAmountsUseTheOriginalDetailPrecision() {
        XCTAssertEqual(DeepSeekDialPresentation.amount(3.125), "¥3.12")
        XCTAssertEqual(DeepSeekDialPresentation.amount(86.4), "¥86.40")
        XCTAssertEqual(DeepSeekDialPresentation.amount(1250), "¥1.2k")
        XCTAssertEqual(DeepSeekDialPresentation.amount(-1), "¥0.00")
    }
}
