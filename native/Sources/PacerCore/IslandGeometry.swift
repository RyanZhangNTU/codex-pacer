import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum IslandGeometry {
    /// The point of the island that stays put while it opens and closes. The
    /// centered bar keeps its top center; a docked strip keeps its screen-side
    /// corner. AppKit coordinates: `top` is the frame's maxY.
    public struct Anchor: Equatable, Sendable {
        public enum Horizontal: Sendable { case left, center, right }
        public enum Vertical: Sendable { case top, bottom }
        public var horizontal: Horizontal
        public var vertical: Vertical

        public init(horizontal: Horizontal, vertical: Vertical) {
            self.horizontal = horizontal
            self.vertical = vertical
        }

        public static let topCenter = Self(horizontal: .center, vertical: .top)

        public func point(in frame: CGRect) -> CGPoint {
            CGPoint(x: horizontal == .left ? frame.minX : horizontal == .right ? frame.maxX : frame.midX,
                    y: vertical == .top ? frame.maxY : frame.minY)
        }

        public func frame(at point: CGPoint, size: CGSize) -> CGRect {
            CGRect(x: horizontal == .left ? point.x : horizontal == .right ? point.x - size.width : point.x - size.width / 2,
                   y: vertical == .top ? point.y - size.height : point.y, width: size.width, height: size.height)
        }
    }

    /// Width of the standard collapsed bar turned on its side: the 22-point
    /// activity badge keeps 5 points on either side. Other sizes scale it
    /// through `CompactBarMetrics.stripWidth`.
    public static let stripWidth: CGFloat = 32

    /// AppKit can round a fractional panel frame outward. An asymptotic spring
    /// then stays one point too large until its exact final sample. Quantize
    /// before setFrame, keeping the anchored edges fixed: a centered frame keeps
    /// both horizontal edges symmetric, a docked one its screen-side edge.
    public static func windowFrame(_ frame: CGRect, anchor: Anchor = .topCenter) -> CGRect {
        let height = max(1, frame.height.rounded())
        let y = anchor.vertical == .top ? frame.maxY.rounded() - height : frame.minY.rounded()
        switch anchor.horizontal {
        case .center:
            let center = (frame.midX * 2).rounded() / 2
            let left = (center - frame.width / 2).rounded()
            return CGRect(x: left, y: y, width: max(1, (center - left) * 2), height: height)
        case .left:
            return CGRect(x: frame.minX.rounded(), y: y, width: max(1, frame.width.rounded()), height: height)
        case .right:
            let width = max(1, frame.width.rounded())
            return CGRect(x: frame.maxX.rounded() - width, y: y, width: width, height: height)
        }
    }

    public static func frame(screen: CGRect, visible: CGRect, notchWidth: CGFloat,
                             topHeight: CGFloat, expanded: Bool, attached: Bool, contentHeight: CGFloat = 342,
                             desiredWidth: CGFloat? = nil) -> CGRect {
        let legacyWidth: CGFloat = attached ? max(480, notchWidth + 300) : expanded ? 440 : 300
        let requestedWidth = desiredWidth.flatMap { $0.isFinite ? max(1, $0) : nil } ?? legacyWidth
        let width = max(1, min(screen.width - 24, requestedWidth))
        let top = attached ? screen.maxY : visible.maxY - 10
        let desiredHeight: CGFloat = expanded ? topHeight + max(0, contentHeight) : topHeight
        let height = min(desiredHeight, max(topHeight, top - visible.minY - 8))
        // Animate to a representable window frame, not a rounding boundary.
        // For an odd notch width, approaching the ideal width from above can
        // otherwise round to the opposite side until the exact final sample.
        return windowFrame(CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height))
    }

    /// A docked strip, or the strip with its panel beside it. The long edge lies
    /// on the visible frame's side, so a side Dock stays uncovered; the panel
    /// opens toward the screen's center and away from the 10-point top or
    /// bottom margin. `position` must have a side.
    public static func sideFrame(visible: CGRect, position: IslandPosition, stripHeight: CGFloat,
                                 expanded: Bool, panelWidth: CGFloat, contentHeight: CGFloat,
                                 stripWidth: CGFloat = IslandGeometry.stripWidth) -> CGRect {
        let margin: CGFloat = 10
        let stripWidth = stripWidth.isFinite ? max(1, stripWidth) : IslandGeometry.stripWidth
        let strip = stripHeight.isFinite ? max(1, stripHeight) : 1
        let panel = panelWidth.isFinite ? max(0, panelWidth) : 0
        let content = contentHeight.isFinite ? max(0, contentHeight) : 0
        let width = max(1, min(visible.width - 12, expanded ? stripWidth + panel : stripWidth))
        let height = min(max(1, visible.height - 2 * margin), expanded ? max(strip, content) : strip)
        let x = position.side == .right ? visible.maxX - width : visible.minX
        let y = position.isBottom ? visible.minY + margin : visible.maxY - margin - height
        return windowFrame(CGRect(x: x, y: y, width: width, height: height), anchor: position.anchor)
    }

    // MARK: Free Move

    /// A dragged bar snaps to an edge it comes within 16 points of and keeps
    /// it within 24 points, so small reversals and corner jitter keep the preview.
    public static let snapEntry: CGFloat = 16, snapHold: CGFloat = 24

    public static func snapEdge(visible: CGRect, bar: CGRect, previous: IslandPlacement.Edge) -> IslandPlacement.Edge {
        let distances: [(edge: IslandPlacement.Edge, distance: CGFloat)] = [
            (.left, max(0, bar.minX - visible.minX)), (.right, max(0, visible.maxX - bar.maxX)),
            (.top, max(0, visible.maxY - bar.maxY)), (.bottom, max(0, bar.minY - visible.minY))
        ]
        guard let nearest = distances.min(by: { $0.distance < $1.distance }) else { return .free }
        if previous != .free, let held = distances.first(where: { $0.edge == previous })?.distance,
           held <= snapHold, nearest.distance > snapEntry || held <= nearest.distance + 4 { return previous }
        return nearest.distance <= snapEntry ? nearest.edge : .free
    }

    public static func placement(edge: IslandPlacement.Edge, visible: CGRect, bar: CGRect) -> IslandPlacement {
        func fraction(_ offset: CGFloat, _ length: CGFloat) -> Double { length > 0 ? Double(min(1, max(0, offset / length))) : 0.5 }
        return IslandPlacement(edge: edge, x: fraction(bar.midX - visible.minX, visible.width),
            y: fraction(visible.maxY - bar.midY, visible.height))
    }

    /// Keeps a frame inside the visible frame, shrinking it only when it is larger.
    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(visible.width, frame.width), height = min(visible.height, frame.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }

    public static func collapsedFrame(_ placement: IslandPlacement, visible: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        let center = CGPoint(x: visible.minX + CGFloat(placement.x) * visible.width,
            y: visible.maxY - CGFloat(placement.y) * visible.height)
        var bar = clamp(CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), to: visible)
        switch placement.edge {
        case .left: bar.origin.x = visible.minX
        case .right: bar.origin.x = visible.maxX - width
        case .top: bar.origin.y = visible.maxY - height
        case .bottom: bar.origin.y = visible.minY
        case .free: break
        }
        return bar
    }

    public struct Arrangement: Equatable, Sendable {
        public var frame: CGRect
        /// The same for the closed and the open island, so it opens in place.
        public var anchor: Anchor
        public var opensUp: Bool
    }

    /// The island at a placement. It opens toward the room it has: up from a
    /// bottom dock or a low bar, down from a top dock, inward from a side, and
    /// beside a free bar that is too close to a side to open around its center.
    /// A strip's panel sits beside it (`contentHeight` is the panel's height);
    /// a bar's panel sits below or above it (`contentHeight` excludes the bar).
    public static func arrange(_ placement: IslandPlacement, visible: CGRect, barSize: CGSize, expandedWidth: CGFloat,
                               contentHeight: CGFloat, expanded: Bool) -> Arrangement {
        let bar = collapsedFrame(placement, visible: visible, size: barSize)
        let content = contentHeight.isFinite ? max(0, contentHeight) : 0
        let below = bar.maxY - visible.minY, above = visible.maxY - bar.minY
        let full = placement.vertical ? max(bar.height, content) : bar.height + content
        let up = placement.edge == .bottom || (placement.edge != .top && below < full && above > below)
        // A bar placed mid-screen can have too little room on both sides; the
        // open panel then slides inward to fit the visible area, not clipped.
        let height = min(full, visible.height)
        let minY = min(max(up ? bar.minY : bar.maxY - height, visible.minY), visible.maxY - height)
        var width = min(expandedWidth.isFinite ? max(bar.width, expandedWidth) : bar.width, visible.width)
        let left = placement.edge == .left || (!placement.vertical && bar.midX - width / 2 < visible.minX)
        let right = placement.edge == .right || (!placement.vertical && bar.midX + width / 2 > visible.maxX)
        if left { width = min(width, visible.maxX - bar.minX) }
        if right { width = min(width, bar.maxX - visible.minX) }
        let panel = CGRect(x: left ? bar.minX : right ? bar.maxX - width : bar.midX - width / 2,
            y: minY, width: width, height: height)
        let anchor = Anchor(horizontal: left ? .left : right ? .right : .center, vertical: up ? .bottom : .top)
        return Arrangement(frame: windowFrame(expanded ? panel : bar, anchor: anchor), anchor: anchor, opensUp: up)
    }
}
