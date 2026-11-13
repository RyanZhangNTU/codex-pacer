import AppKit
import PacerCore
import SwiftUI

/// The light and dark colors a page library draws its tiles in.
enum LibraryPalette {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
    static let placedFill = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: rgb(242, 242, 245))
    static let freeFill = dynamic(dark: NSColor(white: 1, alpha: 0.04), light: .white)
    static let border = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.1))
    static let placedInk = dynamic(dark: rgb(245, 245, 247), light: rgb(29, 29, 31))
    static let freeInk = dynamic(dark: rgb(152, 152, 157), light: rgb(110, 110, 115))
    static let freeIcon = dynamic(dark: rgb(142, 142, 147), light: rgb(142, 142, 147))
    static let buttonRing = dynamic(dark: NSColor(white: 1, alpha: 0.28), light: NSColor(white: 0, alpha: 0.22))
    static let buttonFace = dynamic(dark: .clear, light: .white)
    /// A placed tile's button under the pointer: neutral, for Remove.
    static let removeFill = dynamic(dark: rgb(142, 142, 147), light: rgb(110, 110, 115))
    static let lockedFill = dynamic(dark: rgb(72, 72, 74), light: rgb(199, 199, 204))
    static let lockedInk = dynamic(dark: rgb(152, 152, 157), light: .white)
    static let noteFill = dynamic(dark: rgb(255, 159, 10, 0.16), light: rgb(255, 244, 229))
    static let noteInk = dynamic(dark: rgb(255, 189, 97), light: rgb(138, 75, 0))
    static let lockNoteFill = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: rgb(242, 242, 245))
}

/// One component or block in a page's library. Clicking the tile selects it;
/// the round button at its end adds or removes it and leaves the selection.
struct LibraryTile: View {
    @Environment(\.pacerAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let symbol: String
    let placed: Bool
    let selected: Bool
    /// The icon's color while placed; the label's ink otherwise.
    var tint: Color? = nil
    var provider: AgentProvider? = nil
    /// The service is off or unavailable: still selectable, drawn faint.
    var faint = false
    /// The last block a panel keeps: its button cannot remove it.
    var locked = false
    /// A trailing label in place of the button, for what always shows.
    var always: String? = nil
    /// Read for the button: add or remove, naming the tile.
    var addLabel = ""
    var removeLabel = ""
    var lockedHelp: String? = nil
    let select: () -> Void
    var toggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Group {
                        if let provider {
                            ProviderAppIcon(provider: provider, size: 14)
                        } else {
                            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                                .foregroundStyle(placed ? tint ?? LibraryPalette.placedInk : LibraryPalette.freeIcon)
                        }
                    }.frame(width: 16)
                    Text(label).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(placed ? LibraryPalette.placedInk : LibraryPalette.freeInk)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let always {
                Text(always).font(.system(size: 11)).foregroundStyle(LibraryPalette.freeIcon).lineLimit(1)
                    .padding(.trailing, 11)
            } else {
                roundButton
            }
        }
        .frame(height: 34)
        .background(placed ? LibraryPalette.placedFill : LibraryPalette.freeFill, in: shape)
        .overlay(shape.strokeBorder(selected ? accent : LibraryPalette.border, lineWidth: selected ? 1.5 : 1))
        .opacity(faint ? 0.55 : 1)
    }

    /// Hollow ＋ to add; an accent ✓ once added, which turns into a neutral
    /// − under the pointer; gray and still when the tile cannot be removed.
    private var roundButton: some View {
        let hover = hovering && !locked
        let fill: Color = locked ? LibraryPalette.lockedFill : placed ? (hover ? LibraryPalette.removeFill : accent)
            : hover ? accent.opacity(0.14) : LibraryPalette.buttonFace
        let ink: Color = locked ? LibraryPalette.lockedInk : placed ? .white : hover ? accent : LibraryPalette.freeInk
        let glyph = placed ? (hover ? "minus" : "checkmark") : "plus"
        return Button(action: toggle) {
            Image(systemName: glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(ink)
                .frame(width: 24, height: 24)
                .background(fill, in: Circle())
                .overlay(Circle().strokeBorder(placed ? .clear : hover ? accent : LibraryPalette.buttonRing, lineWidth: 1))
                .padding(.trailing, 5)
                .frame(width: 38, height: 34, alignment: .trailing)
                .contentShape(Rectangle())
        }
        // Plain buttons fade when disabled; the locked gray is already drawn.
        .buttonStyle(RoundButtonStyle())
        .disabled(locked)
        .onHover { inside in
            if reduceMotion { hovering = inside } else { withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        }
        .help(locked ? lockedHelp ?? "" : placed ? removeLabel : addLabel)
        .accessibilityLabel(placed ? removeLabel : addLabel)
        .accessibilityHint(locked ? lockedHelp ?? "" : "")
    }
}

private struct RoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A short state line above an inspector's options: not added yet, or kept
/// because it is the last block.
struct LibraryNote: View {
    let text: String
    var neutral = false

    var body: some View {
        Text(text).font(.system(size: 12))
            .foregroundStyle(neutral ? LibraryPalette.freeInk : LibraryPalette.noteInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(neutral ? LibraryPalette.lockNoteFill : LibraryPalette.noteFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
