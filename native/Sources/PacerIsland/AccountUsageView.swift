import SwiftUI
import PacerCore

struct AccountUsageView: View {
    let snapshot: QuotaSnapshot
    let now: Date
    @Binding var showsExpiryDetails: Bool
    private var presentation: QuotaAccountPresentation { .init(snapshot: snapshot, context: "", now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountSummary
            if showsExpiryDetails { expiryDetails }
        }
        .onChange(of: snapshot.accountScope) { _, _ in showsExpiryDetails = false }
    }

    private var accountSummary: some View {
        HStack(spacing: 14) {
            Button { showsExpiryDetails.toggle() } label: {
                HStack(spacing: 6) {
                    Label(presentation.resetText, systemImage: "arrow.counterclockwise")
                    Image(systemName: showsExpiryDetails ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(presentation.expirySoon ? Color.orange : .secondary)
            .help(presentation.expiryDescription)
            .accessibilityLabel(presentation.resetsAccessibility)
            .accessibilityHint(L10n.text(showsExpiryDetails ? "account.hide_expiries" : "account.show_expiries"))
            .accessibilityValue(L10n.text(showsExpiryDetails ? "account.expiries_expanded" : "account.expiries_collapsed"))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Text(presentation.balanceText).foregroundStyle(.primary).monospacedDigit()
                Text(L10n.text("account.credits")).foregroundStyle(.secondary)
            }
            .help(L10n.text("account.credits_help"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.balanceAccessibility)
        }
        .font(.system(size: 13)).lineLimit(1)
        .padding(.vertical, 3)
    }

    private var expiryDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("account.expiry_title")).font(.system(size: 12, weight: .medium))
            if let message = presentation.detailMessage {
                Text(message).foregroundStyle(.secondary)
            } else {
                ForEach(presentation.expiries, id: \.timestamp) { expiry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(expiry.dateText).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(expiry.countText).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(expiry.accessibilityLabel)
                }
                if let text = presentation.nonExpiringText {
                    Text(text).foregroundStyle(.secondary)
                }
                if let text = presentation.unknownText {
                    Text(text).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let text = presentation.timeZoneText {
                    Text(text)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12))
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(PacerPalette.overlay(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
