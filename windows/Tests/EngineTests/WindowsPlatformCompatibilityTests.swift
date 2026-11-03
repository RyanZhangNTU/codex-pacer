import Foundation
import XCTest
import PacerCore
@testable import PacerEngineSupport

final class WindowsPlatformCompatibilityTests: XCTestCase {
    func testMinimumWindowsBuildAndLaterVersions() {
        XCTAssertEqual(WindowsPlatformCompatibility.minimumBuild, 19041)
        XCTAssertFalse(WindowsPlatformCompatibility.supports(.init(majorVersion: 6, minorVersion: 3, patchVersion: 19041)))
        XCTAssertFalse(WindowsPlatformCompatibility.supports(.init(majorVersion: 10, minorVersion: 0, patchVersion: 19040)))
        for build in [19041, 19045, 22000, 22621, 26200] {
            XCTAssertTrue(WindowsPlatformCompatibility.supports(.init(majorVersion: 10, minorVersion: 0, patchVersion: build)))
        }
        XCTAssertTrue(WindowsPlatformCompatibility.supports(ProcessInfo.processInfo.operatingSystemVersion), "The Foundation version used at engine startup must recognize this supported Windows host")
    }
}
