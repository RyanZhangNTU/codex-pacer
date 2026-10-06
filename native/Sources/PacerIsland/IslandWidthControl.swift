import SwiftUI
import PacerCore

struct IslandWidthControl: View {
    @Binding var settings: IslandWidthSettings
    let attached: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        let range = IslandWidthSettings.range
        return (settings.normalized.width - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let scale = settings.mode == .adaptive ? 0.65 : 0.55 + fraction * 0.4
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid").foregroundStyle(Color(red: 0.56, green: 0.84, blue: 0.79))
                    Text("Codex Pacer").fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text("43%").monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .frame(width: geometry.size.width * scale, height: 36)
                .background(UnevenRoundedRectangle(topLeadingRadius: attached ? 0 : 18,
                    bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: attached ? 0 : 18)
                    .fill(.black))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
