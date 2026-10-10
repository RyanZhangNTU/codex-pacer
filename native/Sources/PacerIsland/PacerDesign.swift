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
        self == .codex ? Color(red: 0.49, green: 0.84, blue: 0.77) : Color(red: 0.95, green: 0.61, blue: 0.42)
    }
    /// Generic glyph for settings navigation; never a vendor logo.
    var glyph: String { self == .codex ? "chevron.left.forwardslash.chevron.right" : "asterisk" }
}

/// One status language for rows and the collapsed bar: a tinted tile carries
/// color and shape, so the text beside it can stay quiet.
struct StatusTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: Self.tileSymbol(symbol))
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    /// A tile already encloses the glyph; drop a redundant outer circle.
    static func tileSymbol(_ name: String) -> String {
        name.hasSuffix(".circle") ? String(name.dropLast(".circle".count)) : name
    }
}

struct IslandSectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = PacerPalette.tertiary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(PacerPalette.secondary)
            if let detail {
                Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(detailColor)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(height: 26)
        .padding(.horizontal, 10)
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
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active || hovered ? PacerPalette.primary : PacerPalette.secondary)
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

/// Compact segmented control matching the island's quiet surfaces.
struct IslandSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let label: (Value) -> String
    let accessibilityLabel: (Value) -> String
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { onSelect(option) } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? PacerPalette.primary : PacerPalette.secondary)
                        .frame(minWidth: 30).padding(.horizontal, 4).frame(height: 20)
                        .background(selected ? Color.white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(option))
                .accessibilityValue(L10n.text(selected ? "provider.selected" : "provider.not_selected"))
            }
        }
        .padding(2)
        .background(PacerPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(PacerPalette.hairline).frame(height: 1) }
}
