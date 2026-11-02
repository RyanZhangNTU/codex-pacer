import Foundation
import XCTest
@testable import PacerCore

final class QuotaCycleChartPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var cycle: QuotaCycle {
        .init(id: "private-window-id", bucketName: "private-bucket", startedAt: start, resetsAt: start.addingTimeInterval(604800),
            points: (0..<300).map { .init(timestamp: start.addingTimeInterval(Double($0) * 1800), remaining: 100 - Double($0) / 4) })
    }
    private func data() -> QuotaChartData {
        let credits = (0..<8).map { number in QuotaResetCredit(id: "private-credit-\(number)", status: "available",
            expiresAt: start.addingTimeInterval(Double(number) * 72000 + 1), grantedAt: start) }
        return .init(cycle: cycle, resetCredits: .init(availableCount: 12, credits: credits), now: start)
    }
    func testProjectionPreservesOriginalSamplesBoundsAndLocalizedLabelsWithoutIdentifiers() throws {
        let raw = data()
        for language in AppLanguage.allCases {
            let value = QuotaCycleChartPresentation(data: raw, language: language)
            XCTAssertEqual(value.points.count, 240)
            XCTAssertEqual(value.points.first?.timestamp, raw.points.first?.timestamp.timeIntervalSince1970)
            XCTAssertEqual(value.points.last?.remaining, raw.points.last?.remaining)
            XCTAssertEqual(value.startedAt, start.timeIntervalSince1970)
            XCTAssertEqual(value.resetsAt, cycle.resetsAt.timeIntervalSince1970)
            XCTAssertTrue(value.hasPartialExpiryDetails)
            XCTAssertFalse(value.accessibilityLabel.contains("chart."))
            let bytes = try JSONEncoder().encode(value), text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("private-")); XCTAssertFalse(text.contains("accountScope")); XCTAssertFalse(text.contains("grantedAt"))
            XCTAssertEqual(try JSONDecoder().decode(QuotaCycleChartPresentation.self, from: bytes), value)
        }
    }
    func testNativeMarkerMergingRetainsAllCountsAndDoesNotOverlap() {
        let value = QuotaCycleChartPresentation(data: data())
        for width in [43.0, 120, 340, 475, 900] {
            let markers = value.markers(plotWidth: width)
            XCTAssertEqual(markers.reduce(0) { $0 + $1.count }, 8)
            XCTAssertTrue(markers.allSatisfy { $0.x >= $0.width / 2 && $0.x + $0.width / 2 <= width })
            for pair in zip(markers, markers.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1.x - pair.0.x + 0.000001, (pair.0.width + pair.1.width) / 2 + 6)
            }
        }
        XCTAssertEqual(value.markers(plotWidth: 43).count, 1)
        XCTAssertNotNil(value.markers(plotWidth: 43).first?.moreText)
        XCTAssertTrue(value.markers(plotWidth: .nan).isEmpty)
        XCTAssertTrue(value.markers(plotWidth: 0).isEmpty)
    }
    func testExpiryBoundaryChangesMarkersWithoutReplacingReadings() {
        let raw = data(), after = QuotaChartData(cycle: cycle, resetCredits: .init(availableCount: 1, credits: [
            .init(id: "private-credit", status: "available", expiresAt: start.addingTimeInterval(1), grantedAt: start)]), now: start.addingTimeInterval(1))
        let before = QuotaCycleChartPresentation(data: raw), value = QuotaCycleChartPresentation(data: after)
        XCTAssertEqual(before.points, value.points); XCTAssertTrue(value.expiries.isEmpty)
    }
}
