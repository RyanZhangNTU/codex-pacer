import Foundation
import CoreGraphics

public enum IslandGeometry {
    public static func frame(screen: CGRect, visible: CGRect, notchWidth: CGFloat,
                             topHeight: CGFloat, expanded: Bool, attached: Bool) -> CGRect {
        let width = min(screen.width - 24, expanded ? max(440, notchWidth + 240) : max(attached ? notchWidth + 240 : 300, 300))
        let top = attached ? screen.maxY : visible.maxY - 10
        let desiredHeight: CGFloat = expanded ? topHeight + 342 : topHeight
        let height = min(desiredHeight, max(topHeight, top - visible.minY - 8))
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}
