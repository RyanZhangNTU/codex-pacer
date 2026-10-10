import SwiftUI
import PacerCore

struct IslandWidthControl: View {
    @ObservedObject var model: IslandModel
    @Binding var settings: IslandWidthSettings
    let layout: CompactIslandLayout
    let attached: Bool
    var quotaPreview: CompactQuotaPreview? = nil
    @State private var naturalWidth: CGFloat = 320
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasNotch: Bool {
        model.screenNotchSize.width.isFinite && model.screenNotchSize.height.isFinite &&
            model.screenNotchSize.width > 0 && model.screenNotchSize.height > 0
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let camera = attached && hasNotch ? model.screenNotchSize.width : 0
                let height: CGFloat = attached && hasNotch ? max(32, model.screenNotchSize.height) : 38
                let width = settings.mode == .adaptive ? max(camera > 0 ? camera + 60 : 80, naturalWidth) : max(camera + 60, settings.normalized.width)
                let previewWidth = max(width, hasNotch ? model.screenNotchSize.width : 0)
                let scale = min(1, max(1, geometry.size.width - 24) / previewWidth, 64 / height)
                VStack(spacing: 8) {
                    if hasNotch && !attached {
                        notchMarker.frame(width: model.screenNotchSize.width, height: model.screenNotchSize.height)
                    }
                    CompactIslandHeader(model: model, layout: layout, baseHeight: height, notchWidth: camera,
                        measuresLayout: false, quotaPreview: quotaPreview)
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: width, height: height)
                        .background(UnevenRoundedRectangle(topLeadingRadius: attached ? 0 : 18,
                            bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: attached ? 0 : 18)
                            .fill(.black))
                        .overlay(alignment: .top) {
                            if hasNotch && attached {
                                notchMarker.frame(width: camera, height: model.screenNotchSize.height)
                            }
                        }
                }
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                .onPreferenceChange(CompactHeaderIdealWidth.self) { naturalWidth = $0 + 2 }
            }
            .frame(height: hasNotch && !attached ? 104 : 76)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(hasNotch ? "settings.width_preview_notch" : "settings.width_preview"))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: settings.width)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: settings.mode)

            if hasNotch && !attached {
                Text(L10n.text("settings.width_notch_floating_help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var notchMarker: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8,
            bottomTrailingRadius: 8, topTrailingRadius: 0)
        return Label(L10n.text("settings.width_notch_marker"), systemImage: "camera.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.18), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .accessibilityHidden(true)
    }
}
