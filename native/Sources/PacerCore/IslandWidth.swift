import Foundation
import CoreGraphics

/// The island's width always follows its content. Around a hardware notch the
/// collapsed bar keeps equal wings sized by the wider side, so it covers no
/// more of the menu bar than its components need; without a camera gap it is
/// a capsule that fits them. The expanded panel fits its task rows.
public enum IslandWidth {
    /// Expanded bounds. The 404-point minimum keeps the content width of the
    /// earlier 440-point panel now that content aligns 15 points from the
    /// edge, so expanding from a narrower bar widens it less.
    public static let expandedRange: ClosedRange<CGFloat> = 404...680

    /// Hardware-notch headers need equal wings so the camera gap stays centered.
    public static func desired(expanded: Bool, notchWidth: CGFloat, leading: CGFloat,
                               trailing: CGFloat, contentWidth: CGFloat = 0, headerWidth: CGFloat = 0) -> CGFloat {
        let gap = notchWidth.isFinite ? max(0, notchWidth) : 0
        let left = leading.isFinite ? max(0, leading) : 80
        let right = trailing.isFinite ? max(0, trailing) : 65
        let natural = gap > 0 ? gap + 8 + 42 + 2 * max(left, right) : 52 + left + right
        let measured = headerWidth.isFinite ? max(0, headerWidth) : 0
        let hardwareMinimum: CGFloat = measured > 0 ? (gap > 0 ? gap + 60 : 80) : (gap > 0 ? gap + 200 : 180)
        let collapsed = max(hardwareMinimum, ceil(measured > 0 ? measured : natural) + 2)
        guard expanded else { return collapsed }
        let content = contentWidth.isFinite ? max(0, contentWidth) : 0
        let panel = min(expandedRange.upperBound, max(expandedRange.lowerBound, content))
        return max(collapsed, panel)
    }
}
