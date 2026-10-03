import XCTest
@testable import PacerCore

final class IslandInstanceLockTests: XCTestCase {
    func testOnlyOneCopyOwnsTheLockAndAnExitAllowsRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("instance.lock")
        var first: IslandInstanceLock? = try IslandInstanceLock(at: file)
        XCTAssertTrue(first?.acquired == true)
        let duplicate = try IslandInstanceLock(at: file)
        XCTAssertFalse(duplicate.acquired)
        first = nil
        let relaunched = try IslandInstanceLock(at: file)
        XCTAssertTrue(relaunched.acquired)
        XCTAssertFalse(try IslandInstanceLock(at: file).acquired)
    }
}
