import AppKit
import PacerCore
import SwiftUI

/// Style, position and screen position are pictures; changes apply to the real
/// island at once, so the page needs no preview of its own. Liquid Glass has no
/// settings of its own: like system glass it follows the look chosen in System
/// Settings, shown as one row rather than footnotes.
struct SettingsAppearancePane: View {
    @ObservedObject var model: IslandModel
    @Binding var appearance: IslandAppearance
    @Binding var displayMode: IslandDisplayMode
    @Binding var position: IslandPosition?
    @Binding var displayID: Int
    @Binding var fullscreen: Bool
    @Binding var quotaStyle: ExpandedQuotaStyle
    /// DeepSeek alone has its own dashboard, where ring styles do not apply;
    /// its Simple or Detailed choice lives in the DeepSeek pane.
    let deepseekAlone: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var glassAvailable: Bool { IslandAppearance.supportsLiquidGlass }
    private var attachesHere: Bool {
        displayMode.layout(safeAreaTop: model.screenNotchSize.height, hardwareNotchWidth: model.screenNotchSize.width).attached
    }
    /// Around the camera the collapsed bar keeps a black backing so it reads as
    /// one shape with the hardware notch; glass shows once it expands.
    private var collapsedStaysBlack: Bool { appearance == .liquidGlass && glassAvailable && attachesHere }
    /// Before a choice, the island attaches only around a notch, so the tile
    /// that matches what the island shows here is the selected one.
    private var customPosition: IslandPosition { .custom(saved: position, attached: attachesHere) }
    var customBinding: Binding<IslandPosition> {
        Binding(get: { customPosition }, set: {
            position = $0
            displayMode = .floating
        })
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                tile(L10n.text("settings.classic"), selected: appearance == .classic) { appearance = .classic } art: {
                    StyleSwatch(glass: false)
                }
                tile(L10n.text("settings.liquid_glass"), selected: appearance == .liquidGlass) { appearance = .liquidGlass } art: {
                    StyleSwatch(glass: true)
                }
                .disabled(!glassAvailable)
                .help(glassAvailable ? "" : L10n.text("settings.glass_requirement"))
            }
            if appearance == .liquidGlass, glassAvailable {
                LabeledContent(L10n.text("appearance.glass_transparency")) {
                    if reduceTransparency {
                        Text(L10n.text("appearance.glass_reduced")).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            Text(L10n.text("appearance.glass_system")).foregroundStyle(.secondary)
                            Button(L10n.text("appearance.glass_adjust")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension")!)
                            }
                        }
                    }
                }
                if collapsedStaysBlack, !reduceTransparency {
                    LabeledContent(L10n.text("appearance.notch_mode")) {
                        Text(L10n.text("appearance.notch_black")).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(L10n.text("appearance.style"))
        }
        if !deepseekAlone {
            Section {
                Picker(L10n.text("appearance.expanded_quota"), selection: $quotaStyle) {
                    ForEach(ExpandedQuotaStyle.allCases) { style in Text(style.label).tag(style) }
                }.pickerStyle(.segmented)
            }
        }
        Section(L10n.text("appearance.position")) {
            HStack(spacing: 10) {
                tile(L10n.text("settings.notch"), selected: attachesHere) { displayMode = .notch } art: {
                    PositionSwatch(kind: .attached)
                }
                tile(L10n.text("settings.custom"), selected: !attachesHere) {
                    customBinding.wrappedValue = customPosition
                } art: {
                    PositionSwatch(kind: .custom(customPosition))
                }
            }
            if !attachesHere {
                LabeledContent {
                    ScreenPositionPicker(selection: customBinding)
                } label: {
                    Text(L10n.text("appearance.screen_position"))
                    Text(L10n.text(customPosition == .center ? "appearance.position_center_note" : "appearance.position_side_note"))
                }
            }
            Picker(L10n.text("settings.display_picker"), selection: $displayID) {
                Text(L10n.text("settings.main_display")).tag(0)
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)
                }
            }
            Toggle(L10n.text("settings.fullscreen"), isOn: $fullscreen)
        }
    }

    // MARK: Tiles

    private func tile<Art: View>(_ title: String, selected: Bool, action: @escaping () -> Void,
                                 @ViewBuilder art: () -> Art) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                art().frame(maxWidth: .infinity).frame(height: 44)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A soft desktop so translucency has something to show through.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.3, blue: 0.47), Color(red: 0.45, green: 0.38, blue: 0.56),
                Color(red: 0.86, green: 0.58, blue: 0.47)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.98, green: 0.78, blue: 0.55)).frame(width: 160).blur(radius: 40).offset(x: 120, y: 30)
            Circle().fill(Color(red: 0.3, green: 0.55, blue: 0.75)).frame(width: 180).blur(radius: 46).offset(x: -150, y: 10)
        }
    }
}

private struct StyleSwatch: View {
    let glass: Bool
    var body: some View {
        ZStack {
            Wallpaper()
            Capsule().fill(glass ? Color.black.opacity(0.3) : Color(red: 0.045, green: 0.047, blue: 0.056))
                .overlay(Capsule().stroke(.white.opacity(glass ? 0.4 : 0.06), lineWidth: 0.5))
                .frame(width: 64, height: 16)
        }
        .frame(width: 112, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A small screen with the five places a floating island can sit: the capsule
/// below the menu bar, and a strip against the side at each corner.
private struct ScreenPositionPicker: View {
    @Binding var selection: IslandPosition
    private static let size = CGSize(width: 168, height: 104)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The wallpaper's glows are wider than the screen; pin it so edge
            // positions are measured from the visible edges.
            Wallpaper().frame(width: Self.size.width, height: Self.size.height)
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: 9)
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 56, height: 8)
                .position(x: Self.size.width / 2, y: Self.size.height - 7)
            ForEach(IslandPosition.allCases, id: \.self) { position in spot(position) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("appearance.screen_position"))
    }

    private func spot(_ position: IslandPosition) -> some View {
        let selected = position == selection
        let inner: CGFloat = 5
        let shape = UnevenRoundedRectangle(topLeadingRadius: position.side == .left ? 0 : inner,
            bottomLeadingRadius: position.side == .left ? 0 : inner,
            bottomTrailingRadius: position.side == .right ? 0 : inner, topTrailingRadius: position.side == .right ? 0 : inner)
        let size = position.side == nil ? CGSize(width: 40, height: 11) : CGSize(width: 11, height: 32)
        let x: CGFloat = switch position.side {
        case nil: Self.size.width / 2
        case .left: size.width / 2
        case .right: Self.size.width - size.width / 2
        }
        let y: CGFloat = position.side == nil ? 19 : position.isBottom ? Self.size.height - 18 - size.height / 2 : 13 + size.height / 2
        return Button { selection = position } label: {
            shape.fill(selected ? Color.black : Color.black.opacity(0.15))
                .overlay(shape.stroke(selected ? Color.accentColor : Color.white.opacity(0.8),
                    style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [3, 2])))
                .frame(width: size.width, height: size.height)
                .padding(5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: x, y: y)
        .help(position.label)
        .accessibilityLabel(position.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A screen's top edge: the bar hangs from it when attached. Custom shows the
/// chosen place: the capsule below the menu bar or a strip at a corner.
private struct PositionSwatch: View {
    enum Kind { case attached, custom(IslandPosition) }
    let kind: Kind
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper().frame(width: 112, height: 40)
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: 9)
            switch kind {
            case .attached:
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(Color.black)
                    .frame(width: 52, height: 12)
            case .custom(let position):
                if let side = position.side {
                    UnevenRoundedRectangle(topLeadingRadius: side == .left ? 0 : 4, bottomLeadingRadius: side == .left ? 0 : 4,
                        bottomTrailingRadius: side == .right ? 0 : 4, topTrailingRadius: side == .right ? 0 : 4)
                        .fill(Color.black).frame(width: 8, height: 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: Alignment(horizontal: side == .left ? .leading : .trailing, vertical: position.isBottom ? .bottom : .top))
                        .padding(.top, 12).padding(.bottom, 3)
                } else {
                    Capsule().fill(Color.black).frame(width: 52, height: 11).padding(.top, 14)
                }
            }
        }
        .frame(width: 112, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}
