import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

final class PinnedPresentationTests: XCTestCase {
    func testIdlePinsRemainWithoutAffectingActiveCounters() {
        var presentation = EnginePresentation(activities: [], requests: [], inbox: CompletionInbox(), hideProjects: false, at: Date())
        let pins = Dictionary(uniqueKeysWithValues: (1...20).map { (String(format: "019a0000-0000-7000-8000-%012d", $0), "Pinned \($0)") })
        presentation.includePinned(pins)
        XCTAssertEqual(presentation.rows.count, 20)
        XCTAssertEqual(presentation.header.activeCount, 0)
        XCTAssertTrue(presentation.rows.allSatisfy { $0.phase == "idle" && !$0.unread && $0.tokensPerSecond == nil })
        presentation.includePinned(pins)
        XCTAssertEqual(presentation.rows.count, 20)
    }
}
