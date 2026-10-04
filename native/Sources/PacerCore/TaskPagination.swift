import Foundation

/// Task pages keep a fixed row capacity so the account section does not move.
public struct TaskPagination: Equatable {
    public let itemCount: Int
    public let pageSize: Int

    public init(itemCount: Int, pageSize: Int = 3) {
        self.itemCount = max(0, itemCount)
        self.pageSize = max(1, pageSize)
    }

    public var pageCount: Int { max(1, (itemCount + pageSize - 1) / pageSize) }
    public var isPaginated: Bool { itemCount > pageSize }
    public var rowCapacity: Int { min(itemCount, pageSize) }
    public func clampedPage(_ page: Int) -> Int { min(max(0, page), pageCount - 1) }

    public func range(on page: Int) -> Range<Int> {
        let start = clampedPage(page) * pageSize
        return start..<min(itemCount, start + pageSize)
    }
}
