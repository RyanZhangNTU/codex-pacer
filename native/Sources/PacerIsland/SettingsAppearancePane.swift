import AppKit
import PacerCore
import SwiftUI

/// Style and position are picture tiles; changes apply to the real island at
/// once, so the page needs no preview of its own. Liquid Glass has no settings
/// of its own: like system glass it follows the look chosen in System Settings,
/// shown as one row rather than footnotes.
struct SettingsAppearancePane: View {
    @ObservedObject var model: IslandModel
    @Binding var appearance: IslandAppearance
    @Binding var displayMode: IslandDisplayMode
    @Binding var displayID: Int
    @Binding var fullscreen: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var glassAvailable: Bool { IslandAppearance.supportsLiquidGlass }
    /// Around the camera the collapsed bar keeps a black backing so it reads as
    /// one shape with the hardware notch; glass shows once it expands.
    private var collapsedStaysBlack: Bool {
        appearance == .liquidGlass && glassAvailable &&
            displayMode.layout(safeAreaTop: model.screenNotchSize.height, hardwareNotchWidth: model.screenNotchSize.width).attached
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
        Section(L10n.text("appearance.position")) {
            HStack(spacing: 10) {
                tile(L10n.text("settings.automatic"), selected: displayMode == .automatic) { displayMode = .automatic } art: {
                    PositionSwatch(kind: .automatic)
                }
                tile(L10n.text("settings.notch"), selected: displayMode == .notch) { displayMode = .notch } art: {
                    PositionSwatch(kind: .attached)
                }
                tile(L10n.text("settings.floating"), selected: displayMode == .floating) { displayMode = .floating } art: {
                    PositionSwatch(kind: .floating)
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

/// A screen's top edge: the bar hangs from it when attached and floats
/// below the menu bar otherwise.
private struct PositionSwatch: View {
    enum Kind { case automatic, attached, floating }
    let kind: Kind
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: 9)
            switch kind {
            case .attached:
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(Color.black)
                    .frame(width: 52, height: 12)
            case .floating:
                Capsule().fill(Color.black).frame(width: 52, height: 11).padding(.top, 14)
            case .automatic:
                Image(systemName: "wand.and.stars").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    .frame(maxHeight: .infinity).padding(.top, 9)
            }
        }
        .frame(width: 112, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}
