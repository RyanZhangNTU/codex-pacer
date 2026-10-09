import SwiftUI
import PacerCore

struct IslandWidthControl: View {
    @ObservedObject var model: IslandModel
    @Binding var settings: IslandWidthSettings
    let layout: CompactIslandLayout
    let attached: Bool
    @State private var naturalWidth: CGFloat = 320
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        let range = IslandWidthSettings.range
        return (settings.normalized.width - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let camera = attached ? model.notchWidth : 0
                let height: CGFloat = 38
                let width = settings.mode == .adaptive ? max(camera > 0 ? camera + 60 : 80, naturalWidth) : max(camera + 60, settings.normalized.width)
                let scale = min(1, (geometry.size.width - 24) / width, 64 / height)
                CompactIslandHeader(model: model, layout: layout, baseHeight: 38, notchWidth: camera, measuresLayout: false)
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: width, height: height)
                .background(UnevenRoundedRectangle(topLeadingRadius: attached ? 0 : 18,
                    bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: attached ? 0 : 18)
                    .fill(.black))
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                .onPreferenceChange(CompactHeaderIdealWidth.self) { naturalWidth = $0 + 2 }
            }
            .frame(height: 72)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("settings.width_preview"))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: settings.width)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: settings.mode)

            if settings.mode == .fixed {
                HStack(spacing: 12) {
                    Text(L10n.text("settings.width_narrow"))
                    Slider(value: $settings.width, in: IslandWidthSettings.range)
                        .accessibilityLabel(L10n.text("settings.width_mode"))
                        .accessibilityValue(L10n.text(fraction < 0.33 ? "settings.width_narrow" :
                            fraction > 0.66 ? "settings.width_wide" : "settings.width_medium"))
                    Text(L10n.text("settings.width_wide"))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
