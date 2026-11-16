import AppKit
import PacerCore
import SwiftUI

@MainActor struct ProviderAppIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 22
    var outline = false

    private static let images = load()
    private static let outlines = load(outline: true)

    private static func load(outline: Bool = false) -> [AgentProvider: NSImage] {
        Dictionary(uniqueKeysWithValues: AgentProvider.allCases.compactMap { provider in
            guard let url = ProviderIcon.resource(for: provider, outline: outline), let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = outline
            return (provider, image)
        })
    }

    var body: some View {
        Group {
            if let image = (outline ? Self.outlines : Self.images)[provider] {
                Image(nsImage: image).renderingMode(outline ? .template : .original)
                    .resizable().interpolation(.high).scaledToFit()
            } else if outline {
                Image(systemName: provider.glyph).font(.system(size: size * 0.7, weight: .medium))
            } else {
                Image(systemName: provider.glyph).font(.system(size: size * 0.6, weight: .medium))
                    .foregroundStyle(provider.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
