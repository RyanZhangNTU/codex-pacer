import AppKit
import PacerCore
import SwiftUI

/// Theme, material and accent are pictures and swatches, as in the system's
/// own Appearance settings, and position shows each mode moving. Changes reach
/// the island and Pacer's windows at once, so the page needs no preview of
/// its own. Liquid Glass follows the look chosen in System Settings.
struct SettingsAppearancePane: View {
    @ObservedObject var model: IslandModel
    @Binding var theme: AppTheme
    @Binding var appearance: IslandAppearance
    @Binding var accent: PacerAccent
    @Binding var barSize: CompactBarSize
    @Binding var displayMode: IslandDisplayMode
    @Binding var position: IslandPosition?
    @Binding var displayID: Int
    @Binding var fullscreen: Bool
    @Binding var positionPerDisplay: Bool
    @Binding var quotaStyle: ExpandedQuotaStyle
    @Binding var deepseekPanelStyle: DeepSeekPanelStyle
    @Binding var showsAppButtons: Bool
    /// DeepSeek alone has its own dashboard, where ring styles do not apply,
    /// so the expanded panel offers its Simple or Detailed choice instead.
    let deepseekAlone: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pacerAccent) private var controlAccent
    private var glassAvailable: Bool { IslandAppearance.supportsLiquidGlass }
    private var layout: IslandDisplayMode.Layout {
        displayMode.layout(safeAreaTop: model.screenNotchSize.height, hardwareNotchWidth: model.screenNotchSize.width, size: barSize)
    }
    private var attachesHere: Bool { layout.attached }
    /// At a hardware notch the collapsed bar is black whatever the material, so
    /// it reads as one shape with the camera housing; glass shows once it opens.
    private var collapsedStaysBlack: Bool { appearance.isGlass && glassAvailable && layout.atHardwareNotch }
    /// Before a choice, the island attaches only around a notch, so the tile
    /// that matches what the island shows here is the selected one.
    private var customPosition: IslandPosition { .custom(saved: position, attached: attachesHere) }
    /// Reread after each drag; Settings does not hold the dragged place itself.
    private var placement: IslandPlacement? {
        _ = model.placementRevision
        return IslandPlacement.load(from: model.defaults)
    }
    var customBinding: Binding<IslandPosition> {
        Binding(get: { customPosition }, set: {
            position = $0
            displayMode = .floating
        })
    }
    /// The swatches follow the choice at once, before the island applies it,
    /// each in its own tone.
    private func ringTint(light: Bool) -> Color { accent.tint(for: .codex, light: light) ?? (light ? AgentProvider.codex.lightShade : AgentProvider.codex.brand) }

    var body: some View {
        MainCard(title: L10n.text("appearance.theme")) {
            HStack(spacing: 10) {
                ForEach(AppTheme.allCases) { option in
                    tile(option.label, selected: theme == option) { theme = option } art: { ThemeSwatch(theme: option, accent: controlAccent) }
                }
            }
            .padding(.vertical, 6)
        }
        MainCard(title: L10n.text("appearance.material")) {
            // Opaque materials above, glass below.
            VStack(spacing: 10) {
                HStack(spacing: 10) { material(.classic); material(.graphite) }
                HStack(spacing: 10) { material(.liquidGlass); material(.liquidGlassLight) }
            }
            .padding(.vertical, 6)
            if appearance.isGlass, glassAvailable {
                CardRow(title: L10n.text("appearance.glass_transparency"),
                        info: collapsedStaysBlack && !reduceTransparency ? L10n.text("appearance.glass_notch_info") : nil) {
                    if reduceTransparency {
                        Text(L10n.text("appearance.glass_reduced")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("appearance.glass_system")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Button(L10n.text("appearance.glass_adjust")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension")!)
                        }.buttonStyle(.main)
                    }
                }
            }
        }
        MainCard {
            CardRow(title: L10n.text("appearance.bar_size"),
                    detail: layout.sizeAdjustable ? nil : L10n.text("appearance.bar_size_notch"),
                    info: L10n.text("appearance.bar_size_info")) {
                MainSegmented(options: CompactBarSize.allCases.map { ($0, $0.label) },
                              selection: Binding(get: { layout.sizeAdjustable ? barSize : .standard }, set: { barSize = $0 }),
                              label: L10n.text("appearance.bar_size"))
                    .disabled(!layout.sizeAdjustable)
            }
        }
        MainCard {
            CardRow(title: L10n.text("appearance.accent"), info: L10n.text("appearance.accent_info")) {
                AccentPicker(selection: $accent)
            }
        }
        MainCard(title: L10n.text("appearance.position"), titleTrailing: currentDisplay) {
            HStack(alignment: .top, spacing: 10) {
                tile(L10n.text("settings.notch"), selected: attachesHere, artHeight: nil) { displayMode = .notch } art: {
                    ModeScene { WelcomeHoverScene(width: $0) }
                }
                tile(L10n.text("appearance.free_move"), selected: !attachesHere, artHeight: nil) {
                    customBinding.wrappedValue = customPosition
                } art: {
                    ModeScene { WelcomeDragScene(width: $0) }
                }
            }
            .padding(.vertical, 6)
            if !attachesHere {
                CardRow(title: L10n.text("appearance.free_move_detail")) {
                    Button(L10n.text("appearance.position_reset")) { model.resetIslandPlacement() }
                        .buttonStyle(.main).disabled(placement == nil && customPosition == .center)
                }
            }
            CardPicker(title: L10n.text("settings.display_picker"), selection: $displayID,
                       options: [(0, L10n.text("settings.main_display"))] + NSScreen.screens.map { screen in
                           ((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0, screen.localizedName)
                       })
            CardToggle(title: L10n.text("appearance.position_per_display"), info: L10n.text("appearance.position_per_display_info"),
                       isOn: $positionPerDisplay)
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

    /// While each display keeps its own place, the card names the display
    /// whose place it shows.
    private var currentDisplay: AnyView? {
        guard positionPerDisplay, NSScreen.screens.count > 1, let name = model.currentDisplayName else { return nil }
        return AnyView(Text(L10n.text("appearance.position_display", name)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle))
    }

    // MARK: Tiles

    /// A material tile; its description shows on hover. Dark glass needs the
    /// system material, light glass keeps a light face without it.
    private func material(_ option: IslandAppearance) -> some View {
        let unavailable = option == .liquidGlass && !glassAvailable
        return tile(option.label, selected: appearance == option) { appearance = option } art: {
            StyleSwatch(material: option, ring: ringTint(light: option.isLight))
        }
        .disabled(unavailable)
        .help(unavailable ? L10n.text("settings.glass_requirement") : option.info)
    }

    /// A picture choice. A nil art height lets the picture size itself, as the
    /// moving position scenes do.
    private func tile<Art: View>(_ title: String, selected: Bool, artHeight: CGFloat? = 64, action: @escaping () -> Void,
                                 @ViewBuilder art: () -> Art) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                art().frame(maxWidth: .infinity).frame(height: artHeight)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MainPalette.fill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? controlAccent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The welcome guide's mode scenes, scaled to the tile's width.
private struct ModeScene<Scene: View>: View {
    @ViewBuilder let scene: (CGFloat) -> Scene

    var body: some View {
        Color.clear.aspectRatio(528 / 352, contentMode: .fit)
            .overlay(GeometryReader { scene($0.size.width) })
            .frame(maxWidth: 240)
    }
}

/// Apple's accent row: Multicolor first, then the colors. The chosen one
/// carries a ring and a white dot, and its name shows underneath.
private struct AccentPicker: View {
    @Binding var selection: PacerAccent

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(PacerAccent.allCases) { option in
                    Button { selection = option } label: { AccentDot(accent: option, selected: selection == option) }
                        .buttonStyle(.plain)
                        .help(option.label)
                        .accessibilityLabel(option.label)
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            Text(selection.label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("appearance.accent"))
    }
}

private struct AccentDot: View {
    let accent: PacerAccent
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
            if selected {
                Circle().strokeBorder(accent.color ?? Color.secondary, lineWidth: 1.5).frame(width: 25, height: 25)
                Circle().fill(Color.white).frame(width: 6, height: 6).shadow(color: .black.opacity(0.35), radius: 1)
            }
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }

    /// Multicolor shows the three services' own colors.
    private var fill: AnyShapeStyle {
        if let color = accent.color { return AnyShapeStyle(color) }
        let colors = AgentProvider.allCases.map(\.brand)
        let stops = colors.enumerated().flatMap { index, color in
            [Gradient.Stop(color: color, location: Double(index) / Double(colors.count)),
             Gradient.Stop(color: color, location: Double(index + 1) / Double(colors.count))]
        }
        return AnyShapeStyle(AngularGradient(stops: stops, center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
    }
}

/// A window in each theme, as the system draws its appearance choices; Auto
/// splits it light and dark.
private struct ThemeSwatch: View {
    let theme: AppTheme
    let accent: Color

    var body: some View {
        Group {
            switch theme {
            case .auto: window(dark: false).overlay(window(dark: true).mask(LowerRightHalf()))
            case .light: window(dark: false)
            case .dark: window(dark: true)
            }
        }
        .frame(width: 100, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .accessibilityHidden(true)
    }

    private func window(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(white: dark ? 0.18 : 0.88)).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color(white: dark ? 0.36 : 0.76)).frame(width: 40, height: 5)
                Capsule().fill(Color(white: dark ? 0.27 : 0.85)).frame(width: 52, height: 5)
                Capsule().fill(accent).frame(width: 22, height: 8)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(white: dark ? 0.12 : 0.97))
    }
}

private struct LowerRightHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
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

/// The island over a desktop in each material: black, graphite, or dark or
/// light glass the wallpaper shows through, with its own rim and ink.
private struct StyleSwatch: View {
    let material: IslandAppearance
    let ring: Color

    private var look: (fill: Color, edge: Color, width: CGFloat) {
        switch material {
        case .liquidGlass: (.black.opacity(0.3), .white.opacity(0.4), 0.5)
        case .liquidGlassLight: (Color(red: 248 / 255, green: 248 / 255, blue: 250 / 255).opacity(0.84), .black.opacity(31 / 255), 0.75)
        case .graphite: (IslandAppearance.graphiteFace, Color(red: 0x30 / 255, green: 0x33 / 255, blue: 0x3A / 255), 1)
        case .classic: (.black, .white.opacity(38 / 255), 0.75)
        }
    }

    var body: some View {
        let look = look
        return ZStack {
            Wallpaper()
            HStack {
                Capsule().fill((material.isLight ? Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255) : .white).opacity(0.75))
                    .frame(width: 20, height: 4)
                Spacer(minLength: 0)
                Circle().strokeBorder(ring, lineWidth: 2).frame(width: 10, height: 10)
            }
            .padding(.horizontal, 9)
            .frame(width: 86, height: 22)
            .background(Capsule().fill(look.fill))
            .overlay(Capsule().strokeBorder(look.edge, lineWidth: look.width))
        }
        .frame(width: 132, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}
