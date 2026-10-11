import AppKit
import PacerCore
import SwiftUI

/// Style and position are picture tiles; changes apply to the real island at
/// once, so the page needs no preview of its own. Liquid Glass adjustments
/// appear only while Liquid Glass is chosen.
struct SettingsAppearancePane: View {
    @ObservedObject var model: IslandModel
    @Binding var appearance: IslandAppearance
    @Binding var displayMode: IslandDisplayMode
    @Binding var displayID: Int
    @Binding var fullscreen: Bool
    @Binding var glass: IslandGlassSettings

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
        } header: {
            Text(L10n.text("appearance.style"))
        } footer: {
            if collapsedStaysBlack {
                Text(L10n.text("appearance.notch_black")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        if appearance == .liquidGlass, glassAvailable { glassSection }
    }

    // MARK: Liquid Glass

    private var glassSection: some View {
        Section {
            Picker(L10n.text("settings.glass_style"), selection: $glass.style) {
                ForEach(IslandGlassSettings.Style.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent(L10n.text("settings.transparency")) {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { glass.transparency }, set: { glass.transparency = ($0 * 20).rounded() / 20 }), in: 0...1)
                        .accessibilityLabel(L10n.text("settings.transparency"))
                    Text("\(Int((glass.transparency * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            LabeledContent(L10n.text("settings.tint")) {
                HStack(spacing: 12) {
                    ForEach(IslandGlassSettings.Tint.allCases, id: \.rawValue) { tint in
                        Button { glass.tint = tint } label: {
                            Circle().fill(Self.swatch(tint)).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().stroke(glass.tint == tint ? Color.accentColor : .clear, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain).help(tint.label).accessibilityLabel(tint.label)
                        .accessibilityAddTraits(glass.tint == tint ? .isSelected : [])
                    }
                }
            }
            LabeledContent(L10n.text("settings.corner_radius")) {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { glass.cornerRadius }, set: { glass.cornerRadius = $0.rounded() }), in: 12...36)
                        .accessibilityLabel(L10n.text("settings.corner_radius"))
                    Text("\(Int(glass.cornerRadius))").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        } header: {
            HStack {
                Text(L10n.text("settings.liquid_glass"))
                Spacer()
                Button(L10n.text("common.restore_defaults")) { glass = IslandGlassSettings() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    /// The tint itself is a dark wash; the swatch shows its hue at a readable lightness.
    private static func swatch(_ tint: IslandGlassSettings.Tint) -> Color {
        switch tint {
        case .neutral: Color(white: 0.55)
        case .cool: Color(red: 0.42, green: 0.57, blue: 0.78)
        case .warm: Color(red: 0.8, green: 0.6, blue: 0.42)
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
private struct Wallpaper: View {
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
