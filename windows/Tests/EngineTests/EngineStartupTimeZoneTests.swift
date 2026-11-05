import Foundation
import XCTest
@testable import PacerEngineSupport

final class EngineStartupTimeZoneTests: XCTestCase {
    func testHostZoneReplacesFoundationsGMTWithAnIANANameOrOffset() throws {
        let winter = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15
        let shanghai = try XCTUnwrap(EngineStartupTimeZone.parse(["PacerEngine.exe", "--language", "zh-Hans", "--time-zone", "Asia/Shanghai"]))
        XCTAssertEqual(shanghai.identifier, "Asia/Shanghai"); XCTAssertEqual(shanghai.secondsFromGMT(for: winter), 8 * 3600)
        let newYork = try XCTUnwrap(EngineStartupTimeZone.parse(["--time-zone", "America/New_York"]))
        XCTAssertEqual(newYork.secondsFromGMT(for: winter), -5 * 3600, "A named zone keeps its own DST rules")
        let offset = try XCTUnwrap(EngineStartupTimeZone.parse(["--time-zone-offset", "20700"]))
        XCTAssertEqual(offset.secondsFromGMT(for: winter), 20700, "A zone without an IANA name keeps the host's current offset")
        XCTAssertEqual(EngineStartupTimeZone.parse(["--time-zone", "Not/AZone", "--time-zone-offset", "3600"])?.secondsFromGMT(for: winter), 3600)
        for invalid in [[String](), ["--time-zone"], ["--time-zone", "Not/AZone"], ["--time-zone-offset", "999999"], ["--time-zone-offset", "PRIVATE"]] {
            XCTAssertNil(EngineStartupTimeZone.parse(invalid), "\(invalid)")
        }
    }
}
