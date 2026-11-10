import PacerCore
import SwiftUI

/// The island's material, chosen in Appearance: black, graphite, or dark or
/// light Liquid Glass.
enum IslandAppearance: String, CaseIterable {
    case classic
    case liquidGlass
    case liquidGlassLight
    case graphite

    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The saved material. Dark glass needs the system material and falls back
    /// to black; light glass keeps its light face without it.
    static var stored: Self { stored(in: .standard) }
    static func stored(in defaults: UserDefaults) -> Self {
        let saved = defaults.string(forKey: "islandAppearance")
        let selected = saved.flatMap(Self.init(rawValue:)) ?? (supportsLiquidGlass ? .liquidGlass : .classic)
        return selected == .liquidGlass && !supportsLiquidGlass ? .classic : selected
    }

    /// The whole island draws its light tone, collapsed and expanded.
    var isLight: Bool { self == .liquidGlassLight }
    var isGlass: Bool { self == .liquidGlass || self == .liquidGlassLight }
    var label: String {
        switch self {
        case .classic: L10n.text("settings.classic")
        case .liquidGlass: L10n.text("settings.liquid_glass")
        case .liquidGlassLight: L10n.text("settings.liquid_glass_light")
        case .graphite: L10n.text("settings.graphite")
        }
    }
    var info: String { L10n.text("appearance.material_info." + rawValue) }

    static let graphiteFace = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1B / 255)
    static let lightFace = Color(red: 236 / 255, green: 236 / 255, blue: 240 / 255)

    /// The fine edge on the island's free sides, with a highlight along the
    /// top of the dark materials.
    struct Rim: Equatable {
        let ink: Color
        let width: CGFloat
        let highlight: Color?
    }
    func rim(glassVisible: Bool) -> Rim {
        switch self {
        case .liquidGlassLight: Rim(ink: .black.opacity(31 / 255), width: 0.75, highlight: nil)
        case .graphite: Rim(ink: Color(red: 0x30 / 255, green: 0x33 / 255, blue: 0x3A / 255), width: 1, highlight: nil)
        case .liquidGlass where glassVisible: Rim(ink: .white.opacity(66 / 255), width: 0.75, highlight: .white.opacity(46 / 255))
        default: Rim(ink: .white.opacity(38 / 255), width: 0.75, highlight: .white.opacity(20 / 255))
        }
    }
}

/// The sides of the island away from the screen edge; the rim follows only these.
struct IslandFreeSides: OptionSet, Hashable {
    let rawValue: Int
    static let top = Self(rawValue: 1), bottom = Self(rawValue: 2), left = Self(rawValue: 4), right = Self(rawValue: 8)
    static let all: Self = [.top, .bottom, .left, .right]

    init(rawValue: Int) { self.rawValue = rawValue }
    /// An attached or top-docked bar keeps its top against the screen, a
    /// bottom dock its bottom and a side strip its outer side.
    init(attached: Bool, flatEdge: IslandPlacement.Edge?) {
        if attached || flatEdge == .top { self = [.bottom, .left, .right]; return }
        switch flatEdge {
        case .bottom: self = [.top, .left, .right]
        case .left: self = [.top, .bottom, .right]
        case .right: self = [.top, .bottom, .left]
        default: self = .all
        }
    }
}

/// Liquid Glass uses the regular variant, which Apple recommends for text-heavy
/// components over changing backgrounds, without a tint so color keeps its
/// provider and alert meanings. Its clarity follows the system's Liquid Glass
/// look (System Settings → Appearance). Over bright content the glass turns
/// light, so a fixed dark wash keeps the island's light text legible: about
/// 3:1 for secondary text over a white page, more with Increase Contrast.
/// Light glass washes the same material light instead, under dark text.
/// Reduce Transparency shows the solid surface.
struct IslandSurface: ViewModifier {
    let appearance: IslandAppearance
    let attached: Bool
    /// A docked island's corners against the screen edge stay square.
    var flatEdge: IslandPlacement.Edge?
    let expanded: Bool
    var progress: Double?
    /// The collapsed bar's corner radius; the corners grow to 27 as it opens.
    var collapsedRadius: CGFloat = 19
    /// At the notch the collapsed bar is pure black whatever the material, with
    /// no rim, so it reads as one with the camera housing. It fades as the bar
    /// opens.
    var notchBlack: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static func corners(collapsedRadius: CGFloat, fraction: Double, attached: Bool, flatEdge: IslandPlacement.Edge?) -> IslandCorners {
        let corner = collapsedRadius + (27 - collapsedRadius) * fraction
        let top = attached || flatEdge == .top ? 0 : corner, lower = flatEdge == .bottom ? 0 : corner
        let left: CGFloat = flatEdge == .left ? 0 : 1, right: CGFloat = flatEdge == .right ? 0 : 1
        return IslandCorners(topLeft: top * left, topRight: top * right, bottomRight: lower * right, bottomLeft: lower * left)
    }
    private var radii: IslandCorners {
        Self.corners(collapsedRadius: collapsedRadius, fraction: progress ?? (expanded ? 1 : 0), attached: attached, flatEdge: flatEdge)
    }
    private var shape: UnevenRoundedRectangle {
        let corners = radii
        return UnevenRoundedRectangle(topLeadingRadius: corners.topLeft, bottomLeadingRadius: corners.bottomLeft,
            bottomTrailingRadius: corners.bottomRight, topTrailingRadius: corners.topRight)
    }
    private var glassVisible: Bool { appearance.isGlass && !reduceTransparency && IslandAppearance.supportsLiquidGlass }

    func body(content: Content) -> some View {
        let rim = appearance.rim(glassVisible: glassVisible), sides = IslandFreeSides(attached: attached, flatEdge: flatEdge)
        let black = min(1, max(0, notchBlack))
        content.background {
            ZStack {
                material
                shape.fill(Color.black.opacity(black))
            }
        }
            .overlay {
                ZStack {
                    IslandRimShape(corners: radii, sides: sides, inset: rim.width / 2).stroke(rim.ink, lineWidth: rim.width)
                    if let highlight = rim.highlight, sides.contains(.top) {
                        IslandTopHighlight(corners: radii, inset: rim.width + 0.5).stroke(highlight, lineWidth: 1)
                    }
                }
                .opacity(1 - black)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(shape)
    }

    // Keep native glass on a stable background view. Putting it around the
    // conditional content lets teardown of that content rebuild the material.
    @ViewBuilder private var material: some View {
        if glassVisible {
            if #available(macOS 26.0, *) {
                shape.fill(appearance.isLight
                    ? Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255).opacity(contrast == .increased ? 0.85 : 0.62)
                    : Color.black.opacity(contrast == .increased ? 0.75 : 0.55))
                    .glassEffect(.regular, in: shape)
            } else { solid }
        } else { solid }
    }

    /// Pure Black is true black, so the bar meets the hardware notch without a
    /// seam. Light glass without the system material keeps a light face, so its
    /// dark ink stays readable.
    private var solid: some View {
        shape.fill(appearance == .graphite ? IslandAppearance.graphiteFace : appearance.isLight ? IslandAppearance.lightFace : Color.black)
    }
}

struct IslandCorners: Equatable {
    var topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat
}

/// The rounded outline inset by `inset`, along the free sides only. Corners
/// between two free sides are traced; the others end where their side ends.
struct IslandRimShape: Shape {
    var corners: IslandCorners
    var sides: IslandFreeSides
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let d = inset, w = rect.width, h = rect.height
        guard w > 2 * d, h > 2 * d else { return Path() }
        let tl = max(0, corners.topLeft - d), tr = max(0, corners.topRight - d)
        let br = max(0, corners.bottomRight - d), bl = max(0, corners.bottomLeft - d)
        // Each side runs clockwise on screen between its corners' tangent points.
        let edges: [(side: IslandFreeSides, from: CGPoint, to: CGPoint)] = [
            (.top, CGPoint(x: d + tl, y: d), CGPoint(x: w - d - tr, y: d)),
            (.right, CGPoint(x: w - d, y: d + tr), CGPoint(x: w - d, y: h - d - br)),
            (.bottom, CGPoint(x: w - d - br, y: h - d), CGPoint(x: d + bl, y: h - d)),
            (.left, CGPoint(x: d, y: h - d - bl), CGPoint(x: d, y: d + tl)),
        ]
        // The corner after each side: its center, radius and starting angle.
        let after: [(center: CGPoint, radius: CGFloat, start: Double)] = [
            (CGPoint(x: w - d - tr, y: d + tr), tr, -90),
            (CGPoint(x: w - d - br, y: h - d - br), br, 0),
            (CGPoint(x: d + bl, y: h - d - bl), bl, 90),
            (CGPoint(x: d + tl, y: d + tl), tl, 180),
        ]
        var path = Path()
        let all = sides == .all
        // Start after a side that is not drawn, so each run is one continuous line.
        let start = all ? 0 : (edges.firstIndex { !sides.contains($0.side) } ?? 0)
        let first = all ? 0 : (start + 1) % 4
        var open = false
        for step in 0..<4 {
            let index = (first + step) % 4, edge = edges[index]
            guard sides.contains(edge.side) else { open = false; continue }
            if !open { path.move(to: edge.from); open = true }
            path.addLine(to: edge.to)
            let next = edges[(index + 1) % 4]
            guard sides.contains(next.side), all || step < 3 else { continue }
            let corner = after[index]
            if corner.radius > 0 {
                path.addArc(center: corner.center, radius: corner.radius, startAngle: .degrees(corner.start),
                    endAngle: .degrees(corner.start + 90), clockwise: false)
            } else { path.addLine(to: next.from) }
        }
        if all { path.closeSubpath() }
        return path
    }
}

/// A 1-point highlight just inside the top edge of the dark materials.
struct IslandTopHighlight: Shape {
    var corners: IslandCorners
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = max(corners.topLeft, inset), right = rect.width - max(corners.topRight, inset)
        var path = Path()
        guard right > left else { return path }
        path.move(to: CGPoint(x: left, y: inset)); path.addLine(to: CGPoint(x: right, y: inset))
        return path
    }
}
