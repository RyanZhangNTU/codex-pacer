import XCTest
@testable import PacerCore

final class IslandMotionTests: XCTestCase {
    private let folded = CGRect(x: 550, y: 768, width: 300, height: 32)
    private let open = CGRect(x: 480, y: 240, width: 440, height: 560)

    func testShellKeepsTopAndCenterAnchoredWithoutOvershoot() {
        let motion = IslandMotion(from: folded, to: open, expansion: 0, content: 0, opening: true, start: 0)
        var previous = folded
        for tick in 0...60 {
            let sample = motion.sample(at: motion.duration * Double(tick) / 60)
            XCTAssertEqual(sample.frame.maxY, folded.maxY, accuracy: 0.000001)
            XCTAssertEqual(sample.frame.midX, folded.midX, accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(sample.frame.width, previous.width)
            XCTAssertGreaterThanOrEqual(sample.frame.height, previous.height)
            XCTAssertLessThanOrEqual(sample.frame.width, open.width)
            XCTAssertLessThanOrEqual(sample.frame.height, open.height)
            XCTAssertTrue((0...1).contains(sample.content))
            previous = sample.frame
        }
    }

    func testContentWaitsForShellAndReachesExactEndState() {
        let motion = IslandMotion(from: folded, to: open, expansion: 0, content: 0, opening: true, start: 10)
        let early = motion.sample(at: 10 + motion.duration * 0.2)
        XCTAssertGreaterThan(early.frame.height, folded.height)
        XCTAssertEqual(early.content, 0)
        let end = motion.sample(at: 10 + motion.duration + 1)
        XCTAssertEqual(end.frame, open)
        XCTAssertEqual(end.expansion, 1)
        XCTAssertEqual(end.content, 1)
        XCTAssertTrue(end.finished)
    }

    func testCollapseHidesContentBeforeFinishingShell() {
        let motion = IslandMotion(from: open, to: folded, expansion: 1, content: 1, opening: false, start: 0)
        let middle = motion.sample(at: motion.duration * 0.3)
        XCTAssertEqual(middle.content, 0)
        XCTAssertGreaterThan(middle.frame.height, folded.height)
        XCTAssertFalse(middle.finished)
        XCTAssertEqual(motion.sample(at: motion.duration).frame, folded)
    }

    func testRapidReversalContinuesFromDisplayedState() {
        let opening = IslandMotion(from: folded, to: open, expansion: 0, content: 0, opening: true, start: 0)
        let current = opening.sample(at: 0.13)
        let reversing = IslandMotion(from: current.frame, to: folded, expansion: current.expansion,
            content: current.content, opening: false, start: 0.13)
        let first = reversing.sample(at: 0.13)
        XCTAssertEqual(first.frame, current.frame)
        XCTAssertEqual(first.expansion, current.expansion)
        XCTAssertEqual(first.content, current.content)
        XCTAssertEqual(reversing.sample(at: 1).frame, folded)
    }

    func testMidTransitionResizeDoesNotHideVisibleContent() {
        let taller = CGRect(x: open.minX, y: open.minY - 64, width: open.width, height: open.height + 64)
        let motion = IslandMotion(from: open, to: taller, expansion: 1, content: 1, opening: true, start: 0)
        for tick in 0...20 {
            let sample = motion.sample(at: motion.duration * Double(tick) / 20)
            XCTAssertEqual(sample.content, 1)
            XCTAssertEqual(sample.expansion, 1)
            XCTAssertEqual(sample.frame.maxY, open.maxY, accuracy: 0.000001)
        }
    }

    func testShortReversalRemainsBoundedAndFinishesPromptly() {
        let motion = IslandMotion(from: CGRect(x: 550, y: 764, width: 300, height: 36), to: folded,
            expansion: 0.01, content: 0, opening: false, start: 0, distance: 0.01)
        XCTAssertLessThanOrEqual(motion.duration, 0.15)
        XCTAssertEqual(motion.sample(at: -1).frame.height, 36)
        XCTAssertTrue(motion.sample(at: 1).finished)
    }
}
