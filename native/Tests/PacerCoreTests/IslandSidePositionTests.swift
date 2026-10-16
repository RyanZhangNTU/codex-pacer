import XCTest
@testable import PacerCore

final class IslandSidePositionTests: XCTestCase {
    private let corners: [IslandPosition] = [.topLeft, .bottomLeft, .topRight, .bottomRight]

    func testPositionDefaultsToTheOriginalCenterAndIgnoresUnknownValues() throws {
        let name = "pacer-island-position-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(IslandPosition.saved(in: defaults))
        XCTAssertEqual(IslandPosition.load(from: defaults), .center)
        for position in IslandPosition.allCases {
            position.save(to: defaults)
            XCTAssertEqual(IslandPosition.saved(in: defaults), position)
            XCTAssertEqual(IslandPosition.load(from: defaults), position)
        }
        defaults.set("bottomCenter", forKey: IslandPosition.defaultsKey)
        XCTAssertNil(IslandPosition.saved(in: defaults))
        XCTAssertEqual(IslandPosition.load(from: defaults), .center)
        XCTAssertEqual(IslandPosition.center.anchor, .topCenter)
        XCTAssertNil(IslandPosition.center.side)
        XCTAssertEqual(corners.map(\.side), [.left, .left, .right, .right])
        XCTAssertEqual(corners.map(\.isBottom), [false, true, false, true])
    }

    func testCustomStartsAtBottomLeftOnlyWhenLeavingTheNotch() {
        // A floating island that never chose (earlier Floating, or Automatic
        // without a notch) keeps its center capsule; a saved choice always wins.
        XCTAssertEqual(IslandPosition.custom(saved: nil, attached: true), .bottomLeft)
        XCTAssertEqual(IslandPosition.custom(saved: nil, attached: false), .center)
        for position in IslandPosition.allCases {
            XCTAssertEqual(IslandPosition.custom(saved: position, attached: true), position)
            XCTAssertEqual(IslandPosition.custom(saved: position, attached: false), position)
        }
    }

    func testStripLeavesOutOnlyTheWordComponents() {
        let hidden = CompactIslandLayout.Component.allCases.filter { !$0.showsInStrip }
        XCTAssertEqual(hidden, [.status, .quotaLabel])
    }

    func testStripLiesOnTheVisibleSideWithTenPointMarginsOnAnyDisplay() {
        for scale in [1.0, 2.0] {
            let screen = CGRect(x: -1920 / scale, y: -120, width: 1920 / scale, height: 1080 / scale)
            // Dock at the bottom, left and right: the strip stays beside it.
            let visibles = [
                CGRect(x: screen.minX, y: screen.minY + 64, width: screen.width, height: screen.height - 64 - 24),
                CGRect(x: screen.minX + 70, y: screen.minY, width: screen.width - 70, height: screen.height - 24),
                CGRect(x: screen.minX, y: screen.minY, width: screen.width - 70, height: screen.height - 24),
            ]
            for visible in visibles {
                for position in corners {
                    let closed = IslandGeometry.sideFrame(visible: visible, position: position, stripHeight: 131.4,
                        expanded: false, panelWidth: 440, contentHeight: 520)
                    let open = IslandGeometry.sideFrame(visible: visible, position: position, stripHeight: 131.4,
                        expanded: true, panelWidth: 440, contentHeight: 520)
                    XCTAssertEqual(closed.size, CGSize(width: IslandGeometry.stripWidth, height: 131))
                    XCTAssertEqual(open.size, CGSize(width: IslandGeometry.stripWidth + 440, height: min(520, visible.height - 20)))
                    for frame in [closed, open] {
                        if position.side == .left { XCTAssertEqual(frame.minX, visible.minX) }
                        else { XCTAssertEqual(frame.maxX, visible.maxX) }
                        if position.isBottom { XCTAssertEqual(frame.minY, visible.minY + 10) }
                        else { XCTAssertEqual(frame.maxY, visible.maxY - 10) }
                        XCTAssertTrue(visible.contains(frame))
                        for edge in [frame.minX, frame.minY, frame.maxX, frame.maxY] {
                            XCTAssertEqual(edge, edge.rounded())
                        }
                    }
                    XCTAssertEqual(position.anchor.point(in: closed), position.anchor.point(in: open))
                }
            }
        }
    }

    func testSmallDisplayClampsThePanelAndATallStripKeepsItsHeight() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
        let open = IslandGeometry.sideFrame(visible: visible, position: .bottomRight, stripHeight: 120,
            expanded: true, panelWidth: 680, contentHeight: 640)
        XCTAssertEqual(open, CGRect(x: 12, y: 10, width: 388, height: 280))
        let tallStrip = IslandGeometry.sideFrame(visible: CGRect(x: 0, y: 0, width: 1440, height: 875),
            position: .topLeft, stripHeight: 300, expanded: true, panelWidth: 404, contentHeight: 250)
        XCTAssertEqual(tallStrip.height, 300)
    }

    func testRoundingKeepsTheScreenSideCornerFixed() {
        for position in corners {
            let anchor = position.anchor
            let corner = CGPoint(x: position.side == .left ? -1440 : 1512, y: position.isBottom ? 40 : 942)
            for step in 0...300 {
                let size = CGSize(width: 40 + Double(step) * 1.37, height: 131 + Double(step) * 1.61)
                let displayed = IslandGeometry.windowFrame(anchor.frame(at: corner, size: size), anchor: anchor)
                XCTAssertEqual(anchor.point(in: displayed), corner)
                for edge in [displayed.minX, displayed.maxX, displayed.minY, displayed.maxY] {
                    XCTAssertEqual(edge, edge.rounded())
                }
                XCTAssertLessThanOrEqual(abs(displayed.width - size.width), 0.5)
                XCTAssertLessThanOrEqual(abs(displayed.height - size.height), 0.5)
            }
        }
    }

    func testDockedSpringKeepsItsCornerThroughReversalAndFinishesWithoutAResize() {
        let visible = CGRect(x: 0, y: 64, width: 1512, height: 918)
        for position in corners {
            let anchor = position.anchor
            let closed = IslandGeometry.sideFrame(visible: visible, position: position, stripHeight: 131,
                expanded: false, panelWidth: 452, contentHeight: 548)
            let open = IslandGeometry.sideFrame(visible: visible, position: position, stripHeight: 131,
                expanded: true, panelWidth: 452, contentHeight: 548)
            let corner = anchor.point(in: closed)
            for refreshRate in [30.0, 60.0, 120.0] {
                // Open, reverse at 0.1 s, and fold back to the strip.
                let opening = IslandMotion(from: .resting(at: closed, expanded: false), to: open, opening: true,
                                           anchor: anchor, start: 0)
                let reversal = 0.1
                let closing = IslandMotion(from: opening.sample(at: reversal), to: closed, opening: false,
                                           anchor: anchor, start: reversal)
                var previous = closed
                var finished = false
                for tick in 1...Int(refreshRate * 1.4) {
                    let time = Double(tick) / refreshRate
                    let sample = time < reversal ? opening.sample(at: time) : closing.sample(at: time)
                    let displayed = IslandGeometry.windowFrame(sample.frame, anchor: anchor)
                    XCTAssertEqual(anchor.point(in: displayed), corner, "\(position) at \(time)")
                    XCTAssertTrue(visible.contains(displayed))
                    if sample.finished {
                        XCTAssertEqual(previous, closed, "Final tick changed size: \(position) at \(refreshRate) Hz")
                        finished = true
                        break
                    }
                    previous = displayed
                }
                XCTAssertTrue(finished)
            }
        }
    }

    func testTransitionWithASideAnchorFoldsWithoutTheNotchBacking() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let closed = IslandGeometry.sideFrame(visible: visible, position: .bottomLeft, stripHeight: 131,
            expanded: false, panelWidth: 440, contentHeight: 500)
        let open = IslandGeometry.sideFrame(visible: visible, position: .bottomLeft, stripHeight: 131,
            expanded: true, panelWidth: 440, contentHeight: 500)
        var transition = IslandTransition(from: .resting(at: open, expanded: true, hasBlackHeader: false), to: closed,
                                          opening: false, hasBlackHeader: false, anchor: IslandPosition.bottomLeft.anchor, start: 0)
        XCTAssertEqual(transition.anchor, IslandPosition.bottomLeft.anchor)
        let sample = transition.sample(at: 2)
        XCTAssertTrue(sample.finished)
        XCTAssertEqual(sample.frame, closed)
        XCTAssertEqual(sample.blackOpacity, 0)
    }
}
