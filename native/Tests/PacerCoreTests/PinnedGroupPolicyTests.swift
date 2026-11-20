import XCTest
@testable import PacerCore

final class PinnedGroupPolicyTests: XCTestCase {
    func testMembershipManualOrderAndActivityPromotion() throws {
        typealias Store = PinnedConversationGroups
        var groups = Store.move(["a", "b"], in: [], to: "one", name: "One")
        groups = Store.move(["c", "d"], in: groups, to: "two", name: "Two")
        groups[1].collapsed = true
        let rows = ["d", "c", "e", "b", "a"]
        let active = Store.sections(groups, ids: rows, running: ["d", "e"])
        XCTAssertEqual(active.map { $0.group?.id }, ["two", nil, "one"])
        XCTAssertEqual(active.map(\.members), [["d", "c"], ["e"], ["a", "b"]])
        XCTAssertEqual(active.first?.group?.collapsed, true)
        XCTAssertEqual(Store.sections(groups, ids: rows, running: []).map(\.members), [["a", "b"], ["c", "d"], ["e"]])
        let reordered = Store.dropGroup("two", in: groups, at: "one", after: false, merge: false)
        XCTAssertEqual(reordered.map(\.id), ["two", "one"])
        let merged = Store.dropGroup("one", in: reordered, at: "two", after: true, merge: true)
        XCTAssertEqual(merged.map(\.members), [["c", "d", "a", "b"]]); XCTAssertTrue(merged[0].collapsed)
        XCTAssertEqual(Store.move(["c"], in: merged, to: nil)[0].members, ["d", "a", "b"])
        XCTAssertEqual(Store.move(["a"], in: merged, to: "one"), merged, "A stale move cannot recreate a group that was merged away")
        var store = Store()
        let data = try XCTUnwrap(store.save(groups, profile: "fixture"))
        XCTAssertEqual(Store.read(data).profiles["fixture"], groups)
        for i in 1..<32 { XCTAssertNotNil(store.save(groups, profile: String(i))) }
        XCTAssertNil(store.save(groups, profile: "overflow"))
        XCTAssertEqual(store.profiles["fixture"], groups)
    }
}
