import SwiftUI
import PacerCore

/// One native button gives the title, chevron and empty space the same action.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(isExpanded: configuration.$isExpanded, label: configuration.label, buttonStyle: .plain)
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }

    func header<Label: View, Style: PrimitiveButtonStyle>(isExpanded: Binding<Bool>, label: Label, buttonStyle: Style) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12).accessibilityHidden(true)
                label
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(buttonStyle)
        .accessibilityIdentifier("quota.details.disclosure")
        .accessibilityValue(Text(L10n.text(isExpanded.wrappedValue ? "account.expiries_expanded" : "account.expiries_collapsed")))
    }
}
