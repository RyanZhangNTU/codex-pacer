import Foundation
import CoreGraphics

public enum IslandGeometry {
    /// AppKit can round a fractional panel frame outward. An asymptotic spring
    /// then stays one point too large until its exact final sample. Quantize
    /// before setFrame, keeping both horizontal edges symmetric and the top fixed.
    public static func windowFrame(_ frame: CGRect) -> CGRect {
        let center = (frame.midX * 2).rounded() / 2
        let left = (center - frame.width / 2).rounded()
        let width = max(1, (center - left) * 2)
        let height = max(1, frame.height.rounded())
        return CGRect(x: left, y: frame.maxY.rounded() - height, width: width, height: height)
    }

    public static func frame(screen: CGRect, visible: CGRect, notchWidth: CGFloat,
                             topHeight: CGFloat, expanded: Bool, attached: Bool, contentHeight: CGFloat = 342) -> CGRect {
        let width = min(screen.width - 24, expanded ? max(440, notchWidth + 240) : max(attached ? notchWidth + 240 : 300, 300))
        let top = attached ? screen.maxY : visible.maxY - 10
        let desiredHeight: CGFloat = expanded ? topHeight + max(0, contentHeight) : topHeight
        let height = min(desiredHeight, max(topHeight, top - visible.minY - 8))
        // Animate to a representable window frame, not a rounding boundary.
        // For an odd notch width, approaching the ideal width from above can
        // otherwise round to the opposite side until the exact final sample.
        return windowFrame(CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height))
    }
}
