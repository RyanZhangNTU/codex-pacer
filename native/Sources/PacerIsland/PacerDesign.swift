import SwiftUI
import PacerCore

/// Shared tokens for the island surface. The island is dark, except under
/// Light Liquid Glass, where the neutral inks, the services' shades and every
/// overlay switch to their light tone together. Settings keep system colors;
/// only their island previews follow the island's tone.
enum PacerPalette {
    /// The island draws its light tone. The model sets it whenever settings
    /// apply, before the island redraws.
    static var light = IslandAppearance.stored.isLight
    static var primary: Color { light ? Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255) : Color(white: 0.96) }
    static var secondary: Color { light ? Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.72) : Color(white: 0.62) }
    static var tertiary: Color { light ? Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.47) : Color(white: 0.42) }
    static var hairline: Color { overlay(0.08) }
    static var track: Color { overlay(0.08) }
    static var fill: Color { overlay(0.05) }
    static var hover: Color { overlay(0.08) }
    static var attention: Color { light ? Color(red: 178 / 255, green: 106 / 255, blue: 0) : Color(red: 1.0, green: 0.74, blue: 0.38) }
    static var danger: Color { light ? Color(red: 211 / 255, green: 58 / 255, blue: 47 / 255) : Color(red: 1.0, green: 0.45, blue: 0.42) }
    static var paused: Color { light ? Color(red: 140 / 255, green: 109 / 255, blue: 46 / 255) : Color(red: 0.86, green: 0.77, blue: 0.6) }
    /// A neutral wash over the island: white on the dark tone, black on the light one.
    static func overlay(_ opacity: Double) -> Color { (light ? Color.black : Color.white).opacity(opacity) }
    static func overlayInk(_ opacity: Double) -> NSColor { (light ? NSColor.black : NSColor.white).withAlphaComponent(opacity) }
    /// Marks drawn over arcs, such as the pace tick and the clock hand.
    static var tick: Color { light ? primary : .white }
    static var tickInk: NSColor { light ? NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1) : .white }
    /// The fine outline that keeps a tick apart from the arc under it.
    static var tickEdge: Color { (light ? Color.white : Color.black).opacity(0.45) }
    /// Units beside a value: 60% of the primary ink.
    static var unit: Color { light ? Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.72) : Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.6) }
    /// The island's own opaque face, for previews of it elsewhere.
    static var surface: Color { face(IslandAppearance.stored) }
    static func face(_ appearance: IslandAppearance) -> Color {
        appearance == .graphite ? IslandAppearance.graphiteFace : appearance.isLight ? IslandAppearance.lightFace : .black
    }
}

extension AgentProvider {
    /// The color the service draws in: its own under Multicolor, otherwise a
    /// shade of the chosen accent. On the light island the brand colors take
    /// a darker shade, so each service keeps its contrast.
    var tint: Color { shade(light: PacerPalette.light) }
    /// The service's shade in either tone: for a preview of a material that is
    /// not the current one, and dark-tone for window icons that stay the same
    /// whatever the island's material.
    func shade(light: Bool) -> Color { PacerAccent.current.tint(for: self, light: light) ?? (light ? lightShade : brand) }
    /// The brand color one shade darker, for light glass.
    var lightShade: Color {
        switch self {
        case .codex: Color(red: 14 / 255, green: 140 / 255, blue: 120 / 255)
        case .claude: Color(red: 196 / 255, green: 88 / 255, blue: 31 / 255)
        case .deepseek: Color(red: 62 / 255, green: 91 / 255, blue: 219 / 255)
        }
    }
    /// The service's own color, which its icon keeps whatever the accent.
    var brand: Color {
        switch self {
        case .codex: Color(red: 0.49, green: 0.84, blue: 0.77)
        case .claude: Color(red: 0.95, green: 0.61, blue: 0.42)
        case .deepseek: color
        }
    }
    /// DeepSeek's blue (#7B93FF) reads at the same weight as the other two on black.
    var color: Color { Color(red: 0x7B / 255, green: 0x93 / 255, blue: 0xFF / 255) }
    /// Generic glyph for settings navigation and app buttons; never a vendor logo.
    var glyph: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        case .deepseek: "water.waves"
        }
    }
}

/// The Appearance page's accent color. Multicolor keeps each service's own
/// color and leaves controls to the system accent. A color takes over rings,
/// progress, controls and selection; the services keep apart as three shades
/// of it. Amber and red keep their meanings whatever the choice.
enum PacerAccent: String, CaseIterable, Identifiable {
    case multicolor, blue, purple, pink, red, orange, yellow, green, graphite
    static let defaultsKey = "accentColor"
    /// What drawing reads. The model refreshes it whenever settings apply.
    static var current = PacerAccent(defaults: .standard)

    init(defaults: UserDefaults) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .multicolor
    }
    var id: String { rawValue }
    var label: String { L10n.text("appearance.accent." + rawValue) }
    /// The chosen color in sRGB, or nil for Multicolor.
    var components: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .multicolor: nil
        case .blue: (0x0A / 255, 0x84 / 255, 0xFF / 255)
        case .purple: (0xBF / 255, 0x5A / 255, 0xF2 / 255)
        case .pink: (0xFF / 255, 0x6B / 255, 0xB5 / 255)
        case .red: (0xFF / 255, 0x5A / 255, 0x52 / 255)
        case .orange: (0xFF / 255, 0x9F / 255, 0x0A / 255)
        case .yellow: (0xFF / 255, 0xD6 / 255, 0x0A / 255)
        case .green: (0x32 / 255, 0xD7 / 255, 0x4B / 255)
        case .graphite: (0xA1 / 255, 0xA1 / 255, 0xA6 / 255)
        }
    }
    var color: Color? { components.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } }
    /// Buttons, switches and selection: the system accent under Multicolor.
    var control: Color { color ?? .accentColor }
    /// The services' three shades of the color, strongest first; nil under
    /// Multicolor. On the dark island Codex takes it at full strength and
    /// Claude and DeepSeek lift toward white, so the rings stay apart. On light
    /// glass each is the color scaled to a set luminance instead, so even a
    /// light color such as yellow keeps at least 3.5:1 against the light face.
    func tint(for provider: AgentProvider, light: Bool = false) -> Color? {
        guard let base = light ? lightComponents(for: provider) : components.map({ base in
            let lift = switch provider { case .codex: 0.0; case .claude: 0.42; case .deepseek: 0.66 }
            func lifted(_ value: Double) -> Double { value + (1 - value) * lift }
            return (lifted(base.red), lifted(base.green), lifted(base.blue))
        }) else { return nil }
        return Color(red: base.red, green: base.green, blue: base.blue)
    }
    /// Relative luminance of each service's shade on light glass: Codex 0.07,
    /// Claude 0.12 and DeepSeek 0.20, about 7.4, 5.2 and 3.6:1 against #ECECF0.
    static func lightLuminance(for provider: AgentProvider) -> Double {
        switch provider { case .codex: 0.07; case .claude: 0.12; case .deepseek: 0.2 }
    }
    /// The color's linear light scaled evenly to the service's luminance, which
    /// keeps its hue and saturation.
    func lightComponents(for provider: AgentProvider) -> (red: Double, green: Double, blue: Double)? {
        guard let base = components else { return nil }
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func encoded(_ value: Double) -> Double { value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055 }
        let red = linear(base.red), green = linear(base.green), blue = linear(base.blue)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let scale = luminance > 0 ? Self.lightLuminance(for: provider) / luminance : 0
        return (encoded(min(1, red * scale)), encoded(min(1, green * scale)), encoded(min(1, blue * scale)))
    }
}

/// Pacer's windows in light, dark or the system's appearance. The island
/// follows its own material instead: only Light Liquid Glass turns it light.
enum AppTheme: String, CaseIterable, Identifiable {
    case auto, light, dark
    static let defaultsKey = "appTheme"

    init(defaults: UserDefaults) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto
    }
    var id: String { rawValue }
    var label: String { L10n.text("appearance.theme." + rawValue) }
    var appearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    @MainActor func apply() { NSApp.appearance = appearance }
}

private struct PacerAccentKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The accent for controls and selection in Pacer's windows.
    var pacerAccent: Color {
        get { self[PacerAccentKey.self] }
        set { self[PacerAccentKey.self] = newValue }
    }
}

extension View {
    /// Controls and selection in a window follow the chosen accent.
    func pacerAccent(_ accent: PacerAccent) -> some View {
        environment(\.pacerAccent, accent.control).tint(accent.control)
    }
}

/// For windows that open apart from Settings: reads the saved accent and
/// follows later changes.
struct SavedPacerAccent: ViewModifier {
    @AppStorage(PacerAccent.defaultsKey) private var raw = PacerAccent.multicolor.rawValue
    func body(content: Content) -> some View {
        content.pacerAccent(PacerAccent(rawValue: raw) ?? .multicolor)
    }
}

/// Expanded content aligns with the collapsed header: sections sit `edgeInset`
/// from the island and pad by `rowInset`, so icons, titles and values start on
/// the header's 15-point line while row highlights reach close to the edge.
enum IslandMetrics {
    static let headerInset: CGFloat = 15
    static let edgeInset: CGFloat = 6
    static let rowInset: CGFloat = headerInset - edgeInset
}

/// The existing pace thresholds: below 85% spends faster than time passes,
/// above 115% leaves spare quota for the rest of the window. Only a fast pace
/// is colored: Claude's orange would otherwise resemble the attention amber.
typealias QuotaPaceVerdict = QuotaDashboardPresentation.Verdict

extension QuotaDashboardPresentation.Verdict {
    var tint: Color {
        switch self {
        case .spare: PacerPalette.primary
        case .steady: PacerPalette.secondary
        case .fast: PacerPalette.attention
        }
    }
}

struct QuotaVerdictChip: View {
    let verdict: QuotaPaceVerdict

    var body: some View {
        Text(verdict.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(verdict.tint)
            .padding(.horizontal, 5).frame(height: 15)
            .background(verdict.tint.opacity(0.14), in: Capsule())
    }
}

/// One status language for the expanded rows: an outline symbol in the
/// provider or alert color, with no tile behind it.
struct StatusGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size + 8, height: size + 8)
            .accessibilityHidden(true)
    }
}

struct IslandSectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = PacerPalette.tertiary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        header.background {
            header.fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ExpandedContentIdealWidth.self, value: geometry.size.width)
                })
                .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
                .fixedSize()
            if let detail {
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(detailColor)
                    .monospacedDigit().fixedSize()
            }
            Spacer(minLength: 8)
            trailing().fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 24)
        .padding(.horizontal, IslandMetrics.rowInset)
    }
}

extension IslandSectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color = PacerPalette.tertiary) {
        self.init(title: title, detail: detail, detailColor: detailColor) { EmptyView() }
    }
}

struct IslandIconButton: View {
    let symbol: String
    let title: String
    var help: String?
    var active = false
    /// A provider color stays on at rest; plain controls brighten on hover.
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? (active || hovered ? PacerPalette.primary : PacerPalette.secondary))
                .frame(width: 28, height: 28)
                .background(Circle().fill(active || (hovered && enabled) ? PacerPalette.hover : .clear))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? title).accessibilityLabel(title)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(PacerPalette.hairline).frame(height: 1) }
}
