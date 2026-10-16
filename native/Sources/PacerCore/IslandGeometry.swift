import Foundation
import CoreGraphics

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

    /// Width of the collapsed bar turned on its side: the 20-point activity
    /// badge and the values held to its width keep 6 points on either side.
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
                                 expanded: Bool, panelWidth: CGFloat, contentHeight: CGFloat) -> CGRect {
        let margin: CGFloat = 10
        let strip = stripHeight.isFinite ? max(1, stripHeight) : 1
        let panel = panelWidth.isFinite ? max(0, panelWidth) : 0
        let content = contentHeight.isFinite ? max(0, contentHeight) : 0
        let width = max(1, min(visible.width - 12, expanded ? stripWidth + panel : stripWidth))
        let height = min(max(1, visible.height - 2 * margin), expanded ? max(strip, content) : strip)
        let x = position.side == .right ? visible.maxX - width : visible.minX
        let y = position.isBottom ? visible.minY + margin : visible.maxY - margin - height
        return windowFrame(CGRect(x: x, y: y, width: width, height: height), anchor: position.anchor)
    }
}
