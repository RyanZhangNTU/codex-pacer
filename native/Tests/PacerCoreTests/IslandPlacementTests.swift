import Foundation
import XCTest
@testable import PacerCore

/// Free Move geometry in AppKit coordinates; it mirrors the Windows
/// IslandPlacementChecks, whose work areas measure y downward.
final class IslandPlacementTests: XCTestCase {
    private let visible = CGRect(x: -960, y: 40, width: 960, height: 722)

    func testSnapEntersWithinSixteenPointsAndHoldsWithinTwentyFour() {
        let nearLeft = CGRect(x: -948, y: 400, width: 160, height: 38)
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: nearLeft, previous: .free), .left, "Enters the snap zone")
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: nearLeft.offsetBy(dx: 9, dy: 0), previous: .left), .left,
            "Small reversals keep the preview")
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: nearLeft.offsetBy(dx: 9, dy: 0), previous: .free), .free,
            "Entering needs sixteen points")
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: nearLeft.offsetBy(dx: 13, dy: 0), previous: .left), .free,
            "Dragging away clears the preview")
        // Twelve points from the left; nine, then one, below the top edge.
        let corner = CGRect(x: -948, y: visible.maxY - 9 - 38, width: 160, height: 38)
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: corner, previous: .left), .left, "Corner jitter is ignored")
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: corner.offsetBy(dx: 0, dy: 8), previous: .left), .top,
            "Moving clearly closer to another edge changes the candidate")
        for (edge, bar) in [(IslandPlacement.Edge.right, CGRect(x: -170, y: 400, width: 160, height: 38)),
                            (.bottom, CGRect(x: -500, y: 50, width: 160, height: 38))] {
            XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: bar, previous: .free), edge)
        }
        XCTAssertEqual(IslandGeometry.snapEdge(visible: visible, bar: CGRect(x: -500, y: 400, width: 160, height: 38), previous: .free), .free)
    }

    func testEachEdgeOpensInwardAndKeepsItsAnchor() {
        for edge in IslandPlacement.Edge.allCases {
            let placement = IslandPlacement(edge: edge, x: 0.68, y: 0.93)
            let bar = placement.vertical ? CGSize(width: 32, height: 126) : CGSize(width: 160, height: 38)
            let closed = IslandGeometry.arrange(placement, visible: visible, barSize: bar, expandedWidth: 460,
                contentHeight: 382, expanded: false)
            let open = IslandGeometry.arrange(placement, visible: visible, barSize: bar, expandedWidth: 460,
                contentHeight: 382, expanded: true)
            XCTAssertEqual(closed.anchor, open.anchor, "\(edge): expansion keeps the chosen anchor")
            XCTAssertEqual(closed.anchor.point(in: closed.frame).y, open.anchor.point(in: open.frame).y, "\(edge)")
            XCTAssertTrue(visible.contains(open.frame), "\(edge): the open island stays clear of the Dock and menu bar")
            XCTAssertEqual(closed.frame.size, bar)
            switch edge {
            case .left: XCTAssertEqual(closed.frame.minX, visible.minX); XCTAssertEqual(open.frame.minX, visible.minX)
            case .right: XCTAssertEqual(closed.frame.maxX, visible.maxX); XCTAssertEqual(open.frame.maxX, visible.maxX)
            case .top:
                XCTAssertFalse(open.opensUp); XCTAssertEqual(closed.frame.maxY, visible.maxY); XCTAssertEqual(open.frame.maxY, visible.maxY)
            case .bottom:
                XCTAssertTrue(open.opensUp); XCTAssertEqual(closed.frame.minY, visible.minY); XCTAssertEqual(open.frame.minY, visible.minY)
            case .free:
                XCTAssertTrue(open.opensUp, "A low floating bar opens upward in place")
                XCTAssertEqual(closed.frame.minY, open.frame.minY)
                XCTAssertEqual(open.anchor.horizontal, .center)
            }
        }
        // High on the screen a free bar opens down; beside a side it opens away from it.
        let high = IslandGeometry.arrange(.init(edge: .free, x: 0.02, y: 0.1), visible: visible, barSize: CGSize(width: 160, height: 38),
            expandedWidth: 460, contentHeight: 382, expanded: true)
        XCTAssertFalse(high.opensUp)
        XCTAssertEqual(high.anchor, .init(horizontal: .left, vertical: .top))
        XCTAssertEqual(high.frame.minX, visible.minX)
    }

    func testATallPanelSlidesInwardInsteadOfBeingClipped() {
        // Mid-screen, neither side has room: the panel keeps its height and moves inside.
        let middle = IslandPlacement(edge: .free, x: 0.5, y: 0.5)
        let bar = CGSize(width: 160, height: 38)
        for content in [600.0, 900.0] {
            let open = IslandGeometry.arrange(middle, visible: visible, barSize: bar, expandedWidth: 460,
                contentHeight: content, expanded: true)
            XCTAssertEqual(open.frame.height, min(38 + content, visible.height), "\(content): not cut to one side's room")
            XCTAssertTrue(visible.contains(open.frame), "\(content)")
        }
        let open = IslandGeometry.arrange(middle, visible: visible, barSize: bar, expandedWidth: 460, contentHeight: 600, expanded: true)
        XCTAssertFalse(open.opensUp, "Equal room on both sides opens down, as before")
        XCTAssertEqual(open.frame.minY, visible.minY, "Opening down, it slides up until it fits")
        // With room on one side nothing moves, and a docked side strip slides the same way.
        let low = IslandGeometry.arrange(.init(edge: .free, x: 0.5, y: 0.9), visible: visible, barSize: bar, expandedWidth: 460,
            contentHeight: 382, expanded: true)
        let closed = IslandGeometry.arrange(.init(edge: .free, x: 0.5, y: 0.9), visible: visible, barSize: bar, expandedWidth: 460,
            contentHeight: 382, expanded: false)
        XCTAssertEqual(low.frame.minY, closed.frame.minY)
        let side = IslandGeometry.arrange(.init(edge: .left, x: 0, y: 0.5), visible: visible, barSize: CGSize(width: 32, height: 126),
            expandedWidth: 492, contentHeight: 1000, expanded: true)
        XCTAssertEqual(side.frame.height, visible.height)
        XCTAssertTrue(visible.contains(side.frame))
    }

    func testAPlacementFollowsTheVisibleFrameOfAnyDisplay() {
        let side = IslandPlacement(edge: .left, x: 0, y: 0.55)
        for secondary in [CGRect(x: -1870, y: 70, width: 1870, height: 1080), CGRect(x: 2560, y: -300, width: 1280, height: 777)] {
            let bar = IslandGeometry.collapsedFrame(side, visible: secondary, size: CGSize(width: 32, height: 126))
            XCTAssertEqual(bar.minX, secondary.minX)
            XCTAssertEqual(bar.midY, secondary.maxY - 0.55 * secondary.height, accuracy: 0.001)
        }
        let dragged = CGRect(x: -700, y: 300, width: 160, height: 38)
        let placement = IslandGeometry.placement(edge: .free, visible: visible, bar: dragged)
        let restored = IslandGeometry.collapsedFrame(placement, visible: visible, size: dragged.size)
        XCTAssertEqual(restored.minX, dragged.minX, accuracy: 0.001, "Saving and restoring a free place returns the same frame")
        XCTAssertEqual(restored.minY, dragged.minY, accuracy: 0.001)
        XCTAssertEqual(IslandGeometry.clamp(CGRect(x: -2000, y: 900, width: 160, height: 38), to: visible),
            CGRect(x: -960, y: visible.maxY - 38, width: 160, height: 38))
        XCTAssertEqual(IslandPosition.corner(side: .right, bottom: true), .bottomRight)
        XCTAssertEqual(IslandPosition.corner(side: .left, bottom: false), .topLeft)
    }

    func testAPlacementSurvivesReloadAndADamagedOneFallsBackToTheOldPosition() throws {
        let name = testDefaultsName("pacer-island-placement-test")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { removeTestDefaults(name) }
        XCTAssertNil(IslandPlacement.load(from: defaults))
        let side = IslandPlacement(edge: .left, x: 0, y: 0.55)
        side.save(to: defaults)
        XCTAssertEqual(IslandPlacement.load(from: defaults), side)
        IslandPosition.bottomRight.save(to: defaults)
        for damaged: [String: Any] in [["edge": "future", "x": 0.0, "y": 1.0], ["edge": "left", "x": -1.0, "y": 1.0], ["edge": "left"]] {
            defaults.set(damaged, forKey: IslandPlacement.defaultsKey)
            XCTAssertNil(IslandPlacement.load(from: defaults))
            XCTAssertEqual(IslandPosition.load(from: defaults), .bottomRight, "Other settings stay as they were")
        }
        side.save(to: defaults)
        IslandPlacement.clear(from: defaults)
        XCTAssertNil(IslandPlacement.load(from: defaults))
    }
}
