import SwiftUI
import PacerCore

struct AccountUsageView: View {
    let snapshot: QuotaSnapshot
    let now: Date
    @Binding var showsExpiryDetails: Bool
    private var summary: QuotaResetSummary? { snapshot.resetCredits }
    private var count: Int? { summary?.remainingCount(at: now, capturedAt: snapshot.capturedAt) }
    private var expiry: Date? { summary?.nextExpiry(at: now) }
    private var expirySoon: Bool { expiry.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false }
    private var details: QuotaResetExpiryDetails? { summary?.expiryDetails(at: now, capturedAt: snapshot.capturedAt) }

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
                    Label(count.map { L10n.text("account.reset_count", $0) } ?? L10n.text("account.resets_unknown"), systemImage: "arrow.counterclockwise")
                    Image(systemName: showsExpiryDetails ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(expirySoon ? Color.orange : .secondary)
            .help(expiryDescription)
            .accessibilityLabel(L10n.text("account.resets_accessibility", count.map(String.init) ?? L10n.text("common.unknown"), expiryDescription))
            .accessibilityHint(L10n.text(showsExpiryDetails ? "account.hide_expiries" : "account.show_expiries"))
            .accessibilityValue(L10n.text(showsExpiryDetails ? "account.expiries_expanded" : "account.expiries_collapsed"))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Text(balanceText).foregroundStyle(.primary).monospacedDigit()
                Text(L10n.text("account.credits")).foregroundStyle(.secondary)
            }
            .help(L10n.text("account.credits_help"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("account.credit_balance", balanceText))
        }
        .font(.system(size: 13)).lineLimit(1)
        .padding(.vertical, 3)
    }

    private var expiryDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("account.expiry_title")).font(.system(size: 12, weight: .medium))
            if count == 0 {
                Text(L10n.text("account.no_resets")).foregroundStyle(.secondary)
            } else if let details {
                ForEach(details.expiries) { expiry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(L10n.date(expiry.date, time: .standard)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(L10n.text("chart.expiry_count", expiry.count)).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("chart.expiry_item", expiry.count, L10n.date(expiry.date, time: .standard)))
                }
                if details.nonExpiringCount > 0 {
                    Text(L10n.text("account.non_expiring_count", details.nonExpiringCount)).foregroundStyle(.secondary)
                }
                if details.unknownCount > 0 {
                    Text(L10n.text("account.unknown_expiry_count", details.unknownCount)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !details.expiries.isEmpty {
                    Text(L10n.text("account.expiry_timezone", TimeZone.current.identifier))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.text("account.expiry_unknown")).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private var expiryDescription: String {
        if count == 0 { return L10n.text("account.no_resets") }
        if let expiry {
            return L10n.text(summary?.hasCompleteDetails == false ? "account.known_expiry" : "account.next_expiry",
                L10n.date(expiry, date: .complete))
        }
        return summary?.hasNoExpiringCredits(at: now) == true ? L10n.text("account.no_expiry") : L10n.text("account.expiry_unknown")
    }
    private var balanceText: String {
        guard let credits = snapshot.credits else { return "—" }
        if credits.unlimited { return L10n.text("common.unlimited") }
        guard let amount = credits.amount else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = L10n.locale
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }
}
