import SwiftUI
import PacerCore

/// Shared tokens for the always-dark island surface. Settings keep system colors.
enum PacerPalette {
    static let primary = Color(white: 0.96)
    static let secondary = Color(white: 0.62)
    static let tertiary = Color(white: 0.42)
    static let hairline = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.05)
    static let hover = Color.white.opacity(0.08)
    static let attention = Color(red: 1.0, green: 0.74, blue: 0.38)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)
    static let paused = Color(red: 0.86, green: 0.77, blue: 0.6)
}

extension AgentProvider {
    var tint: Color {
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
