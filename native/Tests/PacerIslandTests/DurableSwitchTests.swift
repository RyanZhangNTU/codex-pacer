import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerMacSupport
import PacerTestSupport

@MainActor
final class DurableSwitchTests: XCTestCase {
    func testUpgradeKeepsDotOnlyWhereItReportedAndDecidesOnce() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-dot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        func profile() throws -> UserDefaults {
            let domain = testDefaultsName("DurableSwitchTests")
            addTeardownBlock { removeTestDefaults(domain) }
            return try XCTUnwrap(UserDefaults(suiteName: domain))
        }
        // A new or never-used profile starts off; the decision is stored so it is made only once.
        let fresh = try profile()
        IslandModel.migrateDurableSwitch(in: fresh, home: home)
        XCTAssertEqual(fresh.object(forKey: IslandModel.monitorsDurableKey) as? Bool, false)

        let receipts = home.appendingPathComponent(DurableUsageEvidence.receiptsPath)
        try FileManager.default.createDirectory(at: receipts.deletingLastPathComponent(), withIntermediateDirectories: true)
        let thread = "019a0000-0000-7000-8000-000000000001", turn = "019a0000-0000-7000-8000-000000000002"
        try Data(#"{"\#(thread):\#(turn)":{"threadID":"\#(thread)","turnID":"\#(turn)","callID":"call","percent":40,"at":800000000}}"#.utf8)
            .write(to: receipts)
        IslandModel.migrateDurableSwitch(in: fresh, home: home)
        XCTAssertEqual(fresh.object(forKey: IslandModel.monitorsDurableKey) as? Bool, false, "A stored choice is never revisited")

        let upgraded = try profile()
        IslandModel.migrateDurableSwitch(in: upgraded, home: home)
        XCTAssertEqual(upgraded.object(forKey: IslandModel.monitorsDurableKey) as? Bool, true, "A profile whose Dot tasks reported keeps Dot")
    }
}
