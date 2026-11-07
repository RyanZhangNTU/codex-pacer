import AppKit
import PacerCore
import SwiftUI

/// Style and position are pictures; changes apply to the real island at once,
/// so the page needs no preview of its own. Free Move places the island by
/// dragging it, so the page only explains that and offers a way back. Liquid Glass has no
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
    @Binding var deepseekPanelStyle: DeepSeekPanelStyle
    @Binding var showsAppButtons: Bool
    /// DeepSeek alone has its own dashboard, where ring styles do not apply,
    /// so the expanded panel offers its Simple or Detailed choice instead.
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
    /// Reread after each drag; Settings does not hold the dragged place itself.
    private var placement: IslandPlacement? {
        _ = model.placementRevision
        return IslandPlacement.load(from: model.defaults)
    }
    /// The tile shows a strip for a side dock, otherwise the bar.
    private var swatchPosition: IslandPosition {
        guard let placement else { return customPosition }
        guard placement.vertical else { return .center }
        return .corner(side: placement.edge == .left ? .left : .right, bottom: placement.y > 0.5)
    }
    var customBinding: Binding<IslandPosition> {
        Binding(get: { customPosition }, set: {
            position = $0
            displayMode = .floating
        })
    }

    var body: some View {
        MainCard(title: L10n.text("appearance.style")) {
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
            .padding(.vertical, 6)
            if appearance == .liquidGlass, glassAvailable {
                CardRow(title: L10n.text("appearance.glass_transparency")) {
                    if reduceTransparency {
                        Text(L10n.text("appearance.glass_reduced")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("appearance.glass_system")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Button(L10n.text("appearance.glass_adjust")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension")!)
                        }.buttonStyle(.main)
                    }
                }
                if collapsedStaysBlack, !reduceTransparency {
                    CardRow(title: L10n.text("appearance.notch_mode")) {
                        Text(L10n.text("appearance.notch_black")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        MainCard(title: L10n.text("appearance.position")) {
            HStack(spacing: 10) {
                tile(L10n.text("settings.notch"), selected: attachesHere) { displayMode = .notch } art: {
                    PositionSwatch(kind: .attached)
                }
                tile(L10n.text("appearance.free_move"), selected: !attachesHere) {
                    customBinding.wrappedValue = customPosition
                } art: {
                    PositionSwatch(kind: .custom(swatchPosition))
                }
            }
            .padding(.vertical, 6)
            if !attachesHere {
                CardRow(title: L10n.text("appearance.free_move_detail")) {
                    Button(L10n.text("appearance.position_reset")) { model.resetIslandPlacement() }
                        .buttonStyle(.main).disabled(placement == nil && customPosition == .center)
                }
            }
            CardPicker(title: L10n.text("settings.display_picker"), selection: $displayID) {
                Text(L10n.text("settings.main_display")).tag(0)
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)
                }
            }
            CardToggle(title: L10n.text("settings.fullscreen"), isOn: $fullscreen)
        }
        MainCard(title: L10n.text("main.appearance.panel")) {
            if deepseekAlone {
                CardRow(title: L10n.text("main.appearance.deepseek_panel")) {
                    MainSegmented(options: [DeepSeekPanelStyle.simple, .detailed].map { ($0, $0.label) }, selection: $deepseekPanelStyle,
                                  label: L10n.text("main.appearance.deepseek_panel"))
                }
            } else {
                CardRow(title: L10n.text("main.appearance.quota_style")) {
                    MainSegmented(options: ExpandedQuotaStyle.allCases.map { ($0, $0.label) }, selection: $quotaStyle,
                                  label: L10n.text("main.appearance.quota_style"))
                }
            }
            CardToggle(title: L10n.text("settings.app_buttons"), info: L10n.text("main.info.app_buttons"), isOn: $showsAppButtons)
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
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MainPalette.fill))
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

/// A screen's top edge: the bar hangs from it when attached. Free Move shows
/// the bar below the menu bar, or a strip when it is docked at a side.
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
