import SwiftUI
import PacerCore

/// One native button gives the title, chevron and empty space the same action.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("quota.details.disclosure")
            .accessibilityValue(Text(L10n.text(configuration.isExpanded ? "account.expiries_expanded" : "account.expiries_collapsed")))
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }
}
