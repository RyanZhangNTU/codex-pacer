import Foundation
import XCTest
@testable import PacerCore

final class ClaudeQuotaPortableTests: XCTestCase {
    func testJSONBooleanNullAndStringsCannotBecomeUsagePercentages() throws {
        for value in ["true", "false", "null", "\"1\""] {
            let data = Data(("{\"five_hour\":{\"utilization\":" + value + "}}").utf8)
            XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeUsage(data)) { XCTAssertEqual($0 as? ClaudeQuotaError, .unavailable) }
        }
        for value in ["0", "1", "0.0", "1.0", "42.5", "100", "101", "1e2", "2147483648"] {
            let data = Data(("{\"five_hour\":{\"utilization\":" + value + "}}").utf8)
            let snapshot = try ClaudeQuotaDecoder.decodeUsage(data)
            XCTAssertEqual(snapshot.buckets.first?.windows.first?.usedPercent, Double(value))
        }
    }
    func testNativeDecoderKeepsIndependentBucketsTrueResetDatesAndUnknownValues() throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"{"five_hour":{"utilization":24,"resets_at":"2027-01-15T13:00:00Z"},"seven_day":{"utilization":true,"resets_at":1800604800},"seven_day_sonnet":{"utilization":55},"seven_day_opus":{"utilization":65},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Synthetic Model"}},"percent":72,"resets_at":1800604800}]}"#.utf8)
        let snapshot = try ClaudeQuotaDecoder.decodeUsage(data, capturedAt: time, accountScope: "synthetic-scope", plan: "synthetic-plan")
        XCTAssertEqual(snapshot.capturedAt, time); XCTAssertEqual(snapshot.accountScope, "synthetic-scope")
        XCTAssertEqual(snapshot.buckets.count, 4)
        let periods = try XCTUnwrap(snapshot.buckets.first).windows
        XCTAssertEqual(periods.map(\.durationMinutes), [300, 10080])
        XCTAssertEqual(periods.first?.usedPercent, 24); XCTAssertNil(periods.last?.usedPercent)
        XCTAssertEqual(periods.last?.resetsAt?.timeIntervalSince1970, 1800604800)
        XCTAssertNotNil(periods.first?.resetsAt)
        XCTAssertEqual(snapshot.buckets.last?.windows.first?.usedPercent, 72)
    }
}
