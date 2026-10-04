import XCTest
@testable import PacerCore

final class TaskPaginationTests: XCTestCase {
    func testEveryTaskRemainsReachableExactlyOnceAcrossPages() {
        for count in [0, 1, 2, 3, 4, 7, 8, 25] {
            let pages = TaskPagination(itemCount: count)
            let visited = (0..<pages.pageCount).flatMap { Array(pages.range(on: $0)) }
            XCTAssertEqual(visited, Array(0..<count))
        }
    }

    func testLastPageKeepsSameRowCapacityAndShrinkingListClampsPage() {
        let longList = TaskPagination(itemCount: 7)
        XCTAssertEqual(longList.range(on: 2), 6..<7)
        XCTAssertEqual(longList.rowCapacity, 3)
        let shortList = TaskPagination(itemCount: 2)
        XCTAssertEqual(shortList.clampedPage(2), 0)
        XCTAssertEqual(shortList.range(on: 2), 0..<2)
        XCTAssertFalse(shortList.isPaginated)
    }

    func testOutOfRangeNavigationDoesNotWrapOrLoseTasks() {
        let pages = TaskPagination(itemCount: 8)
        XCTAssertEqual(pages.range(on: -1), 0..<3)
        XCTAssertEqual(pages.range(on: 99), 6..<8)
        XCTAssertTrue(pages.isPaginated)
        XCTAssertEqual(TaskPagination(itemCount: -3, pageSize: 0).range(on: 0), 0..<0)
    }
}
